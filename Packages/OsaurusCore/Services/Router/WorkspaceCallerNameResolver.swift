//
//  WorkspaceCallerNameResolver.swift
//  osaurus
//
//  Host-side lookup of a teammate's display name from the workspace member
//  list, keyed by (workspace, account id / wallet). Used to tag inbound
//  workspace runs ("Alice → Research Agent", "for Alice · Workspace") in the
//  sidebar Activity section and persisted history. Results are cached per
//  workspace with a short TTL; a miss falls back to the caller's wallet so
//  the row never blocks on the network.
//

import Foundation

actor WorkspaceCallerNameResolver {
    static let shared = WorkspaceCallerNameResolver()

    private struct CachedMembers {
        let fetchedAt: Date
        let byAccountId: [String: String]
        let byWallet: [String: String]
    }

    private var cache: [String: CachedMembers] = [:]
    private var inflight: [String: Task<CachedMembers?, Never>] = [:]
    private let ttl: TimeInterval

    /// Injectable fetch seam (tests).
    var fetchMembers: @Sendable (String) async throws -> [OsaurusRouterWorkspaceMember] = { id in
        try await OsaurusRouterAPIClient.shared.workspaceMembers(id: id)
    }

    init(ttl: TimeInterval = 300) {
        self.ttl = ttl
    }

    /// Resolve the display name for a caller. Returns nil when unknown so the
    /// caller can fall back to a short wallet.
    func displayName(workspaceId: String, accountId: String?, wallet: String?) async -> String? {
        if let name = lookup(in: await members(for: workspaceId), accountId: accountId, wallet: wallet) {
            return name
        }
        // A miss against a cached list usually means the caller joined after
        // we fetched (new teammate's first run). Refetch once, throttled by
        // `missRefetchInterval`, so the very first row is named correctly
        // instead of showing a wallet for up to `ttl`.
        if let cached = cache[workspaceId],
            Date().timeIntervalSince(cached.fetchedAt) >= Self.missRefetchInterval
        {
            cache.removeValue(forKey: workspaceId)
            return lookup(in: await members(for: workspaceId), accountId: accountId, wallet: wallet)
        }
        return nil
    }

    /// Minimum age of a cached member list before a miss triggers a refetch;
    /// keeps a stream of unknown callers from hammering the router.
    static let missRefetchInterval: TimeInterval = 15

    private func lookup(in members: CachedMembers?, accountId: String?, wallet: String?) -> String? {
        if let accountId, let name = members?.byAccountId[accountId], !name.isEmpty {
            return name
        }
        if let wallet, let name = members?.byWallet[wallet.lowercased()], !name.isEmpty {
            return name
        }
        return nil
    }

    /// Drop a workspace's cached roster (e.g. after a membership change).
    func invalidate(workspaceId: String) {
        cache.removeValue(forKey: workspaceId)
    }

    /// Replace the fetch seam (tests).
    func setFetch(_ fetch: @escaping @Sendable (String) async throws -> [OsaurusRouterWorkspaceMember]) {
        fetchMembers = fetch
    }

    /// Backdate a cached member list so a miss is allowed to refetch (tests).
    func ageCacheForTesting(workspaceId: String, by seconds: TimeInterval) {
        guard let hit = cache[workspaceId] else { return }
        cache[workspaceId] = CachedMembers(
            fetchedAt: hit.fetchedAt.addingTimeInterval(-seconds),
            byAccountId: hit.byAccountId,
            byWallet: hit.byWallet
        )
    }

    private func members(for workspaceId: String) async -> CachedMembers? {
        if let hit = cache[workspaceId], Date().timeIntervalSince(hit.fetchedAt) < ttl {
            return hit
        }
        if let task = inflight[workspaceId] {
            return await task.value
        }
        let fetch = fetchMembers
        let task = Task<CachedMembers?, Never> {
            guard let list = try? await fetch(workspaceId) else { return nil }
            var byAccount: [String: String] = [:]
            var byWallet: [String: String] = [:]
            for member in list {
                guard let name = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !name.isEmpty
                else { continue }
                byAccount[member.accountId] = name
                if let wallet = member.walletAddress {
                    byWallet[wallet.lowercased()] = name
                }
            }
            return CachedMembers(fetchedAt: Date(), byAccountId: byAccount, byWallet: byWallet)
        }
        inflight[workspaceId] = task
        let result = await task.value
        inflight.removeValue(forKey: workspaceId)
        if let result {
            cache[workspaceId] = result
        }
        return result
    }
}
