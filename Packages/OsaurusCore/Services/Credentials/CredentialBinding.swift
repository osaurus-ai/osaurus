//
//  CredentialBinding.swift
//  osaurus
//
//  Consumer slots and credential key naming. A slot is one place that needs
//  a value (an MCP server's env var, a plugin's declared secret, a workflow
//  key, a channel token). Each slot is filled by a credential key: its
//  sidecar binding when set, otherwise its default key.
//

import Foundation

/// Credential key rules and default-key suggestions.
public enum CredentialKeys {
    /// `[A-Za-z_][A-Za-z0-9_]*` — usable as an environment variable name.
    /// Suggested keys are upper case; lower case is accepted because agents
    /// and workflow templates already use names like `crm_token`.
    public static func isValid(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, key.unicodeScalars.count <= 128 else { return false }
        func isLetter(_ s: Unicode.Scalar) -> Bool { ("A"..."Z").contains(s) || ("a"..."z").contains(s) }
        guard first == "_" || isLetter(first) else { return false }
        return key.unicodeScalars.allSatisfy { $0 == "_" || isLetter($0) || ("0"..."9").contains($0) }
    }

    /// `[A-Z_][A-Z0-9_]*`: already reads as a shared env var name, so a
    /// consumer's own name is used as the key unchanged. Anything else
    /// (`api_key`, `X-Api-Key`) gets an owner prefix.
    public static func isConventional(_ key: String) -> Bool {
        isValid(key) && !key.unicodeScalars.contains { ("a"..."z").contains($0) }
    }

    /// Upper-snake-case form of arbitrary text (`"X-Api-Key"` → `X_API_KEY`).
    public static func normalize(_ raw: String) -> String {
        var out = ""
        var lastWasUnderscore = false
        for scalar in raw.uppercased().unicodeScalars {
            let isAlnum = ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
            if isAlnum {
                out.unicodeScalars.append(scalar)
                lastWasUnderscore = false
            } else if !lastWasUnderscore, !out.isEmpty {
                out.append("_")
                lastWasUnderscore = true
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        if out.isEmpty { return "KEY" }
        if let first = out.unicodeScalars.first, ("0"..."9").contains(first) { out = "_" + out }
        return out
    }

    /// Joins an owner prefix and a name without doubling the prefix
    /// (`GITHUB` + `GITHUB_TOKEN` stays `GITHUB_TOKEN`).
    public static func prefixed(_ owner: String, _ name: String) -> String {
        let owner = normalize(owner)
        let name = normalize(name)
        if name == owner || name.hasPrefix(owner + "_") { return name }
        return "\(owner)_\(name)"
    }

    /// `osaurus.tavily` → `TAVILY`; `com.acme.weather-tools` → `WEATHER_TOOLS`.
    public static func pluginOwner(_ pluginId: String) -> String {
        let last = pluginId.split(separator: ".").last.map(String.init) ?? pluginId
        return normalize(last)
    }
}

/// One consumer slot.
public struct CredentialSlot: Hashable, Sendable, Identifiable {
    /// Stable binding id (`mcp:<uuid>:env:NAME`, `plugin:<id>:<spec>`, ...).
    public let id: String
    /// Key used when no binding exists.
    public let defaultKey: String
    /// Human label of the consumer ("GitHub server", "Slack").
    public let consumer: String
    /// What the slot is called inside that consumer (env var, header, field).
    public let field: String
    public let kind: CredentialKind
    public let required: Bool
    /// Where the user configures the consumer, for "Missing keys" rows.
    public let category: CredentialConsumerCategory

    public init(
        id: String, defaultKey: String, consumer: String, field: String,
        kind: CredentialKind = .secret, required: Bool = true, category: CredentialConsumerCategory
    ) {
        self.id = id
        self.defaultKey = defaultKey
        self.consumer = consumer
        self.field = field
        self.kind = kind
        self.required = required
        self.category = category
    }

    /// The key that fills this slot right now.
    public func effectiveKey(in store: CredentialStore = .current) -> String {
        store.boundKey(for: id) ?? defaultKey
    }
}

public enum CredentialConsumerCategory: String, Sendable, Hashable {
    case mcp, plugin, channel, workflow

    public var label: String {
        switch self {
        case .mcp: return "MCP server"
        case .plugin: return "Plugin"
        case .channel: return "Channel"
        case .workflow: return "Workflow"
        }
    }
}

// MARK: - Slot writes

extension CredentialStore {
    /// A key for `slot` that is free or already holds `value`: the slot's
    /// own key, else `<OWNER>_<KEY>`, else that with `_2`, `_3`, ...
    func nonConflictingKey(for slot: CredentialSlot, value: String, owner: String) -> String {
        let base = slot.effectiveKey(in: self)
        func fits(_ key: String) -> Bool {
            guard let existing = record(key, scope: .global) else { return true }
            return existing.kind == .variable
                ? existing.variableValue == value
                : self.value(key, scope: .global) == value
        }
        if fits(base) { return base }
        let prefixed = CredentialKeys.prefixed(owner, base)
        if fits(prefixed) { return prefixed }
        var n = 2
        while !fits("\(prefixed)_\(n)") { n += 1 }
        return "\(prefixed)_\(n)"
    }

    /// Saves `value` for all agents into the key that fills `slot`.
    /// - `separateOnConflict`: a slot with no binding whose key already
    ///   holds a different value gets its own key instead of overwriting
    ///   the shared one (imports and installers, where nobody chose to share).
    /// - `pin`: record the binding even when it equals the suggested key, so
    ///   a consumer rename that changes the suggestion keeps the value.
    @discardableResult
    func save(
        _ value: String, for slot: CredentialSlot, owner: String, origin: CredentialOrigin,
        kind: CredentialKind? = nil, separateOnConflict: Bool = false, pin: Bool = false
    ) -> (outcome: CredentialWriteOutcome, key: String) {
        let key =
            separateOnConflict && boundKey(for: slot.id) == nil
            ? nonConflictingKey(for: slot, value: value, owner: owner)
            : slot.effectiveKey(in: self)
        let outcome = save(key, scope: .global, value: value, kind: kind ?? slot.kind, origin: origin)
        if outcome.isSuccess {
            if pin, boundKey(for: slot.id) != key {
                setBinding(slot: slot.id, key: key)
            } else if key != slot.effectiveKey(in: self) {
                setBinding(slot: slot.id, key: key, defaultKey: slot.defaultKey)
            }
        }
        return (outcome, key)
    }
}

// MARK: - Slot builders

extension CredentialSlot {
    public static func mcpEnv(providerId: UUID, providerName: String, name: String) -> CredentialSlot {
        CredentialSlot(
            id: "mcp:\(providerId.uuidString.lowercased()):env:\(name)",
            defaultKey: CredentialKeys.isConventional(name) ? name : CredentialKeys.prefixed(providerName, name),
            consumer: providerName, field: name, category: .mcp)
    }

    public static func mcpHeader(providerId: UUID, providerName: String, header: String) -> CredentialSlot {
        CredentialSlot(
            id: "mcp:\(providerId.uuidString.lowercased()):header:\(header)",
            defaultKey: CredentialKeys.prefixed(providerName, header),
            consumer: providerName, field: header, category: .mcp)
    }

    public static func mcpToken(providerId: UUID, providerName: String) -> CredentialSlot {
        CredentialSlot(
            id: "mcp:\(providerId.uuidString.lowercased()):token",
            defaultKey: CredentialKeys.prefixed(providerName, "TOKEN"),
            consumer: providerName, field: "Bearer token", required: false, category: .mcp)
    }

    /// A plain (non-secret) env var or header. Only used when the user
    /// explicitly binds it to a variable; the `mcp.json` value is the fallback.
    public static func mcpPlain(providerId: UUID, providerName: String, kind: String, name: String) -> CredentialSlot {
        CredentialSlot(
            id: "mcp:\(providerId.uuidString.lowercased()):\(kind)-plain:\(name)",
            defaultKey: CredentialKeys.isConventional(name) ? name : CredentialKeys.prefixed(providerName, name),
            consumer: providerName, field: name, kind: .variable, required: false, category: .mcp)
    }

    public static func plugin(pluginId: String, pluginName: String, specId: String, required: Bool = true)
        -> CredentialSlot
    {
        CredentialSlot(
            id: "plugin:\(pluginId):\(specId)",
            defaultKey: CredentialKeys.isConventional(specId)
                ? specId : CredentialKeys.prefixed(CredentialKeys.pluginOwner(pluginId), specId),
            consumer: pluginName, field: specId, required: required, category: .plugin)
    }

    public static func channel(_ channel: String, field: String, defaultKey: String, consumer: String)
        -> CredentialSlot
    {
        CredentialSlot(
            id: "channel:\(channel):\(field)", defaultKey: defaultKey, consumer: consumer, field: field,
            category: .channel)
    }

    public static func workflow(installId: UUID, workflowName: String, key: String) -> CredentialSlot {
        CredentialSlot(
            id: "workflow:\(installId.uuidString.lowercased()):\(key)",
            defaultKey: CredentialKeys.isConventional(key) ? key : CredentialKeys.normalize(key),
            consumer: workflowName, field: key, category: .workflow)
    }
}

// MARK: - Channel slots

public enum ChannelCredentialSlots {
    public static let slackBotToken = CredentialSlot.channel(
        "slack", field: "bot_token", defaultKey: "SLACK_BOT_TOKEN", consumer: "Slack")
    public static let slackSigningSecret = CredentialSlot.channel(
        "slack", field: "signing_secret", defaultKey: "SLACK_SIGNING_SECRET", consumer: "Slack")
    public static let slackAppToken = CredentialSlot.channel(
        "slack", field: "app_token", defaultKey: "SLACK_APP_TOKEN", consumer: "Slack")
    public static let discordBotToken = CredentialSlot.channel(
        "discord", field: "bot_token", defaultKey: "DISCORD_BOT_TOKEN", consumer: "Discord")
    public static let telegramBotToken = CredentialSlot.channel(
        "telegram", field: "bot_token", defaultKey: "TELEGRAM_BOT_TOKEN", consumer: "Telegram")

    /// Per-workspace Slack copies (`bot_token.workspace.<team>`).
    public static func slackWorkspace(_ field: String, teamId: String) -> CredentialSlot {
        let base = field == "app_token" ? "SLACK_APP_TOKEN" : "SLACK_BOT_TOKEN"
        return CredentialSlot.channel(
            "slack", field: "\(field).workspace.\(teamId)",
            defaultKey: "\(base)_\(CredentialKeys.normalize(teamId))", consumer: "Slack (\(teamId))")
    }

    /// A secret of a custom JSON / n8n agent channel connection.
    public static func agentChannel(connectionId: String, connectionName: String, secretName: String)
        -> CredentialSlot
    {
        CredentialSlot.channel(
            "agent-channel.\(connectionId)", field: secretName,
            defaultKey: CredentialKeys.prefixed(connectionId, secretName),
            consumer: connectionName.isEmpty ? connectionId : connectionName)
    }
}
