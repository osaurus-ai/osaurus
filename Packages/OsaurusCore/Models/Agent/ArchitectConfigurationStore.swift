//
//  ArchitectConfigurationStore.swift
//  osaurus
//
//  The Architect's user settings at `~/.osaurus/config/architect.json`:
//  its name, avatar, extra instructions, and model (Settings → Architect).
//  Its built-in persona and tool surface stay fixed; the extra
//  instructions are appended after the persona.
//

import Foundation

public struct ArchitectConfiguration: Codable, Equatable, Sendable {
    /// Model id. Nil uses the Default agent's model.
    public var model: String?

    /// Picker choices use the same settings owner as the Architect model.
    public var runtime: AgentRuntime?
    public var claudeCode: ClaudeCodeAgentConfig?

    /// Custom display name. Nil or blank renders "Architect".
    public var displayName: String?

    /// Mascot id (`AgentMascot`). Nil renders the stock blue dino.
    public var avatar: String?

    /// Custom avatar image under `agents/avatars/`; wins over `avatar`.
    public var customAvatarFilename: String?

    /// Extra instructions appended after the built-in Architect persona.
    public var systemPrompt: String

    public init(
        model: String? = nil,
        runtime: AgentRuntime? = nil,
        claudeCode: ClaudeCodeAgentConfig? = nil,
        displayName: String? = nil,
        avatar: String? = nil,
        customAvatarFilename: String? = nil,
        systemPrompt: String = ""
    ) {
        self.model = model
        self.runtime = runtime
        self.claudeCode = claudeCode
        self.displayName = displayName
        self.avatar = avatar
        self.customAvatarFilename = customAvatarFilename
        self.systemPrompt = systemPrompt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        runtime = try c.decodeIfPresent(AgentRuntime.self, forKey: .runtime)
        claudeCode = try c.decodeIfPresent(ClaudeCodeAgentConfig.self, forKey: .claudeCode)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        customAvatarFilename = try c.decodeIfPresent(String.self, forKey: .customAvatarFilename)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
    }

    /// The trimmed custom name, or nil when the stock name applies.
    public var resolvedDisplayName: String? {
        guard let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return nil }
        return name
    }

    /// Building a workflow takes dozens of tool calls, more than the
    /// chat-wide Max Tool Attempts is sized for. The Architect never gets
    /// fewer than this, and a higher user setting still wins.
    public static let stepBudget = 80

    static func maxToolAttempts(agentId: UUID?, configured: Int) -> Int {
        agentId == Agent.architectId ? max(configured, stepBudget) : configured
    }

    /// What the Architect's chat shows when even its budget runs out, with
    /// a Continue suggestion under it.
    static let pausedMessage =
        "I paused to check in after a long stretch of building. The draft so far is saved in the panel on the right. Press Continue and I'll pick up where I left off."

    /// Replaces the chat-wide output-limit notice, which points at a Max
    /// Tokens setting the Architect doesn't have. Also gets a Continue
    /// suggestion.
    static let outputLimitMessage =
        "I ran out of room for this reply before I finished the step. Anything already drafted is kept in the panel on the right. Press Continue and I'll pick up from there."
}

@MainActor
public enum ArchitectConfigurationStore {
    /// Test seam, like `DefaultAgentConfigurationStore.overrideDirectory`.
    public static var overrideDirectory: URL?

    private static var cached: ArchitectConfiguration?

    public static func load() -> ArchitectConfiguration {
        if let cached { return cached }
        let loaded = loadFromDisk()
        cached = loaded
        mirrorIdentity(loaded)
        return loaded
    }

    public static func save(_ configuration: ArchitectConfiguration) {
        cached = configuration
        mirrorIdentity(configuration)
        do {
            let url = fileURL()
            try OsaurusPaths.ensureExists(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: .atomic)
        } catch {
            print("[Osaurus] Failed to save architect.json: \(error)")
        }
        NotificationCenter.default.post(name: .appConfigurationChanged, object: nil)
        NotificationCenter.default.post(name: .agentUpdated, object: Agent.architectId)
    }

    /// Load-modify-write, so each settings control only touches its field.
    public static func update(_ change: (inout ArchitectConfiguration) -> Void) {
        var configuration = load()
        change(&configuration)
        save(configuration)
    }

    public static func resetCacheForTests() {
        cached = nil
        mirrorIdentity(ArchitectConfiguration())
    }

    /// `Agent.architect` is a value built on demand from any context, so
    /// the identity fields it renders live in nonisolated statics.
    private static func mirrorIdentity(_ configuration: ArchitectConfiguration) {
        Agent.architectNameOverride = configuration.resolvedDisplayName
        Agent.architectAvatarOverride = configuration.avatar
        Agent.architectCustomAvatarFilename = configuration.customAvatarFilename
    }

    private static func fileURL() -> URL {
        (overrideDirectory ?? OsaurusPaths.config()).appendingPathComponent("architect.json")
    }

    private static func loadFromDisk() -> ArchitectConfiguration {
        guard let data = try? Data(contentsOf: fileURL()),
            let decoded = try? JSONDecoder().decode(ArchitectConfiguration.self, from: data)
        else { return ArchitectConfiguration() }
        return decoded
    }
}
