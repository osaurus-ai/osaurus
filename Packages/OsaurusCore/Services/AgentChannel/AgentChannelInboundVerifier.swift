//
//  AgentChannelInboundVerifier.swift
//  osaurus
//
//  Provider-neutral wait loop behind the settings sheets' "Verify incoming
//  message" buttons: watches the inbound activity center for a fresh event
//  and stops at the first terminal stage.
//

import Foundation

struct AgentChannelInboundVerificationOutcome: Sendable {
    /// The most informative event observed, or nil when nothing arrived.
    let event: AgentChannelInboundActivityEvent?
    /// True when events arrived but stalled before a terminal stage.
    let timedOutWaitingForMore: Bool
}

enum AgentChannelInboundVerifier {
    /// Polls the activity center for events newer than `start` until a
    /// terminal stage appears or `timeout` elapses. `onActivity` fires on
    /// the main actor whenever new events are observed so the UI can
    /// refresh its activity list.
    static func waitForTerminalEvent(
        connectionId: String,
        since start: Date,
        timeout: TimeInterval = 90,
        autoReplyEnabled: Bool,
        onActivity: @escaping @MainActor () -> Void
    ) async -> AgentChannelInboundVerificationOutcome {
        let deadline = start.addingTimeInterval(timeout)
        var observed: [AgentChannelInboundActivityEvent] = []
        while Date() < deadline {
            observed = await AgentChannelInboundActivityCenter.shared.events(
                connectionId: connectionId,
                since: start
            )
            if !observed.isEmpty {
                await onActivity()
                if let terminal = terminalEvent(in: observed, autoReplyEnabled: autoReplyEnabled) {
                    return AgentChannelInboundVerificationOutcome(
                        event: terminal,
                        timedOutWaitingForMore: false
                    )
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return AgentChannelInboundVerificationOutcome(
            event: observed.last,
            timedOutWaitingForMore: observed.last != nil
        )
    }

    /// Stages that end the verification wait. `dispatched` is terminal only
    /// when auto-reply is off, since a reply confirmation will never come.
    static func terminalEvent(
        in events: [AgentChannelInboundActivityEvent],
        autoReplyEnabled: Bool
    ) -> AgentChannelInboundActivityEvent? {
        events.last { event in
            switch event.stage {
            case .rejected, .dispatchSuppressed, .failed, .replySent, .agentReplied:
                return true
            case .dispatched:
                return !autoReplyEnabled
            case .received, .stored:
                return false
            }
        }
    }
}
