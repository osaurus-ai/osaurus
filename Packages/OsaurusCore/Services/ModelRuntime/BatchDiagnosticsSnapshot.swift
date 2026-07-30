//
//  BatchDiagnosticsSnapshot.swift
//  osaurus
//
//  Aggregated read-only view of every `BatchEngine` instance currently
//  resolved inside `MLXBatchAdapter.Registry`. Used by the
//  Server → Settings panel's "Live Diagnostics" subsection to render
//  pending/active/high-water counters without exposing
//  `BatchEngine`/`Registry` types to view code.
//

import Foundation

/// Snapshot of `BatchEngine` diagnostics aggregated across every
/// resolved engine in `MLXBatchAdapter.Registry`. Decoupled from the
/// MLX layer so SwiftUI views can render it without importing
/// MLX-specific types.
public struct BatchDiagnosticsSnapshot: Equatable, Sendable {
    public let pendingCount: Int
    public let activeCount: Int
    public let activeHighWatermark: Int
    /// Sum of the atomic configured maxima reported by every resolved engine.
    public let configuredEngineCapacity: Int
    /// Sum of each engine's currently available slots from the same atomic
    /// snapshot. This can be lower than configured capacity while work runs.
    public let nominalAvailableCapacity: Int
    /// Stable per-model view (`model: capacity`) for live UI/API inspection.
    public let engineCapacitySummary: String?
    public let decodeSplitCount: Int
    public let turboQuantCompressions: Int
    public let isAcceptingRequests: Bool
    public let loadedModelCount: Int
    public let nativeMTPModelCount: Int
    public let nativeMTPDepthSummary: String?
    public let cacheEnabledModelCount: Int
    public let hybridModelCount: Int
    public let pagedIncompatibleModelCount: Int
    public let prefixHits: Int
    public let prefixMisses: Int
    public let pagedEvictions: Int
    public let diskL2Hits: Int
    public let diskL2Misses: Int
    public let diskL2Stores: Int
    public let ssmCompanionHits: Int
    public let ssmCompanionMisses: Int
    public let ssmCompanionReDerives: Int

    public init(
        pendingCount: Int,
        activeCount: Int,
        activeHighWatermark: Int,
        configuredEngineCapacity: Int = 0,
        nominalAvailableCapacity: Int = 0,
        engineCapacitySummary: String? = nil,
        decodeSplitCount: Int,
        turboQuantCompressions: Int,
        isAcceptingRequests: Bool,
        loadedModelCount: Int = 0,
        nativeMTPModelCount: Int = 0,
        nativeMTPDepthSummary: String? = nil,
        cacheEnabledModelCount: Int = 0,
        hybridModelCount: Int = 0,
        pagedIncompatibleModelCount: Int = 0,
        prefixHits: Int = 0,
        prefixMisses: Int = 0,
        pagedEvictions: Int = 0,
        diskL2Hits: Int = 0,
        diskL2Misses: Int = 0,
        diskL2Stores: Int = 0,
        ssmCompanionHits: Int = 0,
        ssmCompanionMisses: Int = 0,
        ssmCompanionReDerives: Int = 0
    ) {
        self.pendingCount = pendingCount
        self.activeCount = activeCount
        self.activeHighWatermark = activeHighWatermark
        self.configuredEngineCapacity = configuredEngineCapacity
        self.nominalAvailableCapacity = nominalAvailableCapacity
        self.engineCapacitySummary = engineCapacitySummary
        self.decodeSplitCount = decodeSplitCount
        self.turboQuantCompressions = turboQuantCompressions
        self.isAcceptingRequests = isAcceptingRequests
        self.loadedModelCount = loadedModelCount
        self.nativeMTPModelCount = nativeMTPModelCount
        self.nativeMTPDepthSummary = nativeMTPDepthSummary
        self.cacheEnabledModelCount = cacheEnabledModelCount
        self.hybridModelCount = hybridModelCount
        self.pagedIncompatibleModelCount = pagedIncompatibleModelCount
        self.prefixHits = prefixHits
        self.prefixMisses = prefixMisses
        self.pagedEvictions = pagedEvictions
        self.diskL2Hits = diskL2Hits
        self.diskL2Misses = diskL2Misses
        self.diskL2Stores = diskL2Stores
        self.ssmCompanionHits = ssmCompanionHits
        self.ssmCompanionMisses = ssmCompanionMisses
        self.ssmCompanionReDerives = ssmCompanionReDerives
    }
}

/// Monotonic counters retained when a per-model engine/container leaves the
/// live registry. Occupancy, capacity, loaded-model, and topology fields stay
/// live-only; only counters whose meaning is process-lifetime are folded
/// forward across model handoffs.
///
/// Keeping this as a value type makes the retention math independently
/// testable. Additions saturate at `Int.max`: diagnostics must never wrap to a
/// negative value even in a daemon process that serves requests for months.
struct ProcessLifetimeBatchCounters: Equatable, Sendable {
    var activeHighWatermark: Int = 0
    var decodeSplitCount: Int = 0
    var turboQuantCompressions: Int = 0
    var prefixHits: Int = 0
    var prefixMisses: Int = 0
    var pagedEvictions: Int = 0
    var diskL2Hits: Int = 0
    var diskL2Misses: Int = 0
    var diskL2Stores: Int = 0
    var ssmCompanionHits: Int = 0
    var ssmCompanionMisses: Int = 0
    var ssmCompanionReDerives: Int = 0

    init(
        activeHighWatermark: Int = 0,
        decodeSplitCount: Int = 0,
        turboQuantCompressions: Int = 0,
        prefixHits: Int = 0,
        prefixMisses: Int = 0,
        pagedEvictions: Int = 0,
        diskL2Hits: Int = 0,
        diskL2Misses: Int = 0,
        diskL2Stores: Int = 0,
        ssmCompanionHits: Int = 0,
        ssmCompanionMisses: Int = 0,
        ssmCompanionReDerives: Int = 0
    ) {
        self.activeHighWatermark = max(0, activeHighWatermark)
        self.decodeSplitCount = max(0, decodeSplitCount)
        self.turboQuantCompressions = max(0, turboQuantCompressions)
        self.prefixHits = max(0, prefixHits)
        self.prefixMisses = max(0, prefixMisses)
        self.pagedEvictions = max(0, pagedEvictions)
        self.diskL2Hits = max(0, diskL2Hits)
        self.diskL2Misses = max(0, diskL2Misses)
        self.diskL2Stores = max(0, diskL2Stores)
        self.ssmCompanionHits = max(0, ssmCompanionHits)
        self.ssmCompanionMisses = max(0, ssmCompanionMisses)
        self.ssmCompanionReDerives = max(0, ssmCompanionReDerives)
    }

    init(snapshot: BatchDiagnosticsSnapshot) {
        self.init(
            activeHighWatermark: snapshot.activeHighWatermark,
            decodeSplitCount: snapshot.decodeSplitCount,
            turboQuantCompressions: snapshot.turboQuantCompressions,
            prefixHits: snapshot.prefixHits,
            prefixMisses: snapshot.prefixMisses,
            pagedEvictions: snapshot.pagedEvictions,
            diskL2Hits: snapshot.diskL2Hits,
            diskL2Misses: snapshot.diskL2Misses,
            diskL2Stores: snapshot.diskL2Stores,
            ssmCompanionHits: snapshot.ssmCompanionHits,
            ssmCompanionMisses: snapshot.ssmCompanionMisses,
            ssmCompanionReDerives: snapshot.ssmCompanionReDerives
        )
    }

    mutating func absorb(_ other: Self) {
        activeHighWatermark = max(activeHighWatermark, other.activeHighWatermark)
        decodeSplitCount = Self.saturatingAdd(decodeSplitCount, other.decodeSplitCount)
        turboQuantCompressions = Self.saturatingAdd(
            turboQuantCompressions,
            other.turboQuantCompressions
        )
        prefixHits = Self.saturatingAdd(prefixHits, other.prefixHits)
        prefixMisses = Self.saturatingAdd(prefixMisses, other.prefixMisses)
        pagedEvictions = Self.saturatingAdd(pagedEvictions, other.pagedEvictions)
        diskL2Hits = Self.saturatingAdd(diskL2Hits, other.diskL2Hits)
        diskL2Misses = Self.saturatingAdd(diskL2Misses, other.diskL2Misses)
        diskL2Stores = Self.saturatingAdd(diskL2Stores, other.diskL2Stores)
        ssmCompanionHits = Self.saturatingAdd(
            ssmCompanionHits,
            other.ssmCompanionHits
        )
        ssmCompanionMisses = Self.saturatingAdd(
            ssmCompanionMisses,
            other.ssmCompanionMisses
        )
        ssmCompanionReDerives = Self.saturatingAdd(
            ssmCompanionReDerives,
            other.ssmCompanionReDerives
        )
    }

    func mergingCounters(into live: BatchDiagnosticsSnapshot) -> BatchDiagnosticsSnapshot {
        var merged = self
        merged.absorb(Self(snapshot: live))
        return BatchDiagnosticsSnapshot(
            pendingCount: live.pendingCount,
            activeCount: live.activeCount,
            activeHighWatermark: merged.activeHighWatermark,
            configuredEngineCapacity: live.configuredEngineCapacity,
            nominalAvailableCapacity: live.nominalAvailableCapacity,
            engineCapacitySummary: live.engineCapacitySummary,
            decodeSplitCount: merged.decodeSplitCount,
            turboQuantCompressions: merged.turboQuantCompressions,
            isAcceptingRequests: live.isAcceptingRequests,
            loadedModelCount: live.loadedModelCount,
            nativeMTPModelCount: live.nativeMTPModelCount,
            nativeMTPDepthSummary: live.nativeMTPDepthSummary,
            cacheEnabledModelCount: live.cacheEnabledModelCount,
            hybridModelCount: live.hybridModelCount,
            pagedIncompatibleModelCount: live.pagedIncompatibleModelCount,
            prefixHits: merged.prefixHits,
            prefixMisses: merged.prefixMisses,
            pagedEvictions: merged.pagedEvictions,
            diskL2Hits: merged.diskL2Hits,
            diskL2Misses: merged.diskL2Misses,
            diskL2Stores: merged.diskL2Stores,
            ssmCompanionHits: merged.ssmCompanionHits,
            ssmCompanionMisses: merged.ssmCompanionMisses,
            ssmCompanionReDerives: merged.ssmCompanionReDerives
        )
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let nonnegativeRHS = max(0, rhs)
        let (sum, overflow) = lhs.addingReportingOverflow(nonnegativeRHS)
        return overflow ? Int.max : sum
    }
}

/// Actor-consistent capacity for one resolved local model's vMLX
/// `BatchEngine`. This is observability, not a second reservation system:
/// the engine remains the sole authority that admits active decode slots.
struct ModelBatchCapacitySnapshot: Equatable, Sendable {
    let modelName: String
    let configuredMaximum: Int
    let activeCount: Int
    let pendingCount: Int
    let nominalAvailableCount: Int
    let activeHighWatermark: Int
    let isAcceptingRequests: Bool
    let isShutdown: Bool
}
