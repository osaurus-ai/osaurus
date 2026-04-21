//
//  ToolPermissionPolicy.swift
//  osaurus
//
//  Permission model for tools and optional capability requirements.
//

import Foundation

enum ToolPermissionPolicy: String, Codable, Sendable {
    case auto
    case ask
    case deny

    var displayName: String {
        switch self {
        case .auto: return L("Auto")
        case .ask: return L("Ask")
        case .deny: return L("Deny")
        }
    }
}

/// Optional extension protocol for tools that declare requirements and default policy.
protocol PermissionedTool {
    /// Capability/requirement identifiers, e.g. "permission:web", "permission:folder", "tool:browser"
    var requirements: [String] { get }
    /// Default policy suggested by the tool (host configuration may override)
    var defaultPermissionPolicy: ToolPermissionPolicy { get }
}
