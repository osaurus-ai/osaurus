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
}

/// Optional extension protocol for tools that declare requirements and default policy.
protocol PermissionedTool {
    /// Capability/requirement identifiers, e.g. "permission:web", "permission:folder", "tool:browser"
    var requirements: [String] { get }
    /// Default policy suggested by the tool (host configuration may override)
    var defaultPermissionPolicy: ToolPermissionPolicy { get }
}
