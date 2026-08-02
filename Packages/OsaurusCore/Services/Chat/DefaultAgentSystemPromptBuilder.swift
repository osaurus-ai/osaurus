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
    private static var cachedCompactGeneration: Int = -1
    private static var cachedCompactAddendum: String = ""

    /// Render (or return the cached) addendum. Memoized against
    /// `ConfigurationDomainRegistry.shared.generation` so the prompt
    /// is byte-stable across turns when nothing has changed and
    /// regenerated exactly once when a new domain registers.
    ///
    /// `compact` renders the leaner variant for small local models
    /// (`prefersCompactPrompt`) — same tool surface, trimmed prose —
    /// memoized on its own cache slot so toggling model size mid-app
    /// doesn't thrash the full-variant cache.
    public static func render(compact: Bool = false) -> String {
        let generation = ConfigurationDomainRegistry.shared.generation
        if compact {
            if generation == cachedCompactGeneration { return cachedCompactAddendum }
            let rendered = build(from: ConfigurationDomainRegistry.shared.domains, compact: true)
            cachedCompactGeneration = generation
            cachedCompactAddendum = rendered
            return rendered
        }
        if generation == cachedGeneration { return cachedAddendum }
        let rendered = build(from: ConfigurationDomainRegistry.shared.domains, compact: false)
        cachedGeneration = generation
        cachedAddendum = rendered
        return rendered
    }

    /// Test-only build path: render an addendum from an arbitrary
    /// list of domains without touching the shared registry / cache.
    /// Internal because `ConfigurationDomain` itself is internal —
    /// tests reach this through `@testable import OsaurusCore`.
    static func _renderForTests(domains: [ConfigurationDomain], compact: Bool = false) -> String {
        build(from: domains, compact: compact)
    }

    /// Test-only: forget the memoized value so the next `render()`
    /// rebuilds. Use alongside `ConfigurationDomainRegistry._resetForTests()`.
    public static func _resetForTests() {
        cachedGeneration = -1
        cachedAddendum = ""
        cachedCompactGeneration = -1
        cachedCompactAddendum = ""
    }

    private static func build(from domains: [ConfigurationDomain], compact: Bool) -> String {
        // Write tools are listed straight from the registry (sorted for a
        // byte-stable, KV-cacheable prefix). Each tool's own schema carries its
        // `action` enum and per-action required fields, so the prompt only needs
        // to name the tools — not restate their parameters.
        let writeTools =
            Set(domains.flatMap { $0.writeToolNames })
            .sorted()
            .map { "`\($0)`" }
            .joined(separator: ", ")

        if compact {
            // Small local models pay a long prefill for tool schemas, so the
            // per-domain write tools are DEFERRED from the turn-1 schema (in
            // `SystemPromptComposer.resolveTools`). Name them here so the model
            // loads the one it needs by name in a single round-trip — no
            // `capabilities_discover` step. `osaurus_agent` stays loaded, so the
            // "if it isn't already available" clause lets the model call it
            // directly for the out-of-scope handoff.
            //
            // Each write tool carries its domain's one-line `menuHint`:
            // deferring the schemas removed the ONLY text that said what each
            // tool does, and a 12B model reading the bare name `osaurus_model`
            // refused "download the MLX model …" as out-of-scope web work.
            // The full variant doesn't need this — its writes ship complete
            // schemas in turn 1.
            let writeToolLines =
                domains
                .flatMap { domain in
                    domain.writeToolNames.sorted().map { name in
                        "- `\(name)` — \(domain.menuHint)"
                    }
                }
                .sorted()
            var lines: [String] = []
            lines.append("# Osaurus Assistant")
            lines.append("")
            lines.append(
                "You are Osaurus's built-in assistant: you configure Osaurus and answer "
                    + "questions about it. Reads are always available; call them directly "
                    + "(no loading step): `osaurus_status`, `osaurus_list`, `osaurus_describe` "
                    + "for the current configuration; `osaurus_help` for how Osaurus and its "
                    + "features work — read the matching topic, then answer from its text."
            )
            lines.append("")
            if writeToolLines.isEmpty {
                lines.append("Change tools: (none registered yet)")
            } else {
                lines.append("Change tools:")
                lines.append(contentsOf: writeToolLines)
                // The read-exclusion lives HERE, at the load decision site,
                // not only in the intro: gemma-12B live runs read the old
                // "if the one you need isn't already available, load it"
                // as covering reads too, and opened read-only turns with
                // `capabilities_load` ids=[tool/osaurus_status, …] — or
                // loaded a WRITE tool (`osaurus_schedule`) just to list
                // schedules — burning tight iteration budgets into empty
                // finals.
                lines.append(
                    "These change tools load on demand (keeps startup fast): if the "
                        + "change tool you need isn't already available, call "
                        + "`capabilities_load` with `tool/<name>` "
                        + "(e.g. `tool/osaurus_provider`), then call it with an `action` "
                        + "(its schema lists actions + fields). Loading is for change "
                        + "tools only — reads never need it: to look anything up "
                        + "(schedules, MCP, plugins, providers, models, agents) call the "
                        + "read tools directly."
                )
            }
            lines.append("")
            lines.append(
                "Rules: for a change, act in the same turn — briefly state it, then call the "
                    + "tool. A separate one-tap approval gates every change, so never ask for "
                    + "confirmation in chat or wait for a \"yes\". For a question, read then "
                    + "answer: once the tool results contain the answer, reply in plain text — "
                    + "do not call more tools, and do not answer Osaurus questions from memory "
                    + "without reading `osaurus_help`. Secrets go through the native Keychain "
                    + "sheet — never in messages or tool args."
            )
            lines.append("")
            lines.append(
                "Out of scope: doing non-Osaurus work yourself (coding, web tasks, files, "
                    + "images) — offer to create a fitting agent (`osaurus_agent` action "
                    + "`create`) or switch to one (action `activate`); the agent menu also "
                    + "works. Managing or explaining Osaurus itself — agents, models, "
                    + "providers, MCP, plugins, schedules, settings — IS your job, even when "
                    + "the request mentions web or downloads: use the tools above."
            )
            lines.append("")
            return lines.joined(separator: "\n")
        }

        var lines: [String] = []
        lines.append("# Osaurus Assistant")
        lines.append("")
        lines.append(
            "You are Osaurus's built-in assistant. You do two things: configure Osaurus, and answer "
                + "questions about Osaurus itself. Read current state with `osaurus_status`, "
                + "`osaurus_list`, and `osaurus_describe`. For questions about what Osaurus is or how "
                + "a feature works (models, providers, agents, skills, plugins, MCP, schedules, "
                + "memory, server/API, voice, and more), call `osaurus_help` — list `topics`, `read` "
                + "the matching one, and answer from its text rather than from memory. Make changes "
                + "by calling the matching tool below with an `action` (each tool's schema lists its "
                + "actions and required fields)."
        )
        lines.append("")
        if writeTools.isEmpty {
            lines.append("Change tools: (none registered yet)")
        } else {
            lines.append("Change tools: \(writeTools).")
        }
        lines.append("")
        lines.append("Rules:")
        lines.append(
            "- Act in the same turn: briefly state the change, then call the tool. A separate one-tap "
                + "approval gates every change, so don't ask for confirmation in chat or wait for a "
                + "\"yes\" first."
        )
        lines.append(
            "- For a question, read then answer: once the tool results contain the answer, reply in "
                + "plain text grounded in them — don't keep calling tools, and don't guess about "
                + "Osaurus features without reading `osaurus_help`."
        )
        lines.append(
            "- Secrets (API keys, tokens) go through a native sheet straight to Keychain — never put "
                + "them in your messages or tool arguments."
        )
        lines.append("")
        lines.append(
            "Out of scope: doing non-Osaurus work yourself — coding, web research, reading or "
                + "writing files, or other chat tasks. Offer to create a fitting agent with "
                + "`osaurus_agent` (action `create`) or switch to an existing one with `osaurus_agent` "
                + "(action `activate`); the user can also pick one from the agent menu. Questions "
                + "about Osaurus itself are always in scope — answer them with `osaurus_help`."
        )
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
