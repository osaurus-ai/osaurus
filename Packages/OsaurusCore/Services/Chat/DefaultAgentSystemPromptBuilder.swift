//
//  DefaultAgentSystemPromptBuilder.swift
//  osaurus
//
//  Renders the default-agent system-prompt addendum from the
//  `ConfigurationDomainRegistry`. Single source of truth: every
//  registered domain's `displayName` + `summary` + `menuHint` shows
//  up in the addendum so the model can never drift from what the
//  domain registry actually exposes.
//
//  The addendum is memoized per registry generation. As long as no
//  new domain registers, every turn sees byte-identical text, which
//  keeps the prompt prefix in the KV cache. When the user installs
//  a feature that adds a new domain, the cache is invalidated once
//  and the next turn uses the refreshed text.
//

import Foundation

@MainActor
public enum DefaultAgentSystemPromptBuilder {
    private static var cachedGeneration: Int = -1
    private static var cachedAddendum: String = ""

    /// Render (or return the cached) addendum. Memoized against
    /// `ConfigurationDomainRegistry.shared.generation` so the prompt
    /// is byte-stable across turns when nothing has changed and
    /// regenerated exactly once when a new domain registers.
    public static func render() -> String {
        let generation = ConfigurationDomainRegistry.shared.generation
        if generation == cachedGeneration { return cachedAddendum }
        let rendered = build(from: ConfigurationDomainRegistry.shared.domains)
        cachedGeneration = generation
        cachedAddendum = rendered
        return rendered
    }

    /// Test-only build path: render an addendum from an arbitrary
    /// list of domains without touching the shared registry / cache.
    /// Internal because `ConfigurationDomain` itself is internal —
    /// tests reach this through `@testable import OsaurusCore`.
    static func _renderForTests(domains: [ConfigurationDomain]) -> String {
        build(from: domains)
    }

    /// Test-only: forget the memoized value so the next `render()`
    /// rebuilds. Use alongside `ConfigurationDomainRegistry._resetForTests()`.
    public static func _resetForTests() {
        cachedGeneration = -1
        cachedAddendum = ""
    }

    private static func build(from domains: [ConfigurationDomain]) -> String {
        var lines: [String] = []
        lines.append("# Osaurus Configuration Agent")
        lines.append("")
        lines.append(
            "You are the user's first stop for configuring Osaurus. "
                + "Your job is to help them connect cloud providers, install local models, "
                + "set up plugins / schedules / custom agents — anything they need to get the "
                + "most out of Osaurus. You guide; you do not silently change things."
        )
        lines.append("")
        lines.append("**Configurable domains:**")
        if domains.isEmpty {
            lines.append("- (no configuration domains registered yet)")
        } else {
            for domain in domains {
                lines.append(
                    "- **\(domain.id)** — \(domain.summary) "
                        + "(\(domain.menuHint))"
                )
            }
        }
        lines.append("")
        lines.append("**Reading state** — always available, call directly:")
        lines.append("- `osaurus_status` — one-shot overview + suggested next steps")
        lines.append("- `osaurus_list({scope, filter?})` — list items in a scope")
        lines.append("- `osaurus_describe({scope, id})` — full detail for one item")
        lines.append("")
        lines.append("**Performing writes** — writes are NOT in your default schema. To call a write:")
        lines.append(
            "1. `capabilities_discover({query: \"<verb> <noun>\"})` — e.g. \"add provider\", \"install plugin\", \"download model\", \"create schedule\", \"create agent\"."
        )
        lines.append(
            "2. `capabilities_load({ids: [\"tool/<name>\"]})` — injects the write tool's spec into your schema."
        )
        lines.append("3. Call the loaded tool with `snake_case` arguments.")
        lines.append("")
        lines.append("**Rules:**")
        lines.append(
            "- Secrets (API keys, OAuth tokens) NEVER appear in your messages or tool args. They flow through a native sheet directly to Keychain."
        )
        lines.append(
            "- You cannot self-configure. Default-agent settings (persona, model, temperature) are user-edited in Settings → Chat."
        )
        lines.append("- Out of scope: server settings, memory, privacy filter, themes, watchers, sandbox internals.")
        lines.append("- Never invent tool names — `osaurus_*_<verb>` writes only come from `capabilities_discover`.")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
