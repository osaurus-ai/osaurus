//
//  LocalModelCatalogItem.swift
//  osaurus
//
//  One row of the Local Models table, whatever the model kind. Each kind's
//  `LocalModelCatalogSource` maps its own manager state onto this shape so
//  Language, Image, Speech, Privacy Detection and AppleScript read, sort and
//  act the same way.
//

import Foundation
import SwiftUI

/// Which slice of a kind's catalog the table shows.
enum LocalModelCatalogScope: String, CaseIterable, Hashable, Sendable {
    case all
    case onThisMac
    case available

    var title: String {
        switch self {
        case .all: L("All")
        case .onThisMac: L("On This Mac")
        case .available: L("Available")
        }
    }

    func includes(_ status: LocalModelCatalogItem.Status) -> Bool {
        switch self {
        case .all: true
        case .onThisMac: status.isOnThisMac
        case .available: !status.isOnThisMac
        }
    }
}

/// Columns a table header can sort by.
enum LocalModelSortKey: Hashable, Sendable {
    case name
    case fit
    case memory
    case size
    case released
}

/// The shared column vocabulary, in display order. A kind lists only the
/// columns it has real values for.
enum LocalModelColumn: String, CaseIterable, Sendable {
    case model
    case fit
    case memory
    case size
    case released
    case status

    var tableColumn: SettingsDataTableColumn<LocalModelSortKey> {
        switch self {
        case .model:
            SettingsDataTableColumn(id: rawValue, title: "Model", width: .flexible(min: 180), sortKey: .name)
        case .fit:
            SettingsDataTableColumn(
                id: rawValue, title: "Fits This Mac", width: .fixed(128), sortKey: .fit, hidePriority: 1)
        case .memory:
            SettingsDataTableColumn(
                id: rawValue, title: "Memory", width: .fixed(72), alignment: .trailing,
                sortKey: .memory, initialAscending: true, hidePriority: 3)
        case .size:
            SettingsDataTableColumn(
                id: rawValue, title: "Size", width: .fixed(72), alignment: .trailing,
                sortKey: .size, initialAscending: true, hidePriority: 2)
        case .released:
            SettingsDataTableColumn(
                id: rawValue, title: "Released", width: .fixed(76), alignment: .trailing,
                sortKey: .released, initialAscending: false, hidePriority: 4)
        case .status:
            SettingsDataTableColumn(id: rawValue, title: "", width: .fixed(156), alignment: .trailing)
        }
    }
}

struct LocalModelCatalogItem: Identifiable {
    enum Status: Equatable {
        case available
        /// `progress: nil` is an indeterminate phase (preparing, verifying).
        case inProgress(progress: Double?, detail: String?, isPaused: Bool)
        case installed
        case failed(String)

        /// Installed or on its way: what "On This Mac" lists.
        var isOnThisMac: Bool {
            switch self {
            case .installed, .inProgress: true
            case .available, .failed: false
            }
        }

        var isActive: Bool {
            if case .inProgress = self { return true }
            return false
        }
    }

    struct Badge {
        /// Already localized.
        let text: String
        var tone: StatusChip.Tone = .neutral
        var icon: String?
        /// Already localized.
        var help: String?
    }

    struct Action: Identifiable {
        enum Role { case normal, primary, destructive }

        /// Catalog key.
        let title: String
        let icon: String
        var role: Role = .normal
        /// Already-localized message; when set the page asks before running
        /// `handler`.
        var confirmation: String?
        let handler: () -> Void

        var id: String { title }
    }

    /// One label/value pair for the detail panel.
    struct Fact: Identifiable, Hashable {
        /// Catalog key.
        let label: String
        /// Rendered verbatim.
        let value: String

        var id: String { label }
    }

    let id: String
    /// Verbatim.
    let name: String
    /// Verbatim one-liner under the name: use case, versions, capabilities.
    var subtitle: String
    /// Verbatim longer description for the detail panel.
    var description: String = ""
    var icon: String
    /// Short state chips beside the name (Default, Update available, Not MLX).
    var badges: [Badge] = []
    var isTopPick = false
    var isDefault = false
    var fit: ModelCompatibility?
    var memoryText: String?
    var memoryGB: Double?
    var sizeText: String?
    var sizeBytes: Int64?
    var releasedText: String?
    var releasedAt: Date?
    var status: Status
    /// Download / Install / Retry while not installed; Set as Default or
    /// Generate once installed. Nil leaves the installed state showing.
    var primaryAction: Action?
    var menuActions: [Action] = []
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onCancel: (() -> Void)?
    var huggingFaceRepo: String?
    var facts: [Fact] = []
    /// Lowercased haystack for the shared search filter.
    var searchHaystack: String = ""
    /// The MLX build behind a Language or AppleScript row, which opens the
    /// full model detail view.
    var model: MLXModel?
    /// Every precision build of the row's family (Language catalog rows).
    var variants: [MLXModel] = []
    /// Greyed: the bundle is on disk but the local engine can't load it.
    var isUnsupported = false
}

// MARK: - Ordering

enum LocalModelCatalogOrdering {
    /// Scope, then search, then order. `items` arrive in the source's
    /// preferred order (newest first for catalogs), which the default order
    /// keeps within each group.
    static func arrange(
        _ items: [LocalModelCatalogItem],
        scope: LocalModelCatalogScope,
        query: String,
        sort: SettingsDataTableSort<LocalModelSortKey>?
    ) -> [LocalModelCatalogItem] {
        let scoped = items.filter { scope.includes($0.status) }
        return sorted(search(scoped, query: query), by: sort)
    }

    static func search(_ items: [LocalModelCatalogItem], query: String) -> [LocalModelCatalogItem] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return items }
        return items.filter { item in
            let haystack = item.searchHaystack.isEmpty ? item.name.lowercased() : item.searchHaystack
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    /// Default order: downloads in flight, then models on this Mac, then Top
    /// Picks, then the source's order. A header sort replaces it; rows with
    /// no value for that column sort last either way, then by name.
    static func sorted(
        _ items: [LocalModelCatalogItem],
        by sort: SettingsDataTableSort<LocalModelSortKey>?
    ) -> [LocalModelCatalogItem] {
        let indexed = Array(items.enumerated())
        guard let sort else {
            return indexed.sorted { lhs, rhs in
                let l = defaultRank(lhs.element)
                let r = defaultRank(rhs.element)
                return l != r ? l < r : lhs.offset < rhs.offset
            }.map(\.element)
        }
        return indexed.sorted { lhs, rhs in
            switch compare(lhs.element, rhs.element, key: sort.key) {
            case .some(let ascending):
                return sort.ascending ? ascending : !ascending
            case .none:
                let lMissing = value(lhs.element, sort.key) == nil
                let rMissing = value(rhs.element, sort.key) == nil
                if lMissing != rMissing { return rMissing }
                let byName = lhs.element.name.localizedCaseInsensitiveCompare(rhs.element.name)
                return byName == .orderedSame ? lhs.offset < rhs.offset : byName == .orderedAscending
            }
        }.map(\.element)
    }

    private static func defaultRank(_ item: LocalModelCatalogItem) -> Int {
        switch item.status {
        case .inProgress: 0
        case .installed: 1
        case .available, .failed: item.isTopPick ? 2 : 3
        }
    }

    static func fitRank(_ fit: ModelCompatibility) -> Double {
        switch fit {
        case .compatible: 0
        case .tight: 1
        case .tooLarge: 2
        case .unknown: 3
        }
    }

    private static func value(_ item: LocalModelCatalogItem, _ key: LocalModelSortKey) -> Double? {
        switch key {
        case .name: 0
        case .fit: item.fit.map(fitRank)
        case .memory: item.memoryGB
        case .size: item.sizeBytes.map(Double.init)
        case .released: item.releasedAt?.timeIntervalSinceReferenceDate
        }
    }

    /// `true` when `lhs` sorts before `rhs` ascending; nil on a tie or a
    /// missing value, which the caller orders.
    private static func compare(
        _ lhs: LocalModelCatalogItem,
        _ rhs: LocalModelCatalogItem,
        key: LocalModelSortKey
    ) -> Bool? {
        if key == .name {
            let result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return result == .orderedSame ? nil : result == .orderedAscending
        }
        guard let l = value(lhs, key), let r = value(rhs, key), l != r else { return nil }
        return l < r
    }
}

// MARK: - Formatting

enum LocalModelCatalogFormat {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func haystack(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: " ").lowercased()
    }

    static func huggingFaceURL(_ repoId: String) -> URL? {
        URL(string: "https://huggingface.co/\(repoId)")
    }
}
