//
//  ToolCatalogPresentation.swift
//  osaurus
//
//  Pure presentation model for the user-facing Tools catalog. Maps the exact
//  runtime exposure states (`ToolExposureState` / `ToolExposureSource`) onto
//  the plain-language categories the Tools screen shows by default. The
//  technically exact diagnostics remain available unchanged through
//  `ToolExposureDiagnostic` (Advanced diagnostics + reporter-safe export).
//

import Foundation

// MARK: - Catalog Status

/// User-facing status for a tool row. Deliberately coarse: everyday users need
/// to know whether a tool works, is switched off, or needs their help — not
/// which of six exposure states the runtime assigned it.
enum ToolCatalogStatus: String, CaseIterable, Sendable {
    /// The tool can be used (callable now, loadable on demand, or scoped to
    /// specific agents/modes). Nothing for the user to do.
    case ready
    /// The user switched the tool off globally.
    case off
    /// The tool cannot run until the user acts (missing system permission,
    /// required configuration, install/registration failure, or a blocked
    /// permission policy).
    case needsAttention

    var displayLabel: String {
        switch self {
        case .ready: return L("Ready")
        case .off: return L("Off")
        case .needsAttention: return L("Needs attention")
        }
    }
}

// MARK: - Catalog Section

/// Plain-language grouping for the catalog: where a tool comes from, in the
/// user's vocabulary. Every `ToolExposureSource` maps to exactly one section
/// so each registered tool has exactly one home on the All tab.
enum ToolCatalogSection: String, CaseIterable, Identifiable, Sendable {
    case builtIn
    case plugins
    case connections
    case custom

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .builtIn: return L("Built-in")
        case .plugins: return L("Plugins")
        case .connections: return L("Connections")
        case .custom: return L("Custom")
        }
    }
}

// MARK: - Mapping

enum ToolCatalogPresentation {
    /// Maps an exact exposure state to the user-facing status. A missing
    /// system permission always wins: the tool may technically be exposed,
    /// but it cannot succeed until the user grants access.
    static func status(
        state: ToolExposureState?,
        hasMissingSystemPermissions: Bool
    ) -> ToolCatalogStatus {
        if hasMissingSystemPermissions { return .needsAttention }
        guard let state else { return .ready }
        switch state {
        case .exposed, .loadable, .hidden:
            return .ready
        case .disabled:
            return .off
        case .blocked, .unavailable:
            return .needsAttention
        }
    }

    /// Maps an exact exposure source to its catalog section. Runtime-managed
    /// (folder/sandbox execution) and native tools ship with Osaurus, so they
    /// read as Built-in; unknown sources fall back to Built-in rather than
    /// inventing a technical bucket the user can't act on.
    static func section(for source: ToolExposureSource) -> ToolCatalogSection {
        switch source {
        case .builtIn, .native, .runtime, .unknown:
            return .builtIn
        case .plugin:
            return .plugins
        case .mcpProvider:
            return .connections
        case .sandboxPlugin:
            return .custom
        }
    }
}

// MARK: - Filters

/// Status filter for the catalog toolbar.
enum ToolCatalogStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case ready
    case off
    case needsAttention

    var id: String { rawValue }

    var status: ToolCatalogStatus? {
        switch self {
        case .all: return nil
        case .ready: return .ready
        case .off: return .off
        case .needsAttention: return .needsAttention
        }
    }

    var title: String {
        status?.displayLabel ?? L("All Statuses")
    }

    func matches(_ status: ToolCatalogStatus) -> Bool {
        self.status == nil || self.status == status
    }
}

/// Source filter for the catalog toolbar. Mirrors `ToolCatalogSection` plus
/// an "everything" default.
enum ToolCatalogSourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case builtIn
    case plugins
    case connections
    case custom

    var id: String { rawValue }

    var section: ToolCatalogSection? {
        switch self {
        case .all: return nil
        case .builtIn: return .builtIn
        case .plugins: return .plugins
        case .connections: return .connections
        case .custom: return .custom
        }
    }

    var title: String {
        section?.displayLabel ?? L("All Sources")
    }

    func matches(_ section: ToolCatalogSection) -> Bool {
        self.section == nil || self.section == section
    }
}
