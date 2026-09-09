//
//  WorkspaceDispatchTargetTests.swift
//  OsaurusCoreTests
//
//  The `AgentDispatchTarget` plumbing behind every trigger that can name a
//  teammate's shared workspace agent: schedules, watchers, channel routes,
//  the delegation configuration and the dispatch funnel. Stored rows written
//  before workspace targets must keep decoding as `.local`; workspace rows
//  round-trip; the funnel refuses a workspace run with a typed reason that
//  spawn turns into a tool result instead of a prompt change.
//

import Foundation
import Testing

@testable import OsaurusCore

private let wsAddress = "0xaaaa0000000000000000000000000000000000e1"
private let wsRef = WorkspaceAgentRef(workspaceId: "ws-target", agentAddress: wsAddress)

private func json(_ value: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func decode<T: Decodable>(_ type: T.Type, _ body: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(body.utf8))
}

// MARK: - Stored models

@Suite("Workspace dispatch target: stored models")
struct WorkspaceTargetStoredModelTests {

    @Test("legacy schedule with a bare agentId decodes as a local target")
    func legacyScheduleDecodesLocal() throws {
        let id = UUID()
        let body = """
            {"id":"\(UUID().uuidString)","name":"s","instructions":"i","agentId":"\(id.uuidString)",
             "frequency":{"daily":{"hour":8,"minute":0}},"isEnabled":true,
             "createdAt":0,"updatedAt":0}
            """
        let schedule = try decode(Schedule.self, body)
        #expect(schedule.target == .local(id))
        #expect(schedule.agentId == id)
        #expect(schedule.workspaceTarget == nil)
    }

    @Test("oldest schedule shape (personaId) still decodes as a local target")
    func personaIdScheduleDecodesLocal() throws {
        let id = UUID()
        let body = """
            {"id":"\(UUID().uuidString)","name":"s","instructions":"i","personaId":"\(id.uuidString)",
             "frequency":{"daily":{"hour":8,"minute":0}},"isEnabled":true,
             "createdAt":0,"updatedAt":0}
            """
        #expect(try decode(Schedule.self, body).target == .local(id))
    }

    @Test("schedule targeting a workspace agent round-trips and leaves agentId unset")
    func workspaceScheduleRoundTrips() throws {
        let schedule = Schedule(
            name: "Daily digest", instructions: "Summarize", target: .workspace(wsRef),
            frequency: .daily(hour: 8, minute: 0))
        #expect(schedule.agentId == nil)
        #expect(schedule.workspaceTarget == wsRef)

        let object = try json(schedule)
        #expect(object["agentId"] == nil, "older builds must see 'no agent', not a bogus UUID")
        let target = try #require(object["target"] as? [String: Any])
        #expect(target["kind"] as? String == "workspace")

        let decoded = try JSONDecoder().decode(Schedule.self, from: JSONEncoder().encode(schedule))
        #expect(decoded.target == .workspace(wsRef))
    }

    @Test("local schedule keeps writing the legacy agentId alongside target")
    func localScheduleWritesBothKeys() throws {
        let id = UUID()
        let schedule = Schedule(
            name: "s", instructions: "i", agentId: id, frequency: .daily(hour: 8, minute: 0))
        let object = try json(schedule)
        #expect(object["agentId"] as? String == id.uuidString)
        let target = try #require(object["target"] as? [String: Any])
        #expect(target["kind"] as? String == "local")
        #expect(target["id"] as? String == id.uuidString)
    }

    @Test("setting agentId on a schedule replaces the target with a local one")
    func scheduleAgentIdSetterRewritesTarget() {
        var schedule = Schedule(
            name: "s", instructions: "i", target: .workspace(wsRef),
            frequency: .daily(hour: 8, minute: 0))
        let id = UUID()
        schedule.agentId = id
        #expect(schedule.target == .local(id))
        schedule.agentId = nil
        #expect(schedule.target == nil)
    }

    @Test("legacy watcher decodes local; workspace watcher round-trips")
    func watcherTargets() throws {
        let id = UUID()
        let legacy = """
            {"id":"\(UUID().uuidString)","name":"w","instructions":"i","agentId":"\(id.uuidString)",
             "isEnabled":true,"recursive":false,"responsiveness":"balanced","settleSeconds":2,
             "createdAt":0,"updatedAt":0}
            """
        #expect(try decode(Watcher.self, legacy).target == .local(id))

        let watcher = Watcher(name: "Inbox", instructions: "File it", target: .workspace(wsRef))
        #expect(watcher.agentId == nil)
        #expect(watcher.workspaceTarget == wsRef)
        let object = try json(watcher)
        #expect(object["agentId"] == nil)
        let decoded = try JSONDecoder().decode(Watcher.self, from: JSONEncoder().encode(watcher))
        #expect(decoded.target == .workspace(wsRef))
    }

    @Test("channel route: legacy agentId decodes; workspace route round-trips; neither key is malformed")
    func channelRouteTargets() throws {
        let id = UUID()
        let legacy = """
            {"id":"\(UUID().uuidString)","roomId":"C1","agentId":"\(id.uuidString)","nameAliases":["ops"]}
            """
        let legacyRoute = try decode(AgentChannelDispatchRoute.self, legacy)
        #expect(legacyRoute.target == .local(id))
        #expect(legacyRoute.agentId == id)

        let route = AgentChannelDispatchRoute(roomId: "C2", target: .workspace(wsRef), nameAliases: ["Research"])
        #expect(route.agentId == nil)
        let object = try json(route)
        #expect(object["agentId"] == nil)
        let decoded = try JSONDecoder().decode(
            AgentChannelDispatchRoute.self, from: JSONEncoder().encode(route))
        #expect(decoded == route)

        #expect(throws: DecodingError.self) {
            try decode(AgentChannelDispatchRoute.self, #"{"id":"\#(UUID().uuidString)","roomId":"C3"}"#)
        }
    }

    @Test("inbound dispatch configuration: legacy targetAgentId decodes; referencedAgentIds skips workspace")
    func inboundConfigurationTargets() throws {
        let id = UUID()
        let legacy = """
            {"enabled":true,"targetAgentId":"\(id.uuidString)","routes":[],"requireMention":true,
             "continueThreads":true,"autoReplyEnabled":false}
            """
        let legacyConfig = try decode(AgentChannelInboundDispatchConfiguration.self, legacy)
        #expect(legacyConfig.target == .local(id))
        #expect(legacyConfig.targetAgentId == id)

        let localRoute = UUID()
        let config = AgentChannelInboundDispatchConfiguration(
            enabled: true,
            target: .workspace(wsRef),
            routes: [
                AgentChannelDispatchRoute(roomId: "C1", agentId: localRoute),
                AgentChannelDispatchRoute(roomId: "C2", target: .workspace(wsRef)),
            ]
        )
        #expect(config.isConfigured)
        #expect(config.targetAgentId == nil)
        #expect(config.referencedTargets == [.workspace(wsRef), .local(localRoute)])
        #expect(config.referencedAgentIds == [localRoute], "local-only readers must not see workspace refs")

        let decoded = try JSONDecoder().decode(
            AgentChannelInboundDispatchConfiguration.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
    }

    @Test("dispatch router resolves an alias route and the default to workspace targets")
    func routerResolvesWorkspaceTargets() {
        let local = UUID()
        let config = AgentChannelInboundDispatchConfiguration(
            enabled: true,
            target: .workspace(wsRef),
            routes: [AgentChannelDispatchRoute(roomId: nil, agentId: local, nameAliases: ["ops"])]
        )
        let byAlias = AgentChannelDispatchRouter.resolve(settings: config, roomId: "C9", content: "ops: deploy")
        #expect(byAlias?.target == .local(local))
        #expect(byAlias?.agentId == local)
        #expect(byAlias?.content == "deploy")

        let byDefault = AgentChannelDispatchRouter.resolve(settings: config, roomId: "C9", content: "hello")
        #expect(byDefault?.target == .workspace(wsRef))
        #expect(byDefault?.agentId == nil)
        #expect(byDefault?.matchedRule == "default")
    }

    @Test("DispatchRequest derives agentId from a local target and exposes the workspace ref")
    func dispatchRequestTarget() {
        let id = UUID()
        let local = DispatchRequest(prompt: "p", agentId: id)
        #expect(local.target == .local(id))
        #expect(local.agentId == id)
        #expect(local.workspaceTarget == nil)

        let workspace = DispatchRequest(prompt: "p", target: .workspace(wsRef), source: .schedule)
        #expect(workspace.agentId == nil)
        #expect(workspace.workspaceTarget == wsRef)

        // `target` wins when both spellings are given.
        let both = DispatchRequest(prompt: "p", agentId: id, target: .workspace(wsRef))
        #expect(both.target == .workspace(wsRef))
    }

    @Test("delegation configuration and per-agent settings persist the workspace pool")
    func spawnableWorkspaceAgentsPersist() throws {
        let duplicate = WorkspaceAgentRef(workspaceId: "ws-target", agentAddress: wsAddress.uppercased())
        let config = SubagentConfiguration(spawnableWorkspaceAgents: [wsRef, duplicate])
        #expect(config.spawnableWorkspaceAgents == [wsRef], "addresses are lowercased and de-duplicated")
        #expect(config.isWorkspaceAgentSpawnable(wsRef))
        #expect(config.anyWorkspaceAgentSpawnable)

        let roundTrip = try JSONDecoder().decode(
            SubagentConfiguration.self, from: JSONEncoder().encode(config))
        #expect(roundTrip.spawnableWorkspaceAgents == [wsRef])

        // Older files have no key at all; an empty pool is also not written.
        #expect(try decode(SubagentConfiguration.self, "{}").spawnableWorkspaceAgents.isEmpty)
        let bare = try json(SubagentConfiguration())
        #expect(bare["spawnableWorkspaceAgents"] == nil)

        // A malformed entry never discards the whole delegation config.
        let malformed = """
            {"spawnableWorkspaceAgents":[{"workspace_id":"ws","agent_address":42}],
             "spawnableModelNames":["m"]}
            """
        let lenient = try decode(SubagentConfiguration.self, malformed)
        #expect(lenient.spawnableWorkspaceAgents.isEmpty)
        #expect(lenient.spawnableModelNames == ["m"])

        var settings = Agent(name: "Launcher").settings
        settings.spawnDelegationEnabled = true
        settings.spawnableWorkspaceAgents = [wsRef]
        let decodedSettings = try JSONDecoder().decode(
            AgentSettings.self, from: JSONEncoder().encode(settings))
        #expect(decodedSettings.spawnableWorkspaceAgents == [wsRef])
    }

    @Test("effective workspace pool: Default uses the shared pool, custom agents their own list behind the toggle")
    func effectiveWorkspacePool() {
        let config = SubagentConfiguration(spawnableWorkspaceAgents: [wsRef])
        let other = WorkspaceAgentRef(workspaceId: "ws-other", agentAddress: "0xbbbb0000000000000000000000000000000000e2")

        #expect(
            SubagentToolVisibility.effectiveSpawnableWorkspaceAgents(
                isDefault: true, config: config, perAgentEnabled: false, perAgentTargets: [other]) == [wsRef])
        #expect(
            SubagentToolVisibility.effectiveSpawnableWorkspaceAgents(
                isDefault: false, config: config, perAgentEnabled: true, perAgentTargets: [other]) == [other])
        #expect(
            SubagentToolVisibility.effectiveSpawnableWorkspaceAgents(
                isDefault: false, config: config, perAgentEnabled: false, perAgentTargets: [other]).isEmpty,
            "a custom agent with delegation off spawns nothing")
        #expect(
            SubagentToolVisibility.spawnWorkspaceAgentAllowed(
                wsRef, isDefault: true, config: config, perAgentTargets: []))
        #expect(
            !SubagentToolVisibility.spawnWorkspaceAgentAllowed(
                wsRef, isDefault: false, config: config, perAgentTargets: [other]),
            "the shared pool never widens a custom agent's own list")
    }
}

// MARK: - Declarative config

@Suite(.serialized)
@MainActor
struct WorkspaceTargetDeclarativeConfigTests {

    @Test("delegation.spawnable_workspace_agents must be <workspace_id>:<0x-address> keys")
    func spawnableWorkspaceAgentsShapeIsValidated() throws {
        var document = OsaurusConfigDocument()
        var delegation = DelegationSection()
        delegation.spawnableWorkspaceAgents = ["not-a-key", "ws:0x1234"]
        document.delegation = delegation
        do {
            _ = try ConfigPlanner.plan(document: document, prune: false)
            Issue.record("expected ConfigPlanIssues for malformed workspace keys")
        } catch let issues as ConfigPlanIssues {
            #expect(issues.issues.contains { $0.contains("not-a-key") && $0.contains("spawnable_workspace_agents") })
            #expect(issues.issues.contains { $0.contains("ws:0x1234") })
        }

        // A well-formed key plans an update against the (empty) live pool
        // without touching the roster — membership is probed at spawn time.
        delegation.spawnableWorkspaceAgents = [wsRef.key]
        document.delegation = delegation
        let plan = try ConfigPlanner.plan(document: document, prune: false)
        let change = plan.actions.first { $0.section == "delegation" }
        #expect(change?.changes.contains { $0.contains("spawnable_workspace_agents") } == true, "\(plan.summaryText())")
    }

    @Test("schedules and watchers accept a workspace key where an agent name is expected")
    func scheduleAndWatcherAcceptWorkspaceKeys() throws {
        var document = OsaurusConfigDocument()
        var schedule = ScheduleEntry(name: "Workspace Probe Schedule \(UUID().uuidString.prefix(6))")
        schedule.agent = wsRef.key
        schedule.instructions = "do things"
        schedule.frequency = "daily"
        schedule.frequencyTimeOfDay = "08:00"
        document.schedules = [schedule]

        let plan = try ConfigPlanner.plan(document: document, prune: false)
        #expect(plan.actions.contains { $0.section == "schedules" && $0.kind == .create }, "\(plan.summaryText())")

        // The exporter writes the same key back for a workspace-targeted row.
        #expect(ConfigAgentTargetReference.export(.workspace(wsRef)) == wsRef.key)
        #expect(ConfigAgentTargetReference.workspaceRef(wsRef.key) == wsRef)
        #expect(ConfigAgentTargetReference.workspaceRef("Research Agent") == nil)
        #expect(ConfigAgentTargetReference.currentLabel(.workspace(wsRef)) == wsRef.key)
    }
}

// MARK: - Dispatch funnel

@Suite(.serialized)
@MainActor
struct WorkspaceDispatchFunnelTests {

    /// Swap the shared run client's preflight seams for the duration of
    /// `body` so no relay, keychain or pairing is touched.
    private static func withRouterDisabled(_ body: () async throws -> Void) async throws {
        let client = WorkspaceAgentRunClient.shared
        let previous = client.routerEnabled
        client.routerEnabled = { false }
        defer { client.routerEnabled = previous }
        try await body()
    }

    @Test("a workspace dispatch the preflight refuses returns nil and leaves one consumable reason")
    func refusedWorkspaceDispatchIsConsumable() async throws {
        try await Self.withRouterDisabled {
            let manager = BackgroundTaskManager.shared
            let before = manager.backgroundTasks.count
            let request = DispatchRequest(
                prompt: "Summarize", target: .workspace(wsRef), title: "t", source: .schedule)
            let handle = await manager.dispatchChat(request)
            #expect(handle == nil)
            #expect(manager.backgroundTasks.count == before, "no task may be registered for a refused run")

            let reason = manager.consumeWorkspaceDispatchRefusal(for: wsRef)
            #expect(reason?.contains("Osaurus Router") == true, "\(String(describing: reason))")
            #expect(manager.consumeWorkspaceDispatchRefusal(for: wsRef) == nil, "reasons are one-shot")
        }
    }

    @Test("delegation to a refused workspace agent surfaces as SubagentError.unavailable")
    func delegationMapsRefusalToUnavailable() async throws {
        try await Self.withRouterDisabled {
            let feed = SubagentFeed(toolCallId: "t-ws-refused", kindId: "spawn", title: "task")
            defer { SubagentFeedRegistry.shared.removeNow(toolCallId: "t-ws-refused") }
            do {
                _ = try await AgentDelegationDispatcher.run(
                    target: .workspace(wsRef),
                    targetAgentName: "Research Agent",
                    input: "Find papers",
                    maxElapsedSeconds: 30,
                    feed: feed,
                    interrupt: InterruptToken()
                )
                Issue.record("a refused workspace dispatch must throw")
            } catch let SubagentError.unavailable(message) {
                #expect(message.contains("Osaurus Router"))
                #expect(message.contains("Pick a different agent"))
            } catch {
                Issue.record("expected SubagentError.unavailable, got \(error)")
            }
            // The refusal was consumed by the dispatcher, not left behind.
            #expect(BackgroundTaskManager.shared.consumeWorkspaceDispatchRefusal(for: wsRef) == nil)
        }
    }

    @Test("spawn resolve: workspace target outside the pool is denied before any network work")
    func spawnResolveDeniesUnlistedWorkspaceTarget() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-workspace-unlisted")
        defer { lease.release() }
        SubagentConfigurationStore.save(SubagentConfiguration())

        let kind = TextSubagentKind(workspaceAgent: wsRef, input: "x")
        let scope = SubagentScope(sessionId: "s", toolCallId: "t", agentId: Agent.defaultId)
        do {
            _ = try await kind.resolveModel(scope)
            Issue.record("an unlisted workspace target must be denied")
        } catch let SubagentError.denied(message) {
            #expect(message.contains(wsAddress))
        } catch {
            Issue.record("expected SubagentError.denied, got \(error)")
        }
    }

    @Test("spawn resolve: a pooled workspace target resolves to a non-local model with no residency")
    func spawnResolveAcceptsPooledWorkspaceTarget() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-workspace-pooled")
        defer { lease.release() }
        SubagentConfigurationStore.save(SubagentConfiguration(spawnableWorkspaceAgents: [wsRef]))

        try await WorkspaceRosterTestLock.shared.run {
            let kind = TextSubagentKind(workspaceAgent: wsRef, input: "x")
            let scope = SubagentScope(sessionId: "s", toolCallId: "t", agentId: Agent.defaultId)
            let resolved = try await kind.resolveModel(scope)
            #expect(!resolved.isLocal)
            #expect(resolved.id == nil, "the host picks the model; the client never pins one")
            #expect(kind.isWorkspaceTarget)
        }
    }
}
