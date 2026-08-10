//
//  ChatConfigurationDefaultsTests.swift
//  osaurusTests
//
//  Compatibility checks for settings fields retired from persisted JSON.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Retired chat configuration compatibility")
struct ChatConfigurationDefaultsTests {

    @Test("retired greeting keys are ignored and dropped on save")
    func retiredGreetingKeysAreIgnored() throws {
        let agentJSON = """
            {
              "generativeGreetingsEnabled": true,
              "generativeGreetings": "enabled",
              "greetingPersona": "Playful and concise"
            }
            """
        let settings = try JSONDecoder().decode(
            AgentSettings.self,
            from: Data(agentJSON.utf8)
        )
        let encodedSettings = try JSONEncoder().encode(settings)
        let encodedSettingsJSON = String(decoding: encodedSettings, as: UTF8.self)
        #expect(!encodedSettingsJSON.contains("generativeGreetings"))
        #expect(!encodedSettingsJSON.contains("greetingPersona"))

        let chatJSON = """
            {
              "systemPrompt": "",
              "generativeGreetingsEnabled": true,
              "greetingPersona": "Warm and welcoming"
            }
            """
        let chat = try JSONDecoder().decode(
            ChatConfiguration.self,
            from: Data(chatJSON.utf8)
        )
        let encodedChat = try JSONEncoder().encode(chat)
        let encodedChatJSON = String(decoding: encodedChat, as: UTF8.self)
        #expect(!encodedChatJSON.contains("generativeGreetings"))
        #expect(!encodedChatJSON.contains("greetingPersona"))
    }

    @Test("task-local test configurations remain isolated across concurrent tasks")
    @MainActor
    func taskLocalTestConfigurationsDoNotCrossTalk() async {
        var first = ChatConfigurationStore.load()
        first.systemPrompt = "first-task"
        first.warmModelsOnLoad = false

        var second = ChatConfigurationStore.load()
        second.systemPrompt = "second-task"
        second.warmModelsOnLoad = true

        async let firstResult = ChatConfigurationStore.withTestConfiguration(first) {
            await Task.yield()
            var updated = ChatConfigurationStore.load()
            updated.disableTools = true
            ChatConfigurationStore.save(updated)
            await Task.yield()
            return ChatConfigurationStore.load()
        }
        async let secondResult = ChatConfigurationStore.withTestConfiguration(second) {
            await Task.yield()
            var updated = ChatConfigurationStore.load()
            updated.disableTools = false
            ChatConfigurationStore.save(updated)
            await Task.yield()
            return ChatConfigurationStore.load()
        }

        let (resolvedFirst, resolvedSecond) = await (firstResult, secondResult)
        #expect(resolvedFirst.systemPrompt == "first-task")
        #expect(!resolvedFirst.warmModelsOnLoad)
        #expect(resolvedFirst.disableTools)
        #expect(resolvedSecond.systemPrompt == "second-task")
        #expect(resolvedSecond.warmModelsOnLoad)
        #expect(!resolvedSecond.disableTools)
    }
}
