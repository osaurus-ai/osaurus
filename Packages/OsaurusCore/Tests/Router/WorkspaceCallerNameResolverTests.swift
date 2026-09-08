//
//  WorkspaceCallerNameResolverTests.swift
//  osaurusTests
//
//  The host tags inbound workspace runs with the caller's display name from
//  the member list. The list is cached, so a teammate who joined *after* the
//  cache filled would otherwise show as a bare wallet for the whole TTL on
//  their very first run. A miss must refetch once (throttled), and a stream
//  of genuinely unknown callers must not refetch on every lookup.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct WorkspaceCallerNameResolverTests {

    private static func member(accountId: String, wallet: String, name: String) throws
        -> OsaurusRouterWorkspaceMember
    {
        let body = """
            {"account_id":"\(accountId)","wallet_address":"\(wallet)","dino_id":null,
             "display_name":"\(name)","role":"member","agents_shared":0,
             "joined_at":"2026-08-31T00:00:00.000Z"}
            """
        return try JSONDecoder().decode(OsaurusRouterWorkspaceMember.self, from: Data(body.utf8))
    }

    /// Thread-safe fetch recorder: returns the current member list and counts calls.
    private final class FetchStub: @unchecked Sendable {
        private let lock = NSLock()
        private var _members: [OsaurusRouterWorkspaceMember]
        private var _calls = 0
        init(_ members: [OsaurusRouterWorkspaceMember]) { _members = members }
        var calls: Int { lock.withLock { _calls } }
        func set(_ members: [OsaurusRouterWorkspaceMember]) { lock.withLock { _members = members } }
        func fetch(_ id: String) -> [OsaurusRouterWorkspaceMember] {
            lock.withLock {
                _calls += 1
                return _members
            }
        }
    }

    @Test func cachedHit_doesNotRefetch() async throws {
        let stub = FetchStub([try Self.member(accountId: "a1", wallet: "0xAAA1", name: "Alice")])
        let resolver = WorkspaceCallerNameResolver(ttl: 300)
        await resolver.setFetch { stub.fetch($0) }

        #expect(await resolver.displayName(workspaceId: "ws", accountId: "a1", wallet: nil) == "Alice")
        #expect(await resolver.displayName(workspaceId: "ws", accountId: nil, wallet: "0xaaa1") == "Alice")
        #expect(stub.calls == 1, "both hits are served from the cache")
    }

    @Test func missAgainstStaleCache_refetchesOnceAndFindsNewMember() async throws {
        let stub = FetchStub([try Self.member(accountId: "a1", wallet: "0xAAA1", name: "Alice")])
        let resolver = WorkspaceCallerNameResolver(ttl: 300)
        await resolver.setFetch { stub.fetch($0) }
        // Fill the cache, then age it past the miss-refetch threshold.
        _ = await resolver.displayName(workspaceId: "ws", accountId: "a1", wallet: nil)
        await resolver.ageCacheForTesting(workspaceId: "ws", by: WorkspaceCallerNameResolver.missRefetchInterval + 1)

        // Bob joins after the fetch, then invokes an agent.
        stub.set([
            try Self.member(accountId: "a1", wallet: "0xAAA1", name: "Alice"),
            try Self.member(accountId: "b2", wallet: "0xBBB2", name: "Bob"),
        ])

        #expect(await resolver.displayName(workspaceId: "ws", accountId: "b2", wallet: nil) == "Bob")
        #expect(stub.calls == 2, "exactly one refetch on the miss")
    }

    @Test func missAgainstFreshCache_doesNotRefetch() async throws {
        let stub = FetchStub([try Self.member(accountId: "a1", wallet: "0xAAA1", name: "Alice")])
        let resolver = WorkspaceCallerNameResolver(ttl: 300)
        await resolver.setFetch { stub.fetch($0) }
        _ = await resolver.displayName(workspaceId: "ws", accountId: "a1", wallet: nil)

        // Unknown callers right after a fetch fall back to the wallet
        // without hammering the router.
        #expect(await resolver.displayName(workspaceId: "ws", accountId: "zzz", wallet: nil) == nil)
        #expect(await resolver.displayName(workspaceId: "ws", accountId: "yyy", wallet: nil) == nil)
        #expect(stub.calls == 1)
    }
}
