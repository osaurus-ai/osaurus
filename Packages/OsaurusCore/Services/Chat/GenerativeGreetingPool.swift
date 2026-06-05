//
//  GenerativeGreetingPool.swift
//  osaurus
//
//  Per-agent in-memory cache of pre-generated `GenerativeGreeting`s so the
//  chat empty state can render fresh, model-produced content the instant a
//  session opens — instead of always blocking on the underlying inference.
//
//  Sizing model:
//  - target = 3 entries per agent. The user opens at most a handful of
//    sessions in quick succession; three pre-warmed greetings cover that
//    burst without holding the GPU hostage between turns.
//  - ttl = 30 min. Stale entries don't reflect the latest memory hints
//    or time-of-day phrasing, so we age them out and regenerate.
//  - tick = 5 min. The periodic loop sweeps expired entries across all
//    agents and tops up whatever the user is currently looking at.
//
//  Concurrency: actor-isolated. `warmUp` is coalesced per-agent so a
//  burst of triggers can never spawn parallel inferences against the
//  same agent — MLX is GPU-bound and parallel generations only buy
//  contention. All failures are silent: a refill that throws just
//  leaves the pool below target until the next tick or trigger.
//

import CryptoKit
import Foundation
import os

private let poolLogger = Logger(subsystem: "ai.osaurus", category: "core_model")

public actor GenerativeGreetingPool {
    public static let shared = GenerativeGreetingPool()

    /// Single pre-generated greeting + the agent state it was produced
    /// against. We pin the model name so a mid-session model swap drops
    /// pre-warmed entries that no longer match the user's current
    /// inference path. The `agentRevision` (a hash over persona +
    /// system prompt + persona-relevant settings) lets us discard
    /// stale entries when an agent is edited without waiting for TTL.
    /// `Codable` so the pool can survive app relaunches via
    /// `OsaurusPaths.greetingPoolCacheFile()` — the very first chat
    /// open after a relaunch would otherwise always pay the cold
    /// inference cost.
    private struct Entry: Codable {
        let greeting: GenerativeGreeting
        let model: String
        let agentRevision: Int
        let createdAt: Date
    }

    /// On-disk envelope for `pools`. Versioned so a future format
    /// change can reject older payloads cleanly rather than crashing
    /// the decoder.
    private struct PersistedPool: Codable {
        static let currentSchemaVersion: Int = 1
        var schemaVersion: Int
        var pools: [String: [Entry]]
    }

    private var pools: [UUID: [Entry]] = [:]

    /// Coalesces rapid `seed`/`invalidate`/expire calls into a single
    /// disk write. Cancelled on every dirtying mutation and re-armed.
    private var pendingSaveTask: Task<Void, Never>?
    /// Debounce window for `pendingSaveTask`. Short enough that a
    /// crash within a few seconds of a successful generation still
    /// preserves at least the last entry; long enough that a refill
    /// burst (target = 3) collapses to one disk write.
    private let saveDebounce: UInt64 = 1_000_000_000
    /// Per-agent serializer. Coalesces concurrent `warmUp` calls so the
    /// pool refills sequentially even under a burst (e.g. user
    /// rapid-flipping between sessions). Removed when the task ends so
    /// the next call can spawn a fresh refill.
    private var refillTasks: [UUID: Task<Void, Never>] = [:]

    /// Most recently requested (agent, model). The periodic ticker uses
    /// this to know what to top up when no one is calling `popFresh`
    /// (e.g. the user has the empty state idle for several minutes).
    private var activeAgent: Agent?
    private var activeModel: String?

    /// Pool sizing constants. Exposed via internal `let` so `ChatSession`
    /// can reference them when reasoning about cache hit ratios; kept
    /// non-public to discourage external tuning at this stage.
    let target: Int = 3
    let ttl: TimeInterval = 30 * 60
    private let tickInterval: UInt64 = 5 * 60 * 1_000_000_000

    /// Hard cap on how many agents we keep entries for at once.
    /// Without this, a user that rotates through dozens of agents
    /// would accumulate up to `dozens × target` greetings + agent
    /// snapshots (Agent values can carry kilobytes of system prompt
    /// + MCP config). 10 covers the usual "small set of frequent
    /// agents" pattern and the LRU evicts the rest.
    private let maxAgents = 10
    /// MRU-ordered agent ids. Most-recently-touched is at the END.
    /// Touched on `setActive`, `seed`, and `popFresh` so any of the
    /// "user is interacting with this agent" signals counts.
    private var lruOrder: [UUID] = []

    /// Long-lived periodic sweep. Started lazily on the first public
    /// call so unit tests / preview targets that never instantiate the
    /// pool don't pay for the timer.
    private var tickerStarted = false

    /// Set to `true` after `restoreFromDisk()` finishes its first pass,
    /// so the debounced saver doesn't race against a partial in-memory
    /// state on startup. Without this guard, an early `seed` call could
    /// snapshot `pools` while the restore is still inflating it.
    private var didRestoreFromDisk = false

    /// True while the host is asleep / suspended. Short-circuits both
    /// `warmUp` and the periodic ticker so we don't fire a batch of
    /// inferences right as the user lifts the lid (or worse, while
    /// the lid is still down — macOS may schedule background tasks
    /// before the GPU is fully back online). Toggled by `pause()` /
    /// `resume()` from `ChatWindowManager`'s NSWorkspace observers.
    private var paused = false

    /// Public diagnostics snapshot. Returned by `stats()` and emitted
    /// once per ticker pass at `info` so the Console signal exists
    /// without a new in-app surface. Useful for spot-checking that
    /// the cache is actually serving hits (a regression that silently
    /// turned every open into a cold path would only surface in
    /// user-perceived latency otherwise).
    public struct Stats: Sendable {
        public var hits: Int = 0
        public var misses: Int = 0
        public var refillsStarted: Int = 0
        public var refillsSucceeded: Int = 0
        public var refillsFailed: Int = 0
        public var lastFailure: String? = nil
    }

    private var stats = Stats()

    private init() {}

    // MARK: - Public API

    /// Returns and removes the oldest non-expired entry for `agent.id`,
    /// also pruning any expired or stale-revision entries it skips. The
    /// caller is expected to invoke `warmUp(for:)` on success so the
    /// pool stays at target — separated so the pop is a fast, single
    /// actor hop and the (potentially multi-second) refill happens off
    /// the hot path.
    public func popFresh(for agent: Agent, model: String) -> GenerativeGreeting? {
        startTickerIfNeeded()
        let revision = Self.revision(for: agent)
        prune(agentId: agent.id, model: model, revision: revision)
        guard var queue = pools[agent.id], !queue.isEmpty else {
            stats.misses += 1
            return nil
        }
        let head = queue.removeFirst()
        pools[agent.id] = queue
        touch(agentId: agent.id)
        stats.hits += 1
        scheduleSave()
        return head.greeting
    }

    /// Snapshot of cumulative pool counters. Stable contract for
    /// future diagnostics surfaces; today the per-tick `info` log is
    /// the only consumer.
    public func snapshot() -> Stats {
        stats
    }

    /// Drops a freshly produced greeting into the pool. ChatSession
    /// calls this when the pool was empty and it had to generate a
    /// greeting inline — feeding the result back lets the very first
    /// open of a brand-new session prime the pool for the second open.
    public func seed(_ greeting: GenerativeGreeting, for agent: Agent, model: String) {
        let entry = Entry(
            greeting: greeting,
            model: model,
            agentRevision: Self.revision(for: agent),
            createdAt: Date()
        )
        var queue = pools[agent.id] ?? []
        queue.append(entry)
        pools[agent.id] = queue
        touch(agentId: agent.id)
        evictLRUIfNeeded()
        scheduleSave()
    }

    /// Records the (agent, model) the user is currently looking at so
    /// the periodic ticker has a refill target. Idempotent.
    public func setActive(agent: Agent, model: String) {
        startTickerIfNeeded()
        activeAgent = agent
        activeModel = model
        touch(agentId: agent.id)
        // Mirror to UserDefaults so the next launch's prewarm can fire
        // against the same (agent, model) the user just had open,
        // instead of waiting for the chat view to mount and call us.
        UserDefaults.standard.set(agent.id.uuidString, forKey: Self.lastActiveAgentKey)
        UserDefaults.standard.set(model, forKey: Self.lastActiveModelKey)
    }

    /// UserDefaults keys used by `setActive` / `lastActiveContext()`
    /// to survive process restarts. Versioned (`v1`) so a format
    /// change can ignore stale values on the next launch.
    private static let lastActiveAgentKey = "GenerativeGreetingPool.lastActiveAgentId.v1"
    private static let lastActiveModelKey = "GenerativeGreetingPool.lastActiveModel.v1"

    /// Returns the (agentId, model) recorded by the most recent
    /// `setActive` call across launches. Used by
    /// `AppDelegate.applicationDidFinishLaunching` to prime the pool
    /// before the user opens chat for the first time after a relaunch.
    /// Static so it can be read without spinning up the actor.
    public static func lastActiveContext() -> (agentId: UUID, model: String)? {
        guard
            let raw = UserDefaults.standard.string(forKey: lastActiveAgentKey),
            let id = UUID(uuidString: raw),
            let model = UserDefaults.standard.string(forKey: lastActiveModelKey),
            !model.isEmpty
        else { return nil }
        return (id, model)
    }

    /// Drops the recorded active context if it still matches `agentId`.
    /// Called by `ChatWindowManager.hideWindow` so the periodic ticker
    /// stops topping up the pool once the user has closed every window
    /// for that agent — without that, an idle laptop with the app
    /// running would keep generating a fresh batch every TTL cycle
    /// (3 inferences × every 30 min × 24h = ~144 wasted calls/day on
    /// the GPU / Apple Intelligence).
    ///
    /// Idempotent. Scoped to `agentId` on purpose: hiding window A for
    /// agent X must not clobber window B's still-visible activeAgent
    /// pointer at agent Y.
    public func clearActive(agentId: UUID) {
        guard activeAgent?.id == agentId else { return }
        activeAgent = nil
        activeModel = nil
    }

    /// Drops every entry for `agentId` and cancels any in-flight
    /// refill. Called by `AgentManager.update` / `.delete` so a
    /// settings edit (persona, system prompt, …) doesn't leave stale
    /// pre-generated greetings in the pool.
    public func invalidate(agentId: UUID) {
        pools.removeValue(forKey: agentId)
        if let task = refillTasks.removeValue(forKey: agentId) {
            task.cancel()
        }
        lruOrder.removeAll { $0 == agentId }
        scheduleSave()
    }

    /// Background top-up. Generates greetings sequentially until the
    /// pool reaches `target` (or the task is cancelled / the agent is
    /// invalidated). Coalesced per agent: a second call while a refill
    /// is in flight is a no-op. All failures are swallowed — the next
    /// tick (or `popFresh` cold path) will retry. Skipped entirely
    /// while paused — the wake handler will warm up the active agent.
    public func warmUp(for agent: Agent, model: String) {
        startTickerIfNeeded()
        if paused { return }
        if refillTasks[agent.id] != nil { return }

        let agentId = agent.id
        let snapshot = agent
        let modelSnapshot = model
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRefill(for: snapshot, model: modelSnapshot)
            await self.clearRefillTask(agentId: agentId)
        }
        refillTasks[agentId] = task
    }

    /// Suspend background generation. Cancels every in-flight refill
    /// and short-circuits future `warmUp` / ticker invocations until
    /// `resume()` runs. Wired to `NSWorkspace.willSleepNotification`
    /// in `ChatWindowManager` so a sleeping laptop doesn't keep
    /// burning the GPU on greetings the user can't see.
    public func pause() {
        paused = true
        // Drain BEFORE cancelling: `task.cancel()` is fire-and-forget,
        // but iterating + mutating the same Dictionary is undefined
        // in Swift. The cancelled tasks' `clearRefillTask` callbacks
        // hit an already-empty map and no-op out cleanly.
        let tasks = Array(refillTasks.values)
        refillTasks.removeAll()
        for task in tasks { task.cancel() }
    }

    /// Lift the suspension flag and warm up whatever the user was last
    /// looking at. The pool's normal "is the user mid-stream?" gating
    /// inside `runRefill` still applies. Wired to
    /// `NSWorkspace.didWakeNotification`.
    public func resume() {
        paused = false
        if let agent = activeAgent, let model = activeModel {
            warmUp(for: agent, model: model)
        }
    }

    // MARK: - Internals

    private func clearRefillTask(agentId: UUID) {
        refillTasks.removeValue(forKey: agentId)
    }

    /// Move `agentId` to the MRU end of `lruOrder`. O(N) over the cap,
    /// which is bounded at `maxAgents` (~10) so the linear scan is
    /// effectively free vs. carrying around a doubly-linked list.
    private func touch(agentId: UUID) {
        if let idx = lruOrder.firstIndex(of: agentId) {
            lruOrder.remove(at: idx)
        }
        lruOrder.append(agentId)
    }

    /// Evict the least-recently-touched agents until the pool dict
    /// fits inside `maxAgents`. Cancels any in-flight refill for the
    /// evicted ids and drops their pool entries. The active agent is
    /// always at the MRU end (touched on `setActive`) so eviction
    /// only ever targets background entries.
    private func evictLRUIfNeeded() {
        while pools.count > maxAgents, let oldest = lruOrder.first {
            lruOrder.removeFirst()
            pools.removeValue(forKey: oldest)
            if let task = refillTasks.removeValue(forKey: oldest) {
                task.cancel()
            }
        }
    }

    private func runRefill(for agent: Agent, model: String) async {
        // Loop instead of computing the gap upfront: the count can drop
        // mid-refill if `popFresh` runs against the same agent (user
        // opened another session). Re-checking each iteration keeps us
        // converging on `target` rather than overshooting.
        while !Task.isCancelled {
            // Every background path (ticker, wake-resume, launch prewarm)
            // funnels through here, so this is the one gate that stops
            // generation once the feature is toggled off mid-refill.
            guard await isGreetingEnabled(for: agent.id) else { break }

            let preRevision = Self.revision(for: agent)
            prune(agentId: agent.id, model: model, revision: preRevision)
            let count = pools[agent.id]?.count ?? 0
            if count >= target { break }

            // Yield to interactive inference. Greetings share the MLX
            // GPU context with the user's active chat turn — running
            // both concurrently halves the user-visible TPS. Poll on a
            // short sleep with a hard cap so we don't starve the pool
            // entirely if the user is sustaining a long stream.
            if await waitForIdleInference() == false { break }

            // Count the attempt only once we've cleared the target +
            // idle gates. Counting earlier conflated "entered runRefill"
            // with "tried to generate" and made the success ratio in
            // the tick log look worse than it actually was.
            stats.refillsStarted += 1
            do {
                let greeting = try await GenerativeGreetingService.shared.generate(
                    agent: agent,
                    fallbackModel: model
                )
                guard !Task.isCancelled else { break }
                // Drop the result if the live agent's revision drifted
                // mid-inference. `invalidate(agentId:)` cancels the
                // task on `AgentManager.update`, but the cancel hops
                // through this actor's mailbox — under contention the
                // refill can complete BEFORE the cancel is observed,
                // and we'd otherwise seed a stale entry that the next
                // popFresh's `prune` would just discard. Cheaper to
                // catch it here than to let it round-trip through the
                // pool. Hop to the main actor since `AgentManager` is
                // `@MainActor`-isolated.
                let liveRevision: Int? = await MainActor.run {
                    guard let live = AgentManager.shared.agent(for: agent.id) else { return nil }
                    return Self.revision(for: live)
                }
                if liveRevision != preRevision { break }
                seed(greeting, for: agent, model: model)
                stats.refillsSucceeded += 1
            } catch {
                // Silent failure mode matches the rest of the
                // generative-greeting pipeline: a model that's slow,
                // overloaded, or producing malformed JSON should not
                // surface a user-visible error. Bail out of this
                // refill cycle and let the next trigger retry.
                let desc = error.localizedDescription
                stats.refillsFailed += 1
                stats.lastFailure = desc
                poolLogger.warning("greeting pool: refill failed: \(desc)")
                break
            }
        }
    }

    /// Resolved on/off state for `agentId` (per-agent override > global
    /// flag). Hops to the main actor since `AgentManager` and
    /// `AppConfiguration` are `@MainActor`-isolated, and returns `false`
    /// when the agent was deleted between launches.
    private func isGreetingEnabled(for agentId: UUID) async -> Bool {
        await MainActor.run {
            AgentManager.shared.agent(for: agentId)?.shouldUseGenerativeGreetings ?? false
        }
    }

    /// Wait (max ~30 s, in 2 s slices) for any active chat stream to
    /// finish before generating a background greeting. Returns `true`
    /// when the host is idle (or no stream was ever in flight) and the
    /// caller should proceed; `false` when the cap elapsed and the
    /// caller should bail and let the next trigger retry. Cancellation
    /// short-circuits to `false`.
    private func waitForIdleInference() async -> Bool {
        let pollInterval: UInt64 = 2_000_000_000
        let maxWaits = 15
        var waits = 0
        while !Task.isCancelled {
            let busy = await MainActor.run {
                ChatWindowManager.shared.isAnySessionStreaming
            }
            if !busy { return true }
            if waits >= maxWaits { return false }
            try? await Task.sleep(nanoseconds: pollInterval)
            waits += 1
        }
        return false
    }

    /// Removes entries for `agentId` whose model no longer matches
    /// `model`, whose `agentRevision` has drifted (settings edited),
    /// or whose `createdAt` is older than `ttl`.
    private func prune(agentId: UUID, model: String, revision: Int) {
        guard var queue = pools[agentId] else { return }
        let now = Date()
        let originalCount = queue.count
        queue.removeAll { entry in
            entry.model != model
                || entry.agentRevision != revision
                || now.timeIntervalSince(entry.createdAt) > ttl
        }
        let mutated = queue.count != originalCount
        if queue.isEmpty {
            pools.removeValue(forKey: agentId)
        } else {
            pools[agentId] = queue
        }
        if mutated {
            scheduleSave()
        }
    }

    /// Stable hash over the agent fields that influence greeting
    /// generation. `String.hashValue` is per-process randomized, so a
    /// pool entry stamped with revision X in one launch would never
    /// match revision X in the next launch — fine for an in-memory
    /// pool today, but a footgun if we ever persist entries. We fold
    /// the first 8 bytes of an MD5 digest into an `Int` instead.
    /// MD5 is non-cryptographic here; we just need determinism, not
    /// collision resistance, and the inputs are all internal.
    private static func revision(for agent: Agent) -> Int {
        let parts: [String] = [
            agent.systemPrompt,
            agent.settings.greetingPersona ?? "",
            agent.name,
            agent.description,
        ]
        let joined = parts.joined(separator: "|")
        guard let data = joined.data(using: .utf8) else { return 0 }
        let digest = Insecure.MD5.hash(data: data)
        // Fold the first 8 bytes into an Int. Sign-bit risk is fine —
        // collisions only matter as equality, not ordering, and the
        // wraparound math behaves identically across launches.
        var value: UInt64 = 0
        for (i, byte) in digest.prefix(8).enumerated() {
            value |= UInt64(byte) << (UInt64(i) * 8)
        }
        return Int(bitPattern: UInt(value))
    }

    private func startTickerIfNeeded() {
        guard !tickerStarted else { return }
        tickerStarted = true
        // Restore previously persisted entries off the main path so the
        // very first user-visible chat open after relaunch can already
        // pop a warmed entry. Sequenced before the ticker loop so the
        // periodic sweep doesn't observe a partially-hydrated pool.
        Task { [weak self] in
            guard let self else { return }
            await self.restoreFromDisk()
            await self.runTickerLoop()
        }
    }

    // MARK: - Persistence

    /// Loads the on-disk JSON cache and merges its entries into `pools`,
    /// applying the existing TTL filter so anything older than `ttl`
    /// gets dropped immediately. Revision drift is handled lazily on
    /// the next `popFresh` / `runRefill` call, since the live revision
    /// isn't known here without hopping to `AgentManager`.
    private func restoreFromDisk() async {
        defer { didRestoreFromDisk = true }
        let url = OsaurusPaths.greetingPoolCacheFile()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(PersistedPool.self, from: data)
            guard payload.schemaVersion == PersistedPool.currentSchemaVersion else {
                poolLogger.info(
                    "greeting pool: dropping persisted cache with schema v\(payload.schemaVersion)"
                )
                return
            }
            let now = Date()
            var restored: [UUID: [Entry]] = [:]
            for (key, entries) in payload.pools {
                guard let agentId = UUID(uuidString: key) else { continue }
                let kept = entries.filter { now.timeIntervalSince($0.createdAt) <= ttl }
                if !kept.isEmpty {
                    restored[agentId] = kept
                }
            }
            // Merge so any entries seeded between actor init and the
            // restore completing aren't clobbered.
            for (agentId, entries) in restored {
                pools[agentId, default: []].append(contentsOf: entries)
                touch(agentId: agentId)
            }
            evictLRUIfNeeded()
            poolLogger.info(
                "greeting pool: restored \(restored.values.reduce(0) { $0 + $1.count }) entries across \(restored.count) agents"
            )
        } catch {
            poolLogger.warning(
                "greeting pool: restore failed: \(error.localizedDescription)"
            )
        }
    }

    /// Debounced disk write. Calling this multiple times within
    /// `saveDebounce` collapses to a single save. Skipped while the
    /// initial restore is still running so we don't truncate the file
    /// to a partial snapshot.
    private func scheduleSave() {
        guard didRestoreFromDisk else { return }
        pendingSaveTask?.cancel()
        let interval = saveDebounce
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: interval)
            guard !Task.isCancelled else { return }
            await self?.saveToDiskNow()
        }
    }

    /// Synchronously flush any pending save. Wired to
    /// `applicationWillTerminate` so a clean quit always preserves
    /// the latest entries.
    public func flushPendingSave() async {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        await saveToDiskNow()
    }

    private func saveToDiskNow() async {
        let snapshot: [String: [Entry]] = pools.reduce(into: [:]) { acc, pair in
            acc[pair.key.uuidString] = pair.value
        }
        let payload = PersistedPool(
            schemaVersion: PersistedPool.currentSchemaVersion,
            pools: snapshot
        )
        let url = OsaurusPaths.greetingPoolCacheFile()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let data = try JSONEncoder().encode(payload)
            // Atomic write so a crash mid-save can't leave the file in
            // a half-written state that breaks the next restore.
            try data.write(to: url, options: [.atomic])
        } catch {
            poolLogger.warning(
                "greeting pool: save failed: \(error.localizedDescription)"
            )
        }
    }

    /// 5-min sweep that purges expired entries across all agents and
    /// tops up the active agent's pool. Cheap when idle (no agent
    /// active, no entries to expire) and bounded by `warmUp`'s
    /// per-agent coalescing so a slow inference can never compound.
    /// Skips the warm-up arm entirely if the user is mid-stream — the
    /// per-iteration `waitForIdleInference` inside `runRefill` would
    /// catch it eventually, but bailing here avoids spawning a Task
    /// that just sits in a polling loop.
    private func runTickerLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: tickInterval)
            if Task.isCancelled { break }
            purgeAllExpired()
            logTickSummary()
            if paused { continue }
            guard let agent = activeAgent, let model = activeModel else { continue }
            // Drop the stale active context when the feature was toggled
            // off so the loop goes fully idle next tick instead of
            // re-arming a refill that `runRefill` would just bail out of.
            guard await isGreetingEnabled(for: agent.id) else {
                clearActive(agentId: agent.id)
                continue
            }
            let busy = await MainActor.run {
                ChatWindowManager.shared.isAnySessionStreaming
            }
            if busy { continue }
            warmUp(for: agent, model: model)
        }
    }

    /// One-line `info` summary of cumulative counters. Cheap; runs
    /// every `tickInterval` (5 min) regardless of whether the pool is
    /// active so a long idle period still shows up in the log as a
    /// stable counter rather than a gap.
    private func logTickSummary() {
        let agents = pools.count
        let entries = pools.values.reduce(0) { $0 + $1.count }
        poolLogger.info(
            "greeting pool tick: agents=\(agents) entries=\(entries) hits=\(self.stats.hits) misses=\(self.stats.misses) refills=\(self.stats.refillsSucceeded)/\(self.stats.refillsStarted) failed=\(self.stats.refillsFailed)"
        )
    }

    private func purgeAllExpired() {
        let now = Date()
        var changed = false
        for (agentId, queue) in pools {
            let kept = queue.filter { now.timeIntervalSince($0.createdAt) <= ttl }
            if kept.isEmpty {
                pools.removeValue(forKey: agentId)
                changed = true
            } else if kept.count != queue.count {
                pools[agentId] = kept
                changed = true
            }
        }
        if changed {
            scheduleSave()
        }
    }
}

// MARK: - Test hooks

#if DEBUG
    extension GenerativeGreetingPool {
        /// Clear the in-memory pool and re-run the on-disk restore.
        /// Production code never touches this — the singleton's
        /// `tickerStarted` guard makes restore a one-shot, but the
        /// persistence tests need to drive multiple restore cycles
        /// against synthetic disk payloads.
        internal func _testingReloadFromDisk() async {
            pools.removeAll()
            lruOrder.removeAll()
            didRestoreFromDisk = false
            await restoreFromDisk()
        }

        /// Wipe in-memory state without touching disk so persistence
        /// tests start from a known-empty baseline even though the
        /// singleton survives across cases.
        internal func _testingResetInMemory() {
            pools.removeAll()
            lruOrder.removeAll()
            pendingSaveTask?.cancel()
            pendingSaveTask = nil
            didRestoreFromDisk = true
        }

        /// In-memory entry count for `agentId`.
        internal func _testingEntryCount(for agentId: UUID) -> Int {
            pools[agentId]?.count ?? 0
        }
    }
#endif
