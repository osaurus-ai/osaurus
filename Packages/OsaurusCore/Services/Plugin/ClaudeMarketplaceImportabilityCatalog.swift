//
//  ClaudeMarketplaceImportabilityCatalog.swift
//  osaurus
//
//  Precomputed classification of which official Claude marketplace plugins
//  ship something Osaurus can import (skills / agents / commands / MCP) vs.
//  those that ship only unsupported parts (hooks / output-styles / lspServers
//  / etc.).
//
//  Classifying 200+ plugins at runtime would require ~160 GitHub requests per
//  session (rate-limit blowup, jarring "countdown" as entries trickle in), so
//  the classification is precomputed offline and shipped as a bundle resource
//  at `Resources/ClaudePlugins/claude-marketplace-importability.json`.
//
//  Regenerate with:
//      python3 scripts/claude-marketplace/generate-importability-catalog.py
//

import Foundation

/// Read-only view over the bundled importability catalog. Loaded once and
/// cached for the process lifetime.
public struct ClaudeMarketplaceImportabilityCatalog: Sendable {
    /// Plugin names (as they appear in `marketplace.json`) that ship nothing
    /// Osaurus can import. The set is intentionally a denylist: any name NOT
    /// present is treated as importable / visible, so newly added plugins the
    /// bundled catalog hasn't classified yet still appear (and are gated at
    /// install time by `ClaudeMarketplaceService.install`).
    public let nonImportable: Set<String>

    public init(nonImportable: Set<String>) {
        self.nonImportable = nonImportable
    }

    /// True only for plugins explicitly listed as non-importable.
    public func isNonImportable(name: String) -> Bool {
        nonImportable.contains(name)
    }

    // MARK: - Bundled instance

    /// The catalog shipped in the app bundle. Parsed once, lazily.
    public static let bundled: ClaudeMarketplaceImportabilityCatalog = loadBundled()

    private struct CatalogFile: Decodable {
        let nonImportable: [String]
    }

    private static func loadBundled() -> ClaudeMarketplaceImportabilityCatalog {
        guard
            let url = Bundle.module.url(
                forResource: "claude-marketplace-importability",
                withExtension: "json",
                subdirectory: "ClaudePlugins"
            )
                ?? Bundle.module.url(
                    forResource: "claude-marketplace-importability",
                    withExtension: "json"
                )
        else {
            // Missing resource is a packaging error, not a user-facing one.
            // Degrade gracefully: show everything (install-time guard still
            // protects against empty installs).
            assertionFailure("claude-marketplace-importability.json missing from OsaurusCore bundle")
            return ClaudeMarketplaceImportabilityCatalog(nonImportable: [])
        }

        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(CatalogFile.self, from: data)
            return ClaudeMarketplaceImportabilityCatalog(nonImportable: Set(file.nonImportable))
        } catch {
            assertionFailure("Failed to parse importability catalog: \(error)")
            return ClaudeMarketplaceImportabilityCatalog(nonImportable: [])
        }
    }
}
