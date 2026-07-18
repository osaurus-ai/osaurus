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
}
