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
    /// When true, no tools or preflight context are sent for this agent
    public var disableTools: Bool?
    /// When true, memory is neither injected into prompts nor recorded for this agent
    public var disableMemory: Bool?
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
        disableTools: Bool? = nil,
        disableMemory: Bool? = nil,
        avatar: String? = nil,
        customAvatarFilename: String? = nil,
        autoSpeak: Bool? = nil,
        ttsVoice: String? = nil,
        settings: AgentSettings = .defaultDisabled,
        order: Int? = nil
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
        self.disableTools = disableTools
        self.disableMemory = disableMemory
        self.avatar = avatar
        self.customAvatarFilename = customAvatarFilename
        self.autoSpeak = autoSpeak
        self.ttsVoice = ttsVoice
        self.settings = settings
        self.order = order
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
    /// The default agent operates in read-only memory mode.
    public static func isDefaultAgentId(_ id: String) -> Bool {
        id == defaultId.uuidString
    }

    /// The default agent - uses global settings
    public static var `default`: Agent {
        Agent(
            id: defaultId,
            name: "Default",
            description: "Uses your global chat settings",
            systemPrompt: "",
            themeId: nil,
            defaultModel: nil,
            temperature: nil,
            maxTokens: nil,
            isBuiltIn: true,
            createdAt: Date.distantPast,
            updatedAt: Date.distantPast
        )
    }

    /// All built-in agents
    public static var builtInAgents: [Agent] {
        [.default]
    }
}

// MARK: - Decodable Migration

extension Agent {
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
        disableTools = try c.decodeIfPresent(Bool.self, forKey: .disableTools)
        disableMemory = try c.decodeIfPresent(Bool.self, forKey: .disableMemory)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        customAvatarFilename = try c.decodeIfPresent(String.self, forKey: .customAvatarFilename)
        autoSpeak = try c.decodeIfPresent(Bool.self, forKey: .autoSpeak)
        ttsVoice = try c.decodeIfPresent(String.self, forKey: .ttsVoice)
        settings = try c.decodeIfPresent(AgentSettings.self, forKey: .settings) ?? .defaultDisabled
        order = try c.decodeIfPresent(Int.self, forKey: .order)
    }
}

// MARK: - Autonomous Exec Configuration

public struct AutonomousExecConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var maxCommandsPerTurn: Int
    public var commandTimeout: Int
    public var pluginCreate: Bool

    public static let `default` = AutonomousExecConfig(
        enabled: false,
        maxCommandsPerTurn: 10,
        commandTimeout: 30,
        pluginCreate: true
    )

    public init(
        enabled: Bool = false,
        maxCommandsPerTurn: Int = 10,
        commandTimeout: Int = 30,
        pluginCreate: Bool = true
    ) {
        self.enabled = enabled
        self.maxCommandsPerTurn = maxCommandsPerTurn
        self.commandTimeout = commandTimeout
        self.pluginCreate = pluginCreate
    }
}

// Persona-as-JSON export/import was removed: the share-deeplink flow
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
    /// Per-agent on/off for the generative greetings feature.
    /// `nil` defers to the global master switch on
    /// `ChatConfiguration.generativeGreetingsEnabled` (opt-in,
    /// default off). Explicit `true`/`false` always wins over the
    /// global flag — see `Agent.shouldUseGenerativeGreetings`.
    public var generativeGreetingsEnabled: Bool?
    /// Per-agent override for the empty-state greeting voice. `nil` (or
    /// an empty string after trimming) inherits the global persona from
    /// `ChatConfiguration.greetingPersona`; both empty falls back to the
    /// built-in playful default in `GenerativeGreetingService`.
    public var greetingPersona: String?

    public init(
        dbEnabled: Bool,
        schedule: AgentScheduleSettings,
        limits: AgentLimitsSettings = .defaults,
        generativeGreetingsEnabled: Bool? = nil,
        greetingPersona: String? = nil
    ) {
        self.dbEnabled = dbEnabled
        self.schedule = schedule
        self.limits = limits
        self.generativeGreetingsEnabled = generativeGreetingsEnabled
        self.greetingPersona = greetingPersona
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dbEnabled = try c.decodeIfPresent(Bool.self, forKey: .dbEnabled) ?? false
        schedule =
            try c.decodeIfPresent(AgentScheduleSettings.self, forKey: .schedule)
            ?? AgentScheduleSettings.defaults(for: .ambient)
        limits = try c.decodeIfPresent(AgentLimitsSettings.self, forKey: .limits) ?? .defaults
        // Backward compat: prior versions stored a tri-state enum under
        // `generativeGreetings`. Map it onto the new `Bool?` shape so
        // upgrade installs don't lose their explicit on/off choice. The
        // new `generativeGreetingsEnabled` key wins when both are
        // present (which only happens during the first save after
        // upgrade).
        if let explicit = try c.decodeIfPresent(Bool.self, forKey: .generativeGreetingsEnabled) {
            generativeGreetingsEnabled = explicit
        } else if let legacy = try c.decodeIfPresent(
            GenerativeGreetingsPreference.self,
            forKey: .generativeGreetings
        ) {
            switch legacy {
            case .enabled: generativeGreetingsEnabled = true
            case .disabled: generativeGreetingsEnabled = false
            case .followGlobal: generativeGreetingsEnabled = nil
            }
        } else {
            generativeGreetingsEnabled = nil
        }
        greetingPersona = try c.decodeIfPresent(String.self, forKey: .greetingPersona)
    }

    private enum CodingKeys: String, CodingKey {
        case dbEnabled
        case schedule
        case limits
        case generativeGreetingsEnabled
        case greetingPersona
        // Read-only legacy key — never encoded after migration.
        case generativeGreetings
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dbEnabled, forKey: .dbEnabled)
        try c.encode(schedule, forKey: .schedule)
        try c.encode(limits, forKey: .limits)
        try c.encodeIfPresent(generativeGreetingsEnabled, forKey: .generativeGreetingsEnabled)
        try c.encodeIfPresent(greetingPersona, forKey: .greetingPersona)
    }

    /// Default settings for newly created agents (and for back-compat decoding of
    /// older Agent JSON files that predate this field).
    public static var defaultDisabled: AgentSettings {
        AgentSettings(
            dbEnabled: false,
            schedule: AgentScheduleSettings.defaults(for: .ambient),
            limits: .defaults,
            generativeGreetingsEnabled: nil,
            greetingPersona: nil
        )
    }
}

// MARK: - Generative Greetings Helpers

extension Agent {
    /// Resolves whether generative greetings should run for this agent.
    /// Explicit per-agent on/off always wins; otherwise the value falls
    /// through to the global master switch on `ChatConfiguration`. Pass
    /// `globallyEnabled: AppConfiguration.shared.chatConfig.generativeGreetingsEnabled`
    /// at the call site.
    public func shouldUseGenerativeGreetings(globallyEnabled: Bool) -> Bool {
        settings.generativeGreetingsEnabled ?? globallyEnabled
    }
}
