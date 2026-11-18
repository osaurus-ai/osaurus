//
//  WorkspaceAttestationProvider.swift
//  osaurus
//
//  Fresh router workspace attestations for the store registry: sharing a
//  workflow with a workspace, listing a workspace's workflows, and
//  installing one. A token lives 10 minutes; one is reused until a minute
//  before it expires so a list followed by an install mints once.
//  Attestations are bearer tokens and only ever travel in the
//  `X-Workspace-Attestation` header.
//

import Foundation

enum WorkspaceAttestationMintError: LocalizedError, Equatable {
    case routerDisabled
    case suspended

    var errorDescription: String? {
        switch self {
        case .routerDisabled:
            return L("Sign in to Osaurus Router to use workspace workflows.")
        case .suspended:
            return L("This workspace's plan isn't active, so its workflows are paused until the owner renews it.")
        }
    }
}

actor WorkspaceAttestationProvider {
    static let shared = WorkspaceAttestationProvider()

    /// `X-Workspace-Attestation`.
    static let header = "X-Workspace-Attestation"

    typealias Mint = @Sendable (String) async throws -> String

    private struct Cached {
        let token: String
        let reuseUntil: Date
    }

    private var cache: [String: Cached] = [:]
    private var mintOverride: Mint?
    private let now: @Sendable () -> Date

    init(mint: Mint? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.mintOverride = mint
        self.now = now
    }

    /// Test seam.
    func setMint(_ mint: Mint?) {
        mintOverride = mint
        cache.removeAll()
    }

    /// An attestation for `workspaceID` minted to this Mac's wallet. Throws
    /// `.suspended` when the router says the workspace isn't active, since
    /// the registry refuses those anyway.
    func attestation(for workspaceID: String) async throws -> String {
        let key = workspaceID.lowercased()
        if let cached = cache[key], cached.reuseUntil > now() { return cached.token }
        let token: String
        if let mintOverride {
            token = try await mintOverride(key)
        } else {
            guard OsaurusRouter.isEnabled else { throw WorkspaceAttestationMintError.routerDisabled }
            token = try await OsaurusRouterAPIClient.shared.workspaceAttestation(id: key).attestation
        }
        let payload = WorkspaceMembershipAttestation.unverifiedPayload(token: token)
        if payload?.workspaceSuspended == true {
            cache[key] = nil
            throw WorkspaceAttestationMintError.suspended
        }
        let expires = payload.map { Date(timeIntervalSince1970: TimeInterval($0.exp)) } ?? now().addingTimeInterval(600)
        cache[key] = Cached(token: token, reuseUntil: expires.addingTimeInterval(-60))
        return token
    }

    /// Forgets a token the registry refused (a membership or key change).
    func invalidate(_ workspaceID: String) {
        cache[workspaceID.lowercased()] = nil
    }
}
