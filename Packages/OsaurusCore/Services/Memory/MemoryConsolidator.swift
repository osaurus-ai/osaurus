//
//  MemoryConsolidator.swift
//  osaurus
//
//  Background consolidation loop. Runs at most once every
//  `consolidationIntervalHours` (default 24h) on a low-priority detached
//  task. Performs:
//
//    1. Salience decay      — `score *= 0.5 ^ (Δdays / halfLife)` for pinned
//                             facts and episodes.
//    2. Episode merge       — combine near-duplicate episodes from the same
//                             agent (cheap content-overlap check; cosine
//                             when embeddings are available is left for a
//                             later pass).
//    3. Pinned promotion    — facts that appear (via tags / content match)
//                             across `pinnedPromotionThreshold` episodes get
//                             a salience boost.
//    4. Eviction            — pinned facts below `salienceFloor` and idle
//                             for >30 days are deleted.
//    5. Transcript pruning  — turns older than `episodeRetentionDays` are
//                             removed.
//
//  Scheduling: the last successful run is persisted in `UserDefaults`, and a
//  short ticker (every 30 minutes, first tick ~1 minute after launch) runs a
//  pass whenever `now - lastRun >= interval`. The interval therefore means
//  "at most once per N hours" rather than "after N hours of continuous
//  uptime". Pre-fix, the loop slept for the full interval before its first
//  pass and the timestamp lived only in memory, so on any normal usage
//  pattern (quit, update, reboot) the consolidator never fired at all.
//
//  Scheduled passes are deferred while inference or chat work is in flight
//  and retried on the next tick. The explicit "Run Now" button in
//  `MemoryView` bypasses both the interval and the idle gate.
//

import CryptoKit
import Foundation
import os

public actor MemoryConsolidator {
    public static let shared = MemoryConsolidator()

    /// Outcome of a `runOnce()` call, so callers (the "Run Now" button) can
    /// tell the user why nothing happened instead of silently returning.
    public enum RunOutcome: Sendable, Equatable {
        case completed
        case skippedAlreadyRunning
        case skippedDisabled
        case skippedDatabaseClosed
    }

    /// `UserDefaults` key holding the last successful pass as a Unix
    /// timestamp. Persisted so restarts don't reset the schedule.
    static let lastRunDefaultsKey = "memory.consolidation.lastRunAt"

    /// Delay before the first scheduled check after launch, so a catch-up
    /// pass doesn't compete with launch DB and embedding work.
    static let launchGrace: Duration = .seconds(60)

    /// How often the scheduler re-checks whether a pass is due.
    static let tickInterval: Duration = .seconds(30 * 60)

    private var schedulerTask: Task<Void, Never>?
    private var lastRun: Date?
    private var isRunning = false

    private init() {
        lastRun = Self.loadPersistedLastRun()
    }

    /// When the last consolidation pass completed, or `nil` if it never has.
    public var lastRunDate: Date? { lastRun }

    /// Start the periodic loop. Idempotent.
    public func start() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task.detached(priority: .background) { [weak self] in
            await self?.scheduleLoop()
        }
        MemoryLogger.service.info("MemoryConsolidator scheduler started")
    }

    public func stop() {
        schedulerTask?.cancel()
        schedulerTask = nil
    }

    /// Whether a scheduled pass should run now. Pure so it can be unit
    /// tested; a consolidator that has never run is always due.
    static func isDue(lastRun: Date?, intervalHours: Int, now: Date = Date()) -> Bool {
        guard let lastRun else { return true }
        let interval = TimeInterval(max(1, intervalHours) * 3600)
        return now.timeIntervalSince(lastRun) >= interval
    }

    private func scheduleLoop() async {
        try? await Task.sleep(for: Self.launchGrace)
        while !Task.isCancelled {
            let config = MemoryConfigurationStore.load()
            if Self.isDue(lastRun: lastRun, intervalHours: config.consolidationIntervalHours) {
                if await Self.isIdleForBackgroundPass() {
                    await runOnce()
                } else {
                    MemoryLogger.service.info("Consolidator: pass due but app busy; retrying next tick")
                }
            }
            try? await Task.sleep(for: Self.tickInterval)
        }
    }

    /// Scheduled passes run O(n²) shingle comparisons on the memory DB's
    /// serial queue, so only start one when no inference or chat work is in
    /// flight. A deferred pass retries on the next tick because `lastRun`
    /// is not advanced.
    private static func isIdleForBackgroundPass() async -> Bool {
        if HTTPInferenceAdmission.shared.inflightCount > 0 { return false }
        if await InferenceLoadCoordinator.shared.activeCount > 0 { return false }
        return true
    }

    // MARK: - Persisted last run

    private static func loadPersistedLastRun() -> Date? {
        let raw = UserDefaults.standard.double(forKey: lastRunDefaultsKey)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    private func persistLastRun(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastRunDefaultsKey)
    }

    /// Run a single consolidation pass. Safe to call from anywhere; serializes
    /// internally so concurrent triggers don't double-run.
    @discardableResult
    public func runOnce() async -> RunOutcome {
        guard !isRunning else {
            MemoryLogger.service.debug("Consolidator already running; skipping concurrent trigger")
            return .skippedAlreadyRunning
        }
        isRunning = true
        defer { isRunning = false }

        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return .skippedDisabled }
        guard MemoryDatabase.shared.isOpen else { return .skippedDatabaseClosed }

        let started = Date()
        MemoryLogger.service.info("Consolidator: starting pass")

        do {
            try MemoryDatabase.shared.decayPinnedSalience(halfLifeDays: MemoryConfiguration.salienceHalfLifeDays)
            try MemoryDatabase.shared.decayEpisodeSalience(halfLifeDays: MemoryConfiguration.salienceHalfLifeDays)
        } catch {
            MemoryLogger.service.warning("Consolidator: decay step failed: \(error)")
        }

        let mergedCount = await mergeNearDuplicateEpisodes()
        let promotedCount = await promotePinnedCandidates()

        do {
            let evictedKeys = try MemoryDatabase.shared.evictPinnedFactsReturningKeys(
                belowSalience: config.salienceFloor,
                idleDays: 30
            )
            // Drop each evicted fact's vector so the index doesn't keep
            // surfacing rows that no longer exist in SQL.
            for key in evictedKeys {
                await MemorySearchService.shared.removeDocument(
                    id: key.id,
                    agentId: key.agentId.isEmpty ? nil : key.agentId
                )
            }
            if !evictedKeys.isEmpty {
                MemoryLogger.service.info(
                    "Consolidator: evicted \(evictedKeys.count) pinned facts (+ vectors)"
                )
            }
        } catch {
            MemoryLogger.service.warning("Consolidator: eviction failed: \(error)")
        }

        if config.episodeRetentionDays > 0 {
            do {
                let prunedEp = try MemoryDatabase.shared.pruneEpisodes(olderThanDays: config.episodeRetentionDays)

                // Pull the keys back from the prune so we can also
                // drop their Vectura vectors. Pre-fix, this loop was
                // missing entirely and the per-agent vector store
                // grew unbounded — `pruneTranscript` only deleted SQL
                // rows; embeddings stayed indexed until the next
                // explicit `rebuildIndex()`.
                let prunedTranscriptKeys = try MemoryDatabase.shared.pruneTranscriptReturningKeys(
                    olderThanDays: config.episodeRetentionDays
                )

                for key in prunedTranscriptKeys {
                    let vid = TextSimilarity.deterministicUUID(
                        from: "transcript:\(key.conversationId):\(key.chunkIndex)"
                    ).uuidString
                    await MemorySearchService.shared.removeDocument(id: vid)
                }

                if prunedEp + prunedTranscriptKeys.count > 0 {
                    MemoryLogger.service.info(
                        "Consolidator: pruned \(prunedEp) episodes + \(prunedTranscriptKeys.count) transcript turns (+ vectors)"
                    )
                }
            } catch {
                MemoryLogger.service.warning("Consolidator: prune failed: \(error)")
            }
        }

        do {
            try MemoryDatabase.shared.purgeOldEventData()
        } catch {
            MemoryLogger.service.warning("Consolidator: purge failed: \(error)")
        }

        let finished = Date()
        lastRun = finished
        persistLastRun(finished)
        let durationMs = Int(finished.timeIntervalSince(started) * 1000)
        MemoryLogger.service.info(
            "Consolidator: pass done (merged: \(mergedCount), promoted: \(promotedCount), \(durationMs)ms)"
        )

        await MemoryContextAssembler.shared.invalidateCache()
        return .completed
    }

    // MARK: - Episode merge

    private func mergeNearDuplicateEpisodes() async -> Int {
        let episodes = (try? MemoryDatabase.shared.loadEpisodes(limit: 1000)) ?? []
        guard episodes.count > 1 else { return 0 }

        // Group by agent for cheaper comparisons.
        let byAgent = Dictionary(grouping: episodes, by: \.agentId)
        var merged = 0

        for (_, group) in byAgent {
            guard group.count > 1 else { continue }
            let withShingles = group.map { ($0, TextSimilarity.shingleSet($0.summary + " " + $0.topicsCSV)) }

            var consumed = Set<Int>()
            for i in 0 ..< withShingles.count {
                if consumed.contains(withShingles[i].0.id) { continue }
                for j in (i + 1) ..< withShingles.count {
                    if consumed.contains(withShingles[j].0.id) { continue }
                    let sim = TextSimilarity.jaccardTokenized(withShingles[i].1, withShingles[j].1)
                    if sim >= MemoryConfiguration.episodeMergeCosineThreshold {
                        // Keep the older episode; delete the newer near-dup.
                        let keep =
                            withShingles[i].0.conversationAt <= withShingles[j].0.conversationAt
                            ? withShingles[i].0 : withShingles[j].0
                        let drop =
                            keep.id == withShingles[i].0.id ? withShingles[j].0 : withShingles[i].0
                        do {
                            try MemoryDatabase.shared.deleteEpisode(id: drop.id)
                            await MemorySearchService.shared.removeDocument(
                                id: TextSimilarity.deterministicUUID(from: "episode:\(drop.id)").uuidString
                            )
                            consumed.insert(drop.id)
                            merged += 1
                        } catch {
                            MemoryLogger.service.warning("Consolidator: merge delete failed: \(error)")
                        }
                    }
                }
            }
        }
        return merged
    }

    // MARK: - Pinned candidate promotion

    /// Boost salience on pinned facts whose source content overlaps with
    /// ≥ `pinnedPromotionThreshold` recent episodes. Cheap heuristic; the
    /// distillation prompt does most of the promoting itself.
    private func promotePinnedCandidates() async -> Int {
        let recentEpisodes = (try? MemoryDatabase.shared.loadEpisodes(days: 60, limit: 200)) ?? []
        guard !recentEpisodes.isEmpty else { return 0 }
        let pinned = (try? MemoryDatabase.shared.loadPinnedFacts(limit: 500)) ?? []
        guard !pinned.isEmpty else { return 0 }

        let episodeShingles = recentEpisodes.map {
            TextSimilarity.shingleSet($0.summary + " " + $0.topicsCSV + " " + $0.entitiesCSV)
        }

        var promoted = 0
        for fact in pinned {
            let factShingles = TextSimilarity.shingleSet(fact.content)
            let hits = episodeShingles.reduce(0) { count, sh in
                count + (TextSimilarity.jaccardTokenized(factShingles, sh) >= 0.4 ? 1 : 0)
            }
            if hits >= MemoryConfiguration.pinnedPromotionThreshold {
                let boosted = min(1.0, fact.salience + 0.05)
                if boosted > fact.salience + 0.001 {
                    try? MemoryDatabase.shared.updatePinnedFactSalience(id: fact.id, salience: boosted)
                    promoted += 1
                }
            }
        }
        return promoted
    }
}
