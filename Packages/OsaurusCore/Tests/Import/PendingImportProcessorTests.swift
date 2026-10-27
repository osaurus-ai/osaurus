//
//  PendingImportProcessorTests.swift
//  OsaurusCoreTests
//
//  End-to-end over the real queue, SkillManager, ConfigApplier and
//  AgentManager: a queued bundle request installs its skill and agent,
//  re-running it is a no-op, items the bundle does not own are never
//  touched, removing an agent takes its unused dependencies with it, and
//  MCP servers whose secrets are not provisioned register as pending.
//  Names and bundle ids are unique per test because the stores are shared
//  with the rest of the suite.
//

import Foundation
import OsaurusRepository
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct PendingImportProcessorTests {

    private struct Fixture {
        var root: URL
        var bundleId: String
        var skill: String
        var agent: String
        var server: String
        var runtime: String
    }

    private func makeFixture(
        withServer: Bool = false, withRuntime: Bool = false, orchestratorSpawnable: Bool? = nil
    ) throws -> Fixture {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let fixture = Fixture(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-import-\(suffix)", isDirectory: true),
            bundleId: "com.example.import\(suffix)",
            skill: "triage-\(suffix)",
            agent: "Support \(suffix)",
            server: "Tickets \(suffix)",
            runtime: "Pi \(suffix)")
        func write(_ text: String, _ relative: String) throws {
            let url = fixture.root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        var manifest: [String: Any] = [
            "format": "osaurus.bundle", "format_version": 1, "id": fixture.bundleId,
            "name": "Import Probe", "version": "1.0.0",
            "skills": [["name": fixture.skill, "path": "skills/\(fixture.skill)"]],
            "agents": [["path": "agents/support.json"]],
        ]
        var agent: [String: Any] = [
            "name": fixture.agent, "system_prompt": "Triage tickets.", "skills": [fixture.skill],
            "tools": ["mode": "manual", "enabled": ["tickets_\(suffix)_search"]],
        ]
        if let orchestratorSpawnable { agent["orchestrator_spawnable"] = orchestratorSpawnable }
        if withServer {
            manifest["mcp_servers"] = [
                [
                    "name": fixture.server, "transport": "http", "url": "https://mcp.invalid/mcp",
                    "auth": "bearer", "token_ref": "keychain:\(fixture.bundleId)/missing-token",
                ]
            ]
            agent["mcp_servers"] = ["enabled": [fixture.server]]
        }
        if withRuntime {
            manifest["harness_runtimes"] = [
                [
                    "name": fixture.runtime, "kind": "pi_rpc", "executable": "/bin/cat",
                    "arguments": ["--mode", "rpc", "--session-id", "{chat_id}"],
                    "environment": ["PI_LOG_LEVEL": "info"],
                ]
            ]
            agent["runtime"] = fixture.runtime
        }
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try write(String(decoding: manifestData, as: UTF8.self), "osaurus-bundle.json")
        try write(
            "---\nname: \(fixture.skill)\ndescription: Triage a ticket.\n---\n\n# Triage\n\nRead the ticket.\n",
            "skills/\(fixture.skill)/SKILL.md")
        try write("Escalation matrix.\n", "skills/\(fixture.skill)/references/escalation.md")
        let envelope: [String: Any] = [
            "format": "osaurus.template", "format_version": 1, "name": fixture.agent, "agent": agent,
        ]
        let agentData = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        try write(String(decoding: agentData, as: UTF8.self), "agents/support.json")
        return fixture
    }

    /// Other suites swap `OsaurusPaths.overrideRoot` and reload the shared
    /// agent and skill stores under the storage lock, and creating an agent
    /// writes the Orchestrator's spawn pool that spawn suites sandbox under
    /// the subagent store lock. Holding both for the whole test keeps the
    /// stores in place and the pool writes in this test's own sandbox.
    private func exclusive(_ body: @Sendable @MainActor () async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let lease = await acquireSubagentStoreSandbox("bundle-import")
            defer { lease.release() }
            try await body()
        }
    }

    private func processor() -> PendingImportProcessor {
        let processor = PendingImportProcessor()
        processor.connectTimeout = 1
        return processor
    }

    /// Queues a request the way `osaurus import` does and applies it.
    private func run(
        _ action: ImportAction, _ fixture: Fixture, kinds: [BundleItemKind]? = nil, yes: Bool = false
    ) async throws -> ImportResult {
        let bundle = try OsaurusBundle.load(from: fixture.root)
        var operations: [ImportOperation] = []
        if action == .remove {
            operations = ImportQueue.loadReceipts()
                .filter { $0.bundleId == fixture.bundleId && (kinds?.contains($0.kind) ?? true) }
                .map { ImportOperation(action: .remove, kind: $0.kind, name: $0.name, explicit: true) }
        } else {
            let refs = try bundle.select(kind: nil, names: [])
            operations = refs.map {
                ImportOperation(action: action, kind: $0.kind, name: $0.name, explicit: $0.explicit)
            }
        }
        let request = ImportRequest(
            bundleId: bundle.id, bundleName: bundle.manifest.name, bundleVersion: bundle.manifest.version,
            operations: operations, confirmHighRisk: yes)
        try ImportQueue.enqueue(request, bundle: action == .remove ? nil : bundle)
        return try #require(await processor().process(requestId: request.id))
    }

    private func receipts(_ fixture: Fixture) -> [ImportReceipt] {
        ImportQueue.loadReceipts().filter { $0.bundleId == fixture.bundleId }
    }

    private func agent(named name: String) -> Agent? {
        AgentManager.shared.agents.first { $0.name == name }
    }

    @Test
    func installsSkillAndAgent_thenReinstallIsUnchanged_thenRemoveCleansUp() async throws {
        try await exclusive {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            let first = try await run(.install, fixture)
            #expect(first.status == .applied, "\(first.items)")
            #expect(first.items.map(\.kind) == [.skill, .agent])
            #expect(ImportQueue.result(id: first.requestId)?.items == first.items)
            #expect(!ImportQueue.pending().contains { $0.request.id == first.requestId })

            let installed = try #require(agent(named: fixture.agent))
            #expect(installed.skillNames == [fixture.skill])
            #expect(installed.toolSelectionMode == .manual)
            // Kept although no server provides it yet.
            #expect(installed.manualToolNames?.contains { $0.hasSuffix("_search") } == true)
            let skill = try #require(SkillManager.shared.skill(named: fixture.skill))
            #expect(skill.directoryName == fixture.skill)
            #expect(
                FileManager.default.fileExists(
                    atPath: SkillStore.skillDirectory(for: skill).appendingPathComponent("references/escalation.md").path))
            #expect(Set(receipts(fixture).map(\.kind)) == [.skill, .agent])
            #expect(receipts(fixture).first { $0.kind == .agent }?.agentId == installed.id.uuidString)
            #expect(receipts(fixture).first { $0.kind == .skill }?.explicit == true)

            let second = try await run(.install, fixture)
            #expect(second.items.allSatisfy { $0.status == .unchanged }, "\(second.items)")

            let removed = try await run(.remove, fixture, kinds: [.agent])
            #expect(removed.items.first?.kind == .agent)
            #expect(removed.items.first?.status == .done)
            #expect(agent(named: fixture.agent) == nil)
            // The skill was named on its own (select-all), so it stays.
            #expect(SkillManager.shared.skill(named: fixture.skill) != nil)

            let rest = try await run(.remove, fixture)
            #expect(rest.items.allSatisfy { $0.status == .done }, "\(rest.items)")
            #expect(SkillManager.shared.skill(named: fixture.skill) == nil)
            #expect(receipts(fixture).isEmpty)
        }
    }

    @Test
    func agentWithOrchestratorSpawnableFalse_staysOutOfThePool_andUpdatesKeepTheUsersChoice() async throws {
        try await exclusive {
            let fixture = try makeFixture(orchestratorSpawnable: false)
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            let first = try await run(.install, fixture)
            #expect(first.status == .applied, "\(first.items)")
            let installed = try #require(agent(named: fixture.agent))
            #expect(!SubagentConfigurationStore.snapshot().spawnableAgentIDs.contains(installed.id))

            // The user adds it in Settings → Subagents; a bundle update that
            // changes the agent file patches it and must leave the pool alone.
            _ = SubagentConfigurationStore.mutate { $0.spawnableAgentIDs.append(installed.id) }
            let agentFile = fixture.root.appendingPathComponent("agents/support.json")
            try String(contentsOf: agentFile, encoding: .utf8)
                .replacingOccurrences(of: "Triage tickets.", with: "Triage tickets carefully.")
                .write(to: agentFile, atomically: true, encoding: .utf8)
            let update = try await run(.update, fixture)
            #expect(update.items.first { $0.kind == .agent }?.status == .done, "\(update.items)")
            #expect(agent(named: fixture.agent)?.systemPrompt == "Triage tickets carefully.")
            #expect(SubagentConfigurationStore.snapshot().spawnableAgentIDs.contains(installed.id))

            _ = try await run(.remove, fixture)
            #expect(agent(named: fixture.agent) == nil)
        }
    }

    /// Runs `body` with an empty harness runtime store.
    private func withRuntimeStore(_ body: @MainActor () async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-import-runtimes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = HarnessRuntimeStore.overrideDirectory
        HarnessRuntimeStore.overrideDirectory = directory
        HarnessRuntimeStore.shared.resetForTests()
        defer {
            HarnessRuntimeStore.overrideDirectory = previous
            HarnessRuntimeStore.shared.resetForTests()
            try? FileManager.default.removeItem(at: directory)
        }
        try await body()
    }

    @Test
    func harnessRuntimeInstallsWithItsAgent_needsYes_andIsRemovedOnlyWhenUnused() async throws {
        try await exclusive {
            try await withRuntimeStore {
                let fixture = try makeFixture(withRuntime: true)
                defer { try? FileManager.default.removeItem(at: fixture.root) }

                let refused = try await run(.install, fixture)
                let refusedRuntime = try #require(refused.items.first { $0.kind == .harnessRuntime })
                #expect(refusedRuntime.status == .failed)
                #expect(refusedRuntime.message?.contains("--yes") == true)
                #expect(ConfigHarness.runtime(named: fixture.runtime) == nil)
                #expect(agent(named: fixture.agent) == nil)

                let installed = try await run(.install, fixture, yes: true)
                #expect(installed.status == .applied, "\(installed.items)")
                #expect(installed.items.map(\.kind) == [.skill, .harnessRuntime, .agent])
                let runtime = try #require(ConfigHarness.runtime(named: fixture.runtime))
                #expect(runtime.kind == .piRPC)
                #expect(runtime.executable == "/bin/cat")
                #expect(runtime.arguments == ["--mode", "rpc", "--session-id", "{chat_id}"])
                #expect(runtime.environment == ["PI_LOG_LEVEL": "info"])
                let created = try #require(agent(named: fixture.agent))
                #expect(created.runtime == .harness(runtime.id))
                #expect(receipts(fixture).first { $0.kind == .harnessRuntime }?.harnessRuntimeId == runtime.id.uuidString)
                #expect(receipts(fixture).first { $0.kind == .agent }?.harnessRuntime == fixture.runtime)

                let again = try await run(.install, fixture, yes: true)
                #expect(again.items.allSatisfy { $0.status == .unchanged }, "\(again.items)")

                let blocked = try await run(.remove, fixture, kinds: [.harnessRuntime])
                #expect(blocked.items.first?.status == .failed)
                #expect(blocked.items.first?.message?.contains(fixture.agent) == true)
                #expect(ConfigHarness.runtime(named: fixture.runtime) != nil)

                let removed = try await run(.remove, fixture)
                #expect(removed.items.allSatisfy { $0.status == .done }, "\(removed.items)")
                #expect(ConfigHarness.runtime(named: fixture.runtime) == nil)
                #expect(agent(named: fixture.agent) == nil)
                #expect(receipts(fixture).isEmpty)
            }
        }
    }

    @Test
    func agentPullsInItsRuntime_andRemovingTheAgentRemovesIt() async throws {
        try await exclusive {
            try await withRuntimeStore {
                let fixture = try makeFixture(withRuntime: true)
                defer { try? FileManager.default.removeItem(at: fixture.root) }
                let bundle = try OsaurusBundle.load(from: fixture.root)
                let refs = try bundle.select(kind: .agent, names: [fixture.agent])
                #expect(refs.contains { $0.kind == .harnessRuntime && !$0.explicit })
                let request = ImportRequest(
                    bundleId: bundle.id, bundleName: nil, bundleVersion: bundle.manifest.version,
                    operations: refs.map {
                        ImportOperation(action: .install, kind: $0.kind, name: $0.name, explicit: $0.explicit)
                    },
                    confirmHighRisk: true)
                try ImportQueue.enqueue(request, bundle: bundle)
                let installed = try #require(await processor().process(requestId: request.id))
                #expect(installed.status == .applied, "\(installed.items)")

                let removed = try await run(.remove, fixture, kinds: [.agent])
                #expect(removed.items.map(\.kind) == [.agent, .skill, .harnessRuntime], "\(removed.items)")
                #expect(ConfigHarness.runtime(named: fixture.runtime) == nil)
                #expect(receipts(fixture).isEmpty)
            }
        }
    }

    @Test
    func removingAnAgentRemovesDependenciesItPulledIn() async throws {
        try await exclusive {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let bundle = try OsaurusBundle.load(from: fixture.root)
            let refs = try bundle.select(kind: .agent, names: [fixture.agent])
            #expect(refs.contains { $0.kind == .skill && !$0.explicit })
            let request = ImportRequest(
                bundleId: bundle.id, bundleName: nil, bundleVersion: bundle.manifest.version,
                operations: refs.map { ImportOperation(action: .install, kind: $0.kind, name: $0.name, explicit: $0.explicit) },
                confirmHighRisk: false)
            try ImportQueue.enqueue(request, bundle: bundle)
            let installed = try #require(await processor().process(requestId: request.id))
            #expect(installed.status == .applied, "\(installed.items)")

            let removed = try await run(.remove, fixture, kinds: [.agent])
            #expect(removed.items.map(\.kind) == [.agent, .skill], "\(removed.items)")
            #expect(SkillManager.shared.skill(named: fixture.skill) == nil)
            #expect(receipts(fixture).isEmpty)
        }
    }

    @Test
    func neverTouchesItemsTheBundleDoesNotOwn() async throws {
        try await exclusive {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let mine = AgentManager.newCustomAgentRecord(name: fixture.agent)
            AgentManager.shared.add(mine)
            defer { Task { _ = await AgentManager.shared.delete(id: mine.id) } }

            let result = try await run(.install, fixture)
            let row = try #require(result.items.first { $0.kind == .agent })
            #expect(row.status == .failed)
            #expect(row.message?.contains("was not installed by") == true)
            #expect(agent(named: fixture.agent)?.systemPrompt == mine.systemPrompt)
            #expect(result.exitCode == 1)

            _ = try await run(.remove, fixture)
        }
    }

    @Test
    func updateDoesNotBringBackWhatTheUserDeleted() async throws {
        try await exclusive {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            _ = try await run(.install, fixture)
            let installed = try #require(agent(named: fixture.agent))
            _ = await AgentManager.shared.delete(id: installed.id)

            let updated = try await run(.update, fixture)
            let row = try #require(updated.items.first { $0.kind == .agent })
            #expect(row.status == .skipped)
            #expect(agent(named: fixture.agent) == nil)

            _ = try await run(.remove, fixture)
        }
    }

    @Test
    func unchangedItemsMoveToTheNewBundleVersion() async throws {
        try await exclusive {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            func setVersion(_ version: String) throws {
                let url = fixture.root.appendingPathComponent("osaurus-bundle.json")
                var manifest = try #require(
                    JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                manifest["version"] = version
                try JSONSerialization.data(withJSONObject: manifest).write(to: url)
            }
            _ = try await run(.install, fixture)

            try setVersion("1.1.0")
            let updated = try await run(.update, fixture)
            #expect(updated.items.allSatisfy { $0.status == .unchanged }, "\(updated.items)")
            #expect(receipts(fixture).allSatisfy { $0.bundleVersion == "1.1.0" }, "\(receipts(fixture))")

            try setVersion("1.0.5")
            let older = try await run(.update, fixture)
            #expect(older.items.allSatisfy { $0.status == .skipped }, "\(older.items)")

            _ = try await run(.remove, fixture)
        }
    }

    @Test
    func mcpServerNeedsConfirmation_andRegistersWithPendingSecrets() async throws {
        try await exclusive {
            let fixture = try makeFixture(withServer: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            let refused = try await run(.install, fixture)
            let refusedRow = try #require(refused.items.first { $0.kind == .mcp })
            #expect(refusedRow.status == .failed)
            #expect(refusedRow.message?.contains("--yes") == true)

            let result = try await run(.install, fixture, yes: true)
            let server = try #require(result.items.first { $0.kind == .mcp })
            if KeychainQueryHelpers.disablesKeychainForProcess {
                #expect(server.status == .needsUserAction, "\(result.items)")
                #expect(server.pendingSecrets == ["keychain:\(fixture.bundleId)/missing-token"])
                #expect(result.exitCode == 3)
                let agentRow = try #require(result.items.first { $0.kind == .agent })
                #expect(agentRow.status == .needsUserAction)
                #expect(agentRow.pendingSecrets == server.pendingSecrets)
                #expect(receipts(fixture).first { $0.kind == .mcp }?.needsUserAction == true)
            }
            let provider = MCPProviderManager.shared.configuration.providers.first { $0.name == fixture.server }
            #expect(provider?.authType == .bearerToken)
            #expect(agent(named: fixture.agent) != nil)
            let agentMessage = result.items.first { $0.kind == .agent }?.message ?? ""
            #expect(agentMessage.contains("Not connected yet"), "\(agentMessage)")
            #expect(!agentMessage.contains("Not set up on this Mac"), "\(agentMessage)")

            let removed = try await run(.remove, fixture)
            #expect(removed.items.allSatisfy { $0.status == .done }, "\(removed.items)")
            #expect(!MCPProviderManager.shared.configuration.providers.contains { $0.name == fixture.server })
        }
    }

    @Test
    func planReportsConflictsWithoutChangingAnything() async throws {
        try await exclusive {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let mine = AgentManager.newCustomAgentRecord(name: fixture.agent)
            AgentManager.shared.add(mine)
            defer { Task { _ = await AgentManager.shared.delete(id: mine.id) } }

            let checked = await processor().plan(
                bundleAt: fixture.root,
                operations: [
                    ImportOperation(action: .install, kind: .skill, name: fixture.skill, explicit: true),
                    ImportOperation(action: .install, kind: .agent, name: fixture.agent, explicit: true),
                ])
            #expect(checked.issues.count == 1, "\(checked.issues)")
            #expect(checked.issues.first?.contains("agent") == true)
            #expect(SkillManager.shared.skill(named: fixture.skill) == nil)
        }
    }

    // MARK: Settings

    @MainActor
    private final class FakeSettings: ImportSettingsAccess {
        var values: [BundleSetting.ID: BundleSettingValue] = [
            .requireLocalAccessKey: .bool(false), .allowedOrigins: .strings([]),
        ]
        var accessKeys = false
        var restartPending = false
        var restarts = 0

        func value(of setting: BundleSetting) -> BundleSettingValue { values[setting.id]! }

        func set(_ value: BundleSettingValue, for setting: BundleSetting) {
            values[setting.id] = value
            if setting.id == .allowedOrigins { restartPending = true }
        }

        func hasAccessKeys() -> Bool { accessKeys }

        func applyDeferredChanges() async {
            guard restartPending else { return }
            restartPending = false
            restarts += 1
        }
    }

    /// A settings-only bundle; returns its folder and id.
    private func makeSettingsBundle(_ settings: [String: Any], id: String? = nil) throws -> (URL, String) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let bundleId = id ?? "com.example.settings\(suffix)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-import-settings-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "format": "osaurus.bundle", "format_version": 1, "id": bundleId, "name": "Settings Probe",
            "version": "1.0.0", "settings": settings,
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("osaurus-bundle.json"))
        return (root, bundleId)
    }

    private func apply(
        _ action: ImportAction, bundleAt root: URL, bundleId: String, settings: FakeSettings, yes: Bool = false
    ) async throws -> ImportResult {
        var operations: [ImportOperation]
        var bundle: OsaurusBundle?
        if action == .remove {
            operations = ImportQueue.loadReceipts().filter { $0.bundleId == bundleId }.map {
                ImportOperation(action: .remove, kind: $0.kind, name: $0.name, explicit: true)
            }
        } else {
            let loaded = try OsaurusBundle.load(from: root)
            bundle = loaded
            operations = try loaded.select(kind: nil, names: []).map {
                ImportOperation(action: action, kind: $0.kind, name: $0.name, explicit: $0.explicit)
            }
        }
        let request = ImportRequest(
            bundleId: bundleId, bundleName: nil, bundleVersion: bundle?.manifest.version,
            operations: operations, confirmHighRisk: yes)
        try ImportQueue.enqueue(request, bundle: bundle)
        let processor = processor()
        processor.settings = settings
        return try #require(await processor.process(requestId: request.id))
    }

    private func settingReceipt(_ bundleId: String, _ key: String) -> ImportReceipt? {
        ImportQueue.loadReceipts().first { $0.bundleId == bundleId && $0.matches(kind: .setting, name: key) }
    }

    /// Bundle settings name the control by its catalog id and on-screen
    /// title, so messages and the author guide match Settings.
    @Test
    func everyBundleSettingIsACatalogedControl() {
        for setting in BundleSetting.all {
            let entry = SettingsSearchIndex.entries.first { $0.id == setting.catalogId }
            #expect(entry?.title == setting.title, "\(setting.key) -> \(setting.catalogId)")
        }
    }

    @Test
    func accessKeySetting_installs_updateRespectsTheUser_removeLeavesIt() async throws {
        try await exclusive {
            let (root, id) = try makeSettingsBundle(["require_local_access_key": true])
            defer { try? FileManager.default.removeItem(at: root) }
            let settings = FakeSettings()
            let key = BundleSetting.ID.requireLocalAccessKey

            let first = try await apply(.install, bundleAt: root, bundleId: id, settings: settings)
            let row = try #require(first.items.first)
            #expect(row.kind == .setting && row.name == "require_local_access_key")
            #expect(row.status == .needsUserAction, "\(first.items)")
            #expect(row.message?.contains("No access key exists yet") == true, "\(row.message ?? "")")
            #expect(first.exitCode == 3)
            #expect(settings.values[key] == .bool(true))
            #expect(settingReceipt(id, "require_local_access_key")?.settingValue == .bool(true))

            settings.accessKeys = true
            let again = try await apply(.install, bundleAt: root, bundleId: id, settings: settings)
            #expect(again.items.first?.status == .unchanged, "\(again.items)")

            settings.values[key] = .bool(false)
            let update = try await apply(.update, bundleAt: root, bundleId: id, settings: settings)
            #expect(update.items.first?.status == .skipped, "\(update.items)")
            #expect(update.items.first?.message?.contains("Changed in") == true)
            #expect(settings.values[key] == .bool(false))

            let reinstall = try await apply(.install, bundleAt: root, bundleId: id, settings: settings)
            #expect(reinstall.items.first?.status == .done, "\(reinstall.items)")
            #expect(settings.values[key] == .bool(true))

            let removed = try await apply(.remove, bundleAt: root, bundleId: id, settings: settings)
            #expect(removed.items.first?.status == .done, "\(removed.items)")
            #expect(removed.items.first?.message?.contains("stays on") == true, "\(removed.items)")
            #expect(settings.values[key] == .bool(true))
            #expect(settingReceipt(id, "require_local_access_key") == nil)
        }
    }

    @Test
    func turningTheAccessKeyOffNeedsConfirmation() async throws {
        try await exclusive {
            let (root, id) = try makeSettingsBundle(["require_local_access_key": false])
            defer { try? FileManager.default.removeItem(at: root) }
            let settings = FakeSettings()
            settings.values[.requireLocalAccessKey] = .bool(true)

            let refused = try await apply(.install, bundleAt: root, bundleId: id, settings: settings)
            #expect(refused.items.first?.status == .failed)
            #expect(refused.items.first?.message?.contains("--yes") == true)
            #expect(settings.values[.requireLocalAccessKey] == .bool(true))

            let confirmed = try await apply(.install, bundleAt: root, bundleId: id, settings: settings, yes: true)
            #expect(confirmed.items.first?.status == .done, "\(confirmed.items)")
            #expect(settings.values[.requireLocalAccessKey] == .bool(false))

            _ = try await apply(.remove, bundleAt: root, bundleId: id, settings: settings)
        }
    }

    @Test
    func originsAreAdded_andTheServerRestartWaitsForTheCaller() async throws {
        try await exclusive {
            let (root, id) = try makeSettingsBundle(["allowed_origins": ["https://app.example.com"]])
            defer { try? FileManager.default.removeItem(at: root) }
            let settings = FakeSettings()
            settings.values[.allowedOrigins] = .strings(["https://mine.example.com"])

            let refused = try await apply(.install, bundleAt: root, bundleId: id, settings: settings)
            #expect(refused.items.first?.status == .failed)
            #expect(settings.values[.allowedOrigins] == .strings(["https://mine.example.com"]))

            let result = try await apply(.install, bundleAt: root, bundleId: id, settings: settings, yes: true)
            #expect(result.items.first?.status == .done, "\(result.items)")
            #expect(result.items.first?.message?.contains("restarts") == true)
            #expect(
                settings.values[.allowedOrigins] == .strings(["https://mine.example.com", "https://app.example.com"]))
            #expect(settings.restarts == 0)
            let processor = processor()
            processor.settings = settings
            await processor.applyDeferredSettings()
            #expect(settings.restarts == 1)

            let removed = try await apply(.remove, bundleAt: root, bundleId: id, settings: settings)
            #expect(removed.items.first?.status == .done)
            #expect(settings.values[.allowedOrigins]?.description.contains("https://app.example.com") == true)
        }
    }

    @Test
    func aSettingAlreadyInPlaceIsRecorded_soUpdateStillRespectsTheUser() async throws {
        try await exclusive {
            let (root, id) = try makeSettingsBundle(["require_local_access_key": true])
            defer { try? FileManager.default.removeItem(at: root) }
            let settings = FakeSettings()
            settings.values[.requireLocalAccessKey] = .bool(true)
            settings.accessKeys = true

            let first = try await apply(.install, bundleAt: root, bundleId: id, settings: settings)
            #expect(first.items.first?.status == .unchanged, "\(first.items)")
            #expect(first.items.first?.message?.contains("already on") == true, "\(first.items)")
            #expect(settingReceipt(id, "require_local_access_key")?.settingValue == .bool(true))

            settings.values[.requireLocalAccessKey] = .bool(false)
            let update = try await apply(.update, bundleAt: root, bundleId: id, settings: settings)
            #expect(update.items.first?.status == .skipped, "\(update.items)")
            #expect(settings.values[.requireLocalAccessKey] == .bool(false))

            _ = try await apply(.remove, bundleAt: root, bundleId: id, settings: settings)
        }
    }

    @Test
    func twoBundlesMayNotAskForOppositeValues() async throws {
        try await exclusive {
            let (onRoot, onId) = try makeSettingsBundle(["require_local_access_key": true])
            let (offRoot, offId) = try makeSettingsBundle(["require_local_access_key": false])
            defer {
                try? FileManager.default.removeItem(at: onRoot)
                try? FileManager.default.removeItem(at: offRoot)
            }
            let settings = FakeSettings()
            settings.accessKeys = true
            _ = try await apply(.install, bundleAt: onRoot, bundleId: onId, settings: settings)

            let other = try await apply(.install, bundleAt: offRoot, bundleId: offId, settings: settings, yes: true)
            let row = try #require(other.items.first)
            #expect(row.status == .failed)
            #expect(row.message?.contains(onId) == true, "\(row.message ?? "")")
            #expect(settings.values[.requireLocalAccessKey] == .bool(true))

            _ = try await apply(.remove, bundleAt: onRoot, bundleId: onId, settings: settings)
            let afterRemoval = try await apply(.install, bundleAt: offRoot, bundleId: offId, settings: settings, yes: true)
            #expect(afterRemoval.items.first?.status == .done, "\(afterRemoval.items)")
            _ = try await apply(.remove, bundleAt: offRoot, bundleId: offId, settings: settings)
        }
    }

    /// docs/examples/osaurus-bundle-example is what the author guide walks
    /// through: every agent file and server entry passes the app's strict
    /// schema check, the same one `osaurus import validate` asks a running
    /// app for.
    @Test
    func shippedExampleBundlePassesTheAppsSchemaCheck() async throws {
        try await exclusive {
            let example = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Import/
                .deletingLastPathComponent()  // Tests/
                .deletingLastPathComponent()  // OsaurusCore/
                .deletingLastPathComponent()  // Packages/
                .deletingLastPathComponent()  // repo root
                .appendingPathComponent("docs/examples/osaurus-bundle-example", isDirectory: true)
            let bundle = try OsaurusBundle.load(from: example)
            let operations = try bundle.select(kind: nil, names: []).map {
                ImportOperation(action: .install, kind: $0.kind, name: $0.name, explicit: $0.explicit)
            }
            let checked = await processor().plan(bundleAt: example, operations: operations)
            #expect(checked.issues.isEmpty, "\(checked.issues)")

            let support = try Template.parse(
                String(contentsOf: example.appendingPathComponent("agents/support-desk.json"), encoding: .utf8))
            #expect(support.agent.skills == .value(["triage-ticket"]))
            #expect(support.agent.tools?.mode == "manual")
            #expect(support.modelPolicy == .preferred)
            let checker = try Template.parse(
                String(contentsOf: example.appendingPathComponent("agents/release-checker.json"), encoding: .utf8))
            #expect(checker.agent.sandbox?.enabled == true)
            #expect(checker.agent.sandbox?.networkEnabled == false)
            #expect(checker.agent.skills == .value([]))
        }
    }
}
