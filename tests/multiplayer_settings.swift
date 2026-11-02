// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

@main
enum MultiplayerSettingsValidation {
    static func main() {
        let valid = ["ws://127.0.0.1:8080/net", "wss://relay.example.com/net", "ws://192.168.1.10:8080", "ws://[::1]:8080/net"]
        let invalid = ["", "https://relay.example.com/net", "ws://user:password@relay.example.com/net", "ws://relay.example.com/net#fragment", "ws://relay.example.com:0/net", "ws://relay.example.com:99999/net", "ws://relay.example.com/net?room=wrong", "ws://relay.example.com/net?node=ffffffffffff", "ws://relay.example.com\r\nInjected: yes/net", "ws://example%0a.com/net", "ws://example%27.com/net", "ws://example%3b.com/net"]
        for value in valid { precondition(MultiplayerController.validatedAddress(value) != nil, value) }
        for value in invalid { precondition(MultiplayerController.validatedAddress(value) == nil, value) }
        let suite = "org.carmageddon2.tests.multiplayer-settings.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let controller = MultiplayerController(preferences: preferences, changeHandler: {})
        precondition(controller.queryItems().isEmpty)
        precondition(controller.contentSecurityPolicyConnectSources == "'self'")
        preferences.set("ws://192.168.1.10:8080/net", forKey: "MultiplayerRelay")
        preferences.set("friends", forKey: "MultiplayerRoom")
        precondition(controller.contentSecurityPolicyConnectSources == "'self' ws://192.168.1.10:8080")
        precondition(controller.queryItems().first { $0.name == "room" }?.value == "friends")
        preferences.set("ws://example%0a.com/net", forKey: "MultiplayerRelay")
        precondition(controller.queryItems().isEmpty)
        precondition(controller.contentSecurityPolicyConnectSources == "'self'")
        print("Multiplayer URL, room and dynamic CSP validation passed (16 URLs plus preference transitions).")
    }
}
