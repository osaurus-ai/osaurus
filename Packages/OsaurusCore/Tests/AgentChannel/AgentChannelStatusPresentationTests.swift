//
//  AgentChannelStatusPresentationTests.swift
//  osaurusTests
//
//  Coverage for the diagnostics/transport status humanization mapping used by
//  Agent Channel settings UI.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentChannelStatusPresentationTests {

    @Test func knownDiagnosticsCodesAreHumanizedWithExpectedTone() {
        let expectations: [(code: String, tone: AgentChannelStatusTone)] = [
            ("not_configured", .neutral),
            ("configured", .success),
            ("token_invalid_or_unavailable", .error),
            ("connected_team_not_allowlisted", .warning),
            ("connected_needs_allowlist", .warning),
            ("connected_receive_needs_sender_allowlist", .warning),
            ("connected_read_only_write_needs_channels", .warning),
            ("connected_read_only_write_needs_chats", .warning),
            ("connected_long_poll_webhook_conflict", .error),
            ("connected_read_write", .success),
            ("connected_read_only", .success),
        ]

        for expectation in expectations {
            let presentation = AgentChannelStatusPresentation.diagnostics(status: expectation.code)
            #expect(presentation.isRecognized, "expected \(expectation.code) to be recognized")
            #expect(presentation.tone == expectation.tone, "unexpected tone for \(expectation.code)")
            #expect(!presentation.label.isEmpty)
            #expect(
                presentation.label != expectation.code,
                "expected a humanized label for \(expectation.code), got the raw code"
            )
            #expect(
                !presentation.label.contains("_"),
                "humanized label for \(expectation.code) should not look like a machine code"
            )
        }
    }

    @Test func unknownDiagnosticsCodeFallsBackToRawCode() {
        let presentation = AgentChannelStatusPresentation.diagnostics(
            status: "some_future_status_code"
        )
        #expect(!presentation.isRecognized)
        #expect(presentation.label == "some_future_status_code")
        #expect(presentation.tone == .neutral)
    }

    @Test func everyTransportStatusIsHumanized() {
        let expectedTones: [AgentChannelTransportHealthStatus: AgentChannelStatusTone] = [
            .disabled: .neutral,
            .idle: .neutral,
            .healthy: .success,
            .degraded: .warning,
            .conflict: .error,
            .failed: .error,
        ]

        for status in AgentChannelTransportHealthStatus.allCases {
            let presentation = AgentChannelStatusPresentation.transport(status: status)
            #expect(presentation.isRecognized)
            #expect(!presentation.label.isEmpty)
            #expect(
                presentation.label.lowercased() != presentation.label
                    || !presentation.label.contains("_"),
                "transport label for \(status.rawValue) should be presentation text"
            )
            #expect(presentation.tone == expectedTones[status])
        }
    }

    @Test func missingTransportStateHasNeutralNotRunningPresentation() {
        let presentation = AgentChannelStatusPresentation.transportNotRunning
        #expect(presentation.tone == .neutral)
        #expect(!presentation.label.isEmpty)
        #expect(presentation.label != "not_running")
    }
}
