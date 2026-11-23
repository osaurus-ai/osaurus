// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Credential registry")
struct CredentialRegistryTests {
    @Test("missing keys list required slots with no value from any source")
    func missingDerivation() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let id = UUID()
            let mcp = CredentialSlot.mcpEnv(providerId: id, providerName: "GitHub", name: "GITHUB_TOKEN")
            let plugin = CredentialSlot.plugin(pluginId: "osaurus.tavily", pluginName: "Tavily", specId: "TAVILY_API_KEY")
            let optional = CredentialSlot.plugin(
                pluginId: "osaurus.tavily", pluginName: "Tavily", specId: "EXTRA", required: false)
            let legacyServed = CredentialSlot.workflow(installId: UUID(), workflowName: "Clio", key: "CLIO_API_KEY")
            let channel = ChannelCredentialSlots.telegramBotToken

            store.save("TAVILY_API_KEY", scope: .global, value: "t", origin: .plugin)
            let missing = CredentialRegistry.buildMissing(
                slots: [
                    CredentialSlotEntry(mcp), CredentialSlotEntry(plugin), CredentialSlotEntry(optional),
                    CredentialSlotEntry(legacyServed, legacy: [CredentialResolver.LegacyItem("svc/clio") { "v" }]), CredentialSlotEntry(channel),
                ],
                store: store)

            #expect(missing.map(\.key).sorted() == ["GITHUB_TOKEN", "TELEGRAM_BOT_TOKEN"])
            #expect(missing.first { $0.key == "GITHUB_TOKEN" }?.summary == "GitHub needs GITHUB_TOKEN")
        }
    }

    @Test("an agent-only value does not satisfy a shared slot")
    func agentOnlyDoesNotSatisfy() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let slot = CredentialSlot.mcpEnv(providerId: UUID(), providerName: "GitHub", name: "GITHUB_TOKEN")
            store.save("GITHUB_TOKEN", scope: .agent(UUID()), value: "x", origin: .user)
            #expect(CredentialRegistry.buildMissing(slots: [CredentialSlotEntry(slot)], store: store).count == 1)
        }
    }

    @Test("rows group scopes per key and list who uses each key")
    func rowsAndUsedBy() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let agent = UUID()
            let github = CredentialSlot.mcpEnv(providerId: UUID(), providerName: "GitHub", name: "GITHUB_TOKEN")
            let bound = CredentialSlot.plugin(pluginId: "x.gh", pluginName: "GH Plugin", specId: "token")
            store.save("GITHUB_TOKEN", scope: .global, value: "g", origin: .user)
            store.save("GITHUB_TOKEN", scope: .agent(agent), value: "a", origin: .user)
            store.save("SOLO", scope: .agent(agent), value: "s", origin: .user)
            store.setBinding(slot: bound.id, key: "GITHUB_TOKEN", defaultKey: bound.defaultKey)

            let rows = CredentialRegistry.buildRows(slots: [github, bound], store: store)
            #expect(rows.map(\.key) == ["GITHUB_TOKEN", "SOLO"])
            let gh = rows[0]
            #expect(gh.global?.scope == .global)
            #expect(gh.record(for: agent) != nil)
            #expect(Set(gh.usedBy.map(\.consumer)) == ["GitHub", "GH Plugin"])
            #expect(rows[1].global == nil)
            #expect(rows[1].agentRecords.count == 1)
        }
    }

    @Test("rows never read secret values")
    func rowsAreIndexOnly() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            store.save("SECRET", scope: .global, value: "sk", origin: .user)
            let rows = CredentialRegistry.buildRows(slots: [], store: store)
            #expect(rows.first?.global?.variableValue == nil)
        }
    }

    @Test("the text-to-speech key is listed only while Voice uses a remote server, or while one is stored")
    func ttsAppKeyVisibility() {
        var configuration = TTSConfiguration(provider: .pocketTTS, remoteEndpoint: "http://speech.local:5050")
        let onDevice = CredentialRegistry.ttsAppKeyInput(configuration)
        #expect(onDevice.onlyWhenSet)

        configuration.provider = .openAICompatible
        let remote = CredentialRegistry.ttsAppKeyInput(configuration)
        #expect(!remote.onlyWhenSet)
        #expect(remote.title == "Text-to-Speech Server")
        #expect(remote.detail == "API key for speech.local")
        #expect(remote.destination?.settingId == "voice.tts.remote")
        #expect(SettingsSearchIndex.entries.contains { $0.id == remote.destination?.settingId })

        configuration.remoteEndpoint = ""
        #expect(CredentialRegistry.ttsAppKeyInput(configuration).detail == "API key")
    }
}
