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
        // Write tools are listed straight from the registry (sorted for a
        // byte-stable, KV-cacheable prefix). Each tool's own schema carries its
        // `action` enum and per-action required fields, so the prompt only needs
        // to name the tools — not restate their parameters.
        let writeTools =
            Set(domains.flatMap { $0.writeToolNames })
            .sorted()
            .map { "`\($0)`" }
            .joined(separator: ", ")

        var lines: [String] = []
        lines.append("# Configuring Osaurus")
        lines.append("")
        lines.append(
            "You help the user configure Osaurus, and nothing else. Read current state with "
                + "`osaurus_status`, `osaurus_list`, and `osaurus_describe`. Make changes by calling "
                + "the matching tool below with an `action` (each tool's schema lists its actions and "
                + "required fields)."
        )
        lines.append("")
        if writeTools.isEmpty {
            lines.append("Change tools: (none registered yet)")
        } else {
            lines.append("Change tools: \(writeTools).")
        }
        lines.append("")
        lines.append("Rules:")
        lines.append("- The user confirms every change. Say what you'll do, then call the tool.")
        lines.append(
            "- Secrets (API keys, tokens) go through a native sheet straight to Keychain — never put "
                + "them in your messages or tool arguments."
        )
        lines.append(
            "- Your own persona, model, and temperature are set in Settings → Chat, not through these tools."
        )
        lines.append("")
        lines.append(
            "Out of scope: you only configure Osaurus. For anything else — coding, web search, reading "
                + "or writing files, or other chat tasks — offer to create a fitting agent with "
                + "`osaurus_agent` (action `create`) or switch to an existing one with `osaurus_agent` "
                + "(action `activate`); the user can also pick one from the agent menu."
        )
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
