//
//  PreflightEvaluator.swift
//  osaurus
//
//  Public facade over `PreflightCapabilitySearch` for off-process callers
//  (the OsaurusEvals package, future scoreboards, etc.). Keeps the
//  internal `PreflightResult` / `Tool` / `PluginCompanion` types
//  encapsulated and exposes a stable, decode-friendly surface that won't
//  shift if the internal pipeline rearranges itself.
//

import Foundation

// MARK: - Public types

/// Decode-friendly snapshot of one preflight run for an evaluation
/// harness. Only carries names + descriptions (no `Tool` schemas, no
/// JSONSchema parameter blobs) so it round-trips through JSON cleanly
/// and stays stable as the inference plumbing evolves.
public struct PreflightEvaluation: Sendable, Codable {
    /// Tool names the LLM picked, in the canonical order resolved by
    /// `PreflightCapabilitySearch`. Includes only dynamic-tool picks —
    /// always-loaded tools (capabilities_search, etc.) are not counted
    /// here because the evaluator's job is to score the picker, not
    /// the schema baseline.
    public let pickedToolNames: [String]
    /// One entry per plugin that contributed at least one pick. Mirrors
    /// the "Plugin Companions" prompt section the model would actually
    /// see, so eval cases can assert on the exact teaser shape.
    public let companions: [Companion]
    /// Wall-clock duration of `PreflightCapabilitySearch.search`. Used
    /// for trend tracking; not part of pass/fail by default.
    public let latencyMs: Double

    public struct Companion: Sendable, Codable {
        public let pluginId: String
        public let pluginDisplay: String
        /// `nil` when the plugin ships no enabled skill.
        public let skillName: String?
        /// Sibling tools surfaced as `tool/<name>` lines in the teaser.
        /// Already deduped against `pickedToolNames`, ordered, and
        /// capped at `PreflightCompanions.maxSiblingTools`.
        public let siblingToolNames: [String]
    }
}

// MARK: - Evaluator

/// Public entry point for behaviour evals. Wraps the internal preflight
/// pipeline and an optional one-shot agent fixture so eval cases can
/// just supply a query string + mode and get back a stable JSON-shaped
/// result. Lives on the main actor because the underlying registry +
/// agent lookups are main-actor-isolated.
@MainActor
public enum PreflightEvaluator {

    /// Run preflight against the live `ToolRegistry` / `SkillManager` /
    /// `PluginManager` state, using whichever model `CoreModelService`
    /// currently routes to. Callers that want to swap the model around
    /// the call should mutate `ChatConfigurationStore` first (see the
    /// OsaurusEvals `ModelOverride` helper).
    ///
    /// `agentId` defaults to the active agent so cases can omit it; pass
    /// an explicit id when scoping the eval to a custom agent fixture.
    public static func evaluate(
        query: String,
        mode: PreflightSearchMode = .balanced,
        agentId: UUID? = nil
    ) async -> PreflightEvaluation {
        let resolvedAgentId = agentId ?? AgentManager.shared.activeAgent.id
        let started = Date()
        let result = await PreflightCapabilitySearch.search(
            query: query,
            mode: mode,
            agentId: resolvedAgentId
        )
        let elapsed = Date().timeIntervalSince(started) * 1000

        let companions = result.companions.map { c in
            PreflightEvaluation.Companion(
                pluginId: c.pluginId,
                pluginDisplay: c.pluginDisplay,
                skillName: c.skill?.name,
                siblingToolNames: c.siblingTools.map(\.name)
            )
        }

        return PreflightEvaluation(
            pickedToolNames: result.toolSpecs.map { $0.function.name },
            companions: companions,
            latencyMs: elapsed
        )
    }

    /// Plugin ids currently registered with the host. Exposed for the
    /// OsaurusEvals runner so it can `skip + warn` cases whose
    /// `requirePlugins` aren't installed locally instead of failing
    /// them. Includes native dylib plugins (osaurus.browser, etc.) —
    /// kept narrow on purpose; if future eval cases need MCP/sandbox
    /// fixture introspection too, extend this surface explicitly
    /// rather than exposing the full `PluginManager`.
    ///
    /// Returns an empty set if `loadInstalledPlugins()` hasn't been
    /// called yet — `PluginManager.plugins` only lists plugins LOADED
    /// in this process (via `dlopen`), not just installed on disk.
    public static func installedPluginIds() -> Set<String> {
        var ids: Set<String> = []
        for loaded in PluginManager.shared.plugins {
            ids.insert(loaded.plugin.id)
        }
        return ids
    }

    /// Scan the tools directory and load every installed plugin (native
    /// dylib + sandbox plugin) into the in-process `PluginManager` /
    /// `ToolRegistry` / `SkillManager`. The host app does this in
    /// `AppDelegate.applicationDidFinishLaunching`; the eval CLI is its
    /// own process and has to invoke it explicitly before preflight can
    /// see plugin tools or before `installedPluginIds()` returns
    /// anything. Idempotent — `PluginManager.loadAll` serializes
    /// concurrent invocations and re-uses already-loaded dylibs.
    public static func loadInstalledPlugins() async {
        await PluginManager.shared.loadAll()
    }
}
