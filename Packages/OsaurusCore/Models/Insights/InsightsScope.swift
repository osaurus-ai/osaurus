//
//  InsightsScope.swift
//  osaurus
//
//  View-only grouping of `ActivityCategory` into a handful of scopes the
//  Insights page shows as a quiet tab row (All · Models · Web · Tools ·
//  Channels · API · Audio & Media · System), plus the active-filter
//  tokens the toolbar renders beneath the search field. Nothing here is
//  persisted; `ActivityFilter` stays the single source of truth and the
//  store never sees scopes.
//

import Foundation

// MARK: - Scope

enum InsightsScope: String, CaseIterable, Hashable, AnimatedTabItem {
    case all
    case models
    case web
    case tools
    case channels
    case api
    case audioMedia
    case system

    /// Categories this scope narrows to. `all` is the empty set (no
    /// category filter).
    var categories: Set<ActivityCategory> {
        switch self {
        case .all: return []
        case .models: return [.inference, .compaction, .embedding]
        case .web: return [.webSearch, .urlExtract]
        case .tools: return [.mcpToolCall, .pluginCall, .pluginLog]
        case .channels: return [.channelDelivery]
        case .api: return [.inboundAPI, .routerControl]
        case .audioMedia: return [.audioTranscription, .speechSynthesis, .mediaGeneration]
        case .system: return [.system]
        }
    }

    var title: String {
        switch self {
        case .all: return L("All")
        case .models: return L("Models")
        case .web: return L("Web")
        case .tools: return L("Tools")
        case .channels: return L("Channels")
        case .api: return L("API")
        case .audioMedia: return L("Audio & Media")
        case .system: return L("System")
        }
    }

    /// The scope whose category set exactly equals `categories`, or nil when
    /// the filter holds an ad-hoc set (deep links, export descriptions). The
    /// tab row then shows no selection and the categories surface as tokens.
    static func scope(for categories: Set<ActivityCategory>) -> InsightsScope? {
        allCases.first { $0.categories == categories }
    }

    /// Scope that contains a single category (used for row glyph tinting and
    /// for deciding which scope a category token belongs to).
    static func scope(containing category: ActivityCategory) -> InsightsScope {
        allCases.first { $0 != .all && $0.categories.contains(category) } ?? .all
    }
}

// MARK: - Filter tokens

/// One removable chip describing an active narrowing criterion. Derived
/// from `ActivityFilter` on every render; `remove` resets exactly the field
/// the token came from and nothing else.
struct ActivityFilterToken: Identifiable, Equatable {
    enum Kind: Equatable {
        case text
        case dateRange
        case locality
        case categories
        case source(RequestSource)
        case destination
        case model
        case agent
        case status
        case privacyFilter
        case pluginLogsHidden
    }

    let kind: Kind
    let label: String

    var id: String {
        switch kind {
        case .source(let s): return "source:\(s.rawValue)"
        default: return "\(kind)"
        }
    }

    /// Tokens for every active field of `filter`. Scope-shaped category sets
    /// are omitted (the scope tab already shows them); ad-hoc sets render as
    /// one token listing the categories.
    static func tokens(for filter: ActivityFilter) -> [ActivityFilterToken] {
        var out: [ActivityFilterToken] = []
        let trimmed = filter.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            out.append(.init(kind: .text, label: "“\(trimmed)”"))
        }
        if filter.dateRange != .all {
            out.append(.init(kind: .dateRange, label: filter.dateRange.displayName))
        }
        if let locality = filter.locality {
            out.append(.init(kind: .locality, label: locality.displayName))
        }
        if !filter.categories.isEmpty, InsightsScope.scope(for: filter.categories) == nil {
            let names = ActivityCategory.allCases
                .filter { filter.categories.contains($0) }
                .map(\.displayName)
                .joined(separator: ", ")
            out.append(.init(kind: .categories, label: names))
        }
        for source in RequestSource.allCases where filter.sources.contains(source) {
            out.append(.init(kind: .source(source), label: source.displayName))
        }
        if let host = filter.destinationHost {
            out.append(.init(kind: .destination, label: host))
        }
        if let model = filter.model {
            out.append(.init(kind: .model, label: model))
        }
        if filter.agentId != nil {
            out.append(.init(kind: .agent, label: L("Agent")))
        }
        if filter.status != .all {
            out.append(.init(kind: .status, label: filter.status.displayName))
        }
        if let privacy = filter.privacyFilterApplied {
            out.append(.init(kind: .privacyFilter, label: privacy ? L("Privacy-filtered") : L("Unfiltered")))
        }
        if !filter.includePluginLogs {
            out.append(.init(kind: .pluginLogsHidden, label: L("Plugin logs hidden")))
        }
        return out
    }

    /// Reset the one field this token represents.
    func remove(from filter: inout ActivityFilter) {
        switch kind {
        case .text: filter.text = ""
        case .dateRange: filter.dateRange = .all
        case .locality: filter.locality = nil
        case .categories: filter.categories = []
        case .source(let s): filter.sources.remove(s)
        case .destination: filter.destinationHost = nil
        case .model: filter.model = nil
        case .agent: filter.agentId = nil
        case .status: filter.status = .all
        case .privacyFilter: filter.privacyFilterApplied = nil
        case .pluginLogsHidden: filter.includePluginLogs = true
        }
    }
}
