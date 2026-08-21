//
//  DiskCacheUsage.swift
//  osaurus
//
//  Live on-SSD prompt-cache usage, rendered in the chat's Context Budget
//  popover so cache pressure is visible rather than inferred from decode
//  getting slower.
//
//  The cap used to be a flat 10 GB. For Qwen3.8-27B (64 layers, 4 KV heads,
//  head_dim 256) KV costs 256 KiB per token at bf16, so a 222k window needs
//  ~54 GB — a 10 GB cap could not hold ONE full-context conversation, and it is
//  shared across every model in the cache root rather than being per bundle.
//  Past that point each store evicted earlier boundaries of the SAME
//  conversation, so reuse collapsed exactly as context grew, silently. This
//  type is what makes that visible.
//

import Foundation

/// A point-in-time reading of the shared on-disk KV cache.
///
/// Both byte figures are ROOT-WIDE, not per model: every model's `DiskCache`
/// opens the same `cache_index.db` and sums `cache_entries` with no modelKey
/// predicate. They are aggregated with `max` upstream, never summed.
public struct DiskCacheUsage: Equatable, Sendable {
    /// Payload bytes currently counted against the quota. Excludes the SQLite
    /// index and WAL, matching how the quota itself is enforced — which is why
    /// the cap is a soft cap and the Settings copy says so.
    public let usedBytes: Int

    /// The configured quota these bytes are measured against.
    public let maxBytes: Int

    /// Cache boundaries dropped by quota enforcement so far this process.
    /// Non-zero is the observable proof the eviction janitor is running.
    public let evictions: Int

    public init(usedBytes: Int, maxBytes: Int, evictions: Int = 0) {
        self.usedBytes = max(0, usedBytes)
        self.maxBytes = max(0, maxBytes)
        self.evictions = max(0, evictions)
    }

    /// Share of the quota in use, clamped to 0 when no quota is configured.
    /// Deliberately NOT clamped at 1: the cap is a soft cap enforced after a
    /// store, so a transient reading above 100% is real and worth showing
    /// rather than hiding behind a clamp.
    public var usedFraction: Double {
        guard maxBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(maxBytes)
    }

    public var usedLabel: String { Self.format(bytes: usedBytes) }
    public var maxLabel: String { Self.format(bytes: maxBytes) }

    /// Shown once usage crosses the warn threshold. Names the consequence
    /// (re-prefill) and the remedy (raise the size), because "cache is full" on
    /// its own tells the user nothing actionable.
    public var warningText: String {
        let pct = Int((usedFraction * 100).rounded())
        return
            "Cache is \(pct)% full — older prompt checkpoints are being evicted, "
            + "so long conversations may re-prefill instead of resuming. "
            + "Raise Disk Cache Size in Settings."
    }

    /// GB with one decimal above 1 GB, MB below it. Keeps the footer readable
    /// at a glance without a units column that shifts as the cache grows.
    static func format(bytes: Int) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }
}
