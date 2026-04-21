//
//  MemoryConsolidator.swift
//  osaurus
//
//  Background consolidation loop. Runs every `consolidationIntervalHours`
//  (default 24h) on a low-priority detached task. Performs:
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
//  Consolidation runs in the background only; no user action triggers it
//  except the explicit "Run Now" button in `MemoryView`.
//

import CryptoKit
import Foundation
import os

public actor MemoryConsolidator {
    public static let shared = MemoryConsolidator()

    private var schedulerTask: Task<Void, Never>?
    private var lastRun: Date?
    private var isRunning = false

    private init() {}

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

    private func scheduleLoop() async {
        while !Task.isCancelled {
            let config = MemoryConfigurationStore.load()
            let intervalSeconds = max(1, config.consolidationIntervalHours) * 3600
            try? await Task.sleep(for: .seconds(intervalSeconds))
            guard !Task.isCancelled else { return }
            await runOnce()
        }
    }

    /// Run a single consolidation pass. Safe to call from anywhere; serializes
    /// internally so concurrent triggers don't double-run.
    public func runOnce() async {
        guard !isRunning else {
            MemoryLogger.service.debug("Consolidator already running; skipping concurrent trigger")
            return
        }
        isRunning = true
        defer { isRunning = false }

        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }
        guard MemoryDatabase.shared.isOpen else { return }

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
            let evicted = try MemoryDatabase.shared.evictPinnedFacts(
                belowSalience: config.salienceFloor,
                idleDays: 30
            )
            if evicted > 0 {
                MemoryLogger.service.info("Consolidator: evicted \(evicted) pinned facts")
            }
        } catch {
            MemoryLogger.service.warning("Consolidator: eviction failed: \(error)")
        }

        if config.episodeRetentionDays > 0 {
            do {
                let prunedEp = try MemoryDatabase.shared.pruneEpisodes(olderThanDays: config.episodeRetentionDays)
                let prunedTr = try MemoryDatabase.shared.pruneTranscript(
                    olderThanDays: config.episodeRetentionDays
                )
                if prunedEp + prunedTr > 0 {
                    MemoryLogger.service.info(
                        "Consolidator: pruned \(prunedEp) episodes + \(prunedTr) transcript turns"
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

        lastRun = Date()
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        MemoryLogger.service.info(
            "Consolidator: pass done (merged: \(mergedCount), promoted: \(promotedCount), \(durationMs)ms)"
        )

        await MemoryContextAssembler.shared.invalidateCache()
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
