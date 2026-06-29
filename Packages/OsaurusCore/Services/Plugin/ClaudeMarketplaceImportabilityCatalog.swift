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
    /// Precomputed summary of the Osaurus-importable components a plugin ships.
    /// Display names match the runtime `ClaudeSkillEntry`/`ClaudeAgentEntry`/
    /// `ClaudeCommandEntry.displayName` derivations so the detail view can
    /// render chips identically without resolving the manifest over the network.
    public struct ComponentSummary: Sendable, Hashable, Codable {
        public let skills: [String]
        public let agents: [String]
        public let commands: [String]
        public let mcp: Bool
        public let hooks: Bool
        public let unsupportedComponents: [String]

        public init(
            skills: [String],
            agents: [String],
            commands: [String],
            mcp: Bool,
            hooks: Bool = false,
            unsupportedComponents: [String] = []
        ) {
            self.skills = skills
            self.agents = agents
            self.commands = commands
            self.mcp = mcp
            self.hooks = hooks
            self.unsupportedComponents = unsupportedComponents
        }

        /// True when the plugin ships nothing Osaurus can import.
        public var isEmpty: Bool {
            skills.isEmpty && agents.isEmpty && commands.isEmpty && !mcp
        }

        /// Total count of components Osaurus knows how to import.
        public var importableCount: Int {
            skills.count + agents.count + commands.count + (mcp ? 1 : 0)
        }

        private enum CodingKeys: String, CodingKey {
            case skills, agents, commands, mcp, hooks, unsupportedComponents
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
            agents = try container.decodeIfPresent([String].self, forKey: .agents) ?? []
            commands = try container.decodeIfPresent([String].self, forKey: .commands) ?? []
            mcp = try container.decodeIfPresent(Bool.self, forKey: .mcp) ?? false
            hooks = try container.decodeIfPresent(Bool.self, forKey: .hooks) ?? false
            unsupportedComponents =
                try container.decodeIfPresent([String].self, forKey: .unsupportedComponents) ?? []
        }
    }

    /// Plugin names (as they appear in `marketplace.json`) that ship nothing
    /// Osaurus can import. The set is intentionally a denylist: any name NOT
    /// present is treated as importable / visible, so newly added plugins the
    /// bundled catalog hasn't classified yet still appear (and are gated at
    /// install time by `ClaudeMarketplaceService.install`).
    public let nonImportable: Set<String>

    /// Per-plugin importable component summary. A `nil` lookup means the plugin
    /// is unclassified (e.g. newly added upstream); the detail view falls back
    /// to a neutral "details unavailable" state rather than fetching live.
    public let componentsByName: [String: ComponentSummary]

    public init(
        nonImportable: Set<String>,
        componentsByName: [String: ComponentSummary] = [:]
    ) {
        self.nonImportable = nonImportable
        self.componentsByName = componentsByName
    }

    /// True only for plugins explicitly listed as non-importable.
    public func isNonImportable(name: String) -> Bool {
        nonImportable.contains(name)
    }

    /// Precomputed importable components for a plugin, or `nil` if unclassified.
    public func components(for name: String) -> ComponentSummary? {
        componentsByName[name]
    }

    /// Build the trust/provenance preview used by Browse cards, detail, and
    /// install-time guardrails. This is intentionally catalog-backed: opening
    /// Browse should not probe every plugin's repo.
    public func trustPreview(
        for entry: MarketplacePlugin,
        marketplaceRepo: GitHubRepo = ClaudeMarketplaceTrustPreview.Source.defaultMarketplaceRepo
    ) -> ClaudeMarketplaceTrustPreview {
        let summary = components(for: entry.name)
        let source = ClaudeMarketplaceTrustPreview.Source(
            marketplaceRepo: marketplaceRepo,
            marketplaceURLLabel: "github.com/\(marketplaceRepo.owner)/\(marketplaceRepo.name)",
            source: entry.source,
            pluginName: entry.name
        )

        let status: ClaudeMarketplaceTrustPreview.ImportabilityStatus
        let reason: String
        if isNonImportable(name: entry.name) || summary?.isEmpty == true {
            status = .blocked
            reason = "No importable skills, agents, commands, or MCP servers were found in the bundled catalog."
        } else if summary == nil {
            status = .requiresReview
            reason =
                "This entry is not in the bundled importability catalog yet, so Osaurus cannot preview what would be installed."
        } else {
            status = .importable
            reason = "The bundled catalog found importable plugin components."
        }

        return ClaudeMarketplaceTrustPreview(
            pluginName: entry.name,
            source: source,
            componentSummary: summary,
            importabilityStatus: status,
            reason: reason
        )
    }

    // MARK: - Bundled instance

    /// The catalog shipped in the app bundle. Parsed once, lazily.
    public static let bundled: ClaudeMarketplaceImportabilityCatalog = loadBundled()

    private struct CatalogFile: Decodable {
        let nonImportable: [String]
        let plugins: [String: ComponentSummary]?
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
            return ClaudeMarketplaceImportabilityCatalog(
                nonImportable: Set(file.nonImportable),
                componentsByName: file.plugins ?? [:]
            )
        } catch {
            assertionFailure("Failed to parse importability catalog: \(error)")
            return ClaudeMarketplaceImportabilityCatalog(nonImportable: [])
        }
    }
}

public struct ClaudeMarketplaceTrustPreview: Sendable, Hashable {
    public enum ImportabilityStatus: String, Sendable, Hashable {
        case importable
        case requiresReview
        case blocked
    }

    public struct Source: Sendable, Hashable {
        public static let defaultMarketplaceRepo = GitHubRepo(
            owner: "anthropics",
            name: "claude-plugins-official"
        )

        public let marketplaceOwner: String
        public let marketplaceName: String
        public let marketplaceURLLabel: String
        public let owner: String
        public let repository: String
        public let path: String?
        public let isOfficialMarketplace: Bool
        public let isMarketplaceRepo: Bool

        public var repositoryLabel: String { "\(owner)/\(repository)" }
        public var repositoryURLLabel: String { "github.com/\(owner)/\(repository)" }

        public init(
            marketplaceRepo: GitHubRepo,
            marketplaceURLLabel: String,
            source: MarketplaceSource?,
            pluginName: String
        ) {
            self.marketplaceOwner = marketplaceRepo.owner
            self.marketplaceName = marketplaceRepo.name
            self.marketplaceURLLabel = marketplaceURLLabel
            self.isOfficialMarketplace =
                marketplaceRepo.owner == Self.defaultMarketplaceRepo.owner
                && marketplaceRepo.name == Self.defaultMarketplaceRepo.name

            switch source {
            case .localDirectory(let directory):
                self.owner = marketplaceRepo.owner
                self.repository = marketplaceRepo.name
                self.path = Self.normalizedPath(directory)
            case .externalRepo(let repo, _):
                self.owner = repo.owner
                self.repository = repo.name
                self.path = nil
            case .externalSubdir(let repo, let path, _):
                self.owner = repo.owner
                self.repository = repo.name
                self.path = Self.normalizedPath(path)
            case nil:
                self.owner = marketplaceRepo.owner
                self.repository = marketplaceRepo.name
                self.path = Self.normalizedPath(pluginName)
            }

            self.isMarketplaceRepo =
                owner == marketplaceRepo.owner && repository == marketplaceRepo.name
        }

        private static func normalizedPath(_ value: String) -> String? {
            var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
            trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    public struct CapabilityIndicator: Sendable, Hashable, Identifiable {
        public enum Severity: String, Sendable, Hashable {
            case normal
            case sensitive
            case unsupported
        }

        public let id: String
        public let label: String
        public let count: Int?
        public let severity: Severity
    }

    public let pluginName: String
    public let source: Source
    public let componentSummary: ClaudeMarketplaceImportabilityCatalog.ComponentSummary?
    public let importabilityStatus: ImportabilityStatus
    public let reason: String

    public var canInstallWithoutReview: Bool {
        importabilityStatus == .importable
    }

    public var installGuardError: ClaudeMarketplaceInstallPreviewError? {
        switch importabilityStatus {
        case .importable, .requiresReview:
            return nil
        case .blocked:
            return .blocked(pluginName: pluginName, reason: reason)
        }
    }

    public var statusTitle: String {
        switch importabilityStatus {
        case .importable:
            return "Ready to install"
        case .requiresReview:
            return "Review required"
        case .blocked:
            return "Not importable"
        }
    }

    public var capabilityIndicators: [CapabilityIndicator] {
        guard let summary = componentSummary else { return [] }
        var indicators: [CapabilityIndicator] = []
        if !summary.skills.isEmpty {
            indicators.append(
                CapabilityIndicator(
                    id: "skills",
                    label: "Skills",
                    count: summary.skills.count,
                    severity: .normal
                )
            )
        }
        if !summary.agents.isEmpty {
            indicators.append(
                CapabilityIndicator(
                    id: "agents",
                    label: "Agents",
                    count: summary.agents.count,
                    severity: .sensitive
                )
            )
        }
        if !summary.commands.isEmpty {
            indicators.append(
                CapabilityIndicator(
                    id: "commands",
                    label: "Commands",
                    count: summary.commands.count,
                    severity: .sensitive
                )
            )
        }
        if summary.mcp {
            indicators.append(
                CapabilityIndicator(
                    id: "mcp",
                    label: "MCP",
                    count: nil,
                    severity: .sensitive
                )
            )
        }
        if summary.hooks {
            indicators.append(
                CapabilityIndicator(
                    id: "hooks",
                    label: "Hooks",
                    count: nil,
                    severity: .unsupported
                )
            )
        }
        for component in summary.unsupportedComponents {
            indicators.append(
                CapabilityIndicator(
                    id: "unsupported-\(component)",
                    label: Self.displayName(forUnsupportedComponent: component),
                    count: nil,
                    severity: .unsupported
                )
            )
        }
        return indicators
    }

    private static func displayName(forUnsupportedComponent component: String) -> String {
        switch component {
        case "outputStyles":
            return "Output styles"
        case "lspServers":
            return "LSP servers"
        default:
            return
                component
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}

public enum ClaudeMarketplaceInstallPreviewError: Error, LocalizedError, Equatable, Sendable {
    case blocked(pluginName: String, reason: String)
    case reviewRequired(pluginName: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .blocked(let pluginName, let reason):
            return "\(Self.safePluginLabel(pluginName)) cannot be installed: \(reason)"
        case .reviewRequired(let pluginName, let reason):
            return "\(Self.safePluginLabel(pluginName)) requires review before install: \(reason)"
        }
    }

    private static func safePluginLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            !trimmed.localizedCaseInsensitiveContains("://"),
            !trimmed.localizedCaseInsensitiveContains("token"),
            !trimmed.localizedCaseInsensitiveContains("secret")
        else {
            return "This plugin"
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let scalars = trimmed.unicodeScalars.filter { allowed.contains($0) }
        let sanitized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return "This plugin" }
        return String(sanitized.prefix(80))
    }
}
