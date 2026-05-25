//
//  PrivacyHighlightAccumulatorTests.swift
//  osaurusTests
//
//  Tests for ChatSession's `sessionRedactions` accumulator. The
//  observer listens for `privacyFilterRedactionsApproved` and folds
//  each (original, placeholder) pair into a window-local dict. We
//  exercise it by posting the notification directly and asserting
//  the resulting dict + FIFO eviction.
//
//  Serialized because ChatSession's notification observer is
//  registered on the global NotificationCenter; concurrent posts
//  from sibling tests would smear into other sessions' accumulators.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Privacy Highlight Accumulator", .serialized)
struct PrivacyHighlightAccumulatorTests {

    /// Yield to the main actor a few times so the Task in the
    /// observer's `.main` queue closure lands. The observer body
    /// captures `self` weakly and dispatches into `Task { @MainActor in ... }`
    /// — we have to flush that one-hop async to read its result.
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
        await Task.yield()
    }

    private func post(sessionId: UUID, pairs: [(String, String)]) {
        let payload: [[String: String]] = pairs.map {
            ["original": $0.0, "placeholder": $0.1]
        }
        NotificationCenter.default.post(
            name: .privacyFilterRedactionsApproved,
            object: nil,
            userInfo: [
                "sessionId": sessionId.uuidString,
                "approvedCount": pairs.count,
                "redactions": payload,
            ]
        )
    }

    @Test func mergesMatchingSessionPayload() async {
        let session = ChatSession()
        let sid = UUID()
        session.sessionId = sid

        post(
            sessionId: sid,
            pairs: [
                ("949-238-0232", "[PHONE_1]"),
                ("alice@example.com", "[EMAIL_1]"),
            ]
        )
        await settle()

        #expect(session.sessionRedactions["949-238-0232"] == "[PHONE_1]")
        #expect(session.sessionRedactions["alice@example.com"] == "[EMAIL_1]")
    }

    @Test func ignoresOtherSessionPayload() async {
        let session = ChatSession()
        session.sessionId = UUID()
        let otherSid = UUID()
        post(sessionId: otherSid, pairs: [("foo", "[X_1]")])
        await settle()
        #expect(session.sessionRedactions.isEmpty)
    }

    @Test func duplicatePairs_areNoOps() async {
        let session = ChatSession()
        let sid = UUID()
        session.sessionId = sid
        post(sessionId: sid, pairs: [("foo", "[X_1]")])
        await settle()
        post(sessionId: sid, pairs: [("foo", "[X_1]")])
        await settle()
        #expect(session.sessionRedactions.count == 1)
        #expect(session.sessionRedactions["foo"] == "[X_1]")
    }

    @Test func fifoEvictionAtCap() async {
        let session = ChatSession()
        let sid = UUID()
        session.sessionId = sid

        // Fill exactly to cap + 5 to exercise the eviction path.
        let cap = ChatSession.maxSessionRedactions
        var pairs: [(String, String)] = []
        for i in 0 ..< (cap + 5) {
            pairs.append(("orig\(i)", "[X_\(i)]"))
        }
        post(sessionId: sid, pairs: pairs)
        await settle()

        // Dict size must clamp to the cap.
        #expect(session.sessionRedactions.count == cap)
        // First 5 originals must have been evicted (FIFO).
        for i in 0 ..< 5 {
            #expect(session.sessionRedactions["orig\(i)"] == nil)
        }
        // Last entries must still be present.
        #expect(session.sessionRedactions["orig\(cap + 4)"] == "[X_\(cap + 4)]")
    }

    @Test func skipsEmptyOriginals() async {
        let session = ChatSession()
        let sid = UUID()
        session.sessionId = sid
        post(
            sessionId: sid,
            pairs: [
                ("", "[X_1]"),
                ("foo", "[X_2]"),
            ]
        )
        await settle()
        #expect(session.sessionRedactions.count == 1)
        #expect(session.sessionRedactions["foo"] == "[X_2]")
    }
}
