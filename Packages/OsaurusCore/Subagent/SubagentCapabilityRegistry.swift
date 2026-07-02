//
//  SubagentCapabilityRegistry.swift
//  OsaurusCore — Subagent framework
//
//  One per-agent capability registry for the nested subagent family. Each
//  capability declares its gate, the tool name(s) it gates, and the
//  system-prompt guidance to inject when the capability is live. Both the
//  native `SystemPromptComposer` and the HTTP `enrichWithAgentContext` path
//  consume `SubagentToolVisibility` so the two surfaces can never drift on
//  which subagent tools an agent sees (the standing BUG E regression guard).
//
//  Replaces the parallel hand-written `computerUseEnabled` / `spawnDelegationEnabled`
//  gate blocks + guidance sections in the composer and the hardcoded
//  `["image_generate","image_edit","local_delegate","spawn"]` list in the HTTP
//  path.
//

import Foundation

/// The single per-kind descriptor (SSOT) for one nested subagent capability.
///
/// Every subagent surface reads this one value: the `resolveTools` strip + the
/// `ToolRegistry` family gate (`gate`), the AgentsView per-agent toggle
/// (`perAgentFlag`), the live-feed header + tool chip (`displayLabel` /
/// `iconName`), and the system-prompt guidance loop (`guidance*`). It is also
/// the value each `SubagentKind` advertises as its `capability`, so the kind and
/// the registry entry are literally one object — adding a kind is "add one
/// descriptor + its kind + its thin tool".
public struct SubagentCapability: Sendable {
    /// How a kind sources the model it runs — the local-vs-remote axis a future
    /// dedicated model-backed kind (e.g. an AppleScript generator) slots into.
    /// Documents whether a kind needs its own default-model picker + residency
    /// handoff (`dedicatedConfigured` / `agent`) or simply reuses the parent
    /// agent's model (`inheritsParent`).
    public enum ModelSource: Sendable, Equatable {
        /// A dedicated, separately-configured model (image: gen / edit defaults;
        /// coordinator owns residency).
        case dedicatedConfigured
        /// The chosen agent's own model (spawn) — local or remote; the kind runs
        /// the residency handoff when it clashes with a resident chat model.
        case agent
        /// The parent agent's own model (computer_use) — no
        /// residency change.
        case inheritsParent
    }

    /// The per-agent on/off field a capability binds to (the `AgentSettings` /
    /// `AgentConfigSnapshot` flag). Concentrates the "which flag" mapping in one
    /// place so the `resolveTools` strip and the AgentsView editor both read /
    /// write through the descriptor instead of hardcoding field names.
    public enum PerAgentFlag: Sendable, Hashable {
        case computerUse
        case spawn
        case image
        case appleScript

        /// The resolved per-agent flag for the `resolveTools` strip.
        public func enabled(in snapshot: AgentConfigSnapshot) -> Bool {
            switch self {
            case .computerUse: return snapshot.computerUseEnabled
            case .spawn: return snapshot.spawnDelegationEnabled
            case .image: return snapshot.imageEnabled
            case .appleScript: return snapshot.appleScriptEnabled
            }
        }

        /// The stored per-agent flag, for hydrating the AgentsView editor.
        public func read(from settings: AgentSettings) -> Bool {
            switch self {
            case .computerUse: return settings.computerUseEnabled
            case .spawn: return settings.spawnDelegationEnabled
            case .image: return settings.imageEnabled
            case .appleScript: return settings.appleScriptEnabled
            }
        }

        /// Write the per-agent flag back when saving the AgentsView editor.
        public func write(_ value: Bool, into settings: inout AgentSettings) {
            switch self {
            case .computerUse: settings.computerUseEnabled = value
            case .spawn: settings.spawnDelegationEnabled = value
            case .image: settings.imageEnabled = value
            case .appleScript: settings.appleScriptEnabled = value
            }
        }
    }

    /// How this capability is gated.
    public enum Gate: Sendable {
        /// Authoritative per-agent flag, stripped in BOTH auto + manual mode
        /// (computer_use). The Default agent never enables it.
        case perAgent
        /// The spawn / image delegation family. There is no global master
        /// switch — visibility is resolved per agent by `SubagentToolVisibility`
        /// (Default / main chat → its own pool / image switch; custom → its own
        /// per-agent toggle + allow-list). The base schema always carries the
        /// family (superset); the per-agent narrowing happens where the agent
        /// context is known. Off-by-default holds because every agent ships with
        /// the capability disabled until opted in from its Subagents tab.
        case delegation
        /// Sandbox-scoped: gated by sandbox registration + execution mode, NOT
        /// stripped in `resolveTools` and not surfaced as a per-agent /
        /// delegation toggle.
        case sandboxExec
    }

    /// Stable id (`"computer_use"`, `"spawn"`, `"image"`).
    public let id: String
    /// Tool names this capability gates. `toolNames.first` is the primary tool
    /// whose presence in the resolved schema triggers the guidance section.
    public let toolNames: [String]
    public let gate: Gate
    /// The per-agent flag this capability's toggle binds to. `nil` for
    /// `sandboxExec` capabilities (no per-agent toggle).
    public let perAgentFlag: PerAgentFlag?
    /// How this kind gets its model (drives docs + the future model-pick axis).
    public let modelSource: ModelSource
    /// Whether this kind exposes the standard per-agent model-override picker
    /// (`subagentModelOverrides` → `effectiveSubagentModel` → the shared
    /// `SubagentModelResolution` layer). True for the chat-driven kinds
    /// (computer_use, spawn). False for `image`, which owns its
    /// own dedicated gen/edit model system (`effectiveImageModel`) and renders
    /// its own pickers — see the `image` registration below. AgentsView renders
    /// the override row for any capability with this set, so a new chat-driven
    /// kind gets a picker by only flipping this flag.
    public let supportsModelOverride: Bool
    /// Human label for the live-feed header + collapsed tool chip.
    public let displayLabel: String
    /// SF Symbol for the live feed + tool chip.
    public let iconName: String
    /// System-prompt guidance injected when the primary tool resolves.
    public let guidance: String?
    /// Compact guidance variant for small local models (`prefersCompactPrompt`).
    /// When nil the full `guidance` is used regardless of model size.
    public let guidanceCompact: String?
    /// Stable composer section id (KV-cache identity) for the guidance block.
    public let guidanceSectionId: String?
    /// Localization key for the guidance section label.
    public let guidanceLabelKey: String?

    public var primaryToolName: String { toolNames.first ?? id }

    public init(
        id: String,
        toolNames: [String],
        gate: Gate,
        perAgentFlag: PerAgentFlag? = nil,
        modelSource: ModelSource = .inheritsParent,
        supportsModelOverride: Bool = false,
        displayLabel: String? = nil,
        iconName: String = "sparkles",
        guidance: String? = nil,
        guidanceCompact: String? = nil,
        guidanceSectionId: String? = nil,
        guidanceLabelKey: String? = nil
    ) {
        self.id = id
        self.toolNames = toolNames
        self.gate = gate
        self.perAgentFlag = perAgentFlag
        self.modelSource = modelSource
        self.supportsModelOverride = supportsModelOverride
        self.displayLabel = displayLabel ?? id
        self.iconName = iconName
        self.guidance = guidance
        self.guidanceCompact = guidanceCompact
        self.guidanceSectionId = guidanceSectionId
        self.guidanceLabelKey = guidanceLabelKey
    }
}

/// The registry of subagent capabilities, in a stable order (so the guidance
/// sections render in a KV-cache-stable sequence). Each `SubagentKind` exposes
/// its matching entry here as its `capability`, so this is the one place a
/// surface needs to read to gate, render, or describe any subagent.
public enum SubagentCapabilityRegistry {
    public static let computerUse = SubagentCapability(
        id: "computer_use",
        toolNames: [ComputerUseTool.toolName],
        gate: .perAgent,
        perAgentFlag: .computerUse,
        modelSource: .inheritsParent,
        supportsModelOverride: true,
        displayLabel: "Computer Use",
        iconName: "cursorarrow.rays",
        guidance: SystemPromptTemplates.computerUseGuidance,
        guidanceSectionId: "computerUse",
        guidanceLabelKey: "Computer Use"
    )

    /// Stable tool name for the agent-context spawn (`spawn_agent(input,
    /// agent)`). SSOT so the tool, registry gating, and visibility resolver agree.
    public static let spawnAgentToolName = "spawn_agent"
    /// Stable tool name for the model-only spawn (`spawn_model(input, model)`).
    public static let spawnModelToolName = "spawn_model"

    /// The text-spawn family — two sibling tools, one shared capability:
    /// `spawn_agent` (delegate WITH an agent's system prompt + model) and
    /// `spawn_model` (delegate to a bare model id, no agent). Splitting into two
    /// single-required-target tools keeps each JSON contract enforceable (no
    /// "exactly one of agent/model" the schema can't express). Each is gated
    /// independently by its own pool (agents vs models). No static guidance — the
    /// composer renders one dynamic spawn block enumerating the live agents /
    /// models, so `guidance == nil` keeps the generic guidance loop off it. Names
    /// are the SSOT here; `ToolRegistry`'s derived sets read these for gating.
    public static let spawn = SubagentCapability(
        id: "spawn",
        toolNames: [spawnAgentToolName, spawnModelToolName],
        gate: .delegation,
        perAgentFlag: .spawn,
        modelSource: .agent,
        supportsModelOverride: true,
        displayLabel: "Subagent",
        iconName: "person.2.fill"
    )

    /// The image family — one `image` tool that both generates and edits
    /// (`source_paths` → edit). The guidance renders when `image` resolves.
    /// `supportsModelOverride = false` is deliberate: `image` owns its own model
    /// system (separate gen/edit defaults via `effectiveImageModel`, its own
    /// readiness + "first ready" fallback, and coordinator-owned residency), so
    /// it is NOT a `SubagentModelResolution` client and keeps its dedicated
    /// gen/edit pickers instead of the shared per-agent override row.
    public static let image = SubagentCapability(
        id: "image",
        toolNames: ["image"],
        gate: .delegation,
        perAgentFlag: .image,
        modelSource: .dedicatedConfigured,
        supportsModelOverride: false,
        displayLabel: "Image",
        iconName: "photo",
        guidance: SystemPromptTemplates.imageGenerationGuidance,
        guidanceCompact: SystemPromptTemplates.imageGenerationGuidanceCompact,
        guidanceSectionId: "imageGeneration",
        guidanceLabelKey: "Image Generation"
    )

    /// The AppleScript family — two sibling tools, one shared capability + one
    /// on-device model (the curated `AppleScriptModelCatalog`): `applescript`
    /// (state-changing automation, the user's confirm gate) and `mac_query`
    /// (read-only info retrieval, auto-run reads / block writes). `applescript`
    /// is primary, so the guidance + gating key off it; both gate together (one
    /// per-agent toggle + the installed-model check), like the spawn pair.
    /// `supportsModelOverride = false` like `image`: AppleScript owns its own
    /// model system (per-agent / global `appleScriptModelId` + first-installed
    /// fallback) and renders its own picker + execution-mode control instead of
    /// the shared override row.
    public static let appleScript = SubagentCapability(
        id: "applescript",
        toolNames: [AppleScriptTool.toolName, MacQueryTool.toolName],
        gate: .delegation,
        perAgentFlag: .appleScript,
        modelSource: .dedicatedConfigured,
        supportsModelOverride: false,
        displayLabel: "AppleScript",
        iconName: "applescript",
        guidance: SystemPromptTemplates.appleScriptGuidance,
        guidanceCompact: SystemPromptTemplates.appleScriptGuidanceCompact,
        guidanceSectionId: "appleScript",
        guidanceLabelKey: "AppleScript"
    )

    /// Every capability, in guidance-render order (computer_use, then image,
    /// then applescript; spawn renders its own dynamic guidance block in the
    /// composer).
    public static let all: [SubagentCapability] = [computerUse, spawn, image, appleScript]

    /// The delegation-gated capabilities (spawn + image + applescript).
    public static let delegationFamily: [SubagentCapability] = [spawn, image, appleScript]

    /// Distinct per-agent toggle flags, in registry order (computer_use, spawn,
    /// image, applescript). One entry per *toggle* (deduped, so a future kind
    /// that shares a flag would collapse) — the AgentsView Subagents tab renders
    /// exactly one card per flag, driven by the registry instead of hand-built
    /// groups.
    public static var perAgentToggleFlags: [SubagentCapability.PerAgentFlag] {
        var seen = Set<SubagentCapability.PerAgentFlag>()
        var ordered: [SubagentCapability.PerAgentFlag] = []
        for capability in all {
            guard let flag = capability.perAgentFlag else { continue }
            if seen.insert(flag).inserted { ordered.append(flag) }
        }
        return ordered
    }

    /// The descriptor for a kind id (`SubagentFeed.kindId` / `capability.id`).
    public static func capability(forKindId id: String) -> SubagentCapability? {
        all.first { $0.id == id }
    }

    /// The descriptor bound to a per-agent toggle flag — lets the AgentsView
    /// Subagents tab render the standard model-override row generically
    /// (`supportsModelOverride`) instead of hand-wiring it per kind.
    public static func capability(forPerAgentFlag flag: SubagentCapability.PerAgentFlag)
        -> SubagentCapability?
    {
        all.first { $0.perAgentFlag == flag }
    }

    /// The descriptor that gates a given tool name.
    public static func capability(forToolName name: String) -> SubagentCapability? {
        all.first { $0.toolNames.contains(name) }
    }

    /// Feed-header / tool-chip label for a kind id.
    public static func displayLabel(forKindId id: String) -> String? {
        capability(forKindId: id)?.displayLabel
    }

    /// Tool-chip label for a subagent tool name (`nil` for non-subagent tools).
    public static func displayLabel(forToolName name: String) -> String? {
        capability(forToolName: name)?.displayLabel
    }

    /// Tool-chip icon for a subagent tool name (`nil` for non-subagent tools).
    public static func iconName(forToolName name: String) -> String? {
        capability(forToolName: name)?.iconName
    }
}

/// Shared subagent tool-visibility resolver used by BOTH the native
/// `SystemPromptComposer.resolveTools` and the HTTP `enrichWithAgentContext`
/// path, so the two surfaces always agree on which subagent tools an agent
/// sees. This is the single point that previously diverged (BUG E).
public enum SubagentToolVisibility {
    /// SSOT for the delegation-family tool names both surfaces gate together.
    public static var delegationToolNames: Set<String> {
        var names = Set<String>()
        for cap in SubagentCapabilityRegistry.delegationFamily {
            names.formUnion(cap.toolNames)
        }
        return names
    }

    /// The agents effectively spawnable from a launching agent. Default /
    /// main chat → its own global pool; a custom agent → its own per-agent
    /// allow-list, but ONLY while its `spawn` toggle is on (off → nothing). The
    /// SSOT both the `spawn_agent` visibility gate and the guidance enumerator
    /// read, so the tool and its prompt block never list different agents.
    static func effectiveSpawnableAgents(
        isDefault: Bool,
        config: SubagentConfiguration,
        perAgentEnabled: Bool,
        perAgentTargets: [String]
    ) -> [String] {
        if isDefault { return config.spawnableAgentNames }
        return perAgentEnabled ? perAgentTargets : []
    }

    /// The bare model ids effectively spawnable from a launching agent (the
    /// `spawn_model` pool). Same Default-vs-custom shape as
    /// `effectiveSpawnableAgents`; a custom agent's list is live only while its
    /// `spawn` toggle is on.
    static func effectiveSpawnableModels(
        isDefault: Bool,
        config: SubagentConfiguration,
        perAgentEnabled: Bool,
        perAgentModelTargets: [String]
    ) -> [String] {
        if isDefault { return config.spawnableModelNames }
        return perAgentEnabled ? perAgentModelTargets : []
    }

    /// Whether `spawn_agent` is available for an agent — i.e. it has at least one
    /// spawnable agent (nothing to spawn → hide the tool). There is no global
    /// master switch; each agent opts in for itself.
    static func spawnAgentAvailable(
        isDefault: Bool,
        config: SubagentConfiguration,
        perAgentEnabled: Bool,
        perAgentTargets: [String]
    ) -> Bool {
        !effectiveSpawnableAgents(
            isDefault: isDefault,
            config: config,
            perAgentEnabled: perAgentEnabled,
            perAgentTargets: perAgentTargets
        ).isEmpty
    }

    /// Whether `spawn_model` is available for an agent — i.e. it has at least one
    /// spawnable model id.
    static func spawnModelAvailable(
        isDefault: Bool,
        config: SubagentConfiguration,
        perAgentEnabled: Bool,
        perAgentModelTargets: [String]
    ) -> Bool {
        !effectiveSpawnableModels(
            isDefault: isDefault,
            config: config,
            perAgentEnabled: perAgentEnabled,
            perAgentModelTargets: perAgentModelTargets
        ).isEmpty
    }

    /// Whether `image` is available for an agent. The Default / main chat is
    /// governed by its own image switch (`imageDelegationActive`); a custom
    /// agent by its own toggle. There is no global master switch.
    static func imageAvailable(
        isDefault: Bool,
        config: SubagentConfiguration,
        perAgentEnabled: Bool
    ) -> Bool {
        isDefault ? config.imageDelegationActive : perAgentEnabled
    }

    /// Whether `applescript` is available for an agent. The Default / main chat
    /// is governed by its own AppleScript switch (`appleScriptDelegationActive`);
    /// a custom agent by its own toggle. There is no global master switch. The
    /// installed-model gate is applied separately (`hasReadyAppleScriptModel` in
    /// `visibleDelegationToolNames`), mirroring `image`.
    static func appleScriptAvailable(
        isDefault: Bool,
        config: SubagentConfiguration,
        perAgentEnabled: Bool
    ) -> Bool {
        isDefault ? config.appleScriptDelegationActive : perAgentEnabled
    }

    /// Whether a specific `spawn_agent` TARGET agent is reachable from a
    /// launching agent — the execution-time check the spawn kind enforces.
    /// Default / main chat uses its own pool; a custom agent its own allow-list.
    /// Agent names match case-insensitively (display names are user-facing prose).
    static func spawnTargetAllowed(
        _ name: String,
        isDefault: Bool,
        config: SubagentConfiguration,
        perAgentTargets: [String]
    ) -> Bool {
        if isDefault { return config.isAgentSpawnable(name) }
        return perAgentTargets.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether a specific `spawn_model` TARGET model id is reachable from a
    /// launching agent — the execution-time check the spawn kind enforces before
    /// any residency handoff (reject-before-evict). Default / main chat uses its
    /// own pool; a custom agent its own allow-list. Model ids are canonical, so
    /// this matches exactly (trimmed), unlike the case-insensitive agent check.
    static func spawnModelAllowed(
        _ id: String,
        isDefault: Bool,
        config: SubagentConfiguration,
        perAgentModelTargets: [String]
    ) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isDefault { return config.isModelSpawnable(trimmed) }
        return perAgentModelTargets.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        }
    }

    /// The delegation tool names visible to a given agent, applying the master
    /// gate + the per-capability Default-vs-custom predicate. The single source
    /// both the native `resolveTools` strip and the HTTP agent-run path read, so
    /// the two surfaces can never drift (BUG E parity guard).
    ///
    /// `hasReadyImageModel` is the installed-capability gate for `image`: the
    /// per-agent image switch can be ON, but if no ready on-device image model
    /// exists the tool is still withheld so the model is never offered an image
    /// capability the runtime can't satisfy. Passed in (not read from the cache
    /// here) so this stays a pure, MainActor-free SSOT both surfaces can call.
    static func visibleDelegationToolNames(
        agentId: UUID,
        snapshot: AgentConfigSnapshot,
        config: SubagentConfiguration,
        hasReadyImageModel: Bool,
        hasReadyAppleScriptModel: Bool = false
    ) -> Set<String> {
        let isDefault = (agentId == Agent.defaultId)
        var names = Set<String>()
        // The two spawn tools gate independently: each appears only when its own
        // pool is non-empty, so an agent with only models sees `spawn_model` and
        // not `spawn_agent` (and vice versa).
        if spawnAgentAvailable(
            isDefault: isDefault,
            config: config,
            perAgentEnabled: snapshot.spawnDelegationEnabled,
            perAgentTargets: snapshot.spawnableAgentNames
        ) {
            names.insert(SubagentCapabilityRegistry.spawnAgentToolName)
        }
        if spawnModelAvailable(
            isDefault: isDefault,
            config: config,
            perAgentEnabled: snapshot.spawnDelegationEnabled,
            perAgentModelTargets: snapshot.spawnableModelNames
        ) {
            names.insert(SubagentCapabilityRegistry.spawnModelToolName)
        }
        if hasReadyImageModel,
            imageAvailable(
                isDefault: isDefault,
                config: config,
                perAgentEnabled: snapshot.imageEnabled
            )
        {
            names.formUnion(SubagentCapabilityRegistry.image.toolNames)
        }
        // AppleScript gates like image: the per-agent / global switch can be ON,
        // but the tool is withheld until a curated AppleScript model is installed
        // (so the model is never offered a capability the runtime can't satisfy).
        if hasReadyAppleScriptModel,
            appleScriptAvailable(
                isDefault: isDefault,
                config: config,
                perAgentEnabled: snapshot.appleScriptEnabled
            )
        {
            names.formUnion(SubagentCapabilityRegistry.appleScript.toolNames)
        }
        return names
    }

    // MARK: - Per-agent effective settings

    // Image models, permissions, and budgets are configured per-agent (each
    // agent's Subagents tab) for custom agents and in the global config for the
    // Default / main chat. These pure resolvers concentrate that Default-vs-custom
    // branch so every execution path (the kinds) reads it the same way; they take
    // the launching agent's `AgentSettings` (nil-safe) plus the global `config`,
    // so they stay unit-testable without MainActor.

    /// The effective image-model bundle id for an agent + kind. Default / main
    /// chat uses the global configured default; a custom agent uses its own
    /// per-agent model. A `nil` result is intentional — it falls through to the
    /// run-time "first ready model" resolver, so an agent that enabled image
    /// without picking a model still works.
    static func effectiveImageModel(
        isEdit: Bool,
        isDefault: Bool,
        config: SubagentConfiguration,
        settings: AgentSettings?
    ) -> String? {
        if isDefault {
            return isEdit ? config.defaultImageEditModelId : config.defaultImageGenerationModelId
        }
        return isEdit ? settings?.imageEditModelId : settings?.imageGenerationModelId
    }

    /// The configured AppleScript model id for an agent — Default / main chat
    /// uses the global default; a custom agent uses its own. `nil` falls through
    /// to the catalog's first-installed fallback (so an agent that enabled
    /// AppleScript without picking a model still works).
    static func effectiveAppleScriptModel(
        isDefault: Bool,
        config: SubagentConfiguration,
        settings: AgentSettings?
    ) -> String? {
        let raw = isDefault ? config.defaultAppleScriptModelId : settings?.appleScriptModelId
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// The AppleScript execution mode for an agent — Default / main chat uses
    /// the global default; a custom agent uses its own. Defaults to the safe
    /// `confirmEach` when unset.
    static func effectiveAppleScriptExecutionMode(
        isDefault: Bool,
        config: SubagentConfiguration,
        settings: AgentSettings?
    ) -> AppleScriptExecutionMode {
        if isDefault { return config.defaultAppleScriptExecutionMode }
        return settings?.appleScriptExecutionMode ?? .default
    }

    /// The effective per-run model override for a subagent capability, or `nil`
    /// to inherit the kind's default model source (the parent agent's model for
    /// computer_use; the chosen agent's model for spawn). The
    /// Default / main chat reads the global override map; a custom agent its own.
    /// A blank stored value resolves to `nil` (inherit). This is the standard
    /// model-pick axis every chat-driven kind reads the same way.
    static func effectiveSubagentModel(
        capabilityId: String,
        isDefault: Bool,
        config: SubagentConfiguration,
        settings: AgentSettings?
    ) -> String? {
        let raw =
            isDefault
            ? config.subagentModelOverrides[capabilityId]
            : settings?.subagentModelOverrides[capabilityId]
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// The effective permission policy for a delegation capability. Default / main
    /// chat uses the global permission map; a custom agent uses its own. A missing
    /// entry resolves to the safe `.ask` default.
    static func effectivePermission(
        capabilityId: String,
        isDefault: Bool,
        config: SubagentConfiguration,
        settings: AgentSettings?
    ) -> SubagentPermissionPolicy {
        let defaults =
            isDefault
            ? config.permissionDefaults
            : (settings?.subagentPermissions ?? SubagentPermissionDefaults())
        return defaults.policy(for: capabilityId)
    }

    /// The effective (clamped) `spawn` budgets for an agent. Default / main chat
    /// uses the global budgets; a custom agent uses its own.
    static func effectiveBudgets(
        isDefault: Bool,
        config: SubagentConfiguration,
        settings: AgentSettings?
    ) -> SubagentBudgets {
        let budgets = isDefault ? config.budgets : (settings?.subagentBudgets ?? SubagentBudgets())
        return budgets.normalized
    }

    /// The effective child-tool grant for spawn runs launched by an agent.
    /// Default / main chat uses the global setting; a custom agent uses its
    /// own. Missing settings resolve to the safe text-only `.none`.
    static func effectiveSpawnToolAccess(
        isDefault: Bool,
        config: SubagentConfiguration,
        settings: AgentSettings?
    ) -> SpawnToolAccess {
        isDefault ? config.spawnToolAccess : (settings?.spawnToolAccess ?? .none)
    }
}
