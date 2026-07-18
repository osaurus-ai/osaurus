//
//  OpenRouterReauthorizationSessionTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct OpenRouterReauthorizationSessionTests {
    @Test func currentCompletionSucceedsAndIgnoresUnchangedBindingEcho() {
        var session = OpenRouterReauthorizationSession()
        let requestID = UUID()
        session.begin(requestID: requestID, apiKeyInput: "old-key")

        let accepted = session.acceptCompletion(
            requestID: requestID,
            currentAPIKeyInput: "old-key"
        )

        #expect(accepted)
        #expect(session.status == .succeeded)

        let treatedAsManualEdit = session.manualAPIKeyDidChange(
            from: "new-oauth-key",
            to: "new-oauth-key"
        )

        #expect(!treatedAsManualEdit)
        #expect(session.status == .succeeded)
    }

    @Test func manualEditCancelsRequestAndRejectsLateCompletion() {
        var session = OpenRouterReauthorizationSession()
        let requestID = UUID()
        session.begin(requestID: requestID, apiKeyInput: "")

        let treatedAsManualEdit = session.manualAPIKeyDidChange(from: "", to: "typed-key")
        let acceptedLateCompletion = session.acceptCompletion(
            requestID: requestID,
            currentAPIKeyInput: "typed-key"
        )

        #expect(treatedAsManualEdit)
        #expect(session.status == .idle)
        #expect(session.requestID == nil)
        #expect(!acceptedLateCompletion)
    }

    @Test func changedInputRejectsCompletionEvenWithoutManualCancellation() {
        var session = OpenRouterReauthorizationSession()
        let requestID = UUID()
        session.begin(requestID: requestID, apiKeyInput: "old-key")

        let accepted = session.acceptCompletion(
            requestID: requestID,
            currentAPIKeyInput: "typed-key"
        )

        #expect(!accepted)
        #expect(session.status == .idle)
        #expect(session.requestID == nil)
    }

    @Test func staleFailureCannotReplaceNewerRequestState() {
        var session = OpenRouterReauthorizationSession()
        let staleRequestID = UUID()
        let currentRequestID = UUID()
        session.begin(requestID: staleRequestID, apiKeyInput: "old-key")
        session.begin(requestID: currentRequestID, apiKeyInput: "old-key")

        let acceptedStaleFailure = session.acceptFailure(
            requestID: staleRequestID,
            currentAPIKeyInput: "old-key",
            message: "stale failure"
        )

        #expect(!acceptedStaleFailure)
        #expect(session.status == .signingIn)
        #expect(session.requestID == currentRequestID)
        let acceptedCurrentFailure = session.acceptFailure(
            requestID: currentRequestID,
            currentAPIKeyInput: "old-key",
            message: "current failure"
        )

        #expect(acceptedCurrentFailure)
        #expect(session.status == .failed("current failure"))
    }

    @Test func currentFailureRedactsCredentialHeaderAndLocalPathCanaries() throws {
        var session = OpenRouterReauthorizationSession()
        let requestID = UUID()
        session.begin(requestID: requestID, apiKeyInput: "old-key")
        let secret = "sk-or-v1-private-123456789"
        let localPath = "/Users/mmeding/Secrets/openrouter.json"
        let bearer = "private-bearer-token-123456789"

        let accepted = session.acceptFailure(
            requestID: requestID,
            currentAPIKeyInput: "old-key",
            message: "Exchange failed for \(secret) at \(localPath); Authorization: Bearer \(bearer)"
        )

        #expect(accepted)
        guard case .failed(let message) = session.status else {
            Issue.record("Expected the current failure to be stored")
            return
        }
        #expect(!message.contains(secret))
        #expect(!message.contains(localPath))
        #expect(!message.contains(bearer))
        #expect(message.contains("sk-***"))
        #expect(message.contains("/[redacted-local-path]"))
        #expect(message.contains("Authorization=***"))
    }
}
