//
//  ActivityFilter.swift
//  osaurus
//
//  Query + summary types for the persisted Insights activity log. The
//  filter is translated to SQL by `ActivityLogStore`; the summary is what
//  the dashboard's egress card and stats bar render.
//

import Foundation

/// Date-range presets for the Insights filter bar.
enum ActivityDateRange: Equatable, Hashable, Sendable {
    case all
    case today
    case last7Days
    case last30Days
    case custom(start: Date, end: Date)

    /// Resolve to concrete bounds (inclusive start, exclusive end).
    func bounds(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date)? {
        switch self {
        case .all:
            return nil
        case .today:
            let start = calendar.startOfDay(for: now)
            return (start, now.addingTimeInterval(1))
        case .last7Days:
            let start = calendar.startOfDay(for: now).addingTimeInterval(-6 * 86_400)
            return (start, now.addingTimeInterval(1))
        case .last30Days:
            let start = calendar.startOfDay(for: now).addingTimeInterval(-29 * 86_400)
            return (start, now.addingTimeInterval(1))
        case .custom(let start, let end):
            return (min(start, end), max(start, end))
        }
    }

    var displayName: String {
        switch self {
        case .all: return L("All time")
        case .today: return L("Today")
        case .last7Days: return L("7 days")
        case .last30Days: return L("30 days")
        case .custom: return L("Custom")
        }
    }

    static let presets: [ActivityDateRange] = [.today, .last7Days, .last30Days, .all]
}

/// Success / error slice.
enum ActivityStatusFilter: String, CaseIterable, Sendable {
    case all
    case success
    case error

    var displayName: String {
        switch self {
        case .all: return L("Any status")
        case .success: return L("Succeeded")
        case .error: return L("Failed")
        }
    }
}

/// Everything the Insights list can be narrowed by. Empty filter = all rows.
struct ActivityFilter: Equatable, Hashable, Sendable {
    var text: String = ""
    var dateRange: ActivityDateRange = .all
    var locality: DataLocality?
    var categories: Set<ActivityCategory> = []
    var sources: Set<RequestSource> = []
    var destinationHost: String?
    var model: String?
    var agentId: UUID?
    var status: ActivityStatusFilter = .all
    var privacyFilterApplied: Bool?
    /// Hide plugin console log lines (noise for audit review) unless asked.
    var includePluginLogs: Bool = true

    static let empty = ActivityFilter()

    var isEmpty: Bool { self == .empty }

    /// Number of active narrowing criteria (for the "Clear filters (n)" label).
    var activeCount: Int {
        var n = 0
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { n += 1 }
        if dateRange != .all { n += 1 }
        if locality != nil { n += 1 }
        if !categories.isEmpty { n += 1 }
        if !sources.isEmpty { n += 1 }
        if destinationHost != nil { n += 1 }
        if model != nil { n += 1 }
        if agentId != nil { n += 1 }
        if status != .all { n += 1 }
        if privacyFilterApplied != nil { n += 1 }
        if !includePluginLogs { n += 1 }
        return n
    }
}

/// Per-destination roll-up for the egress card.
struct ActivityDestinationSummary: Equatable, Identifiable, Sendable {
    /// Rows are grouped by (label, host); one host can carry several labels
    /// (a configured provider and a bare TTS endpoint on the same loopback
    /// address), so the id must include both or `ForEach` renders duplicates.
    var id: String { host.isEmpty ? label : "\(label)|\(host)" }
    let label: String
    let host: String
    let count: Int
    let bytesSent: Int
    let bytesReceived: Int
    let errorCount: Int
    let lastSeen: Date?
}

/// Aggregate view of the rows matching a filter.
struct ActivitySummary: Equatable, Sendable {
    var totalCount: Int = 0
    var localCount: Int = 0
    var remoteCount: Int = 0
    var errorCount: Int = 0
    var averageDurationMs: Double = 0
    var inferenceCount: Int = 0
    var searchCount: Int = 0
    var extractCount: Int = 0
    var mcpCount: Int = 0
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var averageSpeed: Double = 0
    var bytesSent: Int = 0
    var bytesReceived: Int = 0
    var privacyFilteredCount: Int = 0
    var redactedSpanTotal: Int = 0
    var destinations: [ActivityDestinationSummary] = []
    var earliest: Date?
    var latest: Date?

    static let empty = ActivitySummary()

    var remoteShare: Double {
        totalCount == 0 ? 0 : Double(remoteCount) / Double(totalCount)
    }

    var successRate: Double {
        totalCount == 0 ? 0 : Double(totalCount - errorCount) / Double(totalCount) * 100
    }

    var formattedSuccessRate: String { String(format: "%.0f%%", successRate) }

    var formattedAvgSpeed: String {
        averageSpeed > 0 ? String(format: "%.1f tok/s", averageSpeed) : "-"
    }

    var formattedAvgDuration: String {
        if averageDurationMs < 1000 {
            return String(format: "%.0fms", averageDurationMs)
        }
        return String(format: "%.1fs", averageDurationMs / 1000)
    }

    static func formattedBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}

/// Result of walking the hash chain.
struct ActivityLogVerification: Sendable, Equatable {
    enum Problem: Sendable, Equatable {
        /// Payload failed to decode.
        case malformedRow(seq: Int)
        /// `seq` is not the previous `seq + 1`.
        case sequenceGap(seq: Int, expected: Int)
        /// `prevHash` does not equal the previous record's `hash`.
        case brokenLink(seq: Int)
        /// Recomputed hash differs from the stored one (record edited).
        case hashMismatch(seq: Int)
        /// The first remaining row does not continue from the pruning anchor.
        case anchorMismatch(expectedSeq: Int, actualSeq: Int)
        /// The `.head` sidecar disagrees with the last row (tail truncated).
        case headMismatch(expectedSeq: Int, actualSeq: Int)

        var description: String {
            switch self {
            case .malformedRow(let seq): return String(format: L("Row %d could not be decoded"), seq)
            case .sequenceGap(let seq, let expected):
                return String(format: L("Row %d found where %d was expected (gap)"), seq, expected)
            case .brokenLink(let seq): return String(format: L("Row %d does not link to the previous row"), seq)
            case .hashMismatch(let seq): return String(format: L("Row %d was modified after it was written"), seq)
            case .anchorMismatch(let expected, let actual):
                return String(format: L("Chain should resume at row %d but starts at %d"), expected, actual)
            case .headMismatch(let expected, let actual):
                return String(format: L("Head marker says row %d but the log ends at %d (tail removed)"), expected, actual)
            }
        }
    }

    let recordCount: Int
    let firstSeq: Int?
    let lastSeq: Int?
    let lastHash: String?
    let problems: [Problem]
    let checkedAt: Date

    var isIntact: Bool { problems.isEmpty }
}
