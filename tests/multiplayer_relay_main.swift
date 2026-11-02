// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network

@main
enum RelayProtocolFixture {
    static func main() throws {
        let port = CommandLine.arguments.count > 1 ? UInt16(CommandLine.arguments[1])! : 18808
        let relay = C2LANRelay(port: port)
        relay.onStatus = { print($0); fflush(stdout) }
        try relay.start { error in
            if let error = error { fputs("Relay failed: \(error)\n", stderr); exit(1) }
            print("READY \(port)"); fflush(stdout)
        }
        RunLoop.main.run()
        withExtendedLifetime(relay) {}
    }
}
