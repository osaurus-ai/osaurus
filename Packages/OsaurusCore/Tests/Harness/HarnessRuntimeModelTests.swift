//
//  HarnessRuntimeModelTests.swift
//  osaurusTests
//
//  Persisted shapes (runtimes, per-agent runtime selection), the runtime
//  store's seeding rules, and the move of `claude-code/*` model agents onto
//  the Claude Code runtime.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Harness runtime model")
struct HarnessRuntimeModelTests {

    @Test func newRuntimesGetTheirKindDefaults() {
        let pi = HarnessRuntime(name: "Pi", kind: .piRPC)
        #expect(pi.executable == "pi")
        #expect(pi.arguments == ["--mode", "rpc"])
        let claude = HarnessRuntime(name: "Claude", kind: .claudeCode)
        #expect(claude.executable == "claude")
        #expect(claude.arguments.isEmpty)
    }

    @Test func decodingFillsMissingFieldsFromTheKind() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","kind":"piRPC"}"#
        let runtime = try JSONDecoder().decode(HarnessRuntime.self, from: Data(json.utf8))
        #expect(runtime.id == id)
        #expect(runtime.executable == "pi")
        #expect(runtime.arguments == ["--mode", "rpc"])
        #expect(runtime.environment.isEmpty)
        #expect(runtime.displayName == "Pi (RPC)", "a blank name still displays")
    }

    @Test func runtimesRoundTrip() throws {
        let original = HarnessRuntime(
            name: "Splash",
            kind: .piRPC,
            executable: "~/.local/bin/splash",
            arguments: ["--mode", "rpc", "--session-dir", "~/.splash/{chat_id}"],
            environment: ["SPLASH_PROFILE": "work"]
        )
        let decoded = try JSONDecoder().decode(HarnessRuntime.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func placeholdersAreSubstitutedPerLaunch() {
        let runtime = HarnessRuntime(
            name: "Pi",
            kind: .piRPC,
            arguments: ["--mode", "rpc", "--session", "/s/{chat_id}.jsonl", "--who", "{agent_id}@{cwd}", "{system_prompt_file}"]
        )
        let chatId = UUID()
        let agentId = UUID()
        let args = runtime.resolvedArguments(
            chatId: chatId,
            agentId: agentId,
            workingDirectory: URL(fileURLWithPath: "/work"),
            systemPromptFile: URL(fileURLWithPath: "/private/prompt.md")
        )
        #expect(args == [
            "--mode", "rpc",
            "--session", "/s/\(chatId.uuidString.lowercased()).jsonl",
            "--who", "\(agentId.uuidString.lowercased())@/work",
            "/private/prompt.md",
        ])
        #expect(runtime.wantsSystemPromptFile)
    }

    @Test func onlyChatKeyedPiRuntimesResume() {
        #expect(HarnessRuntime(name: "C", kind: .claudeCode).resumesSessions)
        #expect(!HarnessRuntime(name: "P", kind: .piRPC).resumesSessions)
        #expect(HarnessRuntime(name: "P", kind: .piRPC, arguments: ["--mode", "rpc", "--session-dir", "/x/{chat_id}"]).resumesSessions)
    }

    @Test func agentRuntimeEncodingIsTaggedAndForgiving() throws {
        let id = UUID()
        let encoded = String(decoding: try JSONEncoder().encode(AgentRuntime.harness(id)), as: UTF8.self)
        #expect(encoded.contains(#""kind":"harness""#))
        #expect(try JSONDecoder().decode(AgentRuntime.self, from: Data(encoded.utf8)) == .harness(id))
        #expect(
            try JSONDecoder().decode(AgentRuntime.self, from: JSONEncoder().encode(AgentRuntime.builtIn)) == .builtIn
        )

        // A newer build's kind, or a malformed id, must not lose the agent.
        for json in [#"{"kind":"mcpHarness","id":"x"}"#, #"{"kind":"harness","id":"not-a-uuid"}"#, "{}"] {
            #expect(try JSONDecoder().decode(AgentRuntime.self, from: Data(json.utf8)) == .builtIn)
        }
    }

    @Test func agentsWithoutARuntimeKeyStillDecode() throws {
        let agent = Agent(name: "Legacy")
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(agent)) as? [String: Any]
        )
        object["runtime"] = nil
        object["claudeCode"] = nil
        let decoded = try JSONDecoder().decode(Agent.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.runtime == nil)
        #expect(decoded.claudeCode == nil)

        var harnessAgent = agent
        harnessAgent.runtime = .harness(HarnessRuntime.builtInClaudeCodeId)
        harnessAgent.claudeCode = ClaudeCodeAgentConfig(allowWrites: true, model: "opus")
        let roundTripped = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(harnessAgent))
        #expect(roundTripped.runtime == .harness(HarnessRuntime.builtInClaudeCodeId))
        #expect(roundTripped.claudeCode?.model == "opus")
    }

    @Test func defaultAgentConfigurationCarriesTheRuntime() throws {
        var config = DefaultAgentConfiguration()
        config.runtime = .harness(HarnessRuntime.builtInClaudeCodeId)
        let decoded = try JSONDecoder().decode(
            DefaultAgentConfiguration.self,
            from: JSONEncoder().encode(config)
        )
        #expect(decoded.runtime == .harness(HarnessRuntime.builtInClaudeCodeId))
        let legacy = try JSONDecoder().decode(DefaultAgentConfiguration.self, from: Data("{}".utf8))
        #expect(legacy.runtime == nil)
    }
}

@Suite("Harness runtime store", .serialized)
@MainActor
struct HarnessRuntimeStoreTests {

    private func withStore(_ body: (HarnessRuntimeStore, URL) throws -> Void) throws {
        let directory = try HarnessFixtures.temporaryDirectory("runtime-store")
        let previous = HarnessRuntimeStore.overrideDirectory
        HarnessRuntimeStore.overrideDirectory = directory
        defer {
            HarnessRuntimeStore.overrideDirectory = previous
            try? FileManager.default.removeItem(at: directory)
        }
        try body(HarnessRuntimeStore(), directory.appendingPathComponent("harness-runtimes.json"))
    }

    @Test func claudeCodeIsSeededOnFirstLaunchOnly() throws {
        try withStore { store, file in
            #expect(store.all() == [.builtInClaudeCode])
            #expect(FileManager.default.fileExists(atPath: file.path))

            store.remove(id: HarnessRuntime.builtInClaudeCodeId)
            let reloaded = HarnessRuntimeStore()
            #expect(reloaded.all().isEmpty, "a deleted Claude Code runtime stays deleted")
        }
    }

    @Test func upsertPersistsAndEnsureReusesAnyClaudeRuntime() throws {
        try withStore { store, _ in
            store.remove(id: HarnessRuntime.builtInClaudeCodeId)
            let pi = HarnessRuntime(name: "Spotlight", kind: .piRPC, executable: "~/.local/bin/spotlight")
            store.upsert(pi)
            var edited = pi
            edited.arguments += ["--session-dir", "~/.spotlight/{chat_id}"]
            store.upsert(edited)

            let reloaded = HarnessRuntimeStore()
            #expect(reloaded.all() == [edited])

            let custom = HarnessRuntime(name: "Work Claude", kind: .claudeCode, executable: "/opt/claude")
            reloaded.upsert(custom)
            #expect(reloaded.ensureClaudeCodeRuntime() == custom)
        }
    }

    @Test func anUnreadableFileIsPreserved() throws {
        try withStore { store, file in
            try Data("{ not json".utf8).write(to: file)
            #expect(store.all().isEmpty)
            #expect(try String(contentsOf: file, encoding: .utf8) == "{ not json")
        }
    }
}

@Suite("Claude Code model migration", .serialized)
struct ClaudeCodeHarnessMigrationTests {

    @Test func claudeCodeModelAgentsMoveOntoTheClaudeRuntime() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try HarnessFixtures.temporaryDirectory("harness-migration")
            let originalChat = await MainActor.run { AppConfiguration.shared.chatConfig }
            let previousStoreDir = await MainActor.run { HarnessRuntimeStore.overrideDirectory }

            await MainActor.run {
                OsaurusPaths.overrideRoot = root
                OsaurusPaths.ensureExistsSilent(OsaurusPaths.config())
                DefaultAgentConfigurationStore.resetCacheForTests()
                HarnessRuntimeStore.overrideDirectory = root
                HarnessRuntimeStore.shared.resetForTests()
                AgentManager.shared.refresh()
            }
            defer {
                try? FileManager.default.removeItem(at: root)
            }

            let otherRuntime = UUID()
            // Config write, migration, and the read-back happen in one
            // main-actor step: parallel suites also write the shared chat
            // config.
            let (ids, globalAfter) = await MainActor.run { () -> ([UUID], String?) in
                let explicit = Agent(name: "Explicit", defaultModel: "claude-code/opus")
                let local = Agent(name: "Local", defaultModel: "mlx/some-model")
                let inherits = Agent(name: "Inherits")
                var pinned = Agent(name: "Pinned", defaultModel: "claude-code/sonnet")
                pinned.runtime = .harness(otherRuntime)
                for agent in [explicit, local, inherits, pinned] { AgentManager.shared.add(agent) }
                var chat = originalChat
                chat.defaultModel = "claude-code/haiku"
                AppConfiguration.shared.updateChatConfig(chat)
                AgentManager.shared.migrateClaudeCodeModelsToHarness()
                let globalAfter = ChatConfigurationStore.load().defaultModel
                return ([explicit.id, local.id, inherits.id, pinned.id], globalAfter)
            }

            await MainActor.run {
                let manager = AgentManager.shared
                let claudeId = HarnessRuntime.builtInClaudeCodeId

                let explicit = manager.agent(for: ids[0])
                #expect(explicit?.runtime == .harness(claudeId))
                #expect(explicit?.claudeCode?.model == "opus")
                #expect(explicit?.defaultModel == nil)

                let local = manager.agent(for: ids[1])
                #expect(local?.runtime == nil)
                #expect(local?.defaultModel == "mlx/some-model")

                let inherits = manager.agent(for: ids[2])
                #expect(inherits?.runtime == .harness(claudeId))
                #expect(inherits?.claudeCode?.model == "haiku")

                let pinned = manager.agent(for: ids[3])
                #expect(pinned?.runtime == .harness(otherRuntime), "an explicit runtime choice wins")
                #expect(pinned?.defaultModel == nil, "the dead model id is still cleared")

                #expect(globalAfter == nil, "the dead global model id is cleared")
                #expect(HarnessRuntimeStore.shared.runtime(id: claudeId) != nil)
                #expect(manager.effectiveHarness(for: ids[0]) == .resolved(.builtInClaudeCode))
                #expect(manager.effectiveHarness(for: ids[3]) == .missing(otherRuntime))
                #expect(manager.harnessUnsupportedError(for: ids[0]) == .unsupportedPath(agentName: "Explicit"))
                #expect(manager.harnessUnsupportedError(for: ids[1]) == nil)

                // Idempotent: with nothing left to move, a second pass must not
                // re-seed a Claude Code runtime the user deleted.
                HarnessRuntimeStore.shared.remove(id: claudeId)
                manager.migrateClaudeCodeModelsToHarness()
                #expect(HarnessRuntimeStore.shared.runtime(id: claudeId) == nil)

                // An agent restored from an old backup still gets moved.
                let restored = Agent(name: "Restored", defaultModel: "claude-code/opus")
                manager.add(restored)
                manager.migrateClaudeCodeModelsToHarness()
                #expect(manager.agent(for: restored.id)?.runtime == .harness(claudeId))
                #expect(HarnessRuntimeStore.shared.runtime(id: claudeId) != nil)
            }

            for id in ids { _ = await AgentManager.shared.delete(id: id) }
            await MainActor.run {
                AppConfiguration.shared.updateChatConfig(originalChat)
                OsaurusPaths.overrideRoot = nil
                DefaultAgentConfigurationStore.resetCacheForTests()
                HarnessRuntimeStore.overrideDirectory = previousStoreDir
                HarnessRuntimeStore.shared.resetForTests()
                AgentManager.shared.refresh()
            }
        }
    }
}
