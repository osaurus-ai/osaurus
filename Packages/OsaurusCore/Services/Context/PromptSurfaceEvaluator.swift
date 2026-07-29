//
//  PromptSurfaceEvaluator.swift
//  osaurus
//
//  Public facade for the OsaurusEvals `prompt_surface` domain: a
//  DETERMINISTIC census of the composed prompt/tool surface with NO
//  model call. It runs the same preview compose the welcome-screen
//  budget popover uses (which itself shares every gate with the real
//  send path), optionally under an eval-scoped
//  `PromptComposerExperiment`, and returns the full attribution — so a
//  feature toggle or ablation profile can be priced (tokens by section,
//  tokens by tool schema, compact vs full, static-prefix hash) in
//  milliseconds instead of a model run.
//

import Foundation

/// One deterministic compose census: WHAT the prompt surface was and
/// what it cost, for a given agent + mode + model (+ experiment).
public struct PromptSurfaceCensus: Sendable {
    /// Per-contributor token breakdown (sections, per-tool schema cost).
    public let attribution: ContextAttribution
    /// Section ids that survived composition, in render order.
    public let sectionIds: [String]
    /// Tool names in the outbound request schema, canonical order.
    public let toolNames: [String]
    /// Whether the (possibly experiment-overridden) resolution selected
    /// the compact prompt variant for this model.
    public let prefersCompactPrompt: Bool
    /// FNV-1a hash of the full rendered system prompt — the byte-level
    /// comparability key across profile runs (two censuses with equal
    /// hashes composed EXACTLY the same prompt).
    public let promptHash: String
    /// `ComposedContext.cacheHint` — static prefix + canonical tool
    /// payload hash (the KV-prefix stability evidence).
    public let staticPrefixHash: String

    public var systemPromptTokens: Int { attribution.systemPromptTokens }
    public var toolSchemaTokens: Int { attribution.toolSchemaTokens }
    /// The first-step surface estimate: system prompt + tool schema.
    /// (No history/memory — the census is query-independent.)
    public var surfaceTokens: Int {
        attribution.systemPromptTokens + attribution.toolSchemaTokens
    }
}

public enum PromptSurfaceEvaluator {

    /// Compose the preview surface for `agentId` (nil → an ephemeral
    /// non-default agent id, matching `AgentLoopEvaluator`'s resolution
    /// so the census prices a regular chat agent, not the configure
    /// agent) in host-folder mode against `workspace`, and return the
    /// census.
    ///
    /// `experiment` is applied through `PromptComposerExperimentScope`
    /// for the duration of the compose ONLY — the previous scope value
    /// is restored on exit, so census calls never leak state into a
    /// surrounding optimizer run.
    @MainActor
    public static func census(
        workspace: URL,
        agentId: UUID? = nil,
        model: String? = nil,
        experiment: PromptComposerExperiment? = nil
    ) async -> PromptSurfaceCensus {
        let activeId = AgentManager.shared.activeAgent.id
        let resolvedAgentId = agentId ?? (activeId == Agent.defaultId ? UUID() : activeId)
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"

        let folderContext = await FolderContextService.shared.buildContext(from: workspace)
        FolderToolManager.shared.ensureFolderToolsRegistered()

        let previousScope = PromptComposerExperimentScope.current
        PromptComposerExperimentScope.current = experiment
        defer { PromptComposerExperimentScope.current = previousScope }

        let composed = SystemPromptComposer.composePreviewContext(
            agentId: resolvedAgentId,
            executionMode: .hostFolder(folderContext),
            model: resolvedModel
        )
        let window = ContextSizeResolver.resolve(modelId: resolvedModel)

        return PromptSurfaceCensus(
            attribution: ContextAttribution.build(
                manifest: composed.manifest,
                tools: composed.tools,
                memorySection: composed.memorySection,
                staticPrefixHash: composed.cacheHint
            ),
            sectionIds: composed.manifest.sections.map(\.id),
            toolNames: composed.tools.map(\.function.name),
            prefersCompactPrompt: window.prefersCompactPrompt,
            promptHash: fnv1a(composed.prompt),
            staticPrefixHash: composed.cacheHint
        )
    }

    /// Deterministic, dependency-free content hash (same algorithm as
    /// the eval catalog hash) — 16 hex chars.
    static func fnv1a(_ content: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
