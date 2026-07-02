//
//  Agent.swift
//  osaurus
//
//  Defines an Agent - a customizable assistant configuration with its own
//  system prompt, tools, theme, and generation settings.
//

import Foundation

/// A quick action prompt template shown in the empty state
public struct AgentQuickAction: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var icon: String
    public var text: String
    public var prompt: String

    public init(id: UUID = UUID(), icon: String, text: String, prompt: String) {
        self.id = id
        self.icon = icon
        self.text = text
        self.prompt = prompt
    }

    /// Built-in chat quick actions. Localized at access time (Option A):
    /// defaults only appear in the UI as a read-only fallback when an agent
    /// has `chatQuickActions == nil`; they are never persisted unless the
    /// user explicitly customizes them. A new UUID is generated on each
    /// access, matching the previous `static let` semantics for consumers.
    public static var defaultChatQuickActions: [AgentQuickAction] {
        [
            AgentQuickAction(icon: "lightbulb", text: L("Explain a concept"), prompt: L("Explain ")),
            AgentQuickAction(icon: "doc.text", text: L("Summarize text"), prompt: L("Summarize the following: ")),
            AgentQuickAction(
                icon: "chevron.left.forwardslash.chevron.right",
                text: L("Write code"),
                prompt: L("Write code that ")
            ),
            AgentQuickAction(icon: "pencil.line", text: L("Help me write"), prompt: L("Help me write ")),
        ]
    }

    /// Setup-oriented quick actions for the built-in Osaurus configuration
    /// agent (`Agent.defaultId`). These nudge the user toward the configure
    /// flow that's unique to this agent instead of the generic chat prompts.
    public static var defaultConfigurationQuickActions: [AgentQuickAction] {
        [
            AgentQuickAction(
                icon: "checklist",
                text: L("What's configured?"),
                prompt: L("What's currently configured in Osaurus?")
            ),
            AgentQuickAction(
                icon: "arrow.down.circle",
                text: L("Download a model"),
                prompt: L("Help me download a local model.")
            ),
            AgentQuickAction(
                icon: "cloud",
                text: L("Add a provider"),
                prompt: L("Help me add a cloud AI provider.")
            ),
            AgentQuickAction(
                icon: "puzzlepiece.extension",
                text: L("Install a plugin"),
                prompt: L("Help me install a plugin.")
            ),
        ]
    }

}

/// Controls whether tools are selected automatically via RAG or manually by the user
public enum ToolSelectionMode: String, Codable, Sendable {
    case auto
    case manual
}

/// A customizable assistant agent for ChatView
public struct Agent: Codable, Identifiable, Sendable, Equatable {
    /// Unique identifier for the agent
    public let id: UUID
    /// Display name of the agent
    public var name: String
    /// Brief description of what this agent does
    public var description: String
    /// System prompt prepended to all chat sessions with this agent
    public var systemPrompt: String
    /// Optional custom theme ID to apply when this agent is active
    public var themeId: UUID?
    /// Optional default model for this agent
    public var defaultModel: String?
    /// Optional temperature override
    public var temperature: Float?
    /// Optional max tokens override
    public var maxTokens: Int?
    /// Per-agent chat quick actions. nil = use defaults, empty = hidden, non-empty = custom list
    public var chatQuickActions: [AgentQuickAction]?
    /// User-authored override for the chat empty-state greeting line.
    /// `nil` (or empty after trim) renders the existing time-of-day
    /// default ("Good morning" / "Hello"). Only applied when generative
    /// greetings resolve to OFF for this agent — when AI is generating,
    /// the produced greeting wins.
    public var chatGreeting: String?
    /// User-authored override for the chat empty-state subtitle.
    /// `nil` (or empty after trim) renders the localized default
    /// ("How can I help you today?"). Same gating as `chatGreeting`.
    public var chatSubtitle: String?
    /// Whether this is a built-in agent (cannot be deleted)
    public let isBuiltIn: Bool
    /// When the agent was created
    public let createdAt: Date
    /// When the agent was last modified
    public var updatedAt: Date
    /// Derivation index for the agent's cryptographic identity (nil = no address yet)
    public var agentIndex: UInt32?
    /// Derived cryptographic address for this agent (nil = no address yet)
    public var agentAddress: String?
    /// Controls the agent's ability to run arbitrary commands in the sandbox
    public var autonomousExec: AutonomousExecConfig?
    /// Per-agent plugin instruction overrides keyed by plugin ID
    public var pluginInstructions: [String: String]?
    /// Whether this agent is advertised via Bonjour on the local network
    public var bonjourEnabled: Bool
    /// Controls whether tools are selected automatically (RAG preflight) or manually by the user
    public var toolSelectionMode: ToolSelectionMode?
    /// Tool names explicitly selected by the user when toolSelectionMode is .manual
    public var manualToolNames: [String]?
    /// Skill names explicitly selected by the user when toolSelectionMode is .manual
    public var manualSkillNames: [String]?
    /// Whether this agent may use tools / preflight context. Default true.
    /// Positive polarity (matches `AgentSettings.*Enabled`); the legacy
    /// negative `disableTools` key is read on decode for back-compat.
    public var toolsEnabled: Bool
    /// Whether memory is injected into prompts and recorded for this agent.
    /// Default true. Legacy negative `disableMemory` key read on decode.
    public var memoryEnabled: Bool
    /// Optional mascot avatar identifier. nil falls back
    /// to the agent name's first letter monogram in the UI
    public var avatar: String?
    /// Filename of a user-supplied custom avatar image, stored under
    /// `OsaurusPaths.agents()/avatars/`. When set, takes precedence over
    /// `avatar` in the avatar UI. nil = no custom image.
    public var customAvatarFilename: String?
    /// auto-speak assistant turns after streaming. overrides per-chat toggle.
    public var autoSpeak: Bool?
    /// per-agent PocketTTS voice override. nil = use global voice.
    public var ttsVoice: String?
    /// Opt-in feature settings (Agent DB + self-scheduling). Agents created before
    /// the feature shipped decode with `.defaultDisabled`, leaving the surface dormant.
    public var settings: AgentSettings
    /// User-defined position. `nil` falls to the end, sorted alphabetically.
    public var order: Int?
    /// Security-scoped bookmark (created on this machine) for a host folder
    /// the agent may read/write inside. Persisted so the grant survives
    /// relaunch. When set, an authenticated remote agent run (Secure Channel,
    /// agent-scoped) gets host file tools (`file_read`/`file_write`/`file_edit`)
    /// confined to this folder — shell/git stay denied. `nil` means no host
    /// folder is granted and remote runs fall back to sandbox-only tools.
    /// The bookmark is machine-local (it lives on the agent's own host); a
    /// paired caller never sees it.
    public var hostWorkspaceBookmark: Data?
    /// Human-readable path of `hostWorkspaceBookmark` for display in the agent
    /// editor. Advisory only — `hostWorkspaceBookmark` is the source of truth
    /// for access; this can go stale if the folder is moved/renamed.
    public var hostWorkspacePath: String?

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        systemPrompt: String = "",
        themeId: UUID? = nil,
        defaultModel: String? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        chatQuickActions: [AgentQuickAction]? = nil,
        chatGreeting: String? = nil,
        chatSubtitle: String? = nil,
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        agentIndex: UInt32? = nil,
        agentAddress: String? = nil,
        autonomousExec: AutonomousExecConfig? = nil,
        pluginInstructions: [String: String]? = nil,
        bonjourEnabled: Bool = false,
        toolSelectionMode: ToolSelectionMode? = nil,
        manualToolNames: [String]? = nil,
        manualSkillNames: [String]? = nil,
        toolsEnabled: Bool = true,
        memoryEnabled: Bool = true,
        avatar: String? = nil,
        customAvatarFilename: String? = nil,
        autoSpeak: Bool? = nil,
        ttsVoice: String? = nil,
        settings: AgentSettings = .defaultDisabled,
        order: Int? = nil,
        hostWorkspaceBookmark: Data? = nil,
        hostWorkspacePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.themeId = themeId
        self.defaultModel = defaultModel
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.chatQuickActions = chatQuickActions
        self.chatGreeting = chatGreeting
        self.chatSubtitle = chatSubtitle
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.agentIndex = agentIndex
        self.agentAddress = agentAddress
        self.autonomousExec = autonomousExec
        self.pluginInstructions = pluginInstructions
        self.bonjourEnabled = bonjourEnabled
        self.toolSelectionMode = toolSelectionMode
        self.manualToolNames = manualToolNames
        self.manualSkillNames = manualSkillNames
        self.toolsEnabled = toolsEnabled
        self.memoryEnabled = memoryEnabled
        self.avatar = avatar
        self.customAvatarFilename = customAvatarFilename
        self.autoSpeak = autoSpeak
        self.ttsVoice = ttsVoice
        self.settings = settings
        self.order = order
        self.hostWorkspaceBookmark = hostWorkspaceBookmark
        self.hostWorkspacePath = hostWorkspacePath
    }

    // MARK: - Custom avatar resolution

    /// Absolute URL of the custom avatar image, if one is set and the file
    /// exists on disk. Returns nil when no custom avatar is configured or
    /// the file has been removed out from under us.
    public var customAvatarURL: URL? {
        guard let name = customAvatarFilename, !name.isEmpty else { return nil }
        let url = OsaurusPaths.agents()
            .appendingPathComponent("avatars", isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Localized Display Helpers

    /// Display name for UI rendering. Built-in agents (currently only the
    /// Default agent) resolve their English `name` through the localization
    /// catalog so the sidebar, pickers, menus, etc. render in the user's
    /// language. User-created agents always render their stored name verbatim.
    public var displayName: String {
        isBuiltIn ? L(String.LocalizationValue(name)) : name
    }

    /// Display description for UI rendering. Same rules as `displayName`.
    public var displayDescription: String {
        guard isBuiltIn, !description.isEmpty else { return description }
        return L(String.LocalizationValue(description))
    }

    // MARK: - Built-in Agents

    /// Well-known UUID for the default Osaurus agent
    public static let defaultId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Check whether an agent ID string refers to the default (built-in) agent.
    /// The default agent is in-memory only and is never persisted as an
    /// `Agent.json`; its user-editable settings live in
    /// `DefaultAgentConfiguration` (Settings → Chat).
    public static func isDefaultAgentId(_ id: String) -> Bool {
        id == defaultId.uuidString
    }

    /// The default agent — front door to configuring Osaurus.
    /// Renders as "Osaurus" in chat and the picker; subtitle nudges
    /// users toward the configure flow that's unique to this agent.
    /// `avatar: "green"` resolves the bundled `osaurus-avatar-green`
    /// asset in `NativeMessageCellView`/`SharedHeaderComponents`.
    public static var `default`: Agent {
        Agent(
            id: defaultId,
            name: "Osaurus",
            description: L("Configuration helper"),
            systemPrompt: "",
            themeId: nil,
            defaultModel: nil,
            temperature: nil,
            maxTokens: nil,
            isBuiltIn: true,
            createdAt: Date.distantPast,
            updatedAt: Date.distantPast,
            avatar: "green"
        )
    }

    /// All built-in agents
    public static var builtInAgents: [Agent] {
        [.default]
    }
}

// MARK: - Decodable Migration

extension Agent {
    /// Legacy negative-polarity keys read for back-compat when the new
    /// positive `toolsEnabled` / `memoryEnabled` keys are absent.
    private enum LegacyCodingKeys: String, CodingKey {
        case disableTools
        case disableMemory
    }

    /// Custom decoder that provides default values for fields added after the initial release,
    /// ensuring older persisted JSON files remain loadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        themeId = try c.decodeIfPresent(UUID.self, forKey: .themeId)
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        temperature = try c.decodeIfPresent(Float.self, forKey: .temperature)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        chatQuickActions = try c.decodeIfPresent([AgentQuickAction].self, forKey: .chatQuickActions)
        chatGreeting = try c.decodeIfPresent(String.self, forKey: .chatGreeting)
        chatSubtitle = try c.decodeIfPresent(String.self, forKey: .chatSubtitle)
        isBuiltIn = try c.decode(Bool.self, forKey: .isBuiltIn)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        agentIndex = try c.decodeIfPresent(UInt32.self, forKey: .agentIndex)
        agentAddress = try c.decodeIfPresent(String.self, forKey: .agentAddress)
        autonomousExec = try c.decodeIfPresent(AutonomousExecConfig.self, forKey: .autonomousExec)
        pluginInstructions = try c.decodeIfPresent([String: String].self, forKey: .pluginInstructions)
        bonjourEnabled = try c.decodeIfPresent(Bool.self, forKey: .bonjourEnabled) ?? false
        toolSelectionMode = try c.decodeIfPresent(ToolSelectionMode.self, forKey: .toolSelectionMode)
        manualToolNames = try c.decodeIfPresent([String].self, forKey: .manualToolNames)
        manualSkillNames = try c.decodeIfPresent([String].self, forKey: .manualSkillNames)
        // Positive polarity (`toolsEnabled` / `memoryEnabled`, default true).
        // Older agent JSON only has the negative `disableTools` /
        // `disableMemory` keys; read those from a legacy container and
        // invert when the new keys are absent so existing agents migrate
        // losslessly.
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if let toolsEnabledValue = try c.decodeIfPresent(Bool.self, forKey: .toolsEnabled) {
            toolsEnabled = toolsEnabledValue
        } else {
            toolsEnabled = !(try legacy.decodeIfPresent(Bool.self, forKey: .disableTools) ?? false)
        }
        if let memoryEnabledValue = try c.decodeIfPresent(Bool.self, forKey: .memoryEnabled) {
            memoryEnabled = memoryEnabledValue
        } else {
            memoryEnabled = !(try legacy.decodeIfPresent(Bool.self, forKey: .disableMemory) ?? false)
        }
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        customAvatarFilename = try c.decodeIfPresent(String.self, forKey: .customAvatarFilename)
        autoSpeak = try c.decodeIfPresent(Bool.self, forKey: .autoSpeak)
        ttsVoice = try c.decodeIfPresent(String.self, forKey: .ttsVoice)
        settings = try c.decodeIfPresent(AgentSettings.self, forKey: .settings) ?? .defaultDisabled
        order = try c.decodeIfPresent(Int.self, forKey: .order)
        // Added after initial release; absent in older agent JSON.
        hostWorkspaceBookmark = try c.decodeIfPresent(Data.self, forKey: .hostWorkspaceBookmark)
        hostWorkspacePath = try c.decodeIfPresent(String.self, forKey: .hostWorkspacePath)
    }
}

// MARK: - Autonomous Exec Configuration

public struct AutonomousExecConfig: Codable, Sendable, Equatable {
    /// Whether the agent's sandbox (autonomous code execution) is on. Note the
    /// *effective* default is resolved in
    /// `AgentManager.effectiveAutonomousExec`, not by this struct: the chip
    /// defaults ON for the Default agent and newly created agents on supported
    /// machines (`AgentManager.sandboxEnabledByDefault`). This field's own
    /// default below stays `false` so it remains a neutral base for
    /// `current ?? .default` mutations in the settings UI (which only flips
    /// individual sub-toggles) and never silently turns the sandbox on for an
    /// existing custom agent that was left unconfigured.
    public var enabled: Bool
    public var maxCommandsPerTurn: Int
    public var pluginCreate: Bool
    /// Combined sandbox + host-read mode: allow the host read tools to
    /// read secret files (`.env`, keys, credentials) inside the read-only
    /// workspace. Defaults `false` (refuse) — the user opts in explicitly,
    /// trading the exfiltration protection for convenience.
    public var allowHostSecretReads: Bool
    /// Whether the sandbox VM gets outbound network. Defaults `true`
    /// (egress on) so a first-time user's sandbox can fetch packages and
    /// live data without an extra opt-in. Set `false` to cut the network
    /// leg of the agent-as-bridge exfiltration path — pairs naturally with
    /// combined mode (read-only host + no egress). Honored at VM boot.
    public var sandboxNetworkEnabled: Bool
    /// Whether the agent may run detached background jobs. Gates both
    /// `sandbox_exec(background:true)` and the `sandbox_process` tool
    /// (poll/wait/kill). Defaults `false` to keep the sandbox tool surface
    /// lean — the model isn't shown background affordances it can't reliably
    /// manage. Opt in for dev-server / watcher iteration loops.
    public var backgroundProcessEnabled: Bool

    public static let `default` = AutonomousExecConfig(
        enabled: false,
        maxCommandsPerTurn: 10,
        pluginCreate: true,
        allowHostSecretReads: false,
        sandboxNetworkEnabled: true,
        backgroundProcessEnabled: false
    )

    public init(
        enabled: Bool = false,
        maxCommandsPerTurn: Int = 10,
        pluginCreate: Bool = true,
        allowHostSecretReads: Bool = false,
        sandboxNetworkEnabled: Bool = true,
        backgroundProcessEnabled: Bool = false
    ) {
        self.enabled = enabled
        self.maxCommandsPerTurn = maxCommandsPerTurn
        self.pluginCreate = pluginCreate
        self.allowHostSecretReads = allowHostSecretReads
        self.sandboxNetworkEnabled = sandboxNetworkEnabled
        self.backgroundProcessEnabled = backgroundProcessEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, maxCommandsPerTurn, pluginCreate
        case allowHostSecretReads, sandboxNetworkEnabled
        case backgroundProcessEnabled
    }

    // Custom decode so agents persisted before these fields existed keep
    // loading: missing keys fall back to the safe defaults (secrets
    // refused, egress on) rather than failing the whole agent decode.
    // A legacy `commandTimeout` key may still be present in older agent
    // JSON; keyed decoding ignores it harmlessly (the field was unused).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        maxCommandsPerTurn = try c.decodeIfPresent(Int.self, forKey: .maxCommandsPerTurn) ?? 10
        pluginCreate = try c.decodeIfPresent(Bool.self, forKey: .pluginCreate) ?? true
        allowHostSecretReads = try c.decodeIfPresent(Bool.self, forKey: .allowHostSecretReads) ?? false
        sandboxNetworkEnabled = try c.decodeIfPresent(Bool.self, forKey: .sandboxNetworkEnabled) ?? true
        backgroundProcessEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .backgroundProcessEnabled) ?? false
    }
}

// MARK: - Resolved Agent Capabilities

/// The fully-resolved, positive-polarity view of an agent's capability
/// flags after default-agent overrides and the global memory switch are
/// applied. Produced by `AgentManager.effectiveCapabilities(for:)` and
/// consumed by `AgentConfigSnapshot` so every gate reads one struct
/// instead of calling a handful of `effective*` accessors.
public struct AgentCapabilities: Sendable, Equatable {
    /// Tools / preflight context are available to the model.
    public var toolsEnabled: Bool
    /// Memory is injected into prompts and recorded (per-agent AND global).
    public var memoryEnabled: Bool
    /// Agent DB feature (spec §5.5).
    public var dbEnabled: Bool
    /// `render_chart` tool exposed to the model.
    public var renderChartEnabled: Bool
    /// `speak` (voice output) tool exposed to the model.
    public var speakEnabled: Bool
    /// `search_memory` recall tool exposed to the model. Independent of
    /// `memoryEnabled`, which gates injection + recording.
    public var searchMemoryEnabled: Bool
    /// Self-scheduling tools (`schedule_next_run` / `cancel_next_run` /
    /// `notify`) exposed to the model.
    public var selfSchedulingEnabled: Bool
    /// Computer Use (`computer_use` entry tool) exposed to the model.
    public var computerUseEnabled: Bool
    /// Resolved screen-context injection for this agent. A child of Computer
    /// Use: `computerUseEnabled && AgentSettings.screenContextEnabled`, so it
    /// is always false when Computer Use is off (including the Default agent).
    public var screenContextEnabled: Bool
    /// Spawn (`spawn`) exposed to the model — per-agent opt-in.
    public var spawnDelegationEnabled: Bool
    /// Image (`image`) exposed to the model — per-agent opt-in, split from
    /// `spawnDelegationEnabled` so an agent can spawn without image (or vice
    /// versa).
    public var imageEnabled: Bool
    /// AppleScript (`applescript`) exposed to the model — per-agent opt-in.
    /// Like `image`, the effective tool is additionally gated on an installed
    /// AppleScript model (see `SubagentToolVisibility`).
    public var appleScriptEnabled: Bool
    /// Agents this agent may launch via `spawn_agent`. Empty → the
    /// `spawn_agent` tool stays hidden (nothing to spawn). The Default agent
    /// ignores this and uses the global
    /// `SubagentConfiguration.spawnableAgentNames` pool instead.
    public var spawnableAgentNames: [String]
    /// Raw model ids this agent may hand a task to via `spawn_model` (no agent).
    /// Empty → the `spawn_model` tool stays hidden. The Default agent ignores
    /// this and uses the global `SubagentConfiguration.spawnableModelNames` pool.
    public var spawnableModelNames: [String]
    /// Optional "when/how to use" note per spawnable model id, surfaced in the
    /// spawn guidance descriptor. Pure metadata — the gate is `spawnableModelNames`.
    public var spawnableModelNotes: [String: String]

    public init(
        toolsEnabled: Bool,
        memoryEnabled: Bool,
        dbEnabled: Bool,
        renderChartEnabled: Bool,
        speakEnabled: Bool,
        searchMemoryEnabled: Bool,
        selfSchedulingEnabled: Bool,
        computerUseEnabled: Bool = false,
        screenContextEnabled: Bool = false,
        spawnDelegationEnabled: Bool = false,
        imageEnabled: Bool = false,
        appleScriptEnabled: Bool = false,
        spawnableAgentNames: [String] = [],
        spawnableModelNames: [String] = [],
        spawnableModelNotes: [String: String] = [:]
    ) {
        self.toolsEnabled = toolsEnabled
        self.memoryEnabled = memoryEnabled
        self.dbEnabled = dbEnabled
        self.renderChartEnabled = renderChartEnabled
        self.speakEnabled = speakEnabled
        self.searchMemoryEnabled = searchMemoryEnabled
        self.selfSchedulingEnabled = selfSchedulingEnabled
        self.computerUseEnabled = computerUseEnabled
        self.screenContextEnabled = screenContextEnabled
        self.spawnDelegationEnabled = spawnDelegationEnabled
        self.imageEnabled = imageEnabled
        self.appleScriptEnabled = appleScriptEnabled
        self.spawnableAgentNames = spawnableAgentNames
        self.spawnableModelNames = spawnableModelNames
        self.spawnableModelNotes = spawnableModelNotes
    }
}

// Agent-as-JSON export/import was removed: the share-deeplink flow
// (`AgentInvite`) covers cross-device sharing and the in-grid Duplicate
// action covers local copies. The JSON export couldn't carry memories,
// schedules, watchers, paired remote keys, or the sandbox container, so
// keeping it would have advertised a backup story it couldn't deliver.

// MARK: - Agent Settings (Agent DB + Self-Scheduling)

/// Operating mode for the agent's self-scheduling bounds. Picking a mode writes
/// the matching field defaults from `AgentScheduleSettings.defaults(for:)`; the
/// user can still override individual fields afterwards (see spec §13).
public enum AgentScheduleMode: String, Codable, Sendable, CaseIterable {
    case ambient
    case reactive
    case project
    case manual
}

/// Host-enforced bounds on agent self-scheduling. The agent cannot exceed any
/// of these; `LocalAgentBridge.scheduleNextRun` clamps and reports back. Stored
/// as part of `Agent.settings` so the bounds are exportable config (transient
/// pause state lives separately in `scheduler.sqlite.agent_pause`, per spec §4.1).
public struct AgentScheduleSettings: Codable, Sendable, Equatable {
    /// Furthest the agent may schedule into the future, in seconds.
    public var maxHorizonSeconds: Int
    /// Minimum gap between an agent's self-scheduled runs, in seconds.
    public var minIntervalSeconds: Int
    /// Rolling 24h cap on executed self-scheduled runs.
    public var dailyRunCap: Int
    /// Minute-of-day (0..1439) when quiet hours begin. `nil` = no quiet hours.
    public var quietHoursStart: Int?
    /// Minute-of-day (0..1439) when quiet hours end. `nil` = no quiet hours.
    public var quietHoursEnd: Int?
    /// Bitmask of days the agent may self-schedule on. Sun=1, Mon=2 ... Sat=64. 127 = all days.
    public var allowedDaysMask: Int
    /// Mode preset this bounds set was derived from (UI affordance, not enforcement).
    public var mode: AgentScheduleMode

    public init(
        maxHorizonSeconds: Int,
        minIntervalSeconds: Int,
        dailyRunCap: Int,
        quietHoursStart: Int? = nil,
        quietHoursEnd: Int? = nil,
        allowedDaysMask: Int = 127,
        mode: AgentScheduleMode
    ) {
        self.maxHorizonSeconds = maxHorizonSeconds
        self.minIntervalSeconds = minIntervalSeconds
        self.dailyRunCap = dailyRunCap
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.allowedDaysMask = allowedDaysMask
        self.mode = mode
    }

    /// Defaults per spec §13 mode preset table. Picking a mode in UI writes these
    /// into `Agent.settings.schedule`; individual fields can be overridden after.
    public static func defaults(for mode: AgentScheduleMode) -> AgentScheduleSettings {
        switch mode {
        case .ambient:
            return AgentScheduleSettings(
                maxHorizonSeconds: 7 * 24 * 3600,
                minIntervalSeconds: 3600,
                dailyRunCap: 6,
                quietHoursStart: 22 * 60,
                quietHoursEnd: 7 * 60,
                allowedDaysMask: 127,
                mode: .ambient
            )
        case .reactive:
            return AgentScheduleSettings(
                maxHorizonSeconds: 24 * 3600,
                minIntervalSeconds: 5 * 60,
                dailyRunCap: 48,
                quietHoursStart: nil,
                quietHoursEnd: nil,
                allowedDaysMask: 127,
                mode: .reactive
            )
        case .project:
            return AgentScheduleSettings(
                maxHorizonSeconds: 30 * 24 * 3600,
                minIntervalSeconds: 3600,
                dailyRunCap: 4,
                quietHoursStart: 22 * 60,
                quietHoursEnd: 7 * 60,
                allowedDaysMask: 127,
                mode: .project
            )
        case .manual:
            return AgentScheduleSettings(
                maxHorizonSeconds: 7 * 24 * 3600,
                minIntervalSeconds: 15 * 60,
                dailyRunCap: 0,
                quietHoursStart: nil,
                quietHoursEnd: nil,
                allowedDaysMask: 127,
                mode: .manual
            )
        }
    }
}

/// Per-agent quota / safety limits (spec §11.3). Storage limit applies to
/// the per-agent SQLite database file; run token + USD ceilings apply
/// per `agent_runs` row and cause the dispatcher to cancel the run when
/// exceeded mid-stream.
///
/// Every field has a sentinel "off" value (`0` or `nil`) so the host can
/// honor "no limit" without a separate enabled flag, and so back-compat
/// decoding can populate this struct without forcing a value choice on
/// existing agents.
public struct AgentLimitsSettings: Codable, Sendable, Equatable {
    /// Hard cap on `db.sqlite` size in bytes. `0` disables the check.
    /// Default = 100 MB, which is generous enough that a healthy agent
    /// won't hit it but small enough that a runaway agent gets stopped
    /// before chewing the user's disk.
    public var storageBytesLimit: Int
    /// Soft warning threshold as a percentage of `storageBytesLimit`
    /// (0..100). At/above this the UI shows a "running low" warning but
    /// writes still succeed.
    public var storageWarnPercent: Int
    /// Hard token ceiling for a single run (sum of `tokens_in + tokens_out`
    /// in `agent_runs`). `nil` disables.
    public var runTokensLimit: Int?
    /// Hard USD ceiling for a single run (`cost_usd` in `agent_runs`).
    /// `nil` disables.
    public var runCostUSDLimit: Double?

    public init(
        storageBytesLimit: Int = 100 * 1024 * 1024,
        storageWarnPercent: Int = 80,
        runTokensLimit: Int? = nil,
        runCostUSDLimit: Double? = nil
    ) {
        self.storageBytesLimit = storageBytesLimit
        self.storageWarnPercent = storageWarnPercent
        self.runTokensLimit = runTokensLimit
        self.runCostUSDLimit = runCostUSDLimit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        storageBytesLimit = try c.decodeIfPresent(Int.self, forKey: .storageBytesLimit) ?? (100 * 1024 * 1024)
        storageWarnPercent = try c.decodeIfPresent(Int.self, forKey: .storageWarnPercent) ?? 80
        runTokensLimit = try c.decodeIfPresent(Int.self, forKey: .runTokensLimit)
        runCostUSDLimit = try c.decodeIfPresent(Double.self, forKey: .runCostUSDLimit)
    }

    /// Default limits used by `AgentSettings.defaultDisabled` and by any
    /// agent loaded from JSON that predates this field.
    public static var defaults: AgentLimitsSettings { AgentLimitsSettings() }
}

/// Legacy tri-state used before the master `enableGenerativeGreetings`
/// toggle was retired in favor of a per-agent on/off (auto-on when a
/// Core Model is configured). Kept around purely so old persisted
/// `AgentSettings` JSON still decodes — `AgentSettings.init(from:)`
/// maps `.enabled → true`, `.disabled → false`, `.followGlobal → nil`.
/// New callers should not use this enum.
public enum GenerativeGreetingsPreference: String, Codable, Sendable, CaseIterable {
    case followGlobal
    case enabled
    case disabled
}

/// Top-level opt-in feature settings for an agent. Currently bundles the DB
/// toggle (spec §5.5), self-scheduling bounds (spec §4.1, §9, §13), and the
/// Phase 4 storage / cost limits (spec §11.3). New agent-wide opt-in
/// features should add fields here so a single migration surface stays
/// consolidated.
public struct AgentSettings: Codable, Sendable, Equatable {
    /// Per-agent SQLite database opt-in (spec §5.5.1). When false, db.* tools
    /// are stripped from the model's tool list, the onboarding prompt + schema
    /// snapshot are not injected, and the DB tabs in the detail view are hidden.
    /// The on-disk `db.sqlite` is preserved on toggle-off; "Delete agent data"
    /// is the only path that removes it.
    public var dbEnabled: Bool
    /// Self-scheduling bounds. Always present so the UI never has to disambiguate
    /// "schedule disabled" vs "schedule with default bounds"; `mode = .manual`
    /// (dailyRunCap = 0) is the off state.
    public var schedule: AgentScheduleSettings
    /// Storage quota + per-run cost ceilings (Phase 4).
    public var limits: AgentLimitsSettings
    /// Per-agent on/off for the generative greetings feature. Default
    /// `false` — like the other capability gates, an agent opts in
    /// explicitly. There is no global inheritance: this flag alone
    /// decides whether the empty state generates a greeting (see
    /// `Agent.shouldUseGenerativeGreetings`).
    public var generativeGreetingsEnabled: Bool
    /// Per-agent override for the empty-state greeting voice. `nil` (or
    /// an empty string after trimming) inherits the global persona from
    /// `ChatConfiguration.greetingPersona`; both empty falls back to the
    /// built-in playful default in `GenerativeGreetingService`.
    public var greetingPersona: String?
    /// Per-agent opt-in for the `render_chart` tool. Default off — the
    /// tool is registered as a built-in but stripped from the model's
    /// schema unless the user enables it, keeping the always-loaded tool
    /// count + token cost low for agents that never visualize data.
    public var renderChartEnabled: Bool
    /// Per-agent opt-in for the `speak` (voice output) tool. Default off;
    /// stripped from the schema unless enabled.
    public var speakEnabled: Bool
    /// Per-agent opt-in for the `search_memory` recall tool. Independent
    /// of the "Disable Memory" switch (which gates memory injection +
    /// recording): this flag only controls whether the model can recall
    /// memory mid-session via the tool. Default off.
    public var searchMemoryEnabled: Bool
    /// Per-agent opt-in for the self-scheduling tools (`schedule_next_run`,
    /// `cancel_next_run`, `notify`). Decoupled from the schedule-mode picker
    /// (`schedule.mode`): the mode only sets the host-enforced bounds, while
    /// this flag governs whether those tools are exposed to the model at all.
    /// Default off so a fresh agent never carries the scheduler trio in its
    /// always-loaded schema.
    public var selfSchedulingEnabled: Bool
    /// Per-agent opt-in for the Computer Use feature (the `computer_use`
    /// entry tool that drives macOS apps via the accessibility harness).
    /// Default off; gated authoritatively in `resolveTools` (stripped in
    /// BOTH auto and manual mode unless enabled). Only available on custom
    /// agents — the built-in Default agent cannot enable it.
    public var computerUseEnabled: Bool
    /// Per-agent autonomy ceiling for Computer Use (PR2). A structured hard
    /// cap merged strictest-wins on top of the user's global/per-app policy,
    /// so an agent can be held stricter than the user's default but never
    /// looser. `nil` means "no ceiling" (the user policy applies as-is).
    /// This is the spec's "SOUL.md ceiling" expressed as settings rather
    /// than parsed prose.
    public var computerUseCeiling: AutonomyCeiling?
    /// Per-agent screen-context injection, nested under Computer Use. Defaults
    /// `true`, so enabling Computer Use also turns on ambient screen context
    /// unless the user opts out here. The *effective* value is gated by
    /// `computerUseEnabled` (see `AgentManager.effectiveCapabilities`), so it is
    /// inert while Computer Use is off — including the Default agent.
    public var screenContextEnabled: Bool
    /// Per-agent opt-in for the `spawn` tool. Default off; gated
    /// authoritatively in `resolveTools` (stripped unless enabled AND the agent
    /// has at least one spawnable agent). The global `SubagentConfiguration`
    /// still supplies the system defaults (budgets, RAM safety, permissions);
    /// this is the per-agent enable.
    public var spawnDelegationEnabled: Bool
    /// Per-agent opt-in for the `image` tool (generate + edit). Default off;
    /// split from `spawnDelegationEnabled` so an agent can spawn without image.
    /// The Default agent ignores this and uses the global image enable in
    /// `SubagentConfiguration`.
    public var imageEnabled: Bool
    /// Per-agent opt-in for the `applescript` tool. Default off; the effective
    /// tool is additionally gated on an installed AppleScript model. The Default
    /// agent ignores this and uses the global enable in `SubagentConfiguration`.
    public var appleScriptEnabled: Bool
    /// Per-agent AppleScript model bundle id (`nil` → resolve to the first
    /// installed catalog model at run time). The Default agent uses the global
    /// `SubagentConfiguration.defaultAppleScriptModelId` instead.
    public var appleScriptModelId: String?
    /// Per-agent AppleScript execution mode (confirm each script vs auto-run
    /// with a warning). The Default agent uses the global
    /// `SubagentConfiguration.defaultAppleScriptExecutionMode` instead.
    public var appleScriptExecutionMode: AppleScriptExecutionMode
    /// Agents this agent may launch via `spawn_agent` (per-agent allow-list).
    /// Empty → the `spawn_agent` tool stays hidden (nothing to spawn). The
    /// Default agent ignores this and uses the global pool in
    /// `SubagentConfiguration`.
    public var spawnableAgentNames: [String]
    /// Raw model ids this agent may hand a task to via `spawn_model` (no agent;
    /// per-agent allow-list). Empty → the `spawn_model` tool stays hidden. The
    /// Default agent ignores this and uses the global
    /// `SubagentConfiguration.spawnableModelNames` pool.
    public var spawnableModelNames: [String]
    /// Optional "when/how to use" note per spawnable model id, surfaced in the
    /// spawn guidance descriptor. Pure metadata — the gate is `spawnableModelNames`.
    public var spawnableModelNotes: [String: String]
    /// Per-agent image-generation model bundle id (`nil` → resolve to the first
    /// ready text-to-image model at run time). The Default agent uses the global
    /// `SubagentConfiguration.defaultImageGenerationModelId` instead.
    public var imageGenerationModelId: String?
    /// Per-agent image-edit model bundle id (`nil` → resolve to the first ready
    /// image-edit model at run time). The Default agent uses the global
    /// `SubagentConfiguration.defaultImageEditModelId` instead.
    public var imageEditModelId: String?
    /// Per-agent permission policies for the delegation subagents (`spawn`,
    /// `image`), keyed by capability id. A kind absent from the map resolves to
    /// the safe `.ask` default. The Default agent uses the global
    /// `SubagentConfiguration.permissionDefaults` instead.
    public var subagentPermissions: SubagentPermissionDefaults
    /// Per-agent budgets for `spawn` jobs (token / turn / wall-clock caps). The
    /// Default agent uses the global `SubagentConfiguration.budgets` instead.
    public var subagentBudgets: SubagentBudgets
    /// What tools this agent's spawned workers may reach (`none` = text-only,
    /// `readOnly` = curated read-only set). Default `.none`; the Default agent
    /// uses the global `SubagentConfiguration.spawnToolAccess` instead.
    public var spawnToolAccess: SpawnToolAccess
    /// Per-agent model override for subagent kinds, keyed by capability id
    /// (`"computer_use"`, `"spawn"`). An entry supersedes the
    /// kind's default model source (the parent agent's model for computer_use;
    /// the chosen agent's model for spawn); an absent entry
    /// means "inherit". Stored as a generic `[capabilityId: modelId]` map — like
    /// `subagentPermissions` — so a new kind needs no new field. The Default
    /// agent uses the global `SubagentConfiguration.subagentModelOverrides`.
    public var subagentModelOverrides: [String: String]

    public init(
        dbEnabled: Bool,
        schedule: AgentScheduleSettings,
        limits: AgentLimitsSettings = .defaults,
        generativeGreetingsEnabled: Bool = false,
        greetingPersona: String? = nil,
        renderChartEnabled: Bool = false,
        speakEnabled: Bool = false,
        searchMemoryEnabled: Bool = false,
        selfSchedulingEnabled: Bool = false,
        computerUseEnabled: Bool = false,
        computerUseCeiling: AutonomyCeiling? = nil,
        screenContextEnabled: Bool = true,
        spawnDelegationEnabled: Bool = false,
        imageEnabled: Bool = false,
        appleScriptEnabled: Bool = false,
        appleScriptModelId: String? = nil,
        appleScriptExecutionMode: AppleScriptExecutionMode = .default,
        spawnableAgentNames: [String] = [],
        spawnableModelNames: [String] = [],
        spawnableModelNotes: [String: String] = [:],
        imageGenerationModelId: String? = nil,
        imageEditModelId: String? = nil,
        subagentPermissions: SubagentPermissionDefaults = SubagentPermissionDefaults(),
        subagentBudgets: SubagentBudgets = SubagentBudgets(),
        subagentModelOverrides: [String: String] = [:],
        spawnToolAccess: SpawnToolAccess = .none
    ) {
        self.dbEnabled = dbEnabled
        self.schedule = schedule
        self.limits = limits
        self.generativeGreetingsEnabled = generativeGreetingsEnabled
        self.greetingPersona = greetingPersona
        self.renderChartEnabled = renderChartEnabled
        self.speakEnabled = speakEnabled
        self.searchMemoryEnabled = searchMemoryEnabled
        self.selfSchedulingEnabled = selfSchedulingEnabled
        self.computerUseEnabled = computerUseEnabled
        self.computerUseCeiling = computerUseCeiling
        self.screenContextEnabled = screenContextEnabled
        self.spawnDelegationEnabled = spawnDelegationEnabled
        self.imageEnabled = imageEnabled
        self.appleScriptEnabled = appleScriptEnabled
        self.appleScriptModelId = appleScriptModelId
        self.appleScriptExecutionMode = appleScriptExecutionMode
        self.spawnableAgentNames = spawnableAgentNames
        self.spawnableModelNames = spawnableModelNames
        self.spawnableModelNotes = spawnableModelNotes
        self.imageGenerationModelId = imageGenerationModelId
        self.imageEditModelId = imageEditModelId
        self.subagentPermissions = subagentPermissions
        self.subagentBudgets = subagentBudgets
        self.subagentModelOverrides = subagentModelOverrides
        self.spawnToolAccess = spawnToolAccess
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dbEnabled = try c.decodeIfPresent(Bool.self, forKey: .dbEnabled) ?? false
        schedule =
            try c.decodeIfPresent(AgentScheduleSettings.self, forKey: .schedule)
            ?? AgentScheduleSettings.defaults(for: .ambient)
        limits = try c.decodeIfPresent(AgentLimitsSettings.self, forKey: .limits) ?? .defaults
        // Migrate the old shapes (a `Bool?` whose `nil` inherited the
        // now-removed global switch, or an even older tri-state enum)
        // onto the non-optional `Bool`: only an explicit `true` stays on;
        // everything else, including the inherit/`.followGlobal` states
        // and a missing key, is off (the global defaulted off anyway).
        if let explicit = try c.decodeIfPresent(Bool.self, forKey: .generativeGreetingsEnabled) {
            generativeGreetingsEnabled = explicit
        } else if let legacy = try c.decodeIfPresent(
            GenerativeGreetingsPreference.self,
            forKey: .generativeGreetings
        ) {
            switch legacy {
            case .enabled: generativeGreetingsEnabled = true
            case .disabled, .followGlobal: generativeGreetingsEnabled = false
            }
        } else {
            generativeGreetingsEnabled = false
        }
        greetingPersona = try c.decodeIfPresent(String.self, forKey: .greetingPersona)
        renderChartEnabled = try c.decodeIfPresent(Bool.self, forKey: .renderChartEnabled) ?? false
        speakEnabled = try c.decodeIfPresent(Bool.self, forKey: .speakEnabled) ?? false
        searchMemoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .searchMemoryEnabled) ?? false
        // Default off (consistent with the other built-in tool gates). Existing
        // agents that relied on self-scheduling must re-enable it explicitly.
        selfSchedulingEnabled = try c.decodeIfPresent(Bool.self, forKey: .selfSchedulingEnabled) ?? false
        // Default off; back-compat for agents that predate the feature.
        computerUseEnabled = try c.decodeIfPresent(Bool.self, forKey: .computerUseEnabled) ?? false
        // Default true so an agent with Computer Use on gets ambient screen
        // context unless explicitly turned off. Older agent JSON predates the
        // flag (the feature was global), so missing decodes to on.
        screenContextEnabled = try c.decodeIfPresent(Bool.self, forKey: .screenContextEnabled) ?? true
        spawnDelegationEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .spawnDelegationEnabled) ?? false
        // Default off; spawn/image delegation is pre-release so there is no
        // legacy shape to migrate (image was previously gated by the shared
        // spawn flag, which stays the spawn-only enable now).
        imageEnabled = try c.decodeIfPresent(Bool.self, forKey: .imageEnabled) ?? false
        // Per-agent AppleScript opt-in + model / execution-mode. Default off and
        // the safe `confirmEach`; the enum uses `try?` so a renamed/invalid raw
        // value falls back to the default instead of failing the whole decode.
        appleScriptEnabled = try c.decodeIfPresent(Bool.self, forKey: .appleScriptEnabled) ?? false
        appleScriptModelId = try c.decodeIfPresent(String.self, forKey: .appleScriptModelId)
        appleScriptExecutionMode =
            (try? c.decodeIfPresent(AppleScriptExecutionMode.self, forKey: .appleScriptExecutionMode))
            ?? .default
        spawnableAgentNames =
            try c.decodeIfPresent([String].self, forKey: .spawnableAgentNames) ?? []
        // Raw model ids for `spawn_model` + their notes. Lenient (`try?`) so a
        // malformed pool/notes map never discards the rest of the settings.
        spawnableModelNames =
            (try? c.decodeIfPresent([String].self, forKey: .spawnableModelNames)) ?? []
        spawnableModelNotes =
            (try? c.decodeIfPresent([String: String].self, forKey: .spawnableModelNotes)) ?? [:]
        // Optional; absent means no ceiling (user policy applies as-is).
        computerUseCeiling = try c.decodeIfPresent(
            AutonomyCeiling.self,
            forKey: .computerUseCeiling
        )
        // Per-agent image models / permissions / budgets. All optional with safe
        // defaults; a malformed value must never discard the whole agent decode,
        // so the struct-typed fields use `try?` (the same lenient approach as
        // `SubagentConfiguration`).
        imageGenerationModelId = try c.decodeIfPresent(String.self, forKey: .imageGenerationModelId)
        imageEditModelId = try c.decodeIfPresent(String.self, forKey: .imageEditModelId)
        subagentPermissions =
            (try? c.decodeIfPresent(SubagentPermissionDefaults.self, forKey: .subagentPermissions))
            ?? SubagentPermissionDefaults()
        subagentBudgets =
            (try? c.decodeIfPresent(SubagentBudgets.self, forKey: .subagentBudgets))
            ?? SubagentBudgets()
        // Normalize on decode (trim values, drop blanks) so the per-agent stored
        // shape matches the global `SubagentConfiguration.subagentModelOverrides`
        // — a cleared picker round-trips as "no override", never an empty-string
        // model id. The lenient `try?` keeps a malformed map from discarding the
        // rest of the settings.
        subagentModelOverrides = Self.normalizedModelOverrides(
            (try? c.decodeIfPresent([String: String].self, forKey: .subagentModelOverrides)) ?? [:]
        )
        // Lenient enum decode: an invalid/renamed raw value falls back to the
        // safe text-only default instead of failing the whole agent decode.
        spawnToolAccess =
            (try? c.decodeIfPresent(SpawnToolAccess.self, forKey: .spawnToolAccess)) ?? .none
    }

    /// Trim values and drop blank entries so a cleared override (empty string)
    /// round-trips as "no override" instead of an empty-string model id. Mirrors
    /// `SubagentConfiguration.normalizedModelOverrides` so the per-agent and
    /// global stored shapes agree.
    private static func normalizedModelOverrides(_ value: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, raw) in value {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result[key] = trimmed }
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case dbEnabled
        case schedule
        case limits
        case generativeGreetingsEnabled
        case greetingPersona
        case renderChartEnabled
        case speakEnabled
        case searchMemoryEnabled
        case selfSchedulingEnabled
        case computerUseEnabled
        case computerUseCeiling
        case screenContextEnabled
        case spawnDelegationEnabled
        case imageEnabled
        case appleScriptEnabled
        case appleScriptModelId
        case appleScriptExecutionMode
        case spawnableAgentNames
        case spawnableModelNames
        case spawnableModelNotes
        case imageGenerationModelId
        case imageEditModelId
        case subagentPermissions
        case subagentBudgets
        case subagentModelOverrides
        case spawnToolAccess
        // Read-only legacy key — never encoded after migration.
        case generativeGreetings
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dbEnabled, forKey: .dbEnabled)
        try c.encode(schedule, forKey: .schedule)
        try c.encode(limits, forKey: .limits)
        try c.encode(generativeGreetingsEnabled, forKey: .generativeGreetingsEnabled)
        try c.encodeIfPresent(greetingPersona, forKey: .greetingPersona)
        try c.encode(renderChartEnabled, forKey: .renderChartEnabled)
        try c.encode(speakEnabled, forKey: .speakEnabled)
        try c.encode(searchMemoryEnabled, forKey: .searchMemoryEnabled)
        try c.encode(selfSchedulingEnabled, forKey: .selfSchedulingEnabled)
        try c.encode(computerUseEnabled, forKey: .computerUseEnabled)
        try c.encodeIfPresent(computerUseCeiling, forKey: .computerUseCeiling)
        try c.encode(screenContextEnabled, forKey: .screenContextEnabled)
        try c.encode(spawnDelegationEnabled, forKey: .spawnDelegationEnabled)
        try c.encode(imageEnabled, forKey: .imageEnabled)
        try c.encode(appleScriptEnabled, forKey: .appleScriptEnabled)
        try c.encodeIfPresent(appleScriptModelId, forKey: .appleScriptModelId)
        try c.encode(appleScriptExecutionMode, forKey: .appleScriptExecutionMode)
        try c.encode(spawnableAgentNames, forKey: .spawnableAgentNames)
        try c.encode(spawnableModelNames, forKey: .spawnableModelNames)
        try c.encode(spawnableModelNotes, forKey: .spawnableModelNotes)
        try c.encodeIfPresent(imageGenerationModelId, forKey: .imageGenerationModelId)
        try c.encodeIfPresent(imageEditModelId, forKey: .imageEditModelId)
        try c.encode(subagentPermissions, forKey: .subagentPermissions)
        try c.encode(subagentBudgets, forKey: .subagentBudgets)
        try c.encode(subagentModelOverrides, forKey: .subagentModelOverrides)
        try c.encode(spawnToolAccess, forKey: .spawnToolAccess)
    }

    /// Default settings for newly created agents (and for back-compat decoding of
    /// older Agent JSON files that predate this field).
    public static var defaultDisabled: AgentSettings {
        AgentSettings(
            dbEnabled: false,
            schedule: AgentScheduleSettings.defaults(for: .ambient),
            limits: .defaults,
            generativeGreetingsEnabled: false,
            greetingPersona: nil,
            renderChartEnabled: false,
            speakEnabled: false,
            searchMemoryEnabled: false,
            selfSchedulingEnabled: false,
            computerUseEnabled: false,
            screenContextEnabled: true
        )
    }
}

// MARK: - Generative Greetings Helpers

extension Agent {
    /// Whether generative greetings should run for this agent. The
    /// per-agent flag is the sole control — there is no global
    /// inheritance.
    public var shouldUseGenerativeGreetings: Bool {
        settings.generativeGreetingsEnabled
    }
}
