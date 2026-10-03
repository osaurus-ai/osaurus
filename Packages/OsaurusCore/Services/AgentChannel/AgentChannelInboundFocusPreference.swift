//
//  AgentChannelInboundFocusPreference.swift
//  osaurus
//
//  User preference: bring the channel conversation's chat tab/window to the
//  front whenever a channel message arrives. Off by default — most users do
//  not want an inbound n8n/Slack/Telegram message to steal focus. Advanced
//  users running a dedicated monitoring machine turn it on so every channel
//  activation is visible without watching the Activity list.
//

import Foundation

/// `UserDefaults` is thread-safe but not marked `Sendable`; the wrapper holds
/// nothing else.
struct AgentChannelInboundFocusPreference: @unchecked Sendable {
    /// UserDefaults key. Absent = disabled.
    static let defaultsKey = "ai.osaurus.channels.focusChatOnInbound"

    static let shared = AgentChannelInboundFocusPreference()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether an inbound channel message should reveal its conversation
    /// (focus the tab and bring the chat window forward).
    var isEnabled: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.defaultsKey)
    }
}
