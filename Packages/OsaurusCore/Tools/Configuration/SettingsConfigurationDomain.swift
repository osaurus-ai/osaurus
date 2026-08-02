//
//  SettingsConfigurationDomain.swift
//  osaurus
//
//  Default-agent configure tool for general Osaurus settings. One tool,
//  `osaurus_settings`, with two actions across six scopes:
//   - get — current values for a scope (secrets never included)
//   - set — apply a partial `settings` object to a scope
//
//  Scopes and their backing stores:
//   - server        — `VMLXServerRuntimeSettings` via
//                     `ServerController.applyRuntimeSettingsFromConfigureTool`
//                     (restart-aware: port/expose changes restart the NIO
//                     socket; cache changes unload loaded models — effects
//                     are reported in the result, mirroring the
//                     `/admin/runtime-settings` PUT contract)
//   - default_agent — `DefaultAgentConfigurationStore`
//                     (`~/.osaurus/config/default-agent.json`)
//   - chat          — `AppConfiguration` / `chat.json` globals, including
//                     the Core Model (memory distillation / cleanup model)
//                     and the global disable-tools switch
//   - app           — app shell: start at login, dock icon, appearance
//   - memory        — `MemoryConfigurationStore` (`memory.json`)
//   - voice         — `SpeechConfigurationStore` (voice input) +
//                     `TTSConfigurationStore` (speech output)
//
//  Deliberately out of scope (Settings UI only, by design — security- or
//  risk-bearing): auto-allow-all tool approvals, telemetry / crash-report
//  toggles, identity / pairing keys, storage encryption, channel
//  credentials, the privacy filter, global hotkeys, subagent delegation
//  budgets, computer/browser-use autonomy ceilings, and the full
//  server-runtime surface (memory safety profiles, MTP, multimodal,
//  codecs). The tool description states this so the agent explains the
//  boundary instead of fumbling.
//

import Foundation

enum SettingsConfigurationDomain {
    static let domain = ConfigurationDomain(
        id: "settings",
        displayName: "App & Server Settings",
        summary:
            "Change general Osaurus settings: server (port, generation defaults, cache, concurrency), the default agent's model/persona, chat (incl. core model), app shell, memory, and voice/TTS.",
        menuHint: "get / set server, default-agent, chat, app, memory, or voice settings",
        searchKeywords: [
            "settings", "preferences", "configure", "server port", "expose to network",
            "temperature", "top p", "top k", "max tokens", "generation defaults",
            "continuous batching", "concurrency", "prefix cache", "paged kv", "disk cache",
            "default agent model", "system prompt", "persona",
            "start at login", "dock icon", "appearance", "dark mode", "light mode",
            "memory enabled", "memory budget", "clipboard monitoring", "chat titles",
            "core model", "disable tools", "voice input", "text to speech", "tts",
            "speech", "voice output",
        ],
        exampleQueries: [
            "change the server port to 8080",
            "set the default agent's model",
            "turn on dark mode",
            "disable memory",
            "make osaurus start at login",
            "lower the default temperature",
            "change the core model",
            "enable voice input",
            "turn off text to speech",
        ],
        tools: [
            OsaurusSettingsTool()
        ],
        writeToolNames: [
            "osaurus_settings"
        ]
    )
}

// MARK: - osaurus_settings

public final class OsaurusSettingsTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_settings"
    // The first sentence must stay ≤180 chars and carry the scope routing:
    // the Default agent's compact bootstrap schema keeps only that sentence
    // (see SystemPromptComposer.oneLineToolDescription).
    public let description =
        "Read ('get') or set app settings by scope: server, default_agent, chat (incl. core_model "
        + "for memory/background work + disable_tools), app, memory, voice. "
        + "`action`: get (needs `scope`), set (needs `scope` + "
        + "`settings` object with only the keys to change; JSON null clears an optional override). "
        + "Scopes and keys — "
        + "server: port, expose_to_network, default_temperature, default_top_p, default_top_k, "
        + "default_max_tokens, continuous_batching, max_concurrent_sequences, prefix_cache_enabled, "
        + "paged_kv_enabled, disk_cache_enabled (port/expose changes restart the server; cache changes "
        + "unload loaded models — effects are reported). "
        + "default_agent: model, temperature, max_tokens, system_prompt (your own settings). "
        + "chat: top_p, max_tool_attempts, context_length, warm_models_on_load, "
        + "auto_generate_chat_titles, clipboard_monitoring, core_model (the model used for memory "
        + "distillation and background work — NOT the default agent's chat model; e.g. 'foundation' "
        + "or 'provider/model'; null clears), disable_tools (global: no tools sent to any model). "
        + "app: start_at_login, hide_dock_icon (app restart required), appearance (system|light|dark). "
        + "memory: enabled, budget_tokens, retention_days. "
        + "voice: voice_input_enabled, tts_enabled, tts_engine (pocket_tts|openai_compatible). "
        + "Not settable here (Settings UI only): tool auto-approval, telemetry/crash toggles, "
        + "identity/pairing keys, storage encryption, channel credentials, privacy filter, hotkeys, "
        + "delegation budgets, autonomy ceilings — explain that these need Settings, don't guess."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([.string("get"), .string("set")]),
                "description": .string("Operation to perform."),
            ]),
            "scope": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("server"), .string("default_agent"), .string("chat"),
                    .string("app"), .string("memory"), .string("voice"),
                ]),
                "description": .string("Settings scope."),
            ]),
            "settings": .object([
                "type": .string("object"),
                "additionalProperties": .bool(true),
                "description": .string(
                    "For set: only the keys to change (see the tool description for each scope's keys). "
                        + "JSON null clears an optional override."
                ),
            ]),
        ]),
        "required": .array([.string("action"), .string("scope")]),
    ])

    public var requirements: [String] { [ConfigurationToolBase.requirement] }
    var defaultPermissionPolicy: ToolPermissionPolicy { ConfigurationToolBase.defaultPolicy }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let actionReq = requireAction(args, allowed: ["get", "set"])
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }
        let scopeReq = requireString(args, "scope", expected: "settings scope", tool: name)
        guard case .value(let scope) = scopeReq else { return scopeReq.failureEnvelope ?? "" }
        guard Self.validScopes.contains(scope) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Unknown scope `\(scope)`. Valid: \(Self.validScopes.sorted().joined(separator: ", ")).",
                field: "scope",
                tool: name
            )
        }

        if action == "get" {
            return await handleGet(scope: scope)
        }

        guard let settings = args["settings"] as? [String: Any], !settings.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`set` needs a non-empty `settings` object with the keys to change.",
                field: "settings",
                tool: name
            )
        }
        if let unknown = Self.firstUnknownKey(settings, scope: scope) {
            let valid = Self.knownKeys[scope, default: []].sorted().joined(separator: ", ")
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Unknown `\(scope)` setting `\(unknown)`. Valid keys: \(valid).",
                field: "settings",
                tool: name
            )
        }

        switch scope {
        case "server": return await handleServerSet(settings)
        case "default_agent": return await handleDefaultAgentSet(settings)
        case "chat": return await handleChatSet(settings)
        case "app": return await handleAppSet(settings)
        case "memory": return await handleMemorySet(settings)
        case "voice": return await handleVoiceSet(settings)
        default: return "" // unreachable — scope validated above
        }
    }

    // MARK: - Key registry

    private static let validScopes: Set<String> = [
        "server", "default_agent", "chat", "app", "memory", "voice",
    ]

    private static let knownKeys: [String: Set<String>] = [
        "server": [
            "port", "expose_to_network",
            "default_temperature", "default_top_p", "default_top_k", "default_max_tokens",
            "continuous_batching", "max_concurrent_sequences",
            "prefix_cache_enabled", "paged_kv_enabled", "disk_cache_enabled",
        ],
        "default_agent": [
            "model", "temperature", "max_tokens", "system_prompt",
        ],
        "chat": [
            "top_p", "max_tool_attempts", "context_length",
            "warm_models_on_load", "auto_generate_chat_titles", "clipboard_monitoring",
            "core_model", "disable_tools",
        ],
        "app": [
            "start_at_login", "hide_dock_icon", "appearance",
        ],
        "memory": [
            "enabled", "budget_tokens", "retention_days",
        ],
        "voice": [
            "voice_input_enabled", "tts_enabled", "tts_engine",
        ],
    ]

    private static func firstUnknownKey(_ settings: [String: Any], scope: String) -> String? {
        let known = knownKeys[scope, default: []]
        return settings.keys.sorted().first { !known.contains($0) }
    }

    // MARK: - Typed value helpers
    //
    // `set` payload semantics: an absent key is untouched; JSON null clears
    // an optional override. Each helper returns `.failure` with the field
    // name so the model can self-correct.

    private enum SettingValue<T: Sendable>: Sendable {
        case absent
        case clear
        case value(T)
    }

    private func boolValue(
        _ settings: [String: Any], _ key: String
    ) -> ArgumentRequirement<SettingValue<Bool>> {
        guard let raw = settings[key] else { return .value(.absent) }
        if raw is NSNull { return .value(.clear) }
        guard let b = coerceBool(raw) else {
            return .failure(invalidValueFailure(key, expected: "a boolean"))
        }
        return .value(.value(b))
    }

    private func intValue(
        _ settings: [String: Any], _ key: String, range: ClosedRange<Int>? = nil
    ) -> ArgumentRequirement<SettingValue<Int>> {
        guard let raw = settings[key] else { return .value(.absent) }
        if raw is NSNull { return .value(.clear) }
        guard let n = coerceInt(raw) else {
            return .failure(invalidValueFailure(key, expected: "an integer"))
        }
        if let range, !range.contains(n) {
            return .failure(
                invalidValueFailure(
                    key,
                    expected: "an integer in \(range.lowerBound)...\(range.upperBound)"
                )
            )
        }
        return .value(.value(n))
    }

    private func doubleValue(
        _ settings: [String: Any], _ key: String, range: ClosedRange<Double>? = nil
    ) -> ArgumentRequirement<SettingValue<Double>> {
        guard let raw = settings[key] else { return .value(.absent) }
        if raw is NSNull { return .value(.clear) }
        let parsed: Double?
        switch raw {
        case let n as NSNumber: parsed = n.doubleValue
        case let s as String: parsed = Double(s)
        default: parsed = nil
        }
        guard let d = parsed else {
            return .failure(invalidValueFailure(key, expected: "a number"))
        }
        if let range, !range.contains(d) {
            return .failure(
                invalidValueFailure(
                    key,
                    expected: "a number in \(range.lowerBound)...\(range.upperBound)"
                )
            )
        }
        return .value(.value(d))
    }

    private func stringValue(
        _ settings: [String: Any], _ key: String
    ) -> ArgumentRequirement<SettingValue<String>> {
        guard let raw = settings[key] else { return .value(.absent) }
        if raw is NSNull { return .value(.clear) }
        guard let s = raw as? String else {
            return .failure(invalidValueFailure(key, expected: "a string"))
        }
        return .value(.value(s))
    }

    private func invalidValueFailure(_ key: String, expected: String) -> String {
        ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "`\(key)` must be \(expected).",
            field: key,
            expected: expected,
            tool: name
        )
    }

    // MARK: - get

    private func handleGet(scope: String) async -> String {
        let toolName = name
        return await MainActor.run {
            let payload: [String: Any]
            switch scope {
            case "server":
                let (settings, isRunning) = ServerController.runtimeSettingsForConfigureTool()
                payload = [
                    "scope": "server",
                    "server_running": isRunning,
                    "port": settings.network.port ?? ServerConfiguration.default.port,
                    "expose_to_network": settings.network.host == "0.0.0.0",
                    "default_temperature": settings.generation.temperature ?? NSNull(),
                    "default_top_p": settings.generation.topP ?? NSNull(),
                    "default_top_k": settings.generation.topK ?? NSNull(),
                    "default_max_tokens": settings.generation.maxTokens ?? NSNull(),
                    "continuous_batching": settings.concurrency.continuousBatching,
                    "max_concurrent_sequences": settings.concurrency.maxConcurrentSequences ?? NSNull(),
                    "prefix_cache_enabled": settings.cache.prefix.enabled,
                    "paged_kv_enabled": settings.cache.pagedKV.enabled,
                    "disk_cache_enabled": settings.cache.blockDisk.enabled,
                    "note":
                        "null generation defaults mean the active model bundle's own defaults apply. "
                        + "Port/expose changes restart the server; cache changes unload loaded models.",
                ]
            case "default_agent":
                let config = DefaultAgentConfigurationStore.load()
                payload = [
                    "scope": "default_agent",
                    "model": config.defaultModel ?? NSNull(),
                    "temperature": config.temperature ?? NSNull(),
                    "max_tokens": config.maxTokens ?? NSNull(),
                    "system_prompt": config.systemPrompt,
                    "tools_disabled": config.disableTools,
                    "note": "null model means the first available installed local model is used.",
                ]
            case "chat":
                let config = AppConfiguration.shared.chatConfig
                payload = [
                    "scope": "chat",
                    "top_p": config.topPOverride ?? NSNull(),
                    "max_tool_attempts": config.maxToolAttempts ?? NSNull(),
                    "context_length": config.contextLength ?? NSNull(),
                    "warm_models_on_load": config.warmModelsOnLoad,
                    "auto_generate_chat_titles": config.autoGenerateChatTitles,
                    "clipboard_monitoring": config.enableClipboardMonitoring,
                    "core_model": config.coreModelIdentifier ?? NSNull(),
                    "disable_tools": config.disableTools,
                    "note":
                        "core_model is the lightweight model for memory consolidation and "
                        + "transcription cleanup ('foundation' = Apple's on-device model on "
                        + "macOS 26+); null falls back to the active chat model.",
                ]
            case "app":
                let configuration = ServerController.appShellSettingsForConfigureTool()
                payload = [
                    "scope": "app",
                    "start_at_login": configuration.startAtLogin,
                    "hide_dock_icon": configuration.hideDockIcon,
                    "appearance": ThemeManager.shared.appearanceMode.rawValue,
                    "note": "hide_dock_icon takes effect after the app restarts.",
                ]
            case "memory":
                let config = MemoryConfigurationStore.load()
                payload = [
                    "scope": "memory",
                    "enabled": config.enabled,
                    "budget_tokens": config.memoryBudgetTokens,
                    "retention_days": config.episodeRetentionDays,
                    "note":
                        "The model that runs memory distillation is `core_model` in scope "
                        + "'chat', not here.",
                ]
            case "voice":
                let speech = SpeechConfigurationStore.load()
                let tts = TTSConfigurationStore.load()
                payload = [
                    "scope": "voice",
                    "voice_input_enabled": speech.voiceInputEnabled,
                    "tts_enabled": tts.enabled,
                    "tts_engine": Self.ttsEngineKey(for: tts.provider),
                    "note":
                        "Voices, audio devices, wake words, and remote TTS endpoints are edited in "
                        + "Settings → Voice.",
                ]
            default:
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Unknown scope `\(scope)`.",
                    field: "scope",
                    tool: toolName
                )
            }
            return ToolEnvelope.success(tool: toolName, result: payload)
        }
    }

    // MARK: - set: server

    private func handleServerSet(_ settings: [String: Any]) async -> String {
        // Validate every requested key up front so a bad value can't land a
        // half-applied settings save.
        var portChange: SettingValue<Int> = .absent
        switch intValue(settings, "port", range: 1...65535) {
        case .failure(let envelope): return envelope
        case .value(let v): portChange = v
        }
        if case .clear = portChange {
            return invalidValueFailure("port", expected: "an integer in 1...65535 (not null)")
        }
        var exposeChange: SettingValue<Bool> = .absent
        switch boolValue(settings, "expose_to_network") {
        case .failure(let envelope): return envelope
        case .value(let v): exposeChange = v
        }
        var temperatureChange: SettingValue<Double> = .absent
        switch doubleValue(settings, "default_temperature", range: 0.0...2.0) {
        case .failure(let envelope): return envelope
        case .value(let v): temperatureChange = v
        }
        var topPChange: SettingValue<Double> = .absent
        switch doubleValue(settings, "default_top_p", range: 0.0...1.0) {
        case .failure(let envelope): return envelope
        case .value(let v): topPChange = v
        }
        var topKChange: SettingValue<Int> = .absent
        switch intValue(settings, "default_top_k", range: 1...100_000) {
        case .failure(let envelope): return envelope
        case .value(let v): topKChange = v
        }
        var maxTokensChange: SettingValue<Int> = .absent
        switch intValue(settings, "default_max_tokens", range: 1...10_000_000) {
        case .failure(let envelope): return envelope
        case .value(let v): maxTokensChange = v
        }
        var continuousBatchingChange: SettingValue<Bool> = .absent
        switch boolValue(settings, "continuous_batching") {
        case .failure(let envelope): return envelope
        case .value(let v): continuousBatchingChange = v
        }
        var maxSequencesChange: SettingValue<Int> = .absent
        switch intValue(settings, "max_concurrent_sequences", range: 1...32) {
        case .failure(let envelope): return envelope
        case .value(let v): maxSequencesChange = v
        }
        var prefixCacheChange: SettingValue<Bool> = .absent
        switch boolValue(settings, "prefix_cache_enabled") {
        case .failure(let envelope): return envelope
        case .value(let v): prefixCacheChange = v
        }
        var pagedKVChange: SettingValue<Bool> = .absent
        switch boolValue(settings, "paged_kv_enabled") {
        case .failure(let envelope): return envelope
        case .value(let v): pagedKVChange = v
        }
        var diskCacheChange: SettingValue<Bool> = .absent
        switch boolValue(settings, "disk_cache_enabled") {
        case .failure(let envelope): return envelope
        case .value(let v): diskCacheChange = v
        }

        var updated = await MainActor.run {
            ServerController.runtimeSettingsForConfigureTool().settings
        }
        var changed: [String: Any] = [:]

        if case .value(let port) = portChange {
            updated.network.port = port
            changed["port"] = port
        }
        if case .value(let expose) = exposeChange {
            updated.network.host = expose ? "0.0.0.0" : "127.0.0.1"
            changed["expose_to_network"] = expose
        }
        switch temperatureChange {
        case .value(let v):
            updated.generation.temperature = v
            changed["default_temperature"] = v
        case .clear:
            updated.generation.temperature = nil
            changed["default_temperature"] = NSNull()
        case .absent: break
        }
        switch topPChange {
        case .value(let v):
            updated.generation.topP = v
            changed["default_top_p"] = v
        case .clear:
            updated.generation.topP = nil
            changed["default_top_p"] = NSNull()
        case .absent: break
        }
        switch topKChange {
        case .value(let v):
            updated.generation.topK = v
            changed["default_top_k"] = v
        case .clear:
            updated.generation.topK = nil
            changed["default_top_k"] = NSNull()
        case .absent: break
        }
        switch maxTokensChange {
        case .value(let v):
            updated.generation.maxTokens = v
            changed["default_max_tokens"] = v
        case .clear:
            updated.generation.maxTokens = nil
            changed["default_max_tokens"] = NSNull()
        case .absent: break
        }
        if case .value(let v) = continuousBatchingChange {
            updated.concurrency.continuousBatching = v
            changed["continuous_batching"] = v
        }
        switch maxSequencesChange {
        case .value(let v):
            updated.concurrency.maxConcurrentSequences = v
            changed["max_concurrent_sequences"] = v
        case .clear:
            updated.concurrency.maxConcurrentSequences = nil
            changed["max_concurrent_sequences"] = NSNull()
        case .absent: break
        }
        if case .value(let v) = prefixCacheChange {
            updated.cache.prefix.enabled = v
            changed["prefix_cache_enabled"] = v
        }
        if case .value(let v) = pagedKVChange {
            updated.cache.pagedKV.enabled = v
            changed["paged_kv_enabled"] = v
        }
        if case .value(let v) = diskCacheChange {
            updated.cache.blockDisk.enabled = v
            changed["disk_cache_enabled"] = v
        }

        guard !changed.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No `server` settings to change were provided.",
                field: "settings",
                tool: name
            )
        }

        let effects = await ServerController.applyRuntimeSettingsFromConfigureTool(updated)
        var result: [String: Any] = [
            "scope": "server",
            "status": "saved",
            "changed": changed,
        ]
        if let effects {
            result["effects"] = [
                "restarted_server": effects.restartedServer,
                "models_unloaded": effects.unloadedModelCount,
                "runtime_config_invalidated": effects.invalidatedRuntimeConfig,
            ]
        } else {
            result["note"] = "Server is not wired up yet; settings apply when it starts."
        }
        return ToolEnvelope.success(tool: name, result: result)
    }

    // MARK: - set: default_agent

    private func handleDefaultAgentSet(_ settings: [String: Any]) async -> String {
        var modelChange: SettingValue<String> = .absent
        switch stringValue(settings, "model") {
        case .failure(let envelope): return envelope
        case .value(let v): modelChange = v
        }
        var temperatureChange: SettingValue<Double> = .absent
        switch doubleValue(settings, "temperature", range: 0.0...2.0) {
        case .failure(let envelope): return envelope
        case .value(let v): temperatureChange = v
        }
        var maxTokensChange: SettingValue<Int> = .absent
        switch intValue(settings, "max_tokens", range: 1...10_000_000) {
        case .failure(let envelope): return envelope
        case .value(let v): maxTokensChange = v
        }
        var promptChange: SettingValue<String> = .absent
        switch stringValue(settings, "system_prompt") {
        case .failure(let envelope): return envelope
        case .value(let v): promptChange = v
        }

        let toolName = name
        return await MainActor.run {
            var config = DefaultAgentConfigurationStore.load()
            var changed: [String: Any] = [:]
            var notes: [String] = []

            switch modelChange {
            case .value(let model):
                let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    config.defaultModel = nil
                    changed["model"] = NSNull()
                } else {
                    let installed = ModelManager.shared.availableModels
                        .contains { $0.isDownloaded && $0.id == trimmed }
                    // Remote routes ("provider/model") resolve at request time,
                    // so only warn — never block — on an unrecognized id.
                    if !installed && !trimmed.contains("/") {
                        notes.append(
                            "`\(trimmed)` is not an installed local model — check osaurus_list({scope: 'models'})."
                        )
                    }
                    config.defaultModel = trimmed
                    changed["model"] = trimmed
                }
            case .clear:
                config.defaultModel = nil
                changed["model"] = NSNull()
            case .absent: break
            }
            switch temperatureChange {
            case .value(let v):
                config.temperature = Float(v)
                changed["temperature"] = v
            case .clear:
                config.temperature = nil
                changed["temperature"] = NSNull()
            case .absent: break
            }
            switch maxTokensChange {
            case .value(let v):
                config.maxTokens = v
                changed["max_tokens"] = v
            case .clear:
                config.maxTokens = nil
                changed["max_tokens"] = NSNull()
            case .absent: break
            }
            switch promptChange {
            case .value(let v):
                config.systemPrompt = v
                changed["system_prompt"] = v
            case .clear:
                config.systemPrompt = ""
                changed["system_prompt"] = ""
            case .absent: break
            }

            guard !changed.isEmpty else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No `default_agent` settings to change were provided.",
                    field: "settings",
                    tool: toolName
                )
            }
            DefaultAgentConfigurationStore.save(config)
            var result: [String: Any] = [
                "scope": "default_agent",
                "status": "saved",
                "changed": changed,
            ]
            if !notes.isEmpty { result["notes"] = notes }
            return ToolEnvelope.success(tool: toolName, result: result)
        }
    }

    // MARK: - set: chat

    private func handleChatSet(_ settings: [String: Any]) async -> String {
        var topPChange: SettingValue<Double> = .absent
        switch doubleValue(settings, "top_p", range: 0.0...1.0) {
        case .failure(let envelope): return envelope
        case .value(let v): topPChange = v
        }
        var attemptsChange: SettingValue<Int> = .absent
        switch intValue(settings, "max_tool_attempts", range: 1...1000) {
        case .failure(let envelope): return envelope
        case .value(let v): attemptsChange = v
        }
        var contextChange: SettingValue<Int> = .absent
        switch intValue(settings, "context_length", range: 1024...10_000_000) {
        case .failure(let envelope): return envelope
        case .value(let v): contextChange = v
        }
        var warmChange: SettingValue<Bool> = .absent
        switch boolValue(settings, "warm_models_on_load") {
        case .failure(let envelope): return envelope
        case .value(let v): warmChange = v
        }
        var titlesChange: SettingValue<Bool> = .absent
        switch boolValue(settings, "auto_generate_chat_titles") {
        case .failure(let envelope): return envelope
        case .value(let v): titlesChange = v
        }
        var clipboardChange: SettingValue<Bool> = .absent
        switch boolValue(settings, "clipboard_monitoring") {
        case .failure(let envelope): return envelope
        case .value(let v): clipboardChange = v
        }
        var coreModelChange: SettingValue<String> = .absent
        switch stringValue(settings, "core_model") {
        case .failure(let envelope): return envelope
        case .value(let v): coreModelChange = v
        }
        var disableToolsChange: SettingValue<Bool> = .absent
        switch boolValue(settings, "disable_tools") {
        case .failure(let envelope): return envelope
        case .value(let v): disableToolsChange = v
        }

        let toolName = name
        return await MainActor.run {
            var config = AppConfiguration.shared.chatConfig
            var changed: [String: Any] = [:]
            var notes: [String] = []

            switch topPChange {
            case .value(let v):
                config.topPOverride = Float(v)
                changed["top_p"] = v
            case .clear:
                config.topPOverride = nil
                changed["top_p"] = NSNull()
            case .absent: break
            }
            switch attemptsChange {
            case .value(let v):
                config.maxToolAttempts = v
                changed["max_tool_attempts"] = v
            case .clear:
                config.maxToolAttempts = nil
                changed["max_tool_attempts"] = NSNull()
            case .absent: break
            }
            switch contextChange {
            case .value(let v):
                config.contextLength = v
                changed["context_length"] = v
            case .clear:
                config.contextLength = nil
                changed["context_length"] = NSNull()
            case .absent: break
            }
            if case .value(let v) = warmChange {
                config.warmModelsOnLoad = v
                changed["warm_models_on_load"] = v
            }
            if case .value(let v) = titlesChange {
                config.autoGenerateChatTitles = v
                changed["auto_generate_chat_titles"] = v
            }
            if case .value(let v) = clipboardChange {
                config.enableClipboardMonitoring = v
                changed["clipboard_monitoring"] = v
            }
            switch coreModelChange {
            case .value(let identifier):
                // Mirrors the Settings → General picker: split on the FIRST
                // slash into provider/name; a plain name has no provider.
                let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    config.coreModelProvider = nil
                    config.coreModelName = nil
                    changed["core_model"] = NSNull()
                } else {
                    let parts = trimmed.split(separator: "/", maxSplits: 1)
                    if parts.count == 2 {
                        config.coreModelProvider = String(parts[0])
                        config.coreModelName = String(parts[1])
                    } else {
                        config.coreModelProvider = nil
                        config.coreModelName = trimmed
                    }
                    changed["core_model"] = trimmed
                }
            case .clear:
                config.coreModelProvider = nil
                config.coreModelName = nil
                changed["core_model"] = NSNull()
            case .absent: break
            }
            if changed.keys.contains("core_model") && changed["core_model"] is NSNull {
                notes.append(
                    "Clearing core_model disables the dedicated background model — memory "
                    + "consolidation and transcription cleanup fall back to the active chat model."
                )
            }
            if case .value(let v) = disableToolsChange {
                config.disableTools = v
                changed["disable_tools"] = v
                if v {
                    notes.append(
                        "disable_tools is global: NO model receives tools until it is turned back "
                        + "off — including this configuration agent on its next session."
                    )
                }
            }

            guard !changed.isEmpty else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No `chat` settings to change were provided.",
                    field: "settings",
                    tool: toolName
                )
            }
            AppConfiguration.shared.updateChatConfig(config)
            var result: [String: Any] = ["scope": "chat", "status": "saved", "changed": changed]
            if !notes.isEmpty { result["notes"] = notes }
            return ToolEnvelope.success(tool: toolName, result: result)
        }
    }

    // MARK: - set: app

    private func handleAppSet(_ settings: [String: Any]) async -> String {
        var loginChange: SettingValue<Bool> = .absent
        switch boolValue(settings, "start_at_login") {
        case .failure(let envelope): return envelope
        case .value(let v): loginChange = v
        }
        var dockChange: SettingValue<Bool> = .absent
        switch boolValue(settings, "hide_dock_icon") {
        case .failure(let envelope): return envelope
        case .value(let v): dockChange = v
        }
        var appearanceChange: SettingValue<String> = .absent
        switch stringValue(settings, "appearance") {
        case .failure(let envelope): return envelope
        case .value(let v): appearanceChange = v
        }
        var appearanceMode: AppearanceMode?
        if case .value(let raw) = appearanceChange {
            guard let mode = AppearanceMode(rawValue: raw.lowercased()) else {
                return invalidValueFailure("appearance", expected: "one of: system, light, dark")
            }
            appearanceMode = mode
        }

        let startAtLogin: Bool? = {
            if case .value(let v) = loginChange { return v }
            return nil
        }()
        let hideDockIcon: Bool? = {
            if case .value(let v) = dockChange { return v }
            return nil
        }()

        guard startAtLogin != nil || hideDockIcon != nil || appearanceMode != nil else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No `app` settings to change were provided.",
                field: "settings",
                tool: name
            )
        }

        let toolName = name
        return await MainActor.run {
            var changed: [String: Any] = [:]
            if startAtLogin != nil || hideDockIcon != nil {
                ServerController.applyAppShellSettingsFromConfigureTool(
                    startAtLogin: startAtLogin,
                    hideDockIcon: hideDockIcon
                )
                if let startAtLogin { changed["start_at_login"] = startAtLogin }
                if let hideDockIcon { changed["hide_dock_icon"] = hideDockIcon }
            }
            if let appearanceMode {
                // Mirrors the Themes pane: picking a light/dark/system mode
                // clears any active custom theme so the mode actually shows.
                ThemeManager.shared.setAppearanceMode(appearanceMode, clearActiveTheme: true)
                changed["appearance"] = appearanceMode.rawValue
            }
            var result: [String: Any] = [
                "scope": "app",
                "status": "saved",
                "changed": changed,
            ]
            if hideDockIcon != nil {
                result["note"] = "hide_dock_icon takes effect after the app restarts."
            }
            return ToolEnvelope.success(tool: toolName, result: result)
        }
    }

    // MARK: - set: memory

    private func handleMemorySet(_ settings: [String: Any]) async -> String {
        var enabledChange: SettingValue<Bool> = .absent
        switch boolValue(settings, "enabled") {
        case .failure(let envelope): return envelope
        case .value(let v): enabledChange = v
        }
        var budgetChange: SettingValue<Int> = .absent
        switch intValue(settings, "budget_tokens", range: 100...4000) {
        case .failure(let envelope): return envelope
        case .value(let v): budgetChange = v
        }
        var retentionChange: SettingValue<Int> = .absent
        switch intValue(settings, "retention_days", range: 0...3650) {
        case .failure(let envelope): return envelope
        case .value(let v): retentionChange = v
        }

        let toolName = name
        return await MainActor.run {
            var config = MemoryConfigurationStore.load()
            var changed: [String: Any] = [:]

            if case .value(let v) = enabledChange {
                config.enabled = v
                changed["enabled"] = v
            }
            if case .value(let v) = budgetChange {
                config.memoryBudgetTokens = v
                changed["budget_tokens"] = v
            }
            if case .value(let v) = retentionChange {
                config.episodeRetentionDays = v
                changed["retention_days"] = v
            }

            guard !changed.isEmpty else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No `memory` settings to change were provided.",
                    field: "settings",
                    tool: toolName
                )
            }
            MemoryConfigurationStore.save(config)
            var result: [String: Any] = [
                "scope": "memory",
                "status": "saved",
                "changed": changed,
            ]
            if case .value(0) = retentionChange {
                result["note"] = "retention_days 0 keeps episodes forever."
            }
            return ToolEnvelope.success(tool: toolName, result: result)
        }
    }

    // MARK: - set: voice

    /// Stable snake_case keys for the TTS engine, decoupled from the Swift
    /// enum raw values (`pocketTTS` / `openAICompatible`).
    private static func ttsEngineKey(for provider: TTSProvider) -> String {
        switch provider {
        case .pocketTTS: return "pocket_tts"
        case .openAICompatible: return "openai_compatible"
        }
    }

    private static func ttsProvider(forEngineKey key: String) -> TTSProvider? {
        switch key.lowercased() {
        case "pocket_tts", "pockettts", "pocket": return .pocketTTS
        case "openai_compatible", "openaicompatible", "remote": return .openAICompatible
        default: return nil
        }
    }

    private func handleVoiceSet(_ settings: [String: Any]) async -> String {
        var voiceInputChange: SettingValue<Bool> = .absent
        switch boolValue(settings, "voice_input_enabled") {
        case .failure(let envelope): return envelope
        case .value(let v): voiceInputChange = v
        }
        var ttsEnabledChange: SettingValue<Bool> = .absent
        switch boolValue(settings, "tts_enabled") {
        case .failure(let envelope): return envelope
        case .value(let v): ttsEnabledChange = v
        }
        var engineChange: SettingValue<String> = .absent
        switch stringValue(settings, "tts_engine") {
        case .failure(let envelope): return envelope
        case .value(let v): engineChange = v
        }
        var ttsProvider: TTSProvider?
        if case .value(let raw) = engineChange {
            guard let provider = Self.ttsProvider(forEngineKey: raw) else {
                return invalidValueFailure(
                    "tts_engine", expected: "one of: pocket_tts, openai_compatible"
                )
            }
            ttsProvider = provider
        }

        let toolName = name
        let engineProvider = ttsProvider
        return await MainActor.run {
            var changed: [String: Any] = [:]

            if case .value(let v) = voiceInputChange {
                var speech = SpeechConfigurationStore.load()
                speech.voiceInputEnabled = v
                SpeechConfigurationStore.save(speech)
                changed["voice_input_enabled"] = v
            }
            let ttsEnabledValue: Bool? = {
                if case .value(let v) = ttsEnabledChange { return v }
                return nil
            }()
            if ttsEnabledValue != nil || engineProvider != nil {
                var tts = TTSConfigurationStore.load()
                if let v = ttsEnabledValue {
                    tts.enabled = v
                    changed["tts_enabled"] = v
                }
                if let engineProvider {
                    tts.provider = engineProvider
                    changed["tts_engine"] = Self.ttsEngineKey(for: engineProvider)
                }
                TTSConfigurationStore.save(tts)
            }

            guard !changed.isEmpty else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No `voice` settings to change were provided.",
                    field: "settings",
                    tool: toolName
                )
            }
            var result: [String: Any] = [
                "scope": "voice",
                "status": "saved",
                "changed": changed,
            ]
            if engineProvider == .openAICompatible {
                result["note"] =
                    "The OpenAI-compatible engine needs an endpoint/model/voice configured in "
                    + "Settings → Voice."
            }
            return ToolEnvelope.success(tool: toolName, result: result)
        }
    }
}
