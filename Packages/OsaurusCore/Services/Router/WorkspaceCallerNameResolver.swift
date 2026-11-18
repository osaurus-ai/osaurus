//
//  WorkspaceCallerNameResolver.swift
//  osaurus
//
//  Host-side lookup of a teammate from the workspace member list, keyed by
//  (workspace, account id / wallet). Returns the teammate's claimed
//  `@handle`, display name and wallet separately so every surface can follow
//  the participant naming contract (`ParticipantFormatter`: handle first,
//  wallet beside it). Used to tag inbound workspace runs in the sidebar,
//  persisted history, approval cards and Insights. Results are cached per
//  workspace with a short TTL; a miss falls back to the caller's wallet so
//  the row never blocks on the network.
//

import Foundation

/// A workspace member as the host knows them at the moment of a run.
struct ResolvedPerson: Equatable, Sendable {
    /// Claimed Osaurus ID handle without `@`.
    var handle: String?
    var displayName: String?
    var wallet: String?

    /// Display name first, else the `@handle` (the legacy single-string form).
    var legacyName: String? {
        if let displayName, !displayName.isEmpty { return displayName }
        return OsaurusRouterWorkspacePerson.handle(handle)
    }
}

/// Looks up the claimed Osaurus handle for a bare wallet, for callers no
/// workspace roster names (an invite-link peer that proved its wallet).
protocol WalletHandleResolver: Sendable {
    func handle(forWallet wallet: String) async -> String?
}

struct NoWalletHandleResolver: WalletHandleResolver {
    func handle(forWallet wallet: String) async -> String? { nil }
}

/// Router `POST /id/lookup`, cached per wallet. A miss or an unreachable
/// router answers nil (the caller shows the short wallet) and is retried
/// after `missTTL`, so a run never waits on more than one short request.
actor RouterWalletHandleResolver: WalletHandleResolver {
    private var cache: [String: (handle: String?, fetchedAt: Date)] = [:]
    private var inflight: [String: Task<String?, Never>] = [:]
    let hitTTL: TimeInterval
    let missTTL: TimeInterval

    var lookup: @Sendable (String) async throws -> String? = { wallet in
        guard OsaurusRouter.isEnabled else { return nil }
        return try await OsaurusRouterAPIClient.shared.osaurusIDLookup(wallets: [wallet])[wallet]
    }

    init(hitTTL: TimeInterval = 1800, missTTL: TimeInterval = 120) {
        self.hitTTL = hitTTL
        self.missTTL = missTTL
    }

    func setLookup(_ lookup: @escaping @Sendable (String) async throws -> String?) {
        self.lookup = lookup
        cache.removeAll()
    }

    func handle(forWallet wallet: String) async -> String? {
        let key = wallet.lowercased()
        guard key.hasPrefix("0x"), key.count == 42 else { return nil }
        if let hit = cache[key],
            Date().timeIntervalSince(hit.fetchedAt) < (hit.handle == nil ? missTTL : hitTTL)
        {
            return hit.handle
        }
        if let task = inflight[key] { return await task.value }
        let lookup = lookup
        let task = Task<String?, Never> { (try? await lookup(key)) ?? nil }
        inflight[key] = task
        let handle = await task.value
        inflight.removeValue(forKey: key)
        cache[key] = (handle, Date())
        return handle
    }
}

enum WalletHandles {
    static let resolver: any WalletHandleResolver = RouterWalletHandleResolver()
}

actor WorkspaceCallerNameResolver {
    static let shared = WorkspaceCallerNameResolver()

    private struct CachedMembers {
        let fetchedAt: Date
        let byAccountId: [String: ResolvedPerson]
        let byWallet: [String: ResolvedPerson]
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

    /// Resolve a caller. Returns nil when unknown so the caller can fall
    /// back to a short wallet.
    func person(workspaceId: String, accountId: String?, wallet: String?) async -> ResolvedPerson? {
        if let hit = lookup(in: await members(for: workspaceId), accountId: accountId, wallet: wallet) {
            return hit
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

    /// Display name first, else `@handle` — the single-string form kept for
    /// callers that predate `person(...)`.
    func displayName(workspaceId: String, accountId: String?, wallet: String?) async -> String? {
        await person(workspaceId: workspaceId, accountId: accountId, wallet: wallet)?.legacyName
    }

    /// Minimum age of a cached member list before a miss triggers a refetch;
    /// keeps a stream of unknown callers from hammering the router.
    static let missRefetchInterval: TimeInterval = 15

    private func lookup(in members: CachedMembers?, accountId: String?, wallet: String?) -> ResolvedPerson? {
        if let accountId, let hit = members?.byAccountId[accountId] { return hit }
        if let wallet, let hit = members?.byWallet[wallet.lowercased()] { return hit }
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
            var byAccount: [String: ResolvedPerson] = [:]
            var byWallet: [String: ResolvedPerson] = [:]
            for member in list {
                let name = member.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let handle = member.osaurusId?.trimmingCharacters(in: .whitespacesAndNewlines)
                let person = ResolvedPerson(
                    handle: handle?.isEmpty == false ? handle : nil,
                    displayName: name?.isEmpty == false ? name : nil,
                    wallet: member.walletAddress?.lowercased()
                )
                // A member with neither a name nor a handle keeps the
                // short-wallet fallback.
                guard person.handle != nil || person.displayName != nil else { continue }
                byAccount[member.accountId] = person
                if let wallet = person.wallet { byWallet[wallet] = person }
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
