//
//  ConfigurationDomain.swift
//  osaurus
//
//  Extensibility primitive for the default-agent configure surface.
//  Each configurable area (providers, models, plugins, schedules,
//  agents) is one `ConfigurationDomain` value. Adding a new domain
//  is one file + one `ConfigurationDomainRegistry.shared.register(_:)`.
//

import Foundation

/// A registered configurable surface area for the default agent.
///
/// Kept module-internal because `tools: [any OsaurusTool]` would
/// otherwise leak the internal `OsaurusTool` protocol through a
/// public-API surface. The per-domain factory enums
/// (`ProviderConfigurationDomain`, …) are the only construction
/// sites and they live inside this module.
struct ConfigurationDomain: Sendable {
    /// Stable lower-snake-case id (`"providers"`, `"models"`, …).
    /// Used as the FTS5 row key.
    let id: String

    /// Human-readable display name surfaced in the system-prompt menu.
    let displayName: String

    /// One-line "what does this domain do?" summary (<100 chars).
    /// Indexed by `capabilities_discover` and rendered in the
    /// default-agent system prompt addendum.
    let summary: String

    /// One-line hint shown in the system-prompt menu, typically a
    /// comma-separated list of examples.
    let menuHint: String

    /// User-language phrases that boost BM25 / embedding ranking on
    /// `capabilities_discover`. Not surfaced to the LLM as text.
    let searchKeywords: [String]

    /// 2–3 typical user phrases per write verb, indexed alongside
    /// `searchKeywords` so phrasings like "download a model" rank
    /// the right tool even when the tool name doesn't appear.
    let exampleQueries: [String]

    /// Every tool in this domain — reads and writes. Registration
    /// adds them to `ToolRegistry` as built-ins.
    let tools: [any OsaurusTool]

    /// Subset of `tools` that are write actions. Drives
    /// `ToolRegistry.configureWriteToolNames`, which the composer
    /// strips from non-default-agent schemas and which
    /// `capabilities_load` gates on for the default agent.
    let writeToolNames: Set<String>
}

/// Singleton registry of `ConfigurationDomain`s. Bootstrapped once
/// from `ConfigurationDomainBootstrap.registerBuiltIns()` at app launch.
@MainActor
final class ConfigurationDomainRegistry: ObservableObject {
    static let shared = ConfigurationDomainRegistry()

    /// Registered domains in insertion order — also the order they
    /// appear in the system-prompt menu, so register "most relevant
    /// first" (providers → models → plugins → schedules → agents).
    @Published private(set) var domains: [ConfigurationDomain] = []

    /// Monotonic counter bumped on every `register(_:)`. Consumers
    /// (`DefaultAgentSystemPromptBuilder`, capability search index)
    /// compare against their cached value to invalidate.
    @Published private(set) var generation: Int = 0

    private var registeredIds: Set<String> = []

    private init() {}

    /// Register a configurable domain. Idempotent on `id`. Adds every
    /// tool to `ToolRegistry` as a built-in and seeds the search index
    /// with the domain's user-language hints so phrases like
    /// "connect anthropic" can rank `osaurus_provider` even when
    /// neither term appears in the raw tool description.
    func register(_ domain: ConfigurationDomain) {
        if registeredIds.contains(domain.id) {
            NSLog(
                "[ConfigurationDomainRegistry] Domain '\(domain.id)' is already registered; skipping duplicate."
            )
            return
        }

        for tool in domain.tools {
            ToolRegistry.shared.register(tool)
            ToolRegistry.shared.markBuiltIn(toolName: tool.name)
        }

        registeredIds.insert(domain.id)
        domains.append(domain)
        generation &+= 1

        // Fire-and-forget seed of the FTS5 + embedding index. The
        // index is lazy and `onToolRegistered` upserts, so a later
        // `syncFromRegistry()` is safe.
        for tool in domain.tools {
            let enrichedDescription = enrichedSearchDescription(
                for: tool,
                in: domain
            )
            Task {
                await ToolIndexService.shared.onToolRegistered(
                    name: tool.name,
                    description: enrichedDescription,
                    runtime: .builtin,
                    parameters: tool.parameters
                )
            }
        }
    }

    /// Tool description + domain summary + search keywords + example
    /// queries, joined for the embedder. The model-facing
    /// `tool.description` stays unchanged.
    private func enrichedSearchDescription(
        for tool: any OsaurusTool,
        in domain: ConfigurationDomain
    ) -> String {
        var parts: [String] = [tool.description, domain.summary]
        parts.append(contentsOf: domain.searchKeywords)
        parts.append(contentsOf: domain.exampleQueries)
        return parts.joined(separator: " ")
    }

    /// Test-only: clear every registered domain.
    func _resetForTests() {
        registeredIds.removeAll()
        domains.removeAll()
        generation &+= 1
    }
}
