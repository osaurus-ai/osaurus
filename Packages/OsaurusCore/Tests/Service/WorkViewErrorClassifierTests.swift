//
//  WorkViewErrorClassifierTests.swift
//  osaurusTests
//
//  Regression tests for the Work-mode error banner classifier. The
//  original heuristic (issue #858) classified HTTP 400 errors as
//  "service temporarily unavailable" because the `"api"` substring
//  matched anywhere (including `ai.google.dev/api/...` URLs in error
//  bodies) and the `"server"` substring over-matched Google's own
//  error strings. These tests lock in the new, status-code-first
//  classification.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct WorkViewErrorClassifierTests {

    // MARK: - #858: the exact cases the classifier must get right

    @Test func gemini_invalidModelName_classifiesAsRequestRejected_notServerError() {
        // Simulates what the user saw in issue #858: typed
        // "gemini 3.1 flash lite preview" — not a real model. If the
        // provider's URL validation catches it, we throw requestFailed
        // with an explanatory string. This must surface as "Request
        // Rejected" with the underlying message, NOT as "Server Error
        // / service temporarily unavailable".
        let err =
            "Invalid Gemini model name 'gemini 3.1 flash lite preview': only letters, digits, '-', '_', and '.' are allowed. Check provider settings."
        let (title, message) = WorkViewErrorClassifier.classify(err)
        #expect(title == "Request Rejected")
        #expect(message.contains("gemini 3.1 flash lite preview"))
    }

    @Test func gemini_http400_modelNotFound_classifiesAsNotFound() {
        // If the provider actually returns 400 "model not found",
        // we want the user to see "Not Found — check the model name",
        // not "Authentication Error" (old `"api"` match) or "Server
        // Error" (old `"server"` match).
        let err = "HTTP 400: model 'gemini-3.1' not found for provider google. See https://ai.google.dev/api/models"
        let (title, _) = WorkViewErrorClassifier.classify(err)
        #expect(title == "Not Found")
    }

    @Test func gemini_http404_modelNotFound_classifiesAsNotFound() {
        let err = "HTTP 404: The model is not found. Visit https://ai.google.dev/api for the catalog."
        let (title, _) = WorkViewErrorClassifier.classify(err)
        #expect(title == "Not Found")
    }

    @Test func http500_classifiesAsServerError() {
        let err = "HTTP 500: Internal server error"
        let (title, _) = WorkViewErrorClassifier.classify(err)
        #expect(title == "Server Error")
    }

    @Test func http503_classifiesAsServerError() {
        let err = "HTTP 503: Service unavailable"
        let (title, _) = WorkViewErrorClassifier.classify(err)
        #expect(title == "Server Error")
    }

    @Test func http401_classifiesAsAuthError() {
        let err = "HTTP 401: Unauthorized"
        let (title, _) = WorkViewErrorClassifier.classify(err)
        #expect(title == "Authentication Error")
    }

    @Test func http403_classifiesAsPermissionDenied() {
        let err = "HTTP 403: Forbidden"
        let (title, _) = WorkViewErrorClassifier.classify(err)
        #expect(title == "Permission Denied")
    }

    @Test func http429_classifiesAsRateLimited() {
        let err = "HTTP 429: Too many requests, slow down"
        let (title, _) = WorkViewErrorClassifier.classify(err)
        #expect(title == "Rate Limited")
    }

    @Test func apiKeyMentionInErrorBody_classifiesAsAuthError_notRequestRejected() {
        // "api key" in the body should still route to auth, even
        // without an explicit HTTP code — some providers just return
        // plain-text errors.
        let err = "Your api key is invalid"
        let (title, _) = WorkViewErrorClassifier.classify(err)
        #expect(title == "Authentication Error")
    }

    // MARK: - Regression guards for old over-matching

    @Test func plainApiMention_doesNotTriggerAuthError() {
        // This used to trip the old classifier because it contained "api".
        // A message mentioning "https://ai.google.dev/api/..." is NOT an
        // auth error on its own.
        let err = "Request body malformed — see docs at https://ai.google.dev/api/rest/v1/models"
        let (title, _) = WorkViewErrorClassifier.classify(err)
        #expect(title != "Authentication Error")
    }

    @Test func plainServerMention_doesNotTriggerServerError() {
        // "server" used to trigger "service temporarily unavailable".
        // A generic message mentioning a server shouldn't route there.
        let err = "The upstream server returned an unexpected payload shape"
        let (title, _) = WorkViewErrorClassifier.classify(err)
        // Should fall through to the generic fallback, not Server Error,
        // because no HTTP 5xx code is present.
        #expect(title != "Server Error")
    }

    // MARK: - Connection / timeout classification (unchanged behavior, locked in)

    @Test func nsurlError_classifiesAsConnection() {
        let err = "The operation couldn't be completed. (NSURLErrorDomain error -1004.)"
        let (title, _) = WorkViewErrorClassifier.classify(err)
        #expect(title == "Connection Issue")
    }

    @Test func timeoutError_classifiesAsTimeout() {
        let err = "The request timed out"
        let (title, _) = WorkViewErrorClassifier.classify(err)
        #expect(title == "Request Timed Out")
    }

    // MARK: - Fallback truncation

    @Test func fallback_usesGenericTitle_andKeepsReasonableDetail() {
        let err = "Some totally unrecognized error message with no keywords"
        let (title, message) = WorkViewErrorClassifier.classify(err)
        #expect(title == "Something Went Wrong")
        #expect(message == err)  // under 200 chars, not truncated
    }

    @Test func fallback_truncatesLongMessageTo200Chars() {
        let err = String(repeating: "x", count: 500)
        let (_, message) = WorkViewErrorClassifier.classify(err)
        #expect(message.hasSuffix("..."))
        #expect(message.count == 203)  // 200 chars + "..."
    }
}
