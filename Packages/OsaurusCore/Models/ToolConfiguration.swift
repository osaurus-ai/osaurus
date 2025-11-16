//
//  ToolConfiguration.swift
//  osaurus
//
//  Per-tool enablement configuration persisted to disk.
//

import Foundation

/// Configuration for chat tools enable/disable state
struct ToolConfiguration: Codable, Equatable, Sendable {
    /// Mapping of tool name -> enabled flag. Missing entries default to true (enabled).
    var enabled: [String: Bool]

    init(enabled: [String: Bool] = [:]) {
        self.enabled = enabled
    }

    /// Returns whether a tool is enabled. Defaults to true if not explicitly set.
    func isEnabled(name: String) -> Bool {
        return enabled[name] ?? true
    }

    /// Set enabled state for a tool name.
    mutating func setEnabled(_ value: Bool, for name: String) {
        enabled[name] = value
    }
}
