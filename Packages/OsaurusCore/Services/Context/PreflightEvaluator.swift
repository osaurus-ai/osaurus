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
    /// Raw text the LLM returned for the tool-selection prompt. `nil`
    /// when the LLM threw or preflight short-circuited (empty query /
    /// mode .off / empty catalog). Critical for prompt-iteration evals
    /// — when a small model picks nothing, this is the only signal that
    /// tells you WHY (NONE, malformed picks, prose, refusal, etc.).
    public let rawLLMResponse: String?
    /// The exact system prompt sent to the LLM (post-template,
    /// post-catalog-rendering). Lets eval reports show "what the model
    /// saw" alongside "what the model said" without re-deriving the
    /// catalog client-side.
    public let rawLLMSystemPrompt: String?
    /// Picks the parser extracted, BEFORE the embedding guardrail
    /// dropped any. `pickedToolNames` is `llmPicks` minus the picks the
    /// guardrail rejected. Lets evals tell apart "model picked nothing"
    /// from "model picked but guardrail rejected everything".
    public let llmPicks: [String]
    /// Number of dynamic plugin tools the LLM saw in its catalog.
    /// Zero is the smoking gun for a config-dir mismatch between the
    /// eval-CLI process and the host app — the LLM call gets skipped
    /// entirely and `pickedToolNames` is forced empty.
    public let catalogSize: Int
    /// Description of the error the LLM bridge threw, if any. Lets
    /// evals distinguish "model said NONE" from "bridge timed out /
    /// circuit-breaker open / network failed".
    public let llmError: String?

    public struct Companion: Sendable, Codable {
        public let pluginId: String
        public let pluginDisplay: String
        /// `nil` when the plugin ships no enabled skill.
        public let skillName: String?
        /// Sibling tools surfaced as `tool/<name>` lines in the teaser.
        /// Already deduped against `pickedToolNames`, ordered, and
        /// capped at `PreflightCompanions.maxSiblingTools`.
        public let siblingToolNames: [String]

        /// Internal-to-public converter so `PreflightEvaluator.evaluate`
        /// can map a `PluginCompanion` straight to an eval-shaped row.
        init(_ source: PluginCompanion) {
            self.pluginId = source.pluginId
            self.pluginDisplay = source.pluginDisplay
            self.skillName = source.skill?.name
            self.siblingToolNames = source.siblingTools.map(\.name)
        }
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
        let (result, diagnostic) = await PreflightCapabilitySearch.searchWithDiagnostic(
            query: query,
            mode: mode,
            agentId: resolvedAgentId
        )
        let elapsed = Date().timeIntervalSince(started) * 1000

        return PreflightEvaluation(
            pickedToolNames: result.toolSpecs.map { $0.function.name },
            companions: result.companions.map(PreflightEvaluation.Companion.init(_:)),
            latencyMs: elapsed,
            rawLLMResponse: diagnostic?.rawResponse,
            rawLLMSystemPrompt: diagnostic?.systemPrompt,
            llmPicks: diagnostic?.llmPicks ?? [],
            catalogSize: diagnostic?.catalogSize ?? 0,
            llmError: diagnostic?.llmError
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

    /// Boot every subsystem the chat path's preflight depends on so an
    /// out-of-process eval CLI gets the same view the host app does.
    /// Mirrors the relevant slice of
    /// `AppDelegate.applicationDidFinishLaunching`:
    ///
    /// 1. Scan + dlopen every installed plugin into `PluginManager` /
    ///    `ToolRegistry` / `SkillManager` so plugin tools become
    ///    visible to `listDynamicTools()` and `installedPluginIds()`.
    /// 2. Open the on-disk tool index database and initialise
    ///    `ToolSearchService` so the embedding-rerank step in
    ///    `PreflightCapabilitySearch.rankCatalog` actually has an
    ///    index to query (without this, rerank degrades to the full
    ///    catalog and small models with tight context windows like
    ///    Apple Foundation reject the request before the LLM runs).
    /// 3. Sync the tool index from the live registry so freshly
    ///    registered plugin tools are present in the vector store.
    ///
    /// Idempotent — every step serializes concurrent invocations and
    /// re-uses already-initialised state.
    public static func loadInstalledPlugins() async {
        await PluginManager.shared.loadAll()
        // `ToolDatabase.shared.open()` itself routes through the
        // shared synchronous storage-migration gate (the same one
        // every `*Database.open()` defensively hits), so we don't
        // need an extra `await` here.
        try? ToolDatabase.shared.open()
        await ToolSearchService.shared.initialize()
        await ToolIndexService.shared.syncFromRegistry()
    }
}
