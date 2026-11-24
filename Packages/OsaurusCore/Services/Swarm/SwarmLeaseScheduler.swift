//
//  SwarmLeaseScheduler.swift
//  osaurus
//
//  Reference lease scheduler for the in-process simulator. In production
//  the Swarm master library owns scheduling (one implementation for every
//  master platform); the app only calls `SwarmMasterBackend.acquireLease`.
//  This actor implements the same contract so tests and the simulator
//  exercise the real lifecycle: warm-first node choice, one lease per node,
//  caller affinity, renew, release, expiry while idle, FIFO queue with a
//  deadline, and revocation when a node goes away.
//

import Foundation

actor SwarmLeaseScheduler {
    /// What the scheduler needs to know about one candidate node.
    struct Candidate: Sendable, Equatable {
        let nodeId: SwarmNodeID
        let acceptsLeases: Bool
        let hasModel: Bool
        let warm: Bool
        /// 0...1, lower first.
        let load: Double
        /// Recent decode speed, higher first. Nil when unknown.
        let recentTokensPerSecond: Double?
    }

    /// Current candidates for a pool + model. Called on every attempt so
    /// availability changes (pause, offline, load) are seen immediately.
    typealias CandidateProvider =
        @Sendable (_ poolId: SwarmPoolID, _ nodeIds: [SwarmNodeID], _ modelId: String)
        async -> [Candidate]

    private struct ActiveLease {
        var lease: SwarmLease
        let callerKey: String
        /// Duration each renewal extends the lease by.
        var leaseSeconds: Int
        var inFlight: Int
        /// Granted or renewed for a request that has not started yet. Such a
        /// lease is never reclaimed, so the caller's next request can't lose
        /// its node between acquire and infer.
        var reserved: Bool
    }

    private struct Waiter {
        let id: UUID
        let request: SwarmLeaseRequest
        let continuation: CheckedContinuation<SwarmLease, Error>
    }

    private let candidates: CandidateProvider
    private let now: @Sendable () -> Date
    private var active: [String: ActiveLease] = [:]
    private var waiters: [Waiter] = []
    /// Last node each caller held, so a returning caller lands on the node
    /// that has its prefix cached.
    private var affinity: [String: SwarmNodeID] = [:]

    init(now: @escaping @Sendable () -> Date = Date.init, candidates: @escaping CandidateProvider) {
        self.now = now
        self.candidates = candidates
    }

    // MARK: - Contract

    func acquire(_ request: SwarmLeaseRequest, poolName: String) async throws -> SwarmLease {
        expireIdleLeases()
        // The same caller renews its live lease on the same pool + model.
        if let key = active.first(where: {
            $0.value.callerKey == request.callerKey && $0.value.lease.poolId == request.poolId
                && $0.value.lease.modelId == request.modelId
        })?.key {
            let pool = await candidates(request.poolId, request.nodeIds, request.modelId)
            if let node = active[key]?.lease.nodeId,
                pool.contains(where: { $0.nodeId == node && $0.acceptsLeases && $0.hasModel })
            {
                active[key]?.reserved = true
                return renewInternal(key, seconds: request.leaseSeconds)
            }
            // Its node went away: drop it and pick again.
            active.removeValue(forKey: key)
        }
        if let lease = await tryGrant(request) { return lease }
        guard request.maxWaitSeconds > 0 else {
            throw SwarmError.poolBusy(pool: poolName, waitedSeconds: 0)
        }
        let waiterId = UUID()
        let deadline = request.maxWaitSeconds
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(deadline))
            guard !Task.isCancelled else { return }
            await self?.timeOut(waiterId, poolName: poolName, waited: deadline)
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SwarmLease, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: waiterId, request: request, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterId) }
        }
    }

    func renew(_ leaseId: String, seconds: Int? = nil) throws -> SwarmLease {
        guard active[leaseId] != nil else { throw SwarmError.leaseLost(reason: L("The lease expired.")) }
        return renewInternal(leaseId, seconds: seconds)
    }

    func release(_ leaseId: String) async {
        active.removeValue(forKey: leaseId)
        await serveWaiters()
    }

    /// A request started / ended on this lease. A lease never expires while
    /// a request is running on it.
    func beginRequest(_ leaseId: String) {
        active[leaseId]?.inFlight += 1
        active[leaseId]?.reserved = false
    }

    func endRequest(_ leaseId: String) async {
        guard var entry = active[leaseId] else { return }
        entry.inFlight = max(0, entry.inFlight - 1)
        active[leaseId] = entry
        await serveWaiters()
    }

    /// The node stopped serving (paused, offline, over its cap). Its leases
    /// are lost; returns their ids so in-flight requests can fail typed.
    func revokeLeases(onNode nodeId: SwarmNodeID) -> [String] {
        let lost = active.filter { $0.value.lease.nodeId == nodeId }.map(\.key)
        for id in lost { active.removeValue(forKey: id) }
        return lost
    }

    /// Node availability or library changed: queued callers may fit now.
    func nodesChanged() async {
        expireIdleLeases()
        await serveWaiters()
    }

    func activeLeases() -> [SwarmLease] {
        expireIdleLeases()
        return active.values.map(\.lease).sorted { $0.expiresAt < $1.expiresAt }
    }

    func queuedCount(poolId: SwarmPoolID? = nil) -> Int {
        waiters.filter { poolId == nil || $0.request.poolId == poolId }.count
    }

    func isInFlight(_ leaseId: String) -> Bool {
        (active[leaseId]?.inFlight ?? 0) > 0
    }

    // MARK: - Selection

    /// Prefer warm, then least loaded, then fastest recent token/s; a node
    /// already holding a lease is not free (one lease per node). A caller's
    /// previous node wins ties so its prefix cache is reused.
    static func choose(
        from candidates: [Candidate],
        busy: Set<SwarmNodeID>,
        preferred: SwarmNodeID?
    ) -> Candidate? {
        let free = candidates.filter { $0.acceptsLeases && $0.hasModel && !busy.contains($0.nodeId) }
        if let preferred, let match = free.first(where: { $0.nodeId == preferred }) { return match }
        return free.sorted { a, b in
            if a.warm != b.warm { return a.warm }
            if a.load != b.load { return a.load < b.load }
            let ta = a.recentTokensPerSecond ?? 0
            let tb = b.recentTokensPerSecond ?? 0
            if ta != tb { return ta > tb }
            return a.nodeId < b.nodeId
        }.first
    }

    private func tryGrant(_ request: SwarmLeaseRequest) async -> SwarmLease? {
        expireIdleLeases()
        let pool = await candidates(request.poolId, request.nodeIds, request.modelId)
        let busy = Set(active.values.map(\.lease.nodeId))
        var pick = Self.choose(from: pool, busy: busy, preferred: affinity[request.callerKey])
        if pick == nil, let victim = reclaimIdleSession(request, pool: pool) {
            pick = pool.first { $0.nodeId == victim }
        }
        guard let pick else { return nil }
        // Re-check after the await: another grant may have taken it.
        guard !active.values.contains(where: { $0.lease.nodeId == pick.nodeId }) else { return nil }
        let lease = SwarmLease(
            id: "lease_" + UUID().uuidString.lowercased(),
            poolId: request.poolId,
            nodeId: pick.nodeId,
            modelId: request.modelId,
            expiresAt: now().addingTimeInterval(TimeInterval(max(1, request.leaseSeconds))),
            warm: pick.warm
        )
        active[lease.id] = ActiveLease(
            lease: lease,
            callerKey: request.callerKey,
            leaseSeconds: max(1, request.leaseSeconds),
            inFlight: 0,
            reserved: true
        )
        affinity[request.callerKey] = pick.nodeId
        return lease
    }

    private func renewInternal(_ leaseId: String, seconds: Int?) -> SwarmLease {
        var entry = active[leaseId]!
        if let seconds { entry.leaseSeconds = max(1, seconds) }
        entry.lease.expiresAt = now().addingTimeInterval(TimeInterval(entry.leaseSeconds))
        active[leaseId] = entry
        return entry.lease
    }

    /// Frees the node held longest by another caller's session lease that is
    /// between turns (no request running or about to start), so a waiting
    /// caller is not blocked by an idle conversation. That session's next
    /// turn takes a new lease. Returns the freed node.
    private func reclaimIdleSession(_ request: SwarmLeaseRequest, pool: [Candidate]) -> SwarmNodeID? {
        let usable = Set(pool.filter { $0.acceptsLeases && $0.hasModel }.map(\.nodeId))
        guard
            let victim =
                active
                .filter({
                    $0.value.inFlight == 0 && !$0.value.reserved && $0.value.callerKey != request.callerKey
                        && $0.value.lease.poolId == request.poolId && $0.value.lease.modelId == request.modelId
                        && usable.contains($0.value.lease.nodeId)
                })
                .min(by: { $0.value.lease.expiresAt < $1.value.lease.expiresAt })
        else { return nil }
        active.removeValue(forKey: victim.key)
        return victim.value.lease.nodeId
    }

    /// A lease ends at its expiry only when no request is running on it.
    private func expireIdleLeases() {
        let t = now()
        for (id, entry) in active where entry.lease.expiresAt <= t && entry.inFlight == 0 {
            active.removeValue(forKey: id)
        }
    }

    private func serveWaiters() async {
        var index = 0
        while index < waiters.count {
            let waiter = waiters[index]
            if let lease = await tryGrant(waiter.request) {
                if let position = waiters.firstIndex(where: { $0.id == waiter.id }) {
                    waiters.remove(at: position)
                    waiter.continuation.resume(returning: lease)
                } else {
                    // Timed out or cancelled while we were choosing.
                    active.removeValue(forKey: lease.id)
                }
                continue
            }
            index += 1
        }
    }

    private func timeOut(_ waiterId: UUID, poolName: String, waited: Int) {
        guard let position = waiters.firstIndex(where: { $0.id == waiterId }) else { return }
        let waiter = waiters.remove(at: position)
        waiter.continuation.resume(throwing: SwarmError.poolBusy(pool: poolName, waitedSeconds: waited))
    }

    private func cancelWaiter(_ waiterId: UUID) {
        guard let position = waiters.firstIndex(where: { $0.id == waiterId }) else { return }
        let waiter = waiters.remove(at: position)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
