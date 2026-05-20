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

    public init(
        pendingCount: Int,
        activeCount: Int,
        activeHighWatermark: Int,
        decodeSplitCount: Int,
        turboQuantCompressions: Int,
        isAcceptingRequests: Bool
    ) {
        self.pendingCount = pendingCount
        self.activeCount = activeCount
        self.activeHighWatermark = activeHighWatermark
        self.decodeSplitCount = decodeSplitCount
        self.turboQuantCompressions = turboQuantCompressions
        self.isAcceptingRequests = isAcceptingRequests
    }
}
