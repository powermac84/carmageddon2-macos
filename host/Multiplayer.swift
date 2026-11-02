// SPDX-License-Identifier: GPL-3.0-or-later
// Native LAN relay for Carmageddon II's IPX-over-WebSocket runtime.
import AppKit
import Foundation
import Network
import CryptoKit
import Darwin

final class C2LANRelay {
    private final class Peer {
        let id = UUID()
        let connection: NWConnection
        var buffer = Data()
        var joined = false
        var room = ""
        var node = ""
        var nodeBytes = Data()
        var fragmentOpcode: UInt8?
        var fragment = Data()
        var pendingBytes = 0
        var closed = false
        var closing = false
        init(_ connection: NWConnection) { self.connection = connection }
    }
    let port: UInt16
    private let queue = DispatchQueue(label: "org.carmageddon2.lan-relay")
    private var listener: NWListener?
    private var peers: [UUID:Peer] = [:]
    private var rooms: [String:[String:Peer]] = [:]
    private let maxPacket = 4096
    private let maxRooms = 32
    private let maxPlayers = 16
    var onStatus: ((String) -> Void)?

    init(port: UInt16 = 8080) { self.port = port }
    func start(completion: @escaping (Error?) -> Void) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("0.0.0.0"), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        var completed = false
        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if !completed { completed = true; DispatchQueue.main.async { completion(nil) } }
                self.status()
            case .failed(let error):
                if !completed { completed = true; DispatchQueue.main.async { completion(error) } }
                self.stop()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { connection.cancel(); return }
            guard self.peers.count < 256 else { connection.cancel(); return }
            let peer = Peer(connection)
            self.peers[peer.id] = peer
            connection.stateUpdateHandler = { [weak self, weak peer] state in
                guard let self = self, let peer = peer else { return }
                switch state {
                case .failed, .cancelled: self.close(peer)
                default: break
                }
            }
            connection.start(queue: self.queue)
            self.receive(peer)
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self, weak peer] in
                if let peer = peer, !peer.joined { self?.close(peer) }
            }
        }
        listener.start(queue: queue)
    }
    func stop() {
        queue.async {
            self.listener?.cancel(); self.listener = nil
            for peer in Array(self.peers.values) { self.close(peer) }
            self.rooms.removeAll()
            self.status()
        }
    }
    private func status() {
        let count = rooms.values.reduce(0) { $0 + $1.count }
        let text = listener == nil ? "LAN relay stopped" : "LAN relay on port \(port) · \(count) connected player(s)"
        DispatchQueue.main.async { [weak self] in self?.onStatus?(text) }
    }
    private func receive(_ peer: Peer) {
        guard !peer.closed, !peer.closing else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak peer] data, _, complete, error in
            guard let self = self, let peer = peer, !peer.closed else { return }
            if let data = data { peer.buffer.append(data) }
            if !peer.joined {
                guard peer.buffer.count <= 16384 else { self.close(peer); return }
                if let end = peer.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let header = peer.buffer.subdata(in: 0..<end.upperBound)
                    peer.buffer = Data(peer.buffer.dropFirst(end.upperBound))
                    guard self.upgrade(peer, header: header) else { return }
                }
            }
            if peer.joined { self.parseFrames(peer) }
            if complete || error != nil { self.close(peer) }
            else { self.receive(peer) }
        }
    }
    private func upgrade(_ peer: Peer, header: Data) -> Bool {
        func reject(_ status: String) -> Bool {
            let response = Data("HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
            peer.connection.send(content: response, completion: .contentProcessed { [weak self, weak peer] _ in
                if let peer = peer { self?.close(peer) }
            })
            return false
        }
        guard let text = String(data: header, encoding: .utf8) else { return reject("400 Bad Request") }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1",
              let url = URLComponents(string: "http://relay" + String(first[1])), url.path == "/net" else { return reject("404 Not Found") }
        var headers: [String:String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return reject("400 Bad Request") }
            let key = String(line[..<colon]).lowercased()
            guard headers[key] == nil else { return reject("400 Bad Request") }
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
              headers["sec-websocket-version"] == "13", let key = headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else { return reject("400 Bad Request") }
        let query = url.queryItems ?? []
        let room = String((query.first { $0.name == "room" }?.value ?? "lan").prefix(64))
        let node = (query.first { $0.name == "node" }?.value ?? "").lowercased()
        guard node.count == 12, node != "ffffffffffff", node.allSatisfy({ "0123456789abcdef".contains($0) }), !room.isEmpty else { return reject("400 Bad Request") }
        guard rooms[room] != nil || rooms.count < maxRooms else { return reject("503 Service Unavailable") }
        guard rooms[room]?[node] != nil || (rooms[room]?.count ?? 0) < maxPlayers else { return reject("503 Service Unavailable") }
        if let old = rooms[room]?[node] { close(old) }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        peer.connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self, weak peer] error in
            if error != nil, let peer = peer { self?.close(peer) }
        })
        peer.joined = true; peer.room = room; peer.node = node
        var i = node.startIndex
        for _ in 0..<6 { let end = node.index(i, offsetBy: 2); peer.nodeBytes.append(UInt8(node[i..<end], radix: 16)!); i = end }
        rooms[room, default: [:]][node] = peer
        announce(room); status()
        return true
    }
    private func parseFrames(_ peer: Peer) {
        while !peer.closed && !peer.closing {
            guard peer.buffer.count >= 2 else { return }
            let bytes = [UInt8](peer.buffer)
            let fin = bytes[0] & 0x80 != 0, opcode = bytes[0] & 15
            guard bytes[0] & 0x70 == 0, bytes[1] & 0x80 != 0 else { protocolClose(peer); return }
            var length = UInt64(bytes[1] & 0x7f), offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return }
                length = UInt64(bytes[2]) << 8 | UInt64(bytes[3]); offset = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { return }
                length = 0
                for byte in bytes[2..<10] { length = (length << 8) | UInt64(byte) }
                offset = 10
            }
            guard length <= UInt64(maxPacket) else { protocolClose(peer, code: 1009); return }
            if opcode >= 8 && (!fin || length > 125) { protocolClose(peer); return }
            let count = Int(length)
            guard bytes.count >= offset + 4 + count else { return }
            let mask = Array(bytes[offset..<(offset+4)])
            var payload = Data(capacity: count)
            for j in 0..<count { payload.append(bytes[offset+4+j] ^ mask[j & 3]) }
            peer.buffer = Data(peer.buffer.dropFirst(offset + 4 + count))
            switch opcode {
            case 8:
                if payload.count == 1 { protocolClose(peer); return }
                if payload.count >= 2 {
                    let code = UInt16(payload[0]) << 8 | UInt16(payload[1])
                    guard (1000...4999).contains(code), ![1004,1005,1006,1015].contains(code), String(data: payload.dropFirst(2), encoding: .utf8) != nil else { protocolClose(peer); return }
                }
                peer.closing = true
                send(peer, opcode: 8, payload: payload) { [weak self, weak peer] in if let peer = peer { self?.close(peer) } }
                return
            case 9: send(peer, opcode: 10, payload: payload)
            case 10: break
            case 0:
                guard let originalOpcode = peer.fragmentOpcode, peer.fragment.count + count <= maxPacket else { protocolClose(peer); return }
                peer.fragment.append(payload)
                if fin {
                    let message = peer.fragment; peer.fragment = Data(); peer.fragmentOpcode = nil
                    if originalOpcode == 2 { forward(peer, payload: message) }
                }
            case 1, 2:
                guard peer.fragmentOpcode == nil else { protocolClose(peer); return }
                if fin { if opcode == 2 { forward(peer, payload: payload) } }
                else { peer.fragmentOpcode = opcode; peer.fragment = payload }
            default: protocolClose(peer); return
            }
        }
    }
    private func forward(_ source: Peer, payload: Data) {
        guard payload.count >= 6 else { return }
        let destination = payload.prefix(6).map { String(format: "%02x", $0) }.joined()
        var output = source.nodeBytes; output.append(payload.dropFirst(6))
        if destination == "ffffffffffff" {
            for peer in rooms[source.room]?.values ?? Dictionary<String,Peer>().values where peer !== source { send(peer, opcode: 2, payload: output) }
        } else if let peer = rooms[source.room]?[destination], peer !== source {
            send(peer, opcode: 2, payload: output)
        }
    }
    private func announce(_ room: String) {
        guard let members = rooms[room] else { return }
        let message = Data("peers \(members.count)".utf8)
        for peer in members.values { send(peer, opcode: 1, payload: message) }
    }
    private func send(_ peer: Peer, opcode: UInt8, payload: Data, completion: (() -> Void)? = nil) {
        guard !peer.closed, peer.pendingBytes + payload.count < 1_048_576 else { close(peer); return }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(UInt8(payload.count)) }
        else { frame.append(126); frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 255)) }
        frame.append(payload); peer.pendingBytes += frame.count
        let size = frame.count
        peer.connection.send(content: frame, completion: .contentProcessed { [weak self, weak peer] error in
            guard let self = self, let peer = peer else { return }
            peer.pendingBytes = max(0, peer.pendingBytes - size)
            if error != nil { self.close(peer) }
            completion?()
        })
    }
    private func protocolClose(_ peer: Peer, code: UInt16 = 1002) {
        peer.closing = true
        send(peer, opcode: 8, payload: Data([UInt8(code >> 8), UInt8(code & 255)])) { [weak self, weak peer] in if let peer = peer { self?.close(peer) } }
        queue.asyncAfter(deadline: .now() + 1) { [weak self, weak peer] in if let peer = peer { self?.close(peer) } }
    }
    private func close(_ peer: Peer) {
        guard !peer.closed else { return }
        peer.closed = true; peer.connection.cancel(); peers.removeValue(forKey: peer.id)
        if rooms[peer.room]?[peer.node] === peer {
            rooms[peer.room]?.removeValue(forKey: peer.node)
            if rooms[peer.room]?.isEmpty == true { rooms.removeValue(forKey: peer.room) }
            announce(peer.room); status()
        }
    }
}

/// Owns native multiplayer settings and an explicitly started local relay.
final class MultiplayerController: NSObject {
    private let preferences: UserDefaults
    private let changeHandler: () -> Void
    private var relay: C2LANRelay?
    private var statusItem: NSMenuItem?
    private var stopItem: NSMenuItem?
    private(set) var statusText = "LAN relay stopped"
    init(preferences: UserDefaults, changeHandler: @escaping () -> Void) {
        self.preferences = preferences; self.changeHandler = changeHandler
        super.init()
    }
    var relayAddress: String { preferences.string(forKey: "MultiplayerRelay") ?? "" }
    var room: String { preferences.string(forKey: "MultiplayerRoom") ?? "lan" }
    var computerName: String { preferences.string(forKey: "MultiplayerName") ?? "Carmageddon II" }
    func queryItems() -> [URLQueryItem] {
        guard let address = Self.validatedAddress(relayAddress) else { return [] }
        return [URLQueryItem(name: "relay", value: address), URLQueryItem(name: "room", value: room), URLQueryItem(name: "name", value: computerName)]
    }
    var contentSecurityPolicyConnectSources: String {
        guard let valid = Self.validatedAddress(relayAddress), let url = URLComponents(string: valid), let scheme = url.scheme, let host = url.host,
              ["ws", "wss"].contains(scheme), !host.isEmpty else { return "'self'" }
        let escapedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "'self' \(scheme)://\(escapedHost)\(url.port.map { ":\($0)" } ?? "")"
    }
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Multiplayer")
        func add(_ title: String, _ action: Selector) { let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self }
        add("Host a LAN Session…", #selector(hostLAN))
        add("Connect to a Relay…", #selector(connect))
        add("Connection Settings…", #selector(settings))
        menu.addItem(.separator())
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: ""); status.isEnabled = false; menu.addItem(status); statusItem = status
        add("Show LAN Addresses…", #selector(showAddresses))
        let stop = menu.addItem(withTitle: "Stop LAN Relay", action: #selector(stopRelay), keyEquivalent: ""); stop.target = self; stop.isEnabled = false; stopItem = stop
        menu.addItem(.separator())
        add("How to Play Multiplayer…", #selector(instructions))
        return menu
    }
    static func validatedAddress(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URLComponents(string: value), ["ws", "wss"].contains(url.scheme ?? ""),
              let host = url.host, !host.isEmpty, host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:[]%_").contains($0) }), url.user == nil, url.password == nil, url.fragment == nil,
              !value.contains(where: { $0.isNewline || $0.isWhitespace }), value.count <= 2048,
              !(url.queryItems ?? []).contains(where: { ["room", "node"].contains($0.name.lowercased()) }) else { return nil }
        if url.path.isEmpty || url.path == "/" { url.path = "/net" }
        if let port = url.port, !(1...65535).contains(port) { return nil }
        return url.string
    }
    private func save(address: String, room: String, name: String) {
        preferences.set(address, forKey: "MultiplayerRelay")
        preferences.set(String(room.prefix(64)), forKey: "MultiplayerRoom")
        preferences.set(String(name.prefix(31)), forKey: "MultiplayerName")
        changeHandler()
    }
    private func connectionForm(title: String, address: String) -> (String,String,String)? {
        let alert = NSAlert(); alert.messageText = title
        alert.informativeText = "Use the same relay and room on every computer. Your racer’s name is set in the in-game Driver field. Applying settings restarts the game after saving local data. Finish or leave your current race first."
        alert.addButton(withTitle: "Apply and Restart"); alert.addButton(withTitle: "Cancel")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 142))
        let values = [("Relay URL", address), ("Room", room), ("Computer name", computerName)]
        var fields: [NSTextField] = []
        for (i, value) in values.enumerated() {
            let y = 110 - i * 44
            let label = NSTextField(labelWithString: value.0); label.frame = NSRect(x: 0, y: y + 20, width: 390, height: 18)
            let field = NSTextField(string: value.1); field.frame = NSRect(x: 0, y: y - 3, width: 390, height: 24)
            accessory.addSubview(label); accessory.addSubview(field); fields.append(field)
        }
        alert.accessoryView = accessory
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let relay = Self.validatedAddress(fields[0].stringValue), !fields[1].stringValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            message("Invalid connection settings", "Enter a ws:// or wss:// relay URL and a non-empty room name. Set the room in its own field; do not put room or node parameters in the relay URL."); return nil
        }
        return (relay, fields[1].stringValue, fields[2].stringValue)
    }
    @objc private func connect() {
        guard let value = connectionForm(title: "Connect to a Multiplayer Relay", address: relayAddress.isEmpty ? "ws://192.168.1.10:8080/net" : relayAddress) else { return }
        save(address: value.0, room: value.1, name: value.2)
    }
    @objc private func settings() { connect() }
    @objc private func hostLAN() {
        guard let value = connectionForm(title: "Host a LAN Session", address: "ws://127.0.0.1:8080/net") else { return }
        guard let components = URLComponents(string: value.0), components.scheme == "ws", ["127.0.0.1", "localhost"].contains(components.host ?? ""), components.path == "/net" else {
            message("Host on this Mac", "Use ws://127.0.0.1:PORT/net to start this Mac’s relay. Use Connect to a Relay for a different server."); return
        }
        let port = UInt16(components.port ?? 8080)
        if relay?.port == port { save(address: value.0, room: value.1, name: value.2); return }
        if relay != nil { stopRelay() }
        let server = C2LANRelay(port: port)
        server.onStatus = { [weak self, weak server] status in
            guard let self = self, let server = server, self.relay === server else { return }
            self.statusText = status; self.statusItem?.title = status
        }
        relay = server
        do {
            try server.start { [weak self, weak server] error in
                guard let self = self, let server = server, self.relay === server else { return }
                if let error = error { self.relay = nil; self.message("Could not start the LAN relay", error.localizedDescription); return }
                self.stopItem?.isEnabled = true
                self.save(address: value.0, room: value.1, name: value.2)
            }
        } catch { relay = nil; message("Could not start the LAN relay", error.localizedDescription) }
    }
    @objc private func stopRelay() { relay?.stop(); relay = nil; stopItem?.isEnabled = false; statusText = "LAN relay stopped"; statusItem?.title = statusText }
    func stop() { stopRelay() }
    @objc private func showAddresses() {
        let port = relay?.port ?? 8080
        let addresses = Self.lanAddresses().map { "ws://\($0):\(port)/net" }
        message("LAN Relay Addresses", addresses.isEmpty ? "No active IPv4 LAN address was found. Connect this Mac to your local network first." : addresses.joined(separator: "\n") + "\n\nRoom: \(room)\nEach player imports their own licensed game data. The relay only forwards game packets.")
    }
    @objc private func instructions() {
        message("Play Together", "1. On one Mac, choose Multiplayer → Host a LAN Session.\n2. Choose Show LAN Addresses and give an address and room to the other players.\n3. On each other Mac, choose Connect to a Relay and enter that address and room.\n4. In the game’s race-selection screen, choose Network Game. Set your nickname in Driver. One player selects Host; the others select Join a Game.\n5. When everyone is ready, the game host starts the race.\n\nFor Internet play, use a reachable ws:// or wss:// relay. The repository includes a cross-platform standalone relay. Local hosting does not automatically configure your router. The original Windows retail game does not connect directly to this WebSocket relay.")
    }
    private func message(_ title: String, _ body: String) { let alert = NSAlert(); alert.messageText = title; alert.informativeText = body; alert.addButton(withTitle: "OK"); alert.runModal() }
    static func lanAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(first) }
        var output = Set<String>(), current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  interface.pointee.ifa_flags & UInt32(IFF_UP) != 0, interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { output.insert(String(cString: host)) }
        }
        return output.sorted()
    }
}
