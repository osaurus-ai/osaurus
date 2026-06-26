//
//  SubagentCapabilityRegistry.swift
//  OsaurusCore — Subagent framework
//
//  One per-agent capability registry for the nested sub-agent family. Each
//  capability declares its gate, the tool name(s) it gates, and the
//  system-prompt guidance to inject when the capability is live. Both the
//  native `SystemPromptComposer` and the HTTP `enrichWithAgentContext` path
//  consume `SubagentToolVisibility` so the two surfaces can never drift on
//  which sub-agent tools an agent sees (the standing BUG E regression guard).
//
//  Replaces the parallel hand-written `computerUseEnabled` / `spawnDelegationEnabled`
//  gate blocks + guidance sections in the composer and the hardcoded
//  `["image_generate","image_edit","local_delegate","spawn"]` list in the HTTP
//  path.
//

import Foundation

/// The single per-kind descriptor (SSOT) for one nested sub-agent capability.
///
/// Every sub-agent surface reads this one value: the `resolveTools` strip + the
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
    /// handoff (`dedicatedConfigured` / `persona`) or simply reuses the parent
    /// agent's model (`inheritsParent`).
    public enum ModelSource: Sendable, Equatable {
        /// A dedicated, separately-configured model (image: gen / edit defaults;
        /// coordinator owns residency).
        case dedicatedConfigured
        /// The chosen persona's model (spawn) — local or remote; the kind runs
        /// the residency handoff when it clashes with a resident chat model.
        case persona
        /// The parent agent's own model (computer_use, sandbox_reduce) — no
        /// residency change.
        case inheritsParent
    }

    /// The per-agent on/off field a capability binds to (the `AgentSettings` /
    /// `AgentConfigSnapshot` flag). Concentrates the "which flag" mapping in one
    /// place so the `resolveTools` strip and the AgentsView editor both read /
    /// write through the descriptor instead of hardcoding field names.
    public enum PerAgentFlag: Sendable, Hashable {
        case computerUse
        case spawnDelegation

        /// The resolved per-agent flag for the `resolveTools` strip.
        public func enabled(in snapshot: AgentConfigSnapshot) -> Bool {
            switch self {
            case .computerUse: return snapshot.computerUseEnabled
            case .spawnDelegation: return snapshot.spawnDelegationEnabled
            }
        }

        /// The stored per-agent flag, for hydrating the AgentsView editor.
        public func read(from settings: AgentSettings) -> Bool {
            switch self {
            case .computerUse: return settings.computerUseEnabled
            case .spawnDelegation: return settings.spawnDelegationEnabled
            }
        }

        /// Write the per-agent flag back when saving the AgentsView editor.
        public func write(_ value: Bool, into settings: inout AgentSettings) {
            switch self {
            case .computerUse: settings.computerUseEnabled = value
            case .spawnDelegation: settings.spawnDelegationEnabled = value
            }
        }
    }

    /// The family-specific baseline GLOBAL gate a delegation capability ANDs
    /// with (applied in `ToolRegistry`). Declared as data (not a closure) so the
    /// descriptor stays a plain value; the `SubagentConfiguration` mapping is the
    /// one internal switch a new delegation kind extends.
    public enum DelegationGlobalGate: Sendable, Equatable {
        /// spawn: delegation on AND at least one agent is marked spawnable.
        case anyAgentSpawnable
        /// image: delegation on AND image delegation enabled.
        case imageDelegationActive

        /// Whether this global gate is currently open for `config`.
        func isActive(_ config: SubagentConfiguration) -> Bool {
            switch self {
            case .anyAgentSpawnable: return config.anyAgentSpawnable
            case .imageDelegationActive: return config.imageDelegationActive
            }
        }
    }

    /// How this capability is gated.
    public enum Gate: Sendable {
        /// Authoritative per-agent flag, stripped in BOTH auto + manual mode
        /// (computer_use). The Default agent never enables it.
        case perAgent
        /// The spawn/image delegation family: the Default agent surfaces it when
        /// the GLOBAL `global` gate is on; a custom agent when its per-agent
        /// `spawnDelegationEnabled` is on. `global` is the family-specific
        /// baseline gate applied in `ToolRegistry`.
        case delegation(global: DelegationGlobalGate)
        /// Sandbox-scoped (sandbox_reduce): gated by sandbox registration +
        /// execution mode, NOT stripped in `resolveTools` and not surfaced as a
        /// per-agent / delegation toggle.
        case sandboxExec
    }

    /// Stable id (`"computer_use"`, `"spawn"`, `"image"`, `"sandbox_reduce"`).
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
    /// Human label for the live-feed header + collapsed tool chip.
    public let displayLabel: String
    /// SF Symbol for the live feed + tool chip.
    public let iconName: String
    /// System-prompt guidance injected when the primary tool resolves.
    public let guidance: String?
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
        displayLabel: String? = nil,
        iconName: String = "sparkles",
        guidance: String? = nil,
        guidanceSectionId: String? = nil,
        guidanceLabelKey: String? = nil
    ) {
        self.id = id
        self.toolNames = toolNames
        self.gate = gate
        self.perAgentFlag = perAgentFlag
        self.modelSource = modelSource
        self.displayLabel = displayLabel ?? id
        self.iconName = iconName
        self.guidance = guidance
        self.guidanceSectionId = guidanceSectionId
        self.guidanceLabelKey = guidanceLabelKey
    }
}

/// The registry of sub-agent capabilities, in a stable order (so the guidance
/// sections render in a KV-cache-stable sequence). Each `SubagentKind` exposes
/// its matching entry here as its `capability`, so this is the one place a
/// surface needs to read to gate, render, or describe any sub-agent.
public enum SubagentCapabilityRegistry {
    public static let computerUse = SubagentCapability(
        id: "computer_use",
        toolNames: [ComputerUseTool.toolName],
        gate: .perAgent,
        perAgentFlag: .computerUse,
        modelSource: .inheritsParent,
        displayLabel: "Computer Use",
        iconName: "cursorarrow.rays",
        guidance: SystemPromptTemplates.computerUseGuidance,
        guidanceSectionId: "computerUse",
        guidanceLabelKey: "Computer Use"
    )

    /// The text-spawn family — just `spawn` now that `local_delegate` is gone.
    /// No guidance section today. Names are declared here as the SSOT (the
    /// registry is authoritative for sub-agent tool visibility); `ToolRegistry`'s
    /// derived sets read these for its internal gating.
    public static let spawn = SubagentCapability(
        id: "spawn",
        toolNames: ["spawn"],
        gate: .delegation(global: .anyAgentSpawnable),
        perAgentFlag: .spawnDelegation,
        modelSource: .persona,
        displayLabel: "Subagent",
        iconName: "person.2.fill"
    )

    /// The image family — one `image` tool that both generates and edits
    /// (`source_paths` → edit). The guidance renders when `image` resolves.
    public static let image = SubagentCapability(
        id: "image",
        toolNames: ["image"],
        gate: .delegation(global: .imageDelegationActive),
        perAgentFlag: .spawnDelegation,
        modelSource: .dedicatedConfigured,
        displayLabel: "Image",
        iconName: "photo",
        guidance: SystemPromptTemplates.imageGenerationGuidance,
        guidanceSectionId: "imageGeneration",
        guidanceLabelKey: "Image Generation"
    )

    /// The reduction family — `sandbox_reduce` runs a read/search/exec-only
    /// child loop inside the sandbox and hands back only a digest. Gated by
    /// sandbox registration (NOT a per-agent / delegation toggle), so it never
    /// strips in `resolveTools`; represented here for display + guidance + tests.
    public static let sandboxReduce = SubagentCapability(
        id: "sandbox_reduce",
        toolNames: ["sandbox_reduce"],
        gate: .sandboxExec,
        modelSource: .inheritsParent,
        displayLabel: "Investigation",
        iconName: "doc.text.magnifyingglass"
    )

    /// Every capability, in guidance-render order (computer_use, then image;
    /// spawn / sandbox_reduce have no guidance and are skipped at render time).
    public static let all: [SubagentCapability] = [computerUse, spawn, image, sandboxReduce]

    /// The delegation-gated capabilities (spawn + image).
    public static let delegationFamily: [SubagentCapability] = [spawn, image]

    /// Distinct per-agent toggle flags, in registry order (computer_use, then the
    /// shared spawn/image delegation flag). One entry per *toggle* — the spawn +
    /// image entries collapse onto their shared `spawnDelegationEnabled` flag —
    /// so the AgentsView editor renders exactly one toggle per flag, driven by
    /// the registry instead of hand-built groups.
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

    /// The descriptor that gates a given tool name.
    public static func capability(forToolName name: String) -> SubagentCapability? {
        all.first { $0.toolNames.contains(name) }
    }

    /// Feed-header / tool-chip label for a kind id.
    public static func displayLabel(forKindId id: String) -> String? {
        capability(forKindId: id)?.displayLabel
    }

    /// Tool-chip label for a sub-agent tool name (`nil` for non-sub-agent tools).
    public static func displayLabel(forToolName name: String) -> String? {
        capability(forToolName: name)?.displayLabel
    }

    /// Tool-chip icon for a sub-agent tool name (`nil` for non-sub-agent tools).
    public static func iconName(forToolName name: String) -> String? {
        capability(forToolName: name)?.iconName
    }
}

/// Shared sub-agent tool-visibility resolver used by BOTH the native
/// `SystemPromptComposer.resolveTools` and the HTTP `enrichWithAgentContext`
/// path, so the two surfaces always agree on which sub-agent tools an agent
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

    /// Whether the delegation family is visible for this agent. The Default
    /// agent is governed by the GLOBAL delegation switch; a custom agent by its
    /// own `spawnDelegationEnabled` flag.
    public static func delegationEnabled(
        agentId: UUID,
        perAgentEnabled: Bool,
        globalEnabled: Bool
    ) -> Bool {
        agentId == Agent.defaultId ? globalEnabled : perAgentEnabled
    }
}
