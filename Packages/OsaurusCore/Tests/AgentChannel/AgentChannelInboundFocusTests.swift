//
//  AgentChannelInboundFocusTests.swift
//  osaurusTests
//
//  Settings → Channels → Incoming → "Focus Chat on Incoming Messages":
//  the preference is off unless the user turned it on, round-trips through
//  its defaults store, and the inbound relay only reveals a conversation
//  (focus tab / bring the chat window forward) when it is enabled.
//

import Foundation
import Testing

@testable import OsaurusCore

private func makeIsolatedDefaults() -> (UserDefaults, String) {
    let suite = "ai.osaurus.tests.channel-focus.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
}

struct AgentChannelInboundFocusPreferenceTests {

    @Test func defaultsToOff() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pref = AgentChannelInboundFocusPreference(defaults: defaults)
        #expect(pref.isEnabled == false)
    }

    @Test func roundTripsThroughDefaults() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pref = AgentChannelInboundFocusPreference(defaults: defaults)

        pref.setEnabled(true)
        #expect(pref.isEnabled)
        #expect(AgentChannelInboundFocusPreference(defaults: defaults).isEnabled, "a fresh reader sees the stored value")

        pref.setEnabled(false)
        #expect(pref.isEnabled == false)
    }
}

@MainActor
struct AgentChannelInboundRelayFocusTests {

    @MainActor
    private final class RevealProbe {
        private(set) var revealed: [UUID] = []
        func record(_ id: UUID) { revealed.append(id) }
    }

    @Test func disabled_neverRevealsTheConversation() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = RevealProbe()
        let relay = AgentChannelInboundRelay(
            taskManager: BackgroundTaskManager.makeForTesting(),
            focusPreference: AgentChannelInboundFocusPreference(defaults: defaults),
            revealTask: { probe.record($0) }
        )

        relay.revealConversationIfPreferred(taskId: UUID())
        #expect(probe.revealed.isEmpty)
    }

    @Test func enabled_revealsEachInboundConversationOnce() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pref = AgentChannelInboundFocusPreference(defaults: defaults)
        pref.setEnabled(true)
        let probe = RevealProbe()
        let relay = AgentChannelInboundRelay(
            taskManager: BackgroundTaskManager.makeForTesting(),
            focusPreference: pref,
            revealTask: { probe.record($0) }
        )

        let first = UUID()
        let second = UUID()
        relay.revealConversationIfPreferred(taskId: first)
        relay.revealConversationIfPreferred(taskId: second)
        #expect(probe.revealed == [first, second])

        // Flipping the switch off takes effect on the next message — no relaunch.
        pref.setEnabled(false)
        relay.revealConversationIfPreferred(taskId: UUID())
        #expect(probe.revealed == [first, second])
    }
}
