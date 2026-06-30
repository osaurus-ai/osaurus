//
//  SubagentCapabilityRegistryTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  The standing guard against the BUG E surface split: the native
//  `SystemPromptComposer.resolveTools` strip and the HTTP
//  `enrichWithAgentContext` inject now both read `SubagentToolVisibility`, so
//  they can never drift on which subagent tools an agent sees. These tests
//  pin the shared resolver + the per-agent gate semantics, and assert the
//  registry SSOT and `ToolRegistry`'s internal gating set stay in lockstep.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Subagent capability registry + visibility")
struct SubagentCapabilityRegistryTests {

    @Test("the delegation tool-name set is the union of the delegation family")
    func delegationToolNames() {
        let names = SubagentToolVisibility.delegationToolNames
        // The spawn family is two sibling tools now.
        #expect(names.contains("spawn_agent"))
        #expect(names.contains("spawn_model"))
        // The two image tools merged into one `image` tool.
        #expect(names.contains("image"))
        #expect(!names.contains("image_generate"))
        #expect(!names.contains("image_edit"))
        // `local_delegate` / the old single `spawn` tool are gone.
        #expect(!names.contains("local_delegate"))
        #expect(!names.contains("spawn"))
    }

    /// Minimal snapshot for the visibility resolver — only the per-agent
    /// subagent fields matter here; everything else is inert.
    private func snapshot(
        agentId: UUID,
        spawn: Bool = false,
        image: Bool = false,
        targets: [String] = [],
        models: [String] = []
    ) -> AgentConfigSnapshot {
        AgentConfigSnapshot(
            agentId: agentId,
            toolsDisabled: false,
            memoryDisabled: true,
            autonomousConfig: nil,
            toolMode: .auto,
            model: nil,
            manualToolNames: nil,
            systemPrompt: "",
            dbEnabled: false,
            spawnDelegationEnabled: spawn,
            imageEnabled: image,
            spawnableAgentNames: targets,
            spawnableModelNames: models
        )
    }

    @Test("the Default agent uses its own pools/image; a custom agent its own per-agent toggles + lists")
    func delegationVisibilitySemantics() {
        let custom = UUID()
        // There is no master switch: the Default / main chat's own AGENT pool has
        // one agent, its MODEL pool has one model, and its image switch is on.
        let config = SubagentConfiguration(
            spawnableAgentNames: ["Helper"],
            imageDelegationEnabled: true,
            spawnableModelNames: ["pool-model"]
        )

        // Default agent: governed by its own pools + image switch (its own
        // snapshot flags are irrelevant). Both spawn tools surface (each pool is
        // non-empty), plus image.
        #expect(
            SubagentToolVisibility.visibleDelegationToolNames(
                agentId: Agent.defaultId,
                snapshot: snapshot(agentId: Agent.defaultId),
                config: config,
                hasReadyImageModel: true
            ) == ["spawn_agent", "spawn_model", "image"]
        )

        // Custom agent: each spawn tool needs its own toggle AND a non-empty pool
        // of its own kind; image needs its own toggle. Here spawn on with an AGENT
        // target only → just spawn_agent.
        #expect(
            SubagentToolVisibility.visibleDelegationToolNames(
                agentId: custom,
                snapshot: snapshot(agentId: custom, spawn: true, image: false, targets: ["X"]),
                config: config,
                hasReadyImageModel: true
            ) == ["spawn_agent"]
        )

        // Custom agent with a MODEL pool only → just spawn_model.
        #expect(
            SubagentToolVisibility.visibleDelegationToolNames(
                agentId: custom,
                snapshot: snapshot(agentId: custom, spawn: true, models: ["m"]),
                config: config,
                hasReadyImageModel: true
            ) == ["spawn_model"]
        )

        // Custom agent with both pools → both spawn tools.
        #expect(
            SubagentToolVisibility.visibleDelegationToolNames(
                agentId: custom,
                snapshot: snapshot(agentId: custom, spawn: true, targets: ["X"], models: ["m"]),
                config: config,
                hasReadyImageModel: true
            ) == ["spawn_agent", "spawn_model"]
        )

        // Custom agent with spawn on but BOTH pools empty → spawn hidden.
        #expect(
            SubagentToolVisibility.visibleDelegationToolNames(
                agentId: custom,
                snapshot: snapshot(agentId: custom, spawn: true, targets: []),
                config: config,
                hasReadyImageModel: true
            ).isEmpty
        )

        // A custom agent that has opted into nothing → nothing visible, even
        // when the main chat's own pools/image are populated.
        #expect(
            SubagentToolVisibility.visibleDelegationToolNames(
                agentId: custom,
                snapshot: snapshot(agentId: custom, spawn: false, image: false, targets: []),
                config: config,
                hasReadyImageModel: true
            ).isEmpty
        )
    }

    @Test("image is withheld when no ready image model is installed, even with the switch on")
    func imageGatedOnInstalledModel() {
        // The Default / main chat has its image switch on and a spawn pool, but
        // NO ready on-device image model exists. The installed-capability gate
        // must withhold `image` so the model is never offered an image
        // capability the runtime can't satisfy; spawn is unaffected.
        let config = SubagentConfiguration(
            spawnableAgentNames: ["Helper"],
            imageDelegationEnabled: true,
            spawnableModelNames: ["pool-model"]
        )
        #expect(
            SubagentToolVisibility.visibleDelegationToolNames(
                agentId: Agent.defaultId,
                snapshot: snapshot(agentId: Agent.defaultId),
                config: config,
                hasReadyImageModel: false
            ) == ["spawn_agent", "spawn_model"]
        )
        // A custom agent with its image toggle on but no installed model → no
        // `image` either.
        let custom = UUID()
        #expect(
            !SubagentToolVisibility.visibleDelegationToolNames(
                agentId: custom,
                snapshot: snapshot(agentId: custom, image: true),
                config: config,
                hasReadyImageModel: false
            ).contains("image")
        )
    }

    @Test("spawn target validation: Default uses its own pool; custom uses its own allow-list")
    func spawnTargetValidation() {
        let config = SubagentConfiguration(
            spawnableAgentNames: ["Helper"]
        )
        // Default: the global pool decides (case-insensitive).
        #expect(
            SubagentToolVisibility.spawnTargetAllowed(
                "helper",
                isDefault: true,
                config: config,
                perAgentTargets: []
            )
        )
        #expect(
            !SubagentToolVisibility.spawnTargetAllowed(
                "Other",
                isDefault: true,
                config: config,
                perAgentTargets: ["Other"]
            )
        )
        // Custom: only the agent's OWN list counts, not the global pool.
        #expect(
            SubagentToolVisibility.spawnTargetAllowed(
                "Coder",
                isDefault: false,
                config: config,
                perAgentTargets: ["Coder"]
            )
        )
        #expect(
            !SubagentToolVisibility.spawnTargetAllowed(
                "Helper",
                isDefault: false,
                config: config,
                perAgentTargets: ["Coder"]
            )
        )
    }

    @Test("spawn model validation: Default uses its own model pool; custom uses its own allow-list")
    func spawnModelTargetValidation() {
        let config = SubagentConfiguration(
            spawnableModelNames: ["pool-model"]
        )
        // Default: the global model pool decides (exact, trimmed match).
        #expect(
            SubagentToolVisibility.spawnModelAllowed(
                "  pool-model  ",
                isDefault: true,
                config: config,
                perAgentModelTargets: []
            )
        )
        #expect(
            !SubagentToolVisibility.spawnModelAllowed(
                "other-model",
                isDefault: true,
                config: config,
                perAgentModelTargets: ["other-model"]
            )
        )
        // Custom: only the agent's OWN model list counts, not the global pool.
        #expect(
            SubagentToolVisibility.spawnModelAllowed(
                "agent-model",
                isDefault: false,
                config: config,
                perAgentModelTargets: ["agent-model"]
            )
        )
        #expect(
            !SubagentToolVisibility.spawnModelAllowed(
                "pool-model",
                isDefault: false,
                config: config,
                perAgentModelTargets: ["agent-model"]
            )
        )
        // Empty id never matches.
        #expect(
            !SubagentToolVisibility.spawnModelAllowed(
                "   ",
                isDefault: true,
                config: config,
                perAgentModelTargets: []
            )
        )
    }

    @Test("capability descriptors expose the right primary tool + guidance shape")
    func capabilityShape() {
        #expect(SubagentCapabilityRegistry.computerUse.primaryToolName == "computer_use")
        #expect(SubagentCapabilityRegistry.computerUse.guidance != nil)
        // Image generation + editing now share the single `image` tool.
        #expect(SubagentCapabilityRegistry.image.primaryToolName == "image")
        #expect(SubagentCapabilityRegistry.image.guidance != nil)
        // The spawn family lists both sibling tools; `spawn_agent` is primary.
        #expect(SubagentCapabilityRegistry.spawn.toolNames == ["spawn_agent", "spawn_model"])
        #expect(SubagentCapabilityRegistry.spawn.primaryToolName == "spawn_agent")
        // Spawn has no inline capability guidance — its prompt block is rendered
        // by a dedicated dynamic `.static` section in the composer instead.
        #expect(SubagentCapabilityRegistry.spawn.guidance == nil)
    }

    @Test("the registry represents every shipped kind")
    func allRepresentsEveryKind() {
        let ids = Set(SubagentCapabilityRegistry.all.map(\.id))
        #expect(ids == ["computer_use", "spawn", "image", "applescript"])
    }

    @Test("the modelSource axis records how each kind resolves its model")
    func modelSourceAxis() {
        // The image coordinator owns a dedicated, separately-configured model.
        #expect(SubagentCapabilityRegistry.image.modelSource == .dedicatedConfigured)
        // spawn runs the chosen agent's own model (local or remote).
        #expect(SubagentCapabilityRegistry.spawn.modelSource == .agent)
        // computer_use reuses the parent agent's model.
        #expect(SubagentCapabilityRegistry.computerUse.modelSource == .inheritsParent)
    }

    @Test("supportsModelOverride is true for the chat-driven kinds and false for image")
    func supportsModelOverrideFlag() {
        // The chat-driven kinds share the standard per-agent model picker
        // (`subagentModelOverrides` → `effectiveSubagentModel` →
        // `SubagentModelResolution`).
        #expect(SubagentCapabilityRegistry.computerUse.supportsModelOverride)
        #expect(SubagentCapabilityRegistry.spawn.supportsModelOverride)
        // image owns its own dedicated gen/edit model system → no shared row.
        #expect(!SubagentCapabilityRegistry.image.supportsModelOverride)
    }

    @Test("capability(forPerAgentFlag:) maps each toggle flag to its descriptor")
    func capabilityForPerAgentFlag() {
        #expect(
            SubagentCapabilityRegistry.capability(forPerAgentFlag: .computerUse)?.id
                == "computer_use"
        )
        #expect(SubagentCapabilityRegistry.capability(forPerAgentFlag: .spawn)?.id == "spawn")
        #expect(SubagentCapabilityRegistry.capability(forPerAgentFlag: .image)?.id == "image")
        #expect(
            SubagentCapabilityRegistry.capability(forPerAgentFlag: .appleScript)?.id == "applescript"
        )
    }

    @Test("every descriptor carries a display label + icon for the feed and chip")
    func displayAndIconArePopulated() {
        for capability in SubagentCapabilityRegistry.all {
            #expect(!capability.displayLabel.isEmpty, "\(capability.id) missing displayLabel")
            #expect(!capability.iconName.isEmpty, "\(capability.id) missing iconName")
        }
    }

    @Test("per-agent toggle flags are computer_use, spawn, image, applescript (each independent)")
    func perAgentToggleFlagsAreDistinct() {
        // One card per *flag*: computer_use, spawn, image, and applescript are
        // each their own per-agent toggle (image split out of the old shared
        // spawn flag; applescript is its own kind), so the Subagents tab renders
        // exactly four cards in registry order.
        #expect(
            SubagentCapabilityRegistry.perAgentToggleFlags
                == [.computerUse, .spawn, .image, .appleScript]
        )
    }

    /// Drift guard: the registry SSOT (consumed by both visibility surfaces)
    /// must match `ToolRegistry`'s internal delegation gating sets, so the
    /// schema strip and the registry-driven visibility never disagree. Every
    /// `ToolRegistry` delegation set is now DERIVED from the registry, so these
    /// equalities also prove there is no hand-maintained mirror to drift.
    @MainActor
    @Test("the registry SSOT matches ToolRegistry's derived delegation sets")
    func ssotMatchesToolRegistry() {
        #expect(SubagentToolVisibility.delegationToolNames == ToolRegistry.agentDelegationAllToolNames)
        #expect(ToolRegistry.agentDelegationSpawnToolNames == Set(SubagentCapabilityRegistry.spawn.toolNames))
        #expect(ToolRegistry.agentDelegationImageToolNames == Set(SubagentCapabilityRegistry.image.toolNames))
        #expect(
            ToolRegistry.agentDelegationAppleScriptToolNames
                == Set(SubagentCapabilityRegistry.appleScript.toolNames)
        )
        // The "all" set is exactly the union of the per-family sets.
        #expect(
            ToolRegistry.agentDelegationAllToolNames
                == ToolRegistry.agentDelegationSpawnToolNames
                .union(ToolRegistry.agentDelegationImageToolNames)
                .union(ToolRegistry.agentDelegationAppleScriptToolNames)
        )
    }

    // MARK: - Per-agent effective settings

    @Test("effectiveImageModel: Default uses the global model; a custom agent its own; nil falls through")
    func effectiveImageModelResolves() {
        let config = SubagentConfiguration(
            defaultImageGenerationModelId: "global-gen",
            defaultImageEditModelId: "global-edit"
        )
        var custom = AgentSettings.defaultDisabled
        custom.imageGenerationModelId = "agent-gen"
        custom.imageEditModelId = "agent-edit"

        // Default / main chat → global config.
        #expect(
            SubagentToolVisibility.effectiveImageModel(
                isEdit: false,
                isDefault: true,
                config: config,
                settings: custom
            ) == "global-gen"
        )
        #expect(
            SubagentToolVisibility.effectiveImageModel(
                isEdit: true,
                isDefault: true,
                config: config,
                settings: custom
            ) == "global-edit"
        )
        // Custom agent → its own per-agent model.
        #expect(
            SubagentToolVisibility.effectiveImageModel(
                isEdit: false,
                isDefault: false,
                config: config,
                settings: custom
            ) == "agent-gen"
        )
        #expect(
            SubagentToolVisibility.effectiveImageModel(
                isEdit: true,
                isDefault: false,
                config: config,
                settings: custom
            ) == "agent-edit"
        )
        // Custom agent that enabled image without picking a model → nil, which
        // the downstream resolver turns into the first ready model. nil settings
        // (agent unknown to AgentManager) likewise.
        #expect(
            SubagentToolVisibility.effectiveImageModel(
                isEdit: false,
                isDefault: false,
                config: config,
                settings: AgentSettings.defaultDisabled
            ) == nil
        )
        #expect(
            SubagentToolVisibility.effectiveImageModel(
                isEdit: false,
                isDefault: false,
                config: config,
                settings: nil
            ) == nil
        )
    }

    @Test("effectivePermission: Default uses the global map; a custom agent its own; missing → .ask")
    func effectivePermissionResolves() {
        var globalPerms = SubagentPermissionDefaults()
        globalPerms.setPolicy(.deny, for: SubagentCapabilityRegistry.image.id)
        let config = SubagentConfiguration(permissionDefaults: globalPerms)

        var custom = AgentSettings.defaultDisabled
        var customPerms = SubagentPermissionDefaults()
        customPerms.setPolicy(.alwaysAllow, for: SubagentCapabilityRegistry.spawn.id)
        custom.subagentPermissions = customPerms

        // Default / main chat → global map.
        #expect(
            SubagentToolVisibility.effectivePermission(
                capabilityId: SubagentCapabilityRegistry.image.id,
                isDefault: true,
                config: config,
                settings: custom
            ) == .deny
        )
        // Custom agent → its own map.
        #expect(
            SubagentToolVisibility.effectivePermission(
                capabilityId: SubagentCapabilityRegistry.spawn.id,
                isDefault: false,
                config: config,
                settings: custom
            ) == .alwaysAllow
        )
        // A kind absent from the custom map → the safe `.ask` default (the global
        // deny does NOT leak into a custom agent).
        #expect(
            SubagentToolVisibility.effectivePermission(
                capabilityId: SubagentCapabilityRegistry.image.id,
                isDefault: false,
                config: config,
                settings: custom
            ) == .ask
        )
        // nil settings (custom agent unknown to AgentManager) → `.ask`.
        #expect(
            SubagentToolVisibility.effectivePermission(
                capabilityId: SubagentCapabilityRegistry.spawn.id,
                isDefault: false,
                config: config,
                settings: nil
            ) == .ask
        )
    }

    @Test("effectiveBudgets: Default uses the global budgets; a custom agent its own; both normalized")
    func effectiveBudgetsResolves() {
        let config = SubagentConfiguration(
            budgets: SubagentBudgets(
                maxDelegateTokens: 4096,
                maxDelegateTurns: 3,
                maxElapsedSeconds: 240
            )
        )
        var custom = AgentSettings.defaultDisabled
        custom.subagentBudgets = SubagentBudgets(
            maxDelegateTokens: 1024,
            maxDelegateTurns: 2,
            maxElapsedSeconds: 60
        )

        // Default / main chat → global budgets.
        let def = SubagentToolVisibility.effectiveBudgets(
            isDefault: true,
            config: config,
            settings: custom
        )
        #expect(def.maxDelegateTokens == 4096)
        #expect(def.maxDelegateTurns == 3)
        #expect(def.maxElapsedSeconds == 240)

        // Custom agent → its own budgets.
        let cus = SubagentToolVisibility.effectiveBudgets(
            isDefault: false,
            config: config,
            settings: custom
        )
        #expect(cus.maxDelegateTokens == 1024)
        #expect(cus.maxDelegateTurns == 2)
        #expect(cus.maxElapsedSeconds == 60)

        // nil settings (custom) → normalized defaults.
        #expect(
            SubagentToolVisibility.effectiveBudgets(
                isDefault: false,
                config: config,
                settings: nil
            ) == SubagentBudgets().normalized
        )
    }

    // MARK: - BUG E parity guard

    private static func packageRoot() -> URL {
        // .../Tests/Subagent/<thisFile> → OsaurusCore/
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Subagent/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusCore/
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The original BUG E was a *surface split*: the native composer strip and
    /// the HTTP enrich path each decided subagent tool visibility from their
    /// own hardcoded `["image_generate","image_edit","local_delegate","spawn"]`
    /// list, so they could disagree on what an agent sees. Both must now resolve
    /// from the single `SubagentToolVisibility` SSOT and never re-introduce a
    /// hardcoded delegation list. This is a source-level standing guard (mirrors
    /// `RuntimePolicySourceTests`) so a future edit to either surface that
    /// re-hardcodes the set fails CI instead of silently re-splitting them.
    @Test("native + HTTP tool-visibility surfaces both read the shared SSOT, never a hardcoded list")
    func surfacesShareTheResolver() throws {
        let composer = try Self.source("Services/Chat/SystemPromptComposer.swift")
        let http = try Self.source("Networking/HTTPHandler.swift")

        // Both entry points resolve per-agent visibility through the shared SSOT…
        #expect(composer.contains("SubagentToolVisibility.visibleDelegationToolNames"))
        #expect(http.contains("SubagentToolVisibility.visibleDelegationToolNames"))

        // …and neither re-introduces the BUG E hardcoded delegation list.
        for legacy in ["\"local_delegate\"", "\"image_generate\"", "\"image_edit\""] {
            #expect(!composer.contains(legacy))
            #expect(!http.contains(legacy))
        }
    }

    /// SSOT guard (the add-a-kind invariant): `ToolRegistry`'s delegation
    /// tool-name sets must be DERIVED from the capability registry, never a
    /// hand-maintained literal. A future edit that re-hardcodes the spawn/image
    /// set here fails CI instead of silently re-forking the SSOT.
    @Test("ToolRegistry derives its delegation sets from the registry, not a hardcoded list")
    func toolRegistryDerivesFromRegistry() throws {
        let registry = try Self.source("Tools/ToolRegistry.swift")

        // The delegation accessors read the registry…
        #expect(registry.contains("SubagentCapabilityRegistry.spawn.toolNames"))
        #expect(registry.contains("SubagentCapabilityRegistry.image.toolNames"))
        // …and the master-gate exclusion set is the shared SSOT union, not a
        // hand-maintained literal.
        #expect(registry.contains("SubagentToolVisibility.delegationToolNames"))

        // No re-hardcoded combined delegation literal (the mirror we removed),
        // and no legacy tool names.
        for hardcoded in [
            "[\"spawn\", \"image\"]", "[\"image\", \"spawn\"]",
            "\"local_delegate\"", "\"image_generate\"", "\"image_edit\"",
        ] {
            #expect(!registry.contains(hardcoded), "ToolRegistry must not hardcode \(hardcoded)")
        }
    }
}
