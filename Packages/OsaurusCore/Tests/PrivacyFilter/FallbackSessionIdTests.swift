//
//  FallbackSessionIdTests.swift
//  osaurus / PrivacyFilter Tests
//
//  H3 regression: `PrivacyFilterPipeline.fallbackSessionId(for:)`
//  used to be a content hash of `messages`. That meant two
//  unrelated requests that happened to share the same system
//  prompt + greeting (very common in OpenAI-shaped APIs) collided
//  on a single `RedactionMap`. The first request's `[PHONE_1]`
//  would resolve into the second request's "Jane Smith" on inbound
//  unscrub — a real cross-session privacy bug.
//
//  The fix mints a fresh UUID per call. These tests lock the new
//  contract:
//    1. Two calls with identical `messages` return DIFFERENT ids.
//    2. The id format stays grep-friendly (`pf-anon-<uuid>`) so the
//       Insights view can tag fallback sessions distinctly.
//    3. Empty/edge-case message arrays still produce a stable shape.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("fallbackSessionId collision regression")
struct FallbackSessionIdTests {

    /// Canonical case: two calls with the SAME `messages` payload
    /// must not collide. Pre-fix, both would return the same hash;
    /// the test would fail. Post-fix, each call mints a UUID.
    @Test func identicalMessages_returnDistinctIds() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "You are a helpful assistant."),
            ChatMessage(role: "user", content: "Hi, my name is Jane Smith."),
        ]
        let a = PrivacyFilterPipeline.fallbackSessionId(for: messages)
        let b = PrivacyFilterPipeline.fallbackSessionId(for: messages)
        #expect(a != b, "fallback ids must differ even for identical messages")
    }

    /// 16 rapid calls — guards against any future regression that
    /// re-introduces a content-derived id (e.g. someone replacing
    /// the UUID with a hash for "stability"). Sets and uniqueness
    /// make the test cheap and unambiguous.
    @Test func manyCalls_allUnique() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "ping")
        ]
        var seen: Set<String> = []
        for _ in 0 ..< 16 {
            seen.insert(PrivacyFilterPipeline.fallbackSessionId(for: messages))
        }
        #expect(seen.count == 16, "16 calls must produce 16 distinct ids")
    }

    /// The Insights / logging surface relies on the `pf-anon-`
    /// prefix to label fallback sessions ("no client-supplied
    /// session_id"). Pin the format so the UI doesn't silently
    /// lose its label if someone changes the factory.
    @Test func idShape_isStable() {
        let messages: [ChatMessage] = [ChatMessage(role: "user", content: "ping")]
        let id = PrivacyFilterPipeline.fallbackSessionId(for: messages)
        #expect(id.hasPrefix("pf-anon-"), "id must keep the pf-anon- prefix")
        let suffix = id.dropFirst("pf-anon-".count)
        // UUID-shaped: 36 chars, four dashes. We don't need to RE-
        // validate the UUID grammar — just that it's the right
        // shape for the Insights view's grouping logic.
        #expect(suffix.count == 36)
        #expect(suffix.filter { $0 == "-" }.count == 4)
    }

    /// Empty messages used to hash to the empty-payload id and
    /// cross-collide every empty request. Confirm the empty case
    /// also produces fresh ids per call.
    @Test func emptyMessages_stillProduceFreshIds() {
        let messages: [ChatMessage] = []
        let a = PrivacyFilterPipeline.fallbackSessionId(for: messages)
        let b = PrivacyFilterPipeline.fallbackSessionId(for: messages)
        #expect(a != b)
        #expect(a.hasPrefix("pf-anon-"))
    }
}
