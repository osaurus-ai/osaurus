//
//  CapabilitySearchHealth.swift
//  osaurus
//
//  Read-only health probe over the registry-vs-tool-index parity. Used by
//  the env-flag-gated capability-search trace path and the per-process
//  cheap-path snapshot gates inside `CapabilitySearch.search`.
//
//  Two operating modes — they cost very different amounts:
//
//    - .cheap: one in-memory `ToolRegistry.listTools()` walk + one
//      `SELECT COUNT(*)` against `tool_index`. Sub-millisecond. Reports
//      counts only — `missingFromIndex` / `stale` are left empty. This
//      is what the per-process gates on the hot search path use.
//    - .full: also pulls `ToolDatabase.loadAllEntryNames(source: .system)`
//      and computes set diffs to expose `missingFromIndex` / `stale`.
//      Gated by a 50ms wall-clock budget; if the name-fetch exceeds it,
//      the snapshot falls back to .cheap and trips
//      `diffSkippedDueToBudget`. Only the env-flag-gated trace path
//      requests this mode in production builds.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "CapabilitySearchHealth")

// MARK: - Snapshot

/// Decode-friendly snapshot of capability-search index health. The
/// divergence sets (`missingFromIndex`, `stale`) are only populated in
/// `.full` mode; `.cheap` snapshots leave them empty so the per-process
/// gate path stays sub-millisecond.
public struct CapabilitySearchHealth: Sendable {
    public let registryToolCount: Int
    public let indexedToolCount: Int
    /// Tools registered in `ToolRegistry` (enabled, non-runtime-managed,
    /// non-capability-infrastructure) that have no row in `tool_index`.
    /// Empty in cheap snapshots; populated in `.full`.
    public let missingFromIndex: [String]
    /// Tools present in `tool_index` that are no longer in the registry
    /// (or have been disabled / excluded). Empty in cheap snapshots;
    /// populated in `.full`.
    public let stale: [String]
    /// True when `.full` was requested but the name-diff exceeded the
    /// 50ms budget and the snapshot degraded to `.cheap`. Logged so the
    /// missing data isn't silent.
    public let diffSkippedDueToBudget: Bool

    public init(
        registryToolCount: Int,
        indexedToolCount: Int,
        missingFromIndex: [String] = [],
        stale: [String] = [],
        diffSkippedDueToBudget: Bool = false
    ) {
        self.registryToolCount = registryToolCount
        self.indexedToolCount = indexedToolCount
        self.missingFromIndex = missingFromIndex
        self.stale = stale
        self.diffSkippedDueToBudget = diffSkippedDueToBudget
    }
}

// MARK: - Diagnostics facade

@MainActor
public enum CapabilitySearchDiagnostics {
    public enum Mode: Sendable { case cheap, full }

    /// Hard ceiling for the `.full` name-diff. If the underlying
    /// `loadAllEntryNames` call exceeds this, the snapshot reverts to
    /// counts-only and surfaces `diffSkippedDueToBudget = true`.
    public static let fullModeBudgetMillis: Double = 50

    /// Compute a snapshot. `.cheap` is safe to invoke from the hot
    /// search path (sub-millisecond on healthy installs). `.full`
    /// adds the name diff and is intended for env-flag-gated traces
    /// and offline tooling only.
    public static func snapshot(mode: Mode = .cheap) async -> CapabilitySearchHealth {
        let (registryNames, registryCount) = registrySnapshotNames()
        let indexCount = (try? ToolDatabase.shared.entryCount()) ?? 0

        guard mode == .full else {
            return CapabilitySearchHealth(
                registryToolCount: registryCount,
                indexedToolCount: indexCount
            )
        }

        let started = Date()
        let indexNames: [String]
        do {
            indexNames = try ToolDatabase.shared.loadAllEntryNames(source: .system)
        } catch {
            logger.error(
                "CapabilitySearchHealth: loadAllEntryNames failed: \(error.localizedDescription, privacy: .public)"
            )
            return CapabilitySearchHealth(
                registryToolCount: registryCount,
                indexedToolCount: indexCount,
                diffSkippedDueToBudget: false
            )
        }
        let elapsedMs = Date().timeIntervalSince(started) * 1000
        if elapsedMs > Self.fullModeBudgetMillis {
            logger.notice(
                "CapabilitySearchHealth: name-diff skipped (took \(elapsedMs, format: .fixed(precision: 1))ms > budget \(Self.fullModeBudgetMillis, format: .fixed(precision: 0))ms)"
            )
            return CapabilitySearchHealth(
                registryToolCount: registryCount,
                indexedToolCount: indexCount,
                diffSkippedDueToBudget: true
            )
        }

        let registrySet = Set(registryNames)
        let indexSet = Set(indexNames)
        let missing = registrySet.subtracting(indexSet).sorted()
        let stale = indexSet.subtracting(registrySet).sorted()

        return CapabilitySearchHealth(
            registryToolCount: registryCount,
            indexedToolCount: indexCount,
            missingFromIndex: missing,
            stale: stale
        )
    }

    /// One-shot snapshot + structured log line. Tool names and counts
    /// are non-PII so `privacy: .public` is correct — it lets the log
    /// survive Console redaction during a manual repro.
    public static func logSnapshot(reason: String, mode: Mode = .cheap) async {
        let health = await snapshot(mode: mode)
        let summary = formatSummary(health)
        logger.notice(
            "CapabilitySearchHealth reason=\(reason, privacy: .public) mode=\(String(describing: mode), privacy: .public) \(summary, privacy: .public)"
        )
    }

    /// Per-call-site one-shot variant. The first invocation per process
    /// for a given `reason` emits a snapshot; subsequent calls are
    /// dropped. Lets `CapabilitySearch.search` install cheap snapshot
    /// gates on the hot path without double-logging when callers fire in
    /// the same session. Reason strings are also the de-dup key — pick
    /// stable identifiers (e.g. `"CapabilitySearch.search"`).
    public static func logSnapshotOnce(reason: String, mode: Mode = .cheap) async {
        guard !trippedCallSites.contains(reason) else { return }
        trippedCallSites.insert(reason)
        await logSnapshot(reason: reason, mode: mode)
    }

    /// Set of `logSnapshotOnce` reasons that have already fired in
    /// this process. `@MainActor` isolation makes the read/insert pair
    /// safe — there is no synchronisation primitive around it.
    private static var trippedCallSites: Set<String> = []

    /// Compact, single-line representation safe to embed in another
    /// `Logger.notice(...)` call (e.g. the env-flag trace block in
    /// `CapabilitySearch.search`). Keeps both the cheap and full
    /// shapes readable in one place.
    /// `nonisolated` so non-main-actor callers (e.g.
    /// `CapabilitySearch.search`) don't have to hop the main actor
    /// just to stringify a `Sendable` struct.
    public nonisolated static func formatSummary(_ health: CapabilitySearchHealth) -> String {
        var parts: [String] = [
            "registry=\(health.registryToolCount)",
            "index=\(health.indexedToolCount)",
        ]
        if !health.missingFromIndex.isEmpty {
            parts.append("missingFromIndex=[\(health.missingFromIndex.joined(separator: ","))]")
        }
        if !health.stale.isEmpty {
            parts.append("stale=[\(health.stale.joined(separator: ","))]")
        }
        if health.diffSkippedDueToBudget {
            parts.append("diffSkipped=true")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Internals

    /// Mirror of the `ToolIndexService.syncFromRegistry()` exclusion
    /// rules (Packages/OsaurusCore/Services/Tool/ToolIndexService.swift
    /// lines ~30–35) so the diff is apples-to-apples: only tools the
    /// indexer would have written end up in the registry-side `Set`.
    /// Returns both the name list and the registry count for callers
    /// that don't need the name array.
    private static func registrySnapshotNames() -> (names: [String], count: Int) {
        let all = ToolRegistry.shared.listTools()
        let excluded = ToolRegistry.capabilityToolNames
            .union(ToolRegistry.shared.runtimeManagedToolNames)
        let indexable = all.filter { $0.enabled && !excluded.contains($0.name) }
        return (indexable.map(\.name), indexable.count)
    }
}
