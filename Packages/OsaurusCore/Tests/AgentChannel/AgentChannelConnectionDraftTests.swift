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

    // MARK: - Validation-to-section mapping

    @Test func validationFindingsPointAtTheSectionThatCanFixThem() {
        var draft = AgentChannelConnectionDraft()
        draft.id = ""
        draft.customBaseURL = "ftp://example.test"
        draft.customActionsJSON = """
            { "post_message": { "method": "POST", "path": "/x" } }
            """
        draft.writeEnabled = true
        draft.secretReferencesText = "bearer"
        let findings = draft.validationFindings()

        func sections(containing fragment: String) -> Set<String> {
            Set(findings.filter { $0.message.contains(fragment) }.map(\.sectionId))
        }

        #expect(sections(containing: "Connection ID") == ["basics"])
        #expect(sections(containing: "https:// or http://") == ["basics"])
        #expect(sections(containing: "post_message") == ["capabilities"])
        #expect(sections(containing: "write room allowlist is empty") == ["send-receive"])
        #expect(sections(containing: "keychain id") == ["review"])
    }

    @Test func validationFindingsFlagInvalidActionJSONInCapabilities() {
        var draft = AgentChannelConnectionDraft()
        draft.id = "ops-webhook"
        draft.customBaseURL = "https://hooks.example.test"
        draft.customActionsJSON = "{ not json"
        let findings = draft.validationFindings()
        #expect(findings.contains { $0.sectionId == "capabilities" })
        #expect(draft.validationIssues() == findings.map(\.message))
    }

    // MARK: - Structured action editing round trips

    /// Action with every advanced field the structured editors do NOT expose,
    /// to prove none of them are dropped when a structured field is edited.
    private static let advancedActionsJSON = """
        {
          "send_message": {
            "method": "POST",
            "path": "/rooms/{room_id}/messages",
            "query": { "wait": "true" },
            "headers": { "Authorization": "Bearer ${secret:bearer}" },
            "bodyTemplate": "{\\"text\\":\\"${content}\\"}",
            "successStatusCodes": [200, 201],
            "timeoutSeconds": 12,
            "maxResponseBytes": 65536
          },
          "read_messages": {
            "method": "GET",
            "path": "/rooms/{room_id}/messages"
          }
        }
        """

    @Test func decodedActionsForEditingHandlesValidEmptyAndInvalidJSON() {
        let decoded = AgentChannelConnectionDraft.decodedActionsForEditing(Self.advancedActionsJSON)
        #expect(decoded?.keys.sorted() == ["read_messages", "send_message"])
        #expect(AgentChannelConnectionDraft.decodedActionsForEditing("")?.isEmpty == true)
        #expect(AgentChannelConnectionDraft.decodedActionsForEditing("  \n ")?.isEmpty == true)
        #expect(AgentChannelConnectionDraft.decodedActionsForEditing("{ not json") == nil)
    }

    @Test func upsertingOneActionPreservesAdvancedFieldsAndOtherEntries() throws {
        let original = try #require(
            AgentChannelConnectionDraft.decodedActionsForEditing(Self.advancedActionsJSON)
        )
        var edited = try #require(original["send_message"])
        edited.path = "/v2/rooms/{room_id}/messages"

        let updatedJSON = try #require(
            AgentChannelConnectionDraft.upsertingAction(
                in: Self.advancedActionsJSON,
                name: "send_message",
                action: edited
            )
        )
        let reparsed = try #require(
            AgentChannelConnectionDraft.decodedActionsForEditing(updatedJSON)
        )

        let send = try #require(reparsed["send_message"])
        #expect(send.path == "/v2/rooms/{room_id}/messages")
        #expect(send.query == ["wait": "true"])
        #expect(send.headers == ["Authorization": "Bearer ${secret:bearer}"])
        #expect(send.bodyTemplate == "{\"text\":\"${content}\"}")
        #expect(send.successStatusCodes == [200, 201])
        #expect(send.timeoutSeconds == 12)
        #expect(send.maxResponseBytes == 65536)

        // The other entry must survive untouched.
        let read = try #require(reparsed["read_messages"])
        #expect(read.method == "GET")
        #expect(read.path == "/rooms/{room_id}/messages")
    }

    @Test func upsertingAndRemovingRefuseUnparseableJSON() {
        let action = AgentChannelCustomHTTPAction(path: "/x")
        #expect(
            AgentChannelConnectionDraft.upsertingAction(in: "{ not json", name: "send_message", action: action)
                == nil
        )
        #expect(AgentChannelConnectionDraft.removingAction(in: "{ not json", name: "send_message") == nil)
    }

    @Test func removingAnActionOnlyRemovesThatEntry() throws {
        let updatedJSON = try #require(
            AgentChannelConnectionDraft.removingAction(
                in: Self.advancedActionsJSON,
                name: "read_messages"
            )
        )
        let reparsed = try #require(
            AgentChannelConnectionDraft.decodedActionsForEditing(updatedJSON)
        )
        #expect(reparsed.keys.sorted() == ["send_message"])
        #expect(reparsed["send_message"]?.successStatusCodes == [200, 201])
    }

    @Test func structuredEditsRoundTripThroughTheDraftConnection() throws {
        var draft = AgentChannelConnectionDraft()
        draft.id = "ops-webhook"
        draft.customBaseURL = "https://hooks.example.test"
        draft.customActionsJSON = Self.advancedActionsJSON

        let built = try draft.connection()
        let actions = try #require(built.customHTTP?.actions)
        #expect(actions["send_message"]?.query == ["wait": "true"])
        #expect(actions["send_message"]?.successStatusCodes == [200, 201])

        // Load the built connection into a fresh edit draft and rebuild:
        // nothing may be dropped by the pretty re-encoding.
        let editDraft = AgentChannelConnectionDraft(connection: built)
        let rebuilt = try editDraft.connection()
        #expect(rebuilt.customHTTP?.actions == built.customHTTP?.actions)
    }

    // MARK: - Header line editing

    @Test func headerLinesRoundTripSortedAndParseLeniently() {
        let headers = [
            "Authorization": "Bearer ${secret:bearer}",
            "Content-Type": "application/json",
        ]
        let lines = AgentChannelConnectionDraft.headerLines(headers)
        #expect(
            lines == "Authorization: Bearer ${secret:bearer}\nContent-Type: application/json"
        )
        #expect(AgentChannelConnectionDraft.parsedHeaderLines(lines) == headers)

        // A line without a colon (in-progress typing) keeps the name with an
        // empty value instead of being discarded; blank lines are skipped.
        let partial = AgentChannelConnectionDraft.parsedHeaderLines(
            "Authorization\n\nX-Custom: yes"
        )
        #expect(partial == ["Authorization": "", "X-Custom": "yes"])
    }

    // MARK: - Create vs. edit drafts

    @Test func newDraftStartsWithTemplateAndEditDraftLoadsSavedActions() throws {
        let newDraft = AgentChannelConnectionDraft()
        #expect(newDraft.isNew)
        let templateActions = try #require(
            AgentChannelConnectionDraft.decodedActionsForEditing(newDraft.customActionsJSON)
        )
        #expect(templateActions.keys.sorted() == ["send_message"])

        let existing = AgentChannelConnection(
            id: "ops-webhook",
            name: "Ops Webhook",
            kind: .customHTTP,
            customHTTP: AgentChannelCustomHTTPConfiguration(
                baseURL: "https://hooks.example.test",
                actions: ["read_messages": AgentChannelCustomHTTPAction(path: "/messages")]
            )
        )
        let editDraft = AgentChannelConnectionDraft(connection: existing)
        #expect(!editDraft.isNew)
        let loadedActions = try #require(
            AgentChannelConnectionDraft.decodedActionsForEditing(editDraft.customActionsJSON)
        )
        #expect(loadedActions.keys.sorted() == ["read_messages"])
    }
}
