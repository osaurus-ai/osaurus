//
//  AgentDetailTabRoute.swift
//  osaurus
//
//  Canonical routing for `.agentDetailDeeplink` tab payloads. The agent
//  detail view used to expose one tab per database surface (home /
//  schema / data / views / activity); those are now sections inside a
//  single Database workspace. This resolver keeps every historical raw
//  tab value working by mapping it onto the current tab + database
//  section, so notification taps, `osaurus://` handlers, and saved
//  deep-links from older builds keep landing in the right place.
//

import Foundation

/// Sections inside the agent Database workspace.
public enum AgentDatabaseSection: String, CaseIterable, Identifiable, Sendable {
    case overview
    case tables
    case savedViews
    case history

    public var id: String { rawValue }
}

/// Resolved deep-link target inside an agent's detail view.
public struct AgentDetailTabRoute: Equatable, Sendable {
    /// Raw value of the detail tab to select (matches the detail view's
    /// private `DetailTab` enum raw values).
    public let tabRawValue: String
    /// When the target is the Database workspace, the section to open.
    /// `nil` leaves the workspace on its default section.
    public let databaseSection: AgentDatabaseSection?

    public init(tabRawValue: String, databaseSection: AgentDatabaseSection? = nil) {
        self.tabRawValue = tabRawValue
        self.databaseSection = databaseSection
    }

    /// Current canonical tab raw values, kept in sync with the detail
    /// view's `DetailTab` enum.
    public static let canonicalTabRawValues: Set<String> = [
        "configure", "capabilities", "subagents", "customization", "network",
        "connections", "sandbox", "automation", "memory", "database",
    ]

    /// Resolves a deep-link tab string, including the legacy per-surface
    /// database tab names that older callers still post.
    public static func resolve(_ raw: String) -> AgentDetailTabRoute? {
        switch raw {
        case "home":
            return AgentDetailTabRoute(tabRawValue: "database", databaseSection: .overview)
        case "schema", "data":
            return AgentDetailTabRoute(tabRawValue: "database", databaseSection: .tables)
        case "views":
            return AgentDetailTabRoute(tabRawValue: "database", databaseSection: .savedViews)
        case "activity":
            return AgentDetailTabRoute(tabRawValue: "database", databaseSection: .history)
        default:
            guard canonicalTabRawValues.contains(raw) else { return nil }
            return AgentDetailTabRoute(tabRawValue: raw)
        }
    }
}
