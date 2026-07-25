//
//  AgentChannelConnectionDraftTests.swift
//  osaurus
//
//  Tests for the custom channel sheet's draft model: inbound authorization
//  round-trip and pre-save validation.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentChannelConnectionDraftTests {

    private static let validActionsJSON = """
        {
          "send_message": {
            "method": "POST",
            "path": "/rooms/{room_id}/messages",
            "bodyTemplate": "{\\"text\\":\\"${content}\\"}"
          }
        }
        """

    @Test func inboundAuthorizationRoundTripsThroughTheDraft() throws {
        let original = AgentChannelConnection(
            id: "ops-webhook",
            name: "Ops Webhook",
            kind: .customHTTP,
            customHTTP: AgentChannelCustomHTTPConfiguration(
                baseURL: "https://hooks.example.test",
                actions: ["send_message": AgentChannelCustomHTTPAction(path: "/messages")]
            ),
            inboundAuthorization: AgentChannelInboundAuthorizationPolicy(
                senderAllowlist: ["U123"],
                roomAllowlist: ["R456"],
                allowUnscopedSpaces: true,
                allowBotMessages: true,
                allowSelfMessages: false,
                requireProviderEventId: false,
                duplicateBehavior: "custom_behavior"
            )
        )

        var draft = AgentChannelConnectionDraft(connection: original)
        #expect(draft.inboundSenderAllowlistText == "U123")
        #expect(draft.inboundRoomAllowlistText == "R456")
        #expect(draft.inboundAllowBotMessages)
        #expect(!draft.inboundAllowSelfMessages)

        // Edit the exposed fields; the unexposed policy fields must survive.
        draft.inboundSenderAllowlistText = "U123\nU999"
        draft.inboundAllowSelfMessages = true
        let rebuilt = try draft.connection()
        #expect(rebuilt.inboundAuthorization.senderAllowlist == ["U123", "U999"])
        #expect(rebuilt.inboundAuthorization.roomAllowlist == ["R456"])
        #expect(rebuilt.inboundAuthorization.allowBotMessages)
        #expect(rebuilt.inboundAuthorization.allowSelfMessages)
        #expect(rebuilt.inboundAuthorization.allowUnscopedSpaces)
        #expect(!rebuilt.inboundAuthorization.requireProviderEventId)
        #expect(rebuilt.inboundAuthorization.duplicateBehavior == "custom_behavior")
    }

    @Test func newDraftsDefaultToDenyAllInbound() throws {
        var draft = AgentChannelConnectionDraft()
        draft.id = "fresh"
        draft.customBaseURL = "https://example.test"
        let built = try draft.connection()
        #expect(built.inboundAuthorization.senderAllowlist.isEmpty)
        #expect(!built.inboundAuthorization.allowBotMessages)
        #expect(!built.inboundAuthorization.allowSelfMessages)
        #expect(built.inboundAuthorization.requireProviderEventId)
    }

    @Test func validationFlagsMissingRequiredFields() {
        var draft = AgentChannelConnectionDraft()
        draft.customActionsJSON = ""
        let issues = draft.validationIssues()
        #expect(issues.contains { $0.contains("Connection ID") })
        #expect(issues.contains { $0.contains("Base URL is required") })
        #expect(issues.contains { $0.contains("at least one action") })
    }

    @Test func validationAcceptsAStructurallyValidDraft() {
        var draft = AgentChannelConnectionDraft()
        draft.id = "ops-webhook"
        draft.customBaseURL = "https://hooks.example.test"
        draft.customActionsJSON = Self.validActionsJSON
        #expect(draft.validationIssues().isEmpty)
    }

    @Test func validationFlagsNonStandardActionNamesAndBadURLs() {
        var draft = AgentChannelConnectionDraft()
        draft.id = "ops-webhook"
        draft.customBaseURL = "ftp://example.test"
        draft.customActionsJSON = """
            { "post_message": { "method": "POST", "path": "/x" } }
            """
        let issues = draft.validationIssues()
        #expect(issues.contains { $0.contains("https:// or http://") })
        #expect(issues.contains { $0.contains("post_message") })
    }

    @Test func validationFlagsWriteEnabledWithoutWriteAllowlistAndBadSecrets() {
        var draft = AgentChannelConnectionDraft()
        draft.id = "ops-webhook"
        draft.customBaseURL = "https://hooks.example.test"
        draft.customActionsJSON = Self.validActionsJSON
        draft.writeEnabled = true
        draft.secretReferencesText = "bearer"
        let issues = draft.validationIssues()
        #expect(issues.contains { $0.contains("write room allowlist is empty") })
        #expect(issues.contains { $0.contains("bearer") && $0.contains("keychain id") })
    }
}
