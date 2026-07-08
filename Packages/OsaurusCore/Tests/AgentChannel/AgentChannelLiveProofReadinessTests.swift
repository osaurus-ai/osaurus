//
//  AgentChannelLiveProofReadinessTests.swift
//  osaurusTests
//
//  Tests for release-proof readiness and plugin-vs-channel feedback routing.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentChannelLiveProofReadinessTests {

    @Test func telegramTokenOnlyIsBlockedForReceiveProof() {
        let report = AgentChannelLiveProofReadiness.telegram(
            TelegramConnectionDiagnostics(
                tokenSaved: true,
                bot: nil,
                readableChatIds: [],
                writableChatIds: [],
                senderAllowlist: [],
                writeEnabled: false,
                receiveStorageEnabled: true,
                longPollingEnabled: false,
                status: "connected_receive_long_poll_disabled",
                failures: []
            )
        )

        #expect(report.kind == .telegram)
        #expect(report.status == .blocked)
        #expect(!report.isReadyForLiveProof)
        #expect(report.blockers.contains("Run Test Connection until Telegram accepts the bot token."))
        #expect(report.blockers.contains("Enable Long Polling for local desktop receive proof."))
        #expect(report.blockers.contains("Add at least one readable Telegram chat id."))
        #expect(report.blockers.contains("Add at least one authorized Telegram sender id."))
    }

    @Test func telegramWebhookConflictBlocksLongPollProof() {
        let report = AgentChannelLiveProofReadiness.telegram(
            TelegramConnectionDiagnostics(
                tokenSaved: true,
                bot: .fixtureBot,
                readableChatIds: ["-100111222333"],
                writableChatIds: ["-100111222333"],
                senderAllowlist: ["123456789"],
                writeEnabled: true,
                receiveStorageEnabled: true,
                longPollingEnabled: true,
                webhook: TelegramWebhookDiagnostic(
                    registered: true,
                    redactedURL: "https://example.test/***",
                    pendingUpdateCount: 1,
                    probeError: nil
                ),
                status: "connected_long_poll_webhook_conflict",
                failures: []
            )
        )

        #expect(report.status == .blocked)
        #expect(report.blockers == ["Remove the registered Telegram webhook before long polling."])
    }

    @Test func telegramCompleteReadWriteSetupIsReadyButRequiresManualProof() {
        let report = AgentChannelLiveProofReadiness.telegram(
            TelegramConnectionDiagnostics(
                tokenSaved: true,
                bot: .fixtureBot,
                readableChatIds: ["-100111222333"],
                writableChatIds: ["-100111222333"],
                senderAllowlist: ["123456789"],
                writeEnabled: true,
                receiveStorageEnabled: true,
                longPollingEnabled: true,
                webhook: TelegramWebhookDiagnostic(
                    registered: false,
                    redactedURL: "",
                    pendingUpdateCount: 0,
                    probeError: nil
                ),
                status: "connected_read_write",
                failures: []
            )
        )

        #expect(report.status == .ready)
        #expect(report.isReadyForLiveProof)
        #expect(report.blockers.isEmpty)
        #expect(report.manualProof.contains("Send one inbound Telegram message from an authorized sender."))
        #expect(report.manualProof.contains("Confirm an unauthorized sender in the same group is ignored."))
        #expect(report.manualProof.contains("Send one confirmed message to a write-allowlisted Telegram chat."))
    }

    @Test func telegramWebhookProbeFailureBlocksReadiness() {
        let report = AgentChannelLiveProofReadiness.telegram(
            TelegramConnectionDiagnostics(
                tokenSaved: true,
                bot: .fixtureBot,
                readableChatIds: ["-100111222333"],
                writableChatIds: [],
                senderAllowlist: ["123456789"],
                writeEnabled: false,
                receiveStorageEnabled: true,
                longPollingEnabled: true,
                webhook: TelegramWebhookDiagnostic(
                    registered: false,
                    redactedURL: "",
                    pendingUpdateCount: nil,
                    probeError: "network unavailable"
                ),
                status: "connected_read_only",
                failures: []
            )
        )

        #expect(report.status == .blocked)
        #expect(report.blockers == [
            "Verify Telegram webhook state before long polling proof: network unavailable",
        ])
    }

    @Test func telegramBlankAllowlistEntriesDoNotCountAsSecurityProof() {
        let report = AgentChannelLiveProofReadiness.telegram(
            TelegramConnectionDiagnostics(
                tokenSaved: true,
                bot: .fixtureBot,
                readableChatIds: [" "],
                writableChatIds: ["\n"],
                senderAllowlist: ["\t"],
                writeEnabled: true,
                receiveStorageEnabled: true,
                longPollingEnabled: true,
                webhook: TelegramWebhookDiagnostic(
                    registered: false,
                    redactedURL: "",
                    pendingUpdateCount: 0,
                    probeError: nil
                ),
                status: "connected_read_write",
                failures: []
            )
        )

        #expect(report.status == .blocked)
        #expect(report.blockers.contains("Add at least one readable Telegram chat id."))
        #expect(report.blockers.contains("Add at least one authorized Telegram sender id."))
        #expect(report.blockers.contains("Add at least one writable Telegram chat id or turn writes off."))
    }

    @Test func slackMissingSocketModeCredentialIsBlocked() {
        let report = AgentChannelLiveProofReadiness.slack(
            SlackConnectionDiagnostics(
                botTokenSaved: true,
                signingSecretSaved: true,
                appTokenSaved: false,
                identity: .fixture,
                configuredTeams: [
                    SlackConfiguredTeamDiagnostic(id: "T12345", name: "Example", status: "accessible", reason: nil),
                ],
                readableChannelIds: ["C12345"],
                writableChannelIds: [],
                senderAllowlist: ["U12345"],
                writeEnabled: false,
                allowBroadcastMentions: false,
                status: "connected_read_only",
                failures: []
            )
        )

        #expect(report.kind == .slack)
        #expect(report.status == .blocked)
        #expect(report.blockers == ["Save a Slack Socket Mode app token for local desktop receive proof."])
    }

    @Test func slackCompleteSocketModeSetupIsReady() {
        let report = AgentChannelLiveProofReadiness.slack(
            SlackConnectionDiagnostics(
                botTokenSaved: true,
                signingSecretSaved: false,
                appTokenSaved: true,
                identity: .fixture,
                configuredTeams: [
                    SlackConfiguredTeamDiagnostic(id: "T12345", name: "Example", status: "accessible", reason: nil),
                ],
                readableChannelIds: ["C12345"],
                writableChannelIds: ["C12345"],
                senderAllowlist: ["U12345"],
                writeEnabled: true,
                allowBroadcastMentions: false,
                status: "connected_read_write",
                failures: []
            )
        )

        #expect(report.status == .ready)
        #expect(report.isReadyForLiveProof)
        #expect(report.blockers.isEmpty)
        #expect(report.notes == ["Signed Slack HTTP event proof is unavailable until a signing secret is saved."])
        #expect(report.manualProof.contains("Receive one Slack message through Socket Mode from an authorized sender."))
        #expect(report.manualProof.contains("Send one confirmed message to a write-allowlisted Slack channel."))
    }

    @Test func slackDiagnosticFailuresBlockReadiness() {
        let report = AgentChannelLiveProofReadiness.slack(
            SlackConnectionDiagnostics(
                botTokenSaved: true,
                signingSecretSaved: true,
                appTokenSaved: true,
                identity: .fixture,
                configuredTeams: [
                    SlackConfiguredTeamDiagnostic(id: "T12345", name: "Example", status: "accessible", reason: nil),
                ],
                readableChannelIds: ["C12345"],
                writableChannelIds: [],
                senderAllowlist: ["U12345"],
                writeEnabled: false,
                allowBroadcastMentions: false,
                status: "token_invalid_or_unavailable",
                failures: ["Slack API token check failed."]
            )
        )

        #expect(report.status == .blocked)
        #expect(report.blockers == ["Slack API token check failed."])
    }

    @Test func legacyTelegramPluginFeedbackDoesNotApplyToNativeChannels() {
        let routing = AgentChannelLiveProofReadiness.routeFeedback(source: .legacyTelegramPlugin)

        #expect(routing.source == .legacyTelegramPlugin)
        #expect(!routing.appliesToNativeChannels)
        #expect(routing.guidance.contains("legacy Telegram plugin"))
        #expect(routing.guidance.contains("Do not claim the native Telegram Agent Channel fixed this path"))
    }

    @Test func nativeChannelFeedbackRoutesToNativeChannelPath() {
        let routing = AgentChannelLiveProofReadiness.routeFeedback(source: .nativeAgentChannel(.telegram))

        #expect(routing.appliesToNativeChannels)
        #expect(routing.guidance == "Investigate the native Telegram Agent Channel path.")
    }
}

private extension TelegramUser {
    static var fixtureBot: TelegramUser {
        TelegramUser(
            id: 42,
            isBot: true,
            firstName: "Osaurus",
            lastName: nil,
            username: "osaurus_test_bot"
        )
    }
}

private extension SlackAuthIdentity {
    static var fixture: SlackAuthIdentity {
        SlackAuthIdentity(
            url: "https://example.slack.com/",
            team: "Example",
            user: "osaurus",
            teamId: "T12345",
            userId: "U12345",
            botId: "B12345"
        )
    }
}
