import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct ClassicResaveRecoveryTests {
    @Test("an agent saved by Classic gets its 1.0-only fields back and keeps Classic's edits")
    func agentFieldsSurviveClassicSave() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.agentWithEveryClassicUnknownField()
            AgentStore.save(agent)
            _ = try AgentStore.loadPersisted(id: agent.id)
            let url = Self.agentURL(agent.id)

            try Self.simulateClassicSave(url, dropping: AgentStore.classicUnknownFields) {
                $0["name"] = "Builder (edited in Classic)"
            }
            let onDisk = try Self.decoder.decode(Agent.self, from: Data(contentsOf: url))
            #expect(onDisk.settings.workingFolderReadOnly == false)
            #expect(onDisk.settings.enabledWorkflowIDs.isEmpty)

            let loaded = try AgentStore.loadPersisted(id: agent.id)
            #expect(loaded.name == "Builder (edited in Classic)")
            #expect(loaded.sharedToolApproval == agent.sharedToolApproval)
            #expect(loaded.pluginId == agent.pluginId)
            #expect(loaded.autonomousExec?.hostServicesEnabled == true)
            #expect(loaded.settings.enabledWorkflowIDs == agent.settings.enabledWorkflowIDs)
            #expect(loaded.settings.workingFolderReadOnly == true)
            #expect(loaded.settings.followUp.enabled == false)
        }
    }

    @Test("a field cleared in 1.0 before Classic saved stays cleared")
    func clearedFieldIsNotPutBack() async throws {
        try await ChatHistoryTestStorage.run {
            var agent = Self.agentWithEveryClassicUnknownField()
            AgentStore.save(agent)
            agent.settings.workingFolderReadOnly = false
            agent.settings.enabledWorkflowIDs = []
            AgentStore.save(agent)
            _ = try AgentStore.loadPersisted(id: agent.id)

            try Self.simulateClassicSave(Self.agentURL(agent.id), dropping: AgentStore.classicUnknownFields)

            let loaded = try AgentStore.loadPersisted(id: agent.id)
            #expect(loaded.settings.workingFolderReadOnly == false)
            #expect(loaded.settings.enabledWorkflowIDs.isEmpty)
            #expect(loaded.settings.followUp.enabled == false)
        }
    }

    @Test("an object Classic removed is not recreated, and deleting an agent drops its copy")
    func removedParentAndDeletedAgent() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = Self.agentWithEveryClassicUnknownField()
            AgentStore.save(agent)
            _ = try AgentStore.loadPersisted(id: agent.id)
            let url = Self.agentURL(agent.id)

            try Self.simulateClassicSave(url, dropping: AgentStore.classicUnknownFields) {
                $0.removeValue(forKey: "autonomousExec")
            }
            #expect(try AgentStore.loadPersisted(id: agent.id).autonomousExec == nil)

            let copy = try #require(ClassicResaveRecovery.copyURL(for: url))
            #expect(FileManager.default.fileExists(atPath: copy.path))
            #expect(AgentStore.delete(id: agent.id))
            #expect(!FileManager.default.fileExists(atPath: copy.path))
        }
    }

    @Test("a record with no copy is returned byte for byte")
    func recordWithoutCopyIsUnchanged() async throws {
        try await ChatHistoryTestStorage.run {
            let url = Self.agentURL(UUID())
            let data = Data(#"{"name":"Written by Classic"}"#.utf8)
            #expect(ClassicResaveRecovery.restoring(data, at: url, fields: AgentStore.classicUnknownFields) == data)
        }
    }

    @Test("a remote agent saved by Classic keeps its revocation")
    func remoteAgentRevocationSurvivesClassicSave() async throws {
        try await ChatHistoryTestStorage.run {
            var remote = RemoteAgent(
                agentAddress: "0xabc", name: "Peer", description: "",
                relayBaseURL: "https://relay.example", providerId: UUID()
            )
            remote.accessRevokedAt = Date(timeIntervalSince1970: 1_800_000_000)
            RemoteAgentStore.save(remote)
            let url = OsaurusPaths.remoteAgents().appendingPathComponent("\(remote.id.uuidString).json")

            try Self.simulateClassicSave(url, dropping: RemoteAgentStore.classicUnknownFields) {
                $0["name"] = "Peer (renamed in Classic)"
            }

            let loaded = try #require(RemoteAgentStore.loadAll().first { $0.id == remote.id })
            #expect(loaded.name == "Peer (renamed in Classic)")
            #expect(loaded.accessRevokedAt == remote.accessRevokedAt)
        }
    }

    @Test("sandbox.json saved by Classic keeps the warm-rootfs key and environment limits")
    func sandboxFieldsSurviveClassicSave() async throws {
        try await ChatHistoryTestStorage.run {
            let original = SandboxConfigurationStore.load()
            defer {
                SandboxConfigurationStore.save(original)
                SandboxConfigurationStore.flushPendingWrites()
            }
            var config = SandboxConfiguration.default
            config.maxAgentEnvironments = SandboxConfiguration.legacyDefaultContainersPerBoot
            config.lastRootfsFormatVersion = "rootfs-fixture"
            config.maxRetainedEnvironments = 7
            config.idleShutdownMinutes = 15
            SandboxConfigurationStore.save(config)
            SandboxConfigurationStore.flushPendingWrites()

            try Self.simulateClassicSave(
                OsaurusPaths.sandboxConfigFile(), dropping: SandboxConfigurationStore.classicUnknownFields
            ) {
                $0["cpus"] = 4
            }
            SandboxConfigurationStore.resetCacheForTests()

            let loaded = SandboxConfigurationStore.load()
            #expect(loaded.cpus == 4)
            #expect(loaded.lastRootfsFormatVersion == "rootfs-fixture")
            #expect(loaded.maxRetainedEnvironments == 7)
            #expect(loaded.idleShutdownMinutes == 15)
            // Without maxRetainedEnvironments, 3 containers reads as the
            // pre-split default and is replaced by the RAM-scaled one.
            #expect(loaded.maxAgentEnvironments == SandboxConfiguration.legacyDefaultContainersPerBoot)
        }
    }

    @Test("every listed field is a real key in what 1.0 writes")
    func listedFieldsExistInEncodedRecords() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var remote = RemoteAgent(
            agentAddress: "0xabc", name: "Peer", description: "",
            relayBaseURL: "https://relay.example", providerId: UUID()
        )
        remote.accessRevokedAt = Date()
        var sandbox = SandboxConfiguration.default
        sandbox.lastRootfsFormatVersion = "rootfs-fixture"

        let records: [(Data, [ClassicResaveRecovery.FieldPath])] = [
            (try encoder.encode(Self.agentWithEveryClassicUnknownField()), AgentStore.classicUnknownFields),
            (try encoder.encode(remote), RemoteAgentStore.classicUnknownFields),
            (try encoder.encode(sandbox), SandboxConfigurationStore.classicUnknownFields),
        ]
        for (data, fields) in records {
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            for path in fields {
                #expect(Self.value(at: path, in: json) != nil, "\(path.joined(separator: ".")) is not written")
            }
        }
    }

    // MARK: - Fixtures

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func agentWithEveryClassicUnknownField() -> Agent {
        var agent = Agent(name: "Builder")
        agent.sharedToolApproval = SharedToolApprovalPolicy(mode: .askOwner, timeoutSeconds: 120)
        agent.pluginId = "acme-plugin"
        agent.autonomousExec = AutonomousExecConfig(enabled: true, hostServicesEnabled: true)
        agent.settings.enabledWorkflowIDs = [UUID(), UUID()]
        agent.settings.workingFolderReadOnly = true
        agent.settings.followUp.enabled = false
        return agent
    }

    private static func agentURL(_ id: UUID) -> URL {
        OsaurusPaths.agents().appendingPathComponent("\(id.uuidString).json")
    }

    /// What Classic 0.25.x leaves after loading and saving a record: the
    /// fields it doesn't know are gone, everything else is as written.
    private static func simulateClassicSave(
        _ url: URL,
        dropping fields: [ClassicResaveRecovery.FieldPath],
        edit: (inout [String: Any]) -> Void = { _ in }
    ) throws {
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for path in fields { remove(path[...], from: &json) }
        edit(&json)
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    private static func remove(_ path: ArraySlice<String>, from json: inout [String: Any]) {
        guard let key = path.first else { return }
        if path.count == 1 {
            json.removeValue(forKey: key)
        } else if var child = json[key] as? [String: Any] {
            remove(path.dropFirst(), from: &child)
            json[key] = child
        }
    }

    private static func value(at path: ClassicResaveRecovery.FieldPath, in json: [String: Any]) -> Any? {
        var current: Any? = json
        for key in path { current = (current as? [String: Any])?[key] }
        return current
    }
}
