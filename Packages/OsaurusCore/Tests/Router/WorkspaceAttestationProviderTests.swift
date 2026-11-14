//
//  WorkspaceAttestationProviderTests.swift
//  OsaurusCoreTests
//
//  Attestations for the store registry: one mint serves until a minute
//  before it expires, a suspended workspace is refused instead of cached,
//  and a refused token can be dropped.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkspaceAttestationProviderTests {
    /// An unsigned token with the payload fields the provider reads.
    private static func token(_ workspaceID: String, exp: Int, status: String? = nil, serial: Int = 0) -> String {
        var payload: [String: Any] = [
            "v": 1, "workspace_id": workspaceID, "account_id": "acct", "wallet": "0xabc", "role": "member",
            "iat": exp - 600, "exp": exp, "serial": serial,
        ]
        if let status { payload["workspace_status"] = status }
        let json = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let body = json.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return body + ".c2ln"
    }

    @Test
    func aTokenIsReusedUntilAMinuteBeforeItExpires() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000))
        let mints = Counter()
        let provider = WorkspaceAttestationProvider(
            mint: { id in
                let n = await mints.next()
                return Self.token(id, exp: 1_600, serial: n)
            }, now: { clock.now })

        let first = try await provider.attestation(for: "WS-1")
        #expect(try await provider.attestation(for: "ws-1") == first, "ids are case-insensitive")
        #expect(await mints.value == 1)

        clock.now = Date(timeIntervalSince1970: 1_539)
        #expect(try await provider.attestation(for: "ws-1") == first)
        clock.now = Date(timeIntervalSince1970: 1_541)
        let second = try await provider.attestation(for: "ws-1")
        #expect(second != first)
        #expect(await mints.value == 2)

        await provider.invalidate("ws-1")
        _ = try await provider.attestation(for: "ws-1")
        #expect(await mints.value == 3)
    }

    @Test
    func aSuspendedWorkspaceIsRefused_andNotCached() async throws {
        let mints = Counter()
        let provider = WorkspaceAttestationProvider(
            mint: { id in
                _ = await mints.next()
                return Self.token(id, exp: Int(Date().timeIntervalSince1970) + 600, status: "suspended")
            })
        await #expect(throws: WorkspaceAttestationMintError.suspended) {
            try await provider.attestation(for: "ws-1")
        }
        await #expect(throws: WorkspaceAttestationMintError.suspended) {
            try await provider.attestation(for: "ws-1")
        }
        #expect(await mints.value == 2)
    }

    @Test
    @MainActor
    func onlyActiveWorkspacesWhereYouCanShareAreOffered() {
        let list = [
            OsaurusRouterWorkspaceSummary(id: "owner", name: "A", role: "owner", source: "subscription", active: true),
            OsaurusRouterWorkspaceSummary(id: "member", name: "B", role: "member", active: true),
            OsaurusRouterWorkspaceSummary(id: "older-router", name: "C", role: "admin"),
            OsaurusRouterWorkspaceSummary(id: "viewer", name: "D", role: "viewer", active: true),
            OsaurusRouterWorkspaceSummary(id: "lapsed", name: "E", role: "owner", source: "subscription", active: false),
            OsaurusRouterWorkspaceSummary(id: "suspended", name: "F", role: "member", source: "suspended", active: true),
            OsaurusRouterWorkspaceSummary(id: "future", name: "G", role: "superuser", active: true),
        ]
        #expect(WorkspaceShareChooser.eligible(list).map(\.id) == ["owner", "member", "older-router"])
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

private actor Counter {
    private(set) var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}
