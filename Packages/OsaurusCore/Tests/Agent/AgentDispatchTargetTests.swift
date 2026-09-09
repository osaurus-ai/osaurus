//
//  AgentDispatchTargetTests.swift
//  osaurusTests
//
//  `AgentDispatchTarget` / `WorkspaceAgentRef`: the durable identity a
//  trigger stores for "who runs this", its legacy-UUID decode path, and the
//  resolver that turns caller identifiers (uuid, address, name, key) into a
//  target — including the `localOnly` scope the HTTP API relies on.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct AgentDispatchTargetTests {

    private static let sharedAddress = "0xAAAA000000000000000000000000000000000001"
    private static let otherSharedAddress = "0xBBBB000000000000000000000000000000000002"
    private static let ref = WorkspaceAgentRef(workspaceId: "ws-1", agentAddress: sharedAddress)

    // MARK: - WorkspaceAgentRef

    @Test func ref_lowercasesAddressAndRoundTripsKey() throws {
        let ref = Self.ref
        #expect(ref.agentAddress == Self.sharedAddress.lowercased())
        #expect(ref.key == "ws-1:\(Self.sharedAddress.lowercased())")
        #expect(WorkspaceAgentRef(key: ref.key) == ref)
        // Workspace ids may themselves contain ":" — the LAST separator wins.
        let colon = WorkspaceAgentRef(workspaceId: "org:team", agentAddress: Self.sharedAddress)
        #expect(WorkspaceAgentRef(key: colon.key) == colon)
    }

    @Test func ref_keyParserRejectsNonAddresses() {
        #expect(WorkspaceAgentRef(key: "ws-1:not-an-address") == nil)
        #expect(WorkspaceAgentRef(key: ":\(Self.sharedAddress)") == nil)
        #expect(WorkspaceAgentRef(key: Self.sharedAddress) == nil)
        #expect(WorkspaceAgentRef(key: "sales") == nil)
        #expect(WorkspaceAgentRef.looksLikeAddress(Self.sharedAddress))
        #expect(!WorkspaceAgentRef.looksLikeAddress("0x123"))
        #expect(!WorkspaceAgentRef.looksLikeAddress("0xZZZZ000000000000000000000000000000000001"))
    }

    // MARK: - Codable

    @Test func target_decodesBareUUIDAsLocal() throws {
        let id = UUID()
        let data = Data("\"\(id.uuidString)\"".utf8)
        let decoded = try JSONDecoder().decode(AgentDispatchTarget.self, from: data)
        #expect(decoded == .local(id))
    }

    @Test func target_taggedFormRoundTrips() throws {
        for target in [AgentDispatchTarget.local(UUID()), .workspace(Self.ref)] {
            let data = try JSONEncoder().encode(target)
            let decoded = try JSONDecoder().decode(AgentDispatchTarget.self, from: data)
            #expect(decoded == target)
        }
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AgentDispatchTarget.workspace(Self.ref))
        ) as? [String: Any]
        #expect(json?["kind"] as? String == "workspace")
        #expect((json?["workspace"] as? [String: Any])?["agent_address"] as? String == Self.ref.agentAddress)
    }

    /// Stored schedules only ever carried `agentId` (older still: `personaId`).
    @Test func schedule_decodesLegacyAgentIdAndPersonaId() throws {
        let id = UUID()
        let legacy = """
            {"id":"\(UUID().uuidString)","name":"n","instructions":"i","agentId":"\(id.uuidString)",
             "frequency":{"daily":{"hour":9,"minute":0}},"isEnabled":true,"createdAt":0,"updatedAt":0}
            """
        let schedule = try JSONDecoder().decode(Schedule.self, from: Data(legacy.utf8))
        #expect(schedule.target == .local(id))
        #expect(schedule.agentId == id)
        #expect(schedule.workspaceTarget == nil)

        let persona = legacy.replacingOccurrences(of: "\"agentId\"", with: "\"personaId\"")
        let fromPersona = try JSONDecoder().decode(Schedule.self, from: Data(persona.utf8))
        #expect(fromPersona.target == .local(id))
    }

    /// A local target writes BOTH `target` and the legacy `agentId` so an
    /// older build reading the same file sees the UUID it expects; a
    /// workspace target leaves `agentId` unset.
    @Test func schedule_encodesLegacyAgentIdOnlyForLocalTargets() throws {
        let id = UUID()
        var schedule = Schedule(name: "n", instructions: "i", target: .local(id), frequency: .daily(hour: 9, minute: 0))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schedule)) as? [String: Any]
        #expect(json?["agentId"] as? String == id.uuidString)
        #expect(json?["target"] != nil)

        schedule.target = .workspace(Self.ref)
        json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schedule)) as? [String: Any]
        #expect(json?["agentId"] == nil)
        let decoded = try JSONDecoder().decode(Schedule.self, from: JSONEncoder().encode(schedule))
        #expect(decoded.target == .workspace(Self.ref))
        #expect(decoded.agentId == nil)
        #expect(decoded.workspaceTarget == Self.ref)
    }

    @Test func watcher_decodesLegacyAgentIdAndRoundTripsWorkspaceTarget() throws {
        let id = UUID()
        let legacy = """
            {"id":"\(UUID().uuidString)","name":"n","instructions":"i","agentId":"\(id.uuidString)",
             "watchPath":"/tmp","recursive":false,"isEnabled":true,"createdAt":0,"updatedAt":0}
            """
        let watcher = try JSONDecoder().decode(Watcher.self, from: Data(legacy.utf8))
        #expect(watcher.target == .local(id))

        var shared = watcher
        shared.target = .workspace(Self.ref)
        let decoded = try JSONDecoder().decode(Watcher.self, from: JSONEncoder().encode(shared))
        #expect(decoded.target == .workspace(Self.ref))
        #expect(decoded.agentId == nil)
    }

    @Test func channelRoute_decodesLegacyAgentIdAndRoundTripsWorkspaceTarget() throws {
        let id = UUID()
        let legacy = """
            {"id":"\(UUID().uuidString)","roomId":"C1","agentId":"\(id.uuidString)","nameAliases":["sales"]}
            """
        let route = try JSONDecoder().decode(AgentChannelDispatchRoute.self, from: Data(legacy.utf8))
        #expect(route.target == .local(id))
        #expect(route.agentId == id)

        var shared = route
        shared.target = .workspace(Self.ref)
        let decoded = try JSONDecoder().decode(AgentChannelDispatchRoute.self, from: JSONEncoder().encode(shared))
        #expect(decoded.target == .workspace(Self.ref))
        #expect(decoded.agentId == nil)

        let config = AgentChannelInboundDispatchConfiguration(
            enabled: true, target: .workspace(Self.ref), routes: [shared]
        )
        let decodedConfig = try JSONDecoder().decode(
            AgentChannelInboundDispatchConfiguration.self, from: JSONEncoder().encode(config)
        )
        #expect(decodedConfig.target == .workspace(Self.ref))
        #expect(decodedConfig.targetAgentId == nil)
        #expect(decodedConfig.referencedTargets.contains(.workspace(Self.ref)))
    }

    // MARK: - Resolver

    private static func localAgent(name: String, address: String? = nil) -> Agent {
        var agent = Agent(name: name, description: "", systemPrompt: "")
        agent.agentAddress = address
        return agent
    }

    @Test func resolver_matchesLocalUUIDAndAddressInBothScopes() {
        let local = Self.localAgent(name: "Sales", address: Self.otherSharedAddress)
        let shared = [(ref: Self.ref, name: Optional("Research"))]
        for scope in [AgentTargetResolver.Scope.localOnly, .localAndWorkspace] {
            #expect(
                AgentTargetResolver.resolve(local.id.uuidString, scope: scope, localAgents: [local], sharedAgents: shared)
                    == .success(.local(local.id))
            )
            #expect(
                AgentTargetResolver.resolve(
                    Self.otherSharedAddress.uppercased(), scope: scope, localAgents: [local], sharedAgents: shared
                ) == .success(.local(local.id))
            )
            #expect(
                AgentTargetResolver.resolve(" sales ", scope: scope, localAgents: [local], sharedAgents: shared)
                    == .success(.local(local.id))
            )
            #expect(
                AgentTargetResolver.resolve(UUID().uuidString, scope: scope, localAgents: [local], sharedAgents: shared)
                    == .failure(.notFound)
            )
        }
    }

    /// The whole point of `localOnly`: a teammate's shared agent is not
    /// reachable by address, key or name through the local HTTP API.
    @Test func resolver_localOnlyNeverResolvesSharedAgents() {
        let local = Self.localAgent(name: "Sales")
        let shared = [(ref: Self.ref, name: Optional("Research"))]
        for identifier in [Self.sharedAddress, Self.ref.key, "Research"] {
            #expect(
                AgentTargetResolver.resolve(identifier, scope: .localOnly, localAgents: [local], sharedAgents: shared)
                    == .failure(.notFound),
                "\(identifier)"
            )
            #expect(
                AgentTargetResolver.resolve(
                    identifier, scope: .localAndWorkspace, localAgents: [local], sharedAgents: shared
                ) == .success(.workspace(Self.ref)),
                "\(identifier)"
            )
        }
    }

    @Test func resolver_reportsAmbiguousNamesAndAddresses() {
        let local = Self.localAgent(name: "Research")
        let twice = [
            (ref: Self.ref, name: Optional("Research")),
            (ref: WorkspaceAgentRef(workspaceId: "ws-2", agentAddress: Self.sharedAddress), name: Optional("Research")),
        ]
        // Same address shared into two workspaces: the caller must pick a key.
        let byAddress = AgentTargetResolver.resolve(
            Self.sharedAddress, scope: .localAndWorkspace, localAgents: [], sharedAgents: twice
        )
        #expect(byAddress == .failure(.ambiguous(twice.map(\.ref.key))))
        #expect(
            AgentTargetResolver.resolve(twice[1].ref.key, scope: .localAndWorkspace, localAgents: [], sharedAgents: twice)
                == .success(.workspace(twice[1].ref))
        )
        // A local agent and a shared agent with the same display name.
        let byName = AgentTargetResolver.resolve(
            "research", scope: .localAndWorkspace, localAgents: [local], sharedAgents: [twice[0]]
        )
        guard case .failure(.ambiguous(let candidates)) = byName else {
            Issue.record("expected ambiguous, got \(byName)")
            return
        }
        #expect(candidates.contains(local.id.uuidString))
        #expect(candidates.contains(Self.ref.key))
        // localOnly sees only the local one, so the name is unambiguous.
        #expect(
            AgentTargetResolver.resolve("research", scope: .localOnly, localAgents: [local], sharedAgents: [twice[0]])
                == .success(.local(local.id))
        )
    }
}
