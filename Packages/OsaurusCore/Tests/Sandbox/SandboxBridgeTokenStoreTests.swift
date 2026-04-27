//
//  SandboxBridgeTokenStoreTests.swift
//  OsaurusCoreTests
//
//  Verifies the per-agent bridge token store: tokens are unique per user,
//  registration is idempotent for the same Linux user, unknown tokens fail
//  closed, and revocation removes both lookup directions.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("SandboxBridgeTokenStore")
struct SandboxBridgeTokenStoreTests {

    @Test
    func register_returnsStableTokenForSameUser() async {
        let store = SandboxBridgeTokenStore()
        let agent = UUID()
        let t1 = await store.register(agentId: agent, linuxName: "agent-test")
        let t2 = await store.register(agentId: agent, linuxName: "agent-test")
        #expect(t1 == t2)
    }

    @Test
    func register_returnsDistinctTokensPerUser() async {
        let store = SandboxBridgeTokenStore()
        let t1 = await store.register(agentId: UUID(), linuxName: "agent-a")
        let t2 = await store.register(agentId: UUID(), linuxName: "agent-b")
        #expect(t1 != t2)
    }

    @Test
    func resolve_returnsBoundIdentity() async {
        let store = SandboxBridgeTokenStore()
        let agent = UUID()
        let token = await store.register(agentId: agent, linuxName: "agent-test")
        let resolved = await store.resolve(token: token)
        #expect(resolved?.agentId == agent)
        #expect(resolved?.linuxName == "agent-test")
    }

    @Test
    func resolve_unknownToken_returnsNil() async {
        let store = SandboxBridgeTokenStore()
        _ = await store.register(agentId: UUID(), linuxName: "agent-a")
        let resolved = await store.resolve(token: "this-is-not-a-real-token")
        #expect(resolved == nil)
    }

    @Test
    func resolve_emptyToken_returnsNil() async {
        let store = SandboxBridgeTokenStore()
        _ = await store.register(agentId: UUID(), linuxName: "agent-a")
        let resolved = await store.resolve(token: "")
        #expect(resolved == nil)
    }

    @Test
    func revoke_dropsToken() async {
        let store = SandboxBridgeTokenStore()
        let agent = UUID()
        let token = await store.register(agentId: agent, linuxName: "agent-x")
        let removed = await store.revoke(linuxName: "agent-x")
        #expect(removed == true)
        let resolved = await store.resolve(token: token)
        #expect(resolved == nil)
    }

    @Test
    func revoke_unknownUser_returnsFalse() async {
        let store = SandboxBridgeTokenStore()
        let removed = await store.revoke(linuxName: "agent-never-registered")
        #expect(removed == false)
    }

    @Test
    func revokeAll_clearsEverything() async {
        let store = SandboxBridgeTokenStore()
        let t1 = await store.register(agentId: UUID(), linuxName: "agent-a")
        let t2 = await store.register(agentId: UUID(), linuxName: "agent-b")
        await store.revokeAll()
        let r1 = await store.resolve(token: t1)
        let r2 = await store.resolve(token: t2)
        #expect(r1 == nil)
        #expect(r2 == nil)
        let count = await store.tokenCount()
        #expect(count == 0)
    }

    @Test
    func tokens_areLongEnoughToBeUnpredictable() async {
        // 256 bits of entropy → base64url is at least 43 chars (no padding).
        let store = SandboxBridgeTokenStore()
        let token = await store.register(agentId: UUID(), linuxName: "agent-len")
        #expect(token.count >= 43)
        // base64url alphabet only.
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for ch in token {
            #expect(allowed.contains(ch))
        }
    }
}
