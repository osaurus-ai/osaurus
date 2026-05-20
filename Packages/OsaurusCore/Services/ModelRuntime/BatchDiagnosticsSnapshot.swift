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
        self.diskL2Hits = diskL2Hits
        self.diskL2Misses = diskL2Misses
        self.diskL2Stores = diskL2Stores
        self.ssmCompanionHits = ssmCompanionHits
        self.ssmCompanionMisses = ssmCompanionMisses
        self.ssmCompanionReDerives = ssmCompanionReDerives
    }
}
