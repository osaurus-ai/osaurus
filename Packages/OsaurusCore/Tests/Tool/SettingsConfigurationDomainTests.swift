//
//  SettingsConfigurationDomainTests.swift
//  OsaurusCoreTests
//
//  Coverage for the `osaurus_settings` configure tool:
//
//   * get/set across the server, default_agent, chat, and memory scopes,
//     each against a sandboxed store (`overrideDirectory` / test root) so
//     the user's real `~/.osaurus/config/` is never touched.
//   * The partial-set contract: absent keys untouched, JSON null clears an
//     optional override, unknown keys and out-of-range values fail typed
//     BEFORE anything is persisted (no half-applied saves).
//   * Default-agent gating identical to the other configure tools.
//
//  The `app` scope's happy path (start at login, dock icon, appearance)
//  drives `LoginItemService` / `ThemeManager` process-global state, so only
//  its validation failures are unit-tested here; the effect is covered by
//  the live Release-app proof.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SettingsConfigurationDomainTests {

    private let tool = OsaurusSettingsTool()

    // MARK: - Harness

    private func parse(_ envelope: String) throws -> [String: Any] {
        let data = try #require(envelope.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Run `execute` as the Default agent (the only caller the tool serves).
    private func executeAsDefaultAgent(_ argumentsJSON: String) async throws -> [String: Any] {
        let envelope = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await tool.execute(argumentsJSON: argumentsJSON)
        }
        return try parse(envelope)
    }

    private func makeTempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("osaurus-settings-tool-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Sandbox the server-runtime store (and its legacy migration source)
    /// into a temp directory for the duration of `body`.
    private func withSandboxedServerStore(_ body: () async throws -> Void) async throws {
        let dir = try makeTempDirectory()
        let previous = await MainActor.run {
            let previous = (
                runtime: ServerRuntimeSettingsStore.overrideDirectory,
                legacy: ServerConfigurationStore.overrideDirectory
            )
            ServerRuntimeSettingsStore.overrideDirectory = dir
            ServerConfigurationStore.overrideDirectory = dir
            ServerRuntimeSettingsStore.invalidateSnapshot()
            return previous
        }
        func teardown() async {
            await MainActor.run {
                ServerRuntimeSettingsStore.overrideDirectory = previous.runtime
                ServerConfigurationStore.overrideDirectory = previous.legacy
                ServerRuntimeSettingsStore.invalidateSnapshot()
            }
            try? FileManager.default.removeItem(at: dir)
        }
        do {
            try await body()
        } catch {
            await teardown()
            throw error
        }
        await teardown()
    }

    private func withSandboxedDefaultAgentStore(_ body: () async throws -> Void) async throws {
        let dir = try makeTempDirectory()
        let previous = await MainActor.run {
            let previous = DefaultAgentConfigurationStore.overrideDirectory
            DefaultAgentConfigurationStore.overrideDirectory = dir
            DefaultAgentConfigurationStore.resetCacheForTests()
            return previous
        }
        func teardown() async {
            await MainActor.run {
                DefaultAgentConfigurationStore.overrideDirectory = previous
                DefaultAgentConfigurationStore.resetCacheForTests()
            }
            try? FileManager.default.removeItem(at: dir)
        }
        do {
            try await body()
        } catch {
            await teardown()
            throw error
        }
        await teardown()
    }

    /// MainActor read of the sandboxed default-agent config.
    private func loadDefaultAgentConfig() async -> DefaultAgentConfiguration {
        await MainActor.run { DefaultAgentConfigurationStore.load() }
    }

    // MARK: - Gating and argument validation

    @Test
    func execute_isGatedToTheDefaultAgent() async throws {
        let envelope = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await tool.execute(argumentsJSON: #"{"action": "get", "scope": "server"}"#)
        }
        let dict = try parse(envelope)
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["kind"] as? String == "unavailable")
    }

    @Test
    func execute_rejectsUnknownScopeNamingValidOnes() async throws {
        let dict = try await executeAsDefaultAgent(#"{"action": "get", "scope": "network"}"#)
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["kind"] as? String == "invalid_args")
        #expect(dict["field"] as? String == "scope")
        let message = try #require(dict["message"] as? String)
        for scope in ["server", "default_agent", "chat", "app", "memory", "voice"] {
            #expect(message.contains(scope))
        }
    }

    @Test
    func set_rejectsUnknownKeyNamingValidOnes() async throws {
        let dict = try await executeAsDefaultAgent(
            #"{"action": "set", "scope": "server", "settings": {"cors": "*"}}"#
        )
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["kind"] as? String == "invalid_args")
        let message = try #require(dict["message"] as? String)
        #expect(message.contains("cors"))
        #expect(message.contains("port"))
    }

    @Test
    func set_rejectsEmptySettingsObject() async throws {
        let dict = try await executeAsDefaultAgent(
            #"{"action": "set", "scope": "chat", "settings": {}}"#
        )
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["field"] as? String == "settings")
    }

    // MARK: - server scope

    @Test
    func serverGet_reportsRuntimeSettingsAndLiveness() async throws {
        // Value-level assertions (default port, expose false, not running)
        // would only hold when no live ServerController exists in-process,
        // but sibling suites in the full parallel run create real
        // controllers that register in the process-global holder and take
        // precedence over the sandboxed store. Pin the response SCHEMA —
        // stable on both paths — not environment-dependent values.
        try await withSandboxedServerStore {
            let dict = try await executeAsDefaultAgent(#"{"action": "get", "scope": "server"}"#)
            #expect(dict["ok"] as? Bool == true)
            let result = try #require(dict["result"] as? [String: Any])
            #expect(result["scope"] as? String == "server")
            #expect(result["server_running"] as? Bool != nil)
            #expect(result["port"] as? Int != nil)
            #expect(result["expose_to_network"] as? Bool != nil)
            #expect(result["prefix_cache_enabled"] as? Bool != nil)
            #expect(result["paged_kv_enabled"] as? Bool != nil)
            #expect(result["disk_cache_enabled"] as? Bool != nil)
            #expect(result["continuous_batching"] as? Bool != nil)
            #expect(result["note"] as? String != nil)
        }
    }

    @Test
    func serverSet_persistsToRuntimeStoreAndReportsApplication() async throws {
        try await withSandboxedServerStore {
            let dict = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "server", "settings": {"port": 8123, "default_temperature": 0.4, "expose_to_network": true}}"#
            )
            #expect(dict["ok"] as? Bool == true)
            let result = try #require(dict["result"] as? [String: Any])
            #expect(result["status"] as? String == "saved")
            let changed = try #require(result["changed"] as? [String: Any])
            #expect(changed["port"] as? Int == 8123)
            #expect(changed["expose_to_network"] as? Bool == true)
            // Application reporting depends on whether a live ServerController
            // exists in-process (sibling suites create real controllers in the
            // full parallel run): live → `effects` dict from the restart-aware
            // save; none → a deferred-application `note`. Exactly one of the
            // two must be present.
            let hasEffects = result["effects"] as? [String: Any] != nil
            let hasDeferredNote = result["note"] as? String != nil
            #expect(hasEffects != hasDeferredNote)

            // Persistence lands in the sandboxed store on BOTH paths (the
            // live controller saves through the same override directory).
            let persisted = await MainActor.run { ServerRuntimeSettingsStore.snapshot() }
            #expect(persisted.network.port == 8123)
            #expect(persisted.network.host == "0.0.0.0")
            #expect(persisted.generation.temperature == 0.4)
        }
    }

    @Test
    func serverSet_nullClearsGenerationOverride() async throws {
        try await withSandboxedServerStore {
            _ = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "server", "settings": {"default_temperature": 0.9}}"#
            )
            let dict = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "server", "settings": {"default_temperature": null}}"#
            )
            #expect(dict["ok"] as? Bool == true)
            let persisted = await MainActor.run { ServerRuntimeSettingsStore.snapshot() }
            #expect(persisted.generation.temperature == nil)
        }
    }

    @Test
    func serverSet_validatesBeforePersistingAnything() async throws {
        try await withSandboxedServerStore {
            let before = await MainActor.run { ServerRuntimeSettingsStore.snapshot() }
            // Valid port + out-of-range temperature in one call: nothing may land.
            let dict = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "server", "settings": {"port": 9999, "default_temperature": 9.5}}"#
            )
            #expect(dict["ok"] as? Bool == false)
            #expect(dict["kind"] as? String == "invalid_args")
            #expect(dict["field"] as? String == "default_temperature")
            let after = await MainActor.run { ServerRuntimeSettingsStore.snapshot() }
            #expect(after.network.port == before.network.port)
            #expect(after.generation.temperature == before.generation.temperature)
        }
    }

    @Test
    func serverSet_rejectsOutOfRangePort() async throws {
        try await withSandboxedServerStore {
            let dict = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "server", "settings": {"port": 0}}"#
            )
            #expect(dict["ok"] as? Bool == false)
            #expect(dict["field"] as? String == "port")
        }
    }

    // MARK: - default_agent scope

    @Test
    func defaultAgentSetAndGet_roundTripsPersonaModelAndSampling() async throws {
        try await withSandboxedDefaultAgentStore {
            let dict = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "default_agent", "settings": {"model": "provider/some-remote", "temperature": 0.3, "max_tokens": 2048, "system_prompt": "Be terse."}}"#
            )
            #expect(dict["ok"] as? Bool == true)
            let result = try #require(dict["result"] as? [String: Any])
            #expect(result["status"] as? String == "saved")
            // "provider/model" routes resolve at request time — no
            // not-installed warning for slash ids.
            #expect(result["notes"] == nil)

            let saved = await loadDefaultAgentConfig()
            #expect(saved.defaultModel == "provider/some-remote")
            #expect(saved.temperature == 0.3)
            #expect(saved.maxTokens == 2048)
            #expect(saved.systemPrompt == "Be terse.")

            let got = try await executeAsDefaultAgent(
                #"{"action": "get", "scope": "default_agent"}"#
            )
            let gotResult = try #require(got["result"] as? [String: Any])
            #expect(gotResult["model"] as? String == "provider/some-remote")
            #expect(gotResult["system_prompt"] as? String == "Be terse.")
        }
    }

    @Test
    func defaultAgentSet_nullClearsModelAndSamplingOverrides() async throws {
        try await withSandboxedDefaultAgentStore {
            _ = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "default_agent", "settings": {"model": "provider/m", "temperature": 0.5}}"#
            )
            let dict = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "default_agent", "settings": {"model": null, "temperature": null}}"#
            )
            #expect(dict["ok"] as? Bool == true)
            let saved = await loadDefaultAgentConfig()
            #expect(saved.defaultModel == nil)
            #expect(saved.temperature == nil)
        }
    }

    @Test
    func defaultAgentSet_warnsOnUnknownBareLocalModelId() async throws {
        try await withSandboxedDefaultAgentStore {
            let dict = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "default_agent", "settings": {"model": "definitely-not-installed-model"}}"#
            )
            // Saved (never blocked) but flagged so the model can steer the
            // user to osaurus_list.
            #expect(dict["ok"] as? Bool == true)
            let result = try #require(dict["result"] as? [String: Any])
            let notes = try #require(result["notes"] as? [String])
            #expect(notes.contains { $0.contains("definitely-not-installed-model") })
            let saved = await loadDefaultAgentConfig()
            #expect(saved.defaultModel == "definitely-not-installed-model")
        }
    }

    @Test
    func defaultAgentSet_rejectsOutOfRangeTemperature() async throws {
        try await withSandboxedDefaultAgentStore {
            let dict = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "default_agent", "settings": {"temperature": 3.5}}"#
            )
            #expect(dict["ok"] as? Bool == false)
            #expect(dict["field"] as? String == "temperature")
        }
    }

    // MARK: - chat scope

    @Test
    func chatSetAndGet_roundTripsGlobals() async throws {
        // `AppConfiguration.shared` is process-global (backed by the test
        // root's chat.json) — snapshot and restore around the mutation.
        let original = await MainActor.run { AppConfiguration.shared.chatConfig }
        func restore() async {
            await MainActor.run { AppConfiguration.shared.updateChatConfig(original) }
        }
        do {
            let dict = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "chat", "settings": {"top_p": 0.85, "auto_generate_chat_titles": false, "max_tool_attempts": 12}}"#
            )
            #expect(dict["ok"] as? Bool == true)

            let updated = await MainActor.run { AppConfiguration.shared.chatConfig }
            #expect(updated.topPOverride == 0.85)
            #expect(updated.autoGenerateChatTitles == false)
            #expect(updated.maxToolAttempts == 12)

            let got = try await executeAsDefaultAgent(#"{"action": "get", "scope": "chat"}"#)
            let gotResult = try #require(got["result"] as? [String: Any])
            #expect(gotResult["auto_generate_chat_titles"] as? Bool == false)
            #expect(gotResult["max_tool_attempts"] as? Int == 12)
        } catch {
            await restore()
            throw error
        }
        await restore()
    }

    @Test
    func chatSet_rejectsOutOfRangeTopP() async throws {
        let dict = try await executeAsDefaultAgent(
            #"{"action": "set", "scope": "chat", "settings": {"top_p": 1.5}}"#
        )
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["field"] as? String == "top_p")
    }

    @Test
    func chatSet_coreModelSplitsProviderSlashName() async throws {
        let original = await MainActor.run { AppConfiguration.shared.chatConfig }
        func restore() async {
            await MainActor.run { AppConfiguration.shared.updateChatConfig(original) }
        }
        do {
            // "provider/name" splits on the FIRST slash (mirrors the
            // Settings → General picker).
            var dict = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "chat", "settings": {"core_model": "openai/gpt-5.5-mini"}}"#
            )
            #expect(dict["ok"] as? Bool == true)
            var config = await MainActor.run { AppConfiguration.shared.chatConfig }
            #expect(config.coreModelProvider == "openai")
            #expect(config.coreModelName == "gpt-5.5-mini")
            #expect(config.coreModelIdentifier == "openai/gpt-5.5-mini")

            // A bare name has no provider ("foundation" = Apple's on-device model).
            dict = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "chat", "settings": {"core_model": "foundation"}}"#
            )
            #expect(dict["ok"] as? Bool == true)
            config = await MainActor.run { AppConfiguration.shared.chatConfig }
            #expect(config.coreModelProvider == nil)
            #expect(config.coreModelName == "foundation")

            // The get surface reads it back as one identifier.
            let got = try await executeAsDefaultAgent(#"{"action": "get", "scope": "chat"}"#)
            let gotResult = try #require(got["result"] as? [String: Any])
            #expect(gotResult["core_model"] as? String == "foundation")
        } catch {
            await restore()
            throw error
        }
        await restore()
    }

    @Test
    func chatSet_nullClearsCoreModelWithFallbackNote() async throws {
        let original = await MainActor.run { AppConfiguration.shared.chatConfig }
        func restore() async {
            await MainActor.run { AppConfiguration.shared.updateChatConfig(original) }
        }
        do {
            _ = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "chat", "settings": {"core_model": "foundation"}}"#
            )
            let dict = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "chat", "settings": {"core_model": null}}"#
            )
            #expect(dict["ok"] as? Bool == true)
            let result = try #require(dict["result"] as? [String: Any])
            let notes = try #require(result["notes"] as? [String])
            #expect(notes.contains { $0.contains("fall back") || $0.contains("falls back") })
            let config = await MainActor.run { AppConfiguration.shared.chatConfig }
            #expect(config.coreModelIdentifier == nil)
        } catch {
            await restore()
            throw error
        }
        await restore()
    }

    @Test
    func chatSet_disableToolsIsGlobalAndWarns() async throws {
        let original = await MainActor.run { AppConfiguration.shared.chatConfig }
        func restore() async {
            await MainActor.run { AppConfiguration.shared.updateChatConfig(original) }
        }
        do {
            let dict = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "chat", "settings": {"disable_tools": true}}"#
            )
            #expect(dict["ok"] as? Bool == true)
            let result = try #require(dict["result"] as? [String: Any])
            // Turning tools off globally also disarms THIS agent — the
            // result must say so.
            let notes = try #require(result["notes"] as? [String])
            #expect(notes.contains { $0.contains("global") })
            let config = await MainActor.run { AppConfiguration.shared.chatConfig }
            #expect(config.disableTools == true)

            let got = try await executeAsDefaultAgent(#"{"action": "get", "scope": "chat"}"#)
            let gotResult = try #require(got["result"] as? [String: Any])
            #expect(gotResult["disable_tools"] as? Bool == true)
        } catch {
            await restore()
            throw error
        }
        await restore()
    }

    // MARK: - app scope (validation only — happy path is live-proofed)

    @Test
    func appSet_rejectsUnknownAppearanceValue() async throws {
        let dict = try await executeAsDefaultAgent(
            #"{"action": "set", "scope": "app", "settings": {"appearance": "midnight"}}"#
        )
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["field"] as? String == "appearance")
        let message = try #require(dict["message"] as? String)
        #expect(message.contains("system"))
        #expect(message.contains("dark"))
    }

    @Test
    func appSet_rejectsNonBooleanStartAtLogin() async throws {
        let dict = try await executeAsDefaultAgent(
            #"{"action": "set", "scope": "app", "settings": {"start_at_login": "yes please"}}"#
        )
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["field"] as? String == "start_at_login")
    }

    // MARK: - memory scope

    @Test
    func memorySetAndGet_roundTrips() async throws {
        let original = MemoryConfigurationStore.load()
        defer {
            MemoryConfigurationStore.save(original)
            MemoryConfigurationStore.invalidateCache()
        }

        let dict = try await executeAsDefaultAgent(
            #"{"action": "set", "scope": "memory", "settings": {"enabled": false, "budget_tokens": 500, "retention_days": 30}}"#
        )
        #expect(dict["ok"] as? Bool == true)

        let saved = MemoryConfigurationStore.load()
        #expect(saved.enabled == false)
        #expect(saved.memoryBudgetTokens == 500)
        #expect(saved.episodeRetentionDays == 30)

        let got = try await executeAsDefaultAgent(#"{"action": "get", "scope": "memory"}"#)
        let gotResult = try #require(got["result"] as? [String: Any])
        #expect(gotResult["enabled"] as? Bool == false)
        #expect(gotResult["budget_tokens"] as? Int == 500)
        #expect(gotResult["retention_days"] as? Int == 30)
    }

    @Test
    func memorySet_rejectsOutOfRangeBudget() async throws {
        let dict = try await executeAsDefaultAgent(
            #"{"action": "set", "scope": "memory", "settings": {"budget_tokens": 5}}"#
        )
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["field"] as? String == "budget_tokens")
    }

    // MARK: - voice scope

    @Test
    func voiceSetAndGet_roundTripsInputAndTTS() async throws {
        // Speech + TTS stores are process-global (backed by the test root's
        // config files) — snapshot and restore around the mutation.
        let originalSpeech = await MainActor.run { SpeechConfigurationStore.load() }
        let originalTTS = await MainActor.run { TTSConfigurationStore.load() }
        func restore() async {
            await MainActor.run {
                SpeechConfigurationStore.save(originalSpeech)
                TTSConfigurationStore.save(originalTTS)
            }
        }
        do {
            let dict = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "voice", "settings": {"voice_input_enabled": true, "tts_enabled": true, "tts_engine": "pocket_tts"}}"#
            )
            #expect(dict["ok"] as? Bool == true)
            let result = try #require(dict["result"] as? [String: Any])
            let changed = try #require(result["changed"] as? [String: Any])
            #expect(changed["voice_input_enabled"] as? Bool == true)
            #expect(changed["tts_enabled"] as? Bool == true)
            #expect(changed["tts_engine"] as? String == "pocket_tts")

            let speech = await MainActor.run { SpeechConfigurationStore.load() }
            let tts = await MainActor.run { TTSConfigurationStore.load() }
            #expect(speech.voiceInputEnabled == true)
            #expect(tts.enabled == true)
            #expect(tts.provider == .pocketTTS)

            let got = try await executeAsDefaultAgent(#"{"action": "get", "scope": "voice"}"#)
            let gotResult = try #require(got["result"] as? [String: Any])
            #expect(gotResult["voice_input_enabled"] as? Bool == true)
            #expect(gotResult["tts_enabled"] as? Bool == true)
            #expect(gotResult["tts_engine"] as? String == "pocket_tts")
        } catch {
            await restore()
            throw error
        }
        await restore()
    }

    @Test
    func voiceSet_remoteEngineNeedsSettingsNote() async throws {
        let originalTTS = await MainActor.run { TTSConfigurationStore.load() }
        func restore() async {
            await MainActor.run { TTSConfigurationStore.save(originalTTS) }
        }
        do {
            let dict = try await executeAsDefaultAgent(
                #"{"action": "set", "scope": "voice", "settings": {"tts_engine": "openai_compatible"}}"#
            )
            #expect(dict["ok"] as? Bool == true)
            let result = try #require(dict["result"] as? [String: Any])
            // Endpoint/model/voice can't travel through chat — the result
            // must direct the user to Settings → Voice.
            let note = try #require(result["note"] as? String)
            #expect(note.contains("Settings"))
            let tts = await MainActor.run { TTSConfigurationStore.load() }
            #expect(tts.provider == .openAICompatible)
        } catch {
            await restore()
            throw error
        }
        await restore()
    }

    @Test
    func voiceSet_rejectsUnknownEngine() async throws {
        let dict = try await executeAsDefaultAgent(
            #"{"action": "set", "scope": "voice", "settings": {"tts_engine": "espeak"}}"#
        )
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["field"] as? String == "tts_engine")
        let message = try #require(dict["message"] as? String)
        #expect(message.contains("pocket_tts"))
        #expect(message.contains("openai_compatible"))
    }
}
