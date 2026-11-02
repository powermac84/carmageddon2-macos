# Multiplayer

The Mac app includes a native LAN relay. Players do not need Node.js, Python, Wine, or an IPX driver to use it. Every player supplies their own licensed game data.

## Play on a local network

1. On one Mac, choose **Multiplayer → Host a LAN Session…**. Keep the local relay URL (`ws://127.0.0.1:8080/net`) and choose a room. Applying settings restarts the game after synchronizing local saves; leave the current race first.
2. On that Mac, choose **Multiplayer → Show LAN Addresses…** and share one reachable address and the room with the other players. If macOS asks for local-network or firewall access, allow it for LAN play.
3. On the other Macs, choose **Multiplayer → Connect to a Relay…**. Enter the host's LAN address, such as `ws://192.168.1.10:8080/net`, and the same room.
4. In the game's race-selection screen, choose **Network Game**. Set a racer nickname in the original **Driver** field. The app's **Computer name** field controls the runtime computer name and does not replace this nickname.
5. One player selects the game type and track and clicks **Host**. The others select the advertised game under **Join a Game** and click **Join**.
6. Once every player is **READY**, the game host clicks **START**.

Starting the native LAN relay and hosting an actual game are separate steps. A relay can carry several independent rooms. The room name is a routing label, not a password. **Stop LAN Relay** disconnects players using this Mac's relay, and quitting the app stops its relay.

Use a private LAN or a trusted VPN for plain `ws://` connections. Local hosting does not set up port forwarding or a public server automatically.

## Internet or cross-platform relay hosting

The app can connect to a reachable `ws://` or `wss://` relay. For a shared Internet server, the included Node.js relay can run separately from the Mac app:

```sh
node server/relay.js --host 127.0.0.1 --port 8080
```

Use a currently supported Node.js release. Put the relay behind an HTTPS reverse proxy that upgrades `/net` to WebSocket, then give players the `wss://` URL and a shared room. `nginx.conf.example` and `carma2-relay.service` are deployment examples that need your domain, user and paths. Python `relay.py`, Windows scripts and a Dockerfile are also retained from the upstream runtime.

The relay forwards game packets only. It does not distribute the original game, and it needs no game files. Do not publish game data alongside the relay. The `--static` option in the upstream standalone relay is optional and is not needed by Mac app users.

All participating clients must use this runtime's IPX-over-WebSocket protocol. An unmodified Windows or classic Mac retail game does not connect directly to it. Internet latency, NAT, all network game types, and mixed game-data editions have not been exhaustively tested.

## What has been tested

The native Swift relay was tested with real WebSocket clients for broadcast, source-address rewriting, unicast, room isolation, ping/pong, fragmented binary packets, size limits, and replacing a duplicate node.

Two separate actual game clients on one Apple Silicon Mac discovered a hosted **Driven to Destruction / New Sumo** game, joined, became ready, and entered a race. Moving the host's car updated the corresponding car in the guest, with both clients reporting the same player IDs and nearly identical positions. This is a local two-client test, not a two-physical-Mac or Internet session. The native WebKit/CSP integration is recorded separately in the release verification.

See `tests/multiplayer-verification.json` for the bounded results. Tests use local licensed data that is excluded from the repository and release packages.

## Packet protocol

WebSocket path: `/net?room=ROOM&node=XXXXXXXXXXXX`. The node is a 12-digit hexadecimal IPX node, and `ffffffffffff` is the broadcast destination.

- Client to relay: six destination-node bytes followed by the original game packet.
- Relay to client: six source-node bytes followed by the unchanged game packet.
- Text notice: `peers N` reports the number of connections in a room.

The native relay accepts at most 32 rooms, 16 connections per room, and 4096-byte WebSocket game messages. These are transport limits; the original game rules still determine the playable race size. It requires masked client frames and bounds its receive/send buffers. It is started only by an explicit **Host a LAN Session** action.

## Developer checks

On macOS, compile the native transport fixture separately from the app:

```sh
xcrun swiftc -swift-version 5 -O -framework AppKit -framework Network \
  host/Multiplayer.swift tests/multiplayer_relay_main.swift -o /tmp/c2-relay-test
/tmp/c2-relay-test 18808
```

In another terminal, run `python3 tests/multiplayer_protocol.py ws://127.0.0.1:18808/net`. This developer test uses the optional Python `websocket-client` package; the shipped app does not require it. `tests/multiplayer_settings.swift` similarly checks native relay-URL and dynamic-CSP validation without opening a game or network listener.
