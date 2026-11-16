//
//  SpawnTargetAvailabilityTests.swift
//  OsaurusCoreTests
//
//  Request-local spawn target truth. Durable configuration can retain stale
//  rows for Settings repair, while prompts and schemas expose runnable targets.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Spawn target availability")
@MainActor
struct SpawnTargetAvailabilityTests {
    private let researcherID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private func localModel(_ id: String) -> MLXModel {
        MLXModel(
            id: id,
            name: id.split(separator: "/").last.map(String.init) ?? id,
            description: "availability fixture",
            downloadURL: "https://example.invalid/\(id)"
        )
    }

    @Test("request discovery covers agent-only and launcher-override pools")
    func requestDiscoveryCoverage() {
        #expect(
            SpawnDescriptors.requiresLocalDiscovery(
                agentIDs: [researcherID],
                launcherModelOverride: nil
            )
        )
        #expect(
            SpawnDescriptors.requiresLocalDiscovery(
                agentIDs: [],
                launcherModelOverride: "local/override"
            )
        )
        #expect(
            !SpawnDescriptors.requiresLocalDiscovery(
                agentIDs: [],
                launcherModelOverride: " \n "
            )
        )
    }

    private func resolve(
        agents: [UUID] = [],
        sources: [SpawnDescriptors.AgentSource] = [],
        locals: [MLXModel] = [],
        localAuthoritative: Bool,
        pickerItems: [ModelPickerItem] = [],
        remoteTargets: [RemoteProviderManager.ConnectedSpawnModelTarget] = [],
        remoteProviderNames: [UUID: String] = [:],
        launcherOverride: String? = nil
    ) -> SpawnTargetAvailabilitySnapshot {
        SpawnDescriptors.resolve(
            agentIDs: agents,
            agentSources: sources,
            localModels: locals,
            localCatalogIsAuthoritative: localAuthoritative,
            pickerItems: pickerItems,
            connectedRemoteTargets: .init(targets: remoteTargets),
            remoteProviderNames: remoteProviderNames,
            foundationAvailable: false,
            launcherModelOverride: launcherOverride
        )
    }

    @Test("agent follows launcher override precedence and target model availability")
    func agentAvailabilityTracksEffectiveRunModel() {
        let source = SpawnDescriptors.AgentSource(
            id: researcherID,
            name: "Researcher",
            description: "Research helper",
            modelId: "local/missing-own-model"
        )

        let missingOwnModel = resolve(
            agents: [researcherID],
            sources: [source],
            localAuthoritative: true
        )
        #expect(missingOwnModel.agentTargets.first?.state == .missing)
        #expect(missingOwnModel.agents.isEmpty)

        let overrideId = "local/runnable-override"
        let runnableOverride = resolve(
            agents: [researcherID],
            sources: [source],
            locals: [localModel(overrideId)],
            localAuthoritative: true,
            launcherOverride: overrideId
        )
        #expect(runnableOverride.agentTargets.first?.state == .runnable)
        #expect(runnableOverride.runnableAgentIDs == [researcherID])
        #expect(runnableOverride.agents.first?.modelId == overrideId)

        let missingOverride = resolve(
            agents: [researcherID],
            sources: [source],
            localAuthoritative: true,
            launcherOverride: "local/removed-override"
        )
        #expect(missingOverride.agentTargets.first?.state == .missing)
        #expect(missingOverride.agents.isEmpty)
    }

    @Test("agent with disconnected launcher override never falls back to its runnable own model")
    func disconnectedLauncherOverrideFailsClosed() throws {
        let providerId = UUID(uuidString: "013DDA70-0FC2-4757-8F4D-BC12ECFA3A90")!
        let disconnectedOverride = try #require(
            SpawnRemoteModelIdentity.make(
                providerId: providerId,
                modelId: "provider/offline"
            )
        )
        let ownModel = "local/runnable-own-model"
        let snapshot = resolve(
            agents: [researcherID],
            sources: [
                .init(
                    id: researcherID,
                    name: "Researcher",
                    description: "Research helper",
                    modelId: ownModel
                )
            ],
            locals: [localModel(ownModel)],
            localAuthoritative: true,
            remoteProviderNames: [providerId: "Disconnected Cloud"],
            launcherOverride: disconnectedOverride
        )

        #expect(snapshot.agentTargets.first?.state == .disconnected)
        #expect(snapshot.agentTargets.first?.descriptor.modelId == disconnectedOverride)
        #expect(snapshot.agents.isEmpty)
    }

    @Test("one availability snapshot drives the spawn_agent schema and the prompt targets")
    func snapshotKeepsPromptAndSchemasInParity() throws {
        let runnableAgentID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let staleAgentID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let runnableAgent = SpawnAgentDescriptor(
            id: runnableAgentID,
            name: "Researcher",
            description: "Runnable agent",
            modelId: "local/agent-model",
            isLocal: true,
            providerName: nil
        )
        let staleAgent = SpawnAgentDescriptor(
            id: staleAgentID,
            name: "Deleted Agent",
            description: nil,
            modelId: nil,
            isLocal: nil,
            providerName: nil
        )
        let snapshot = SpawnTargetAvailabilitySnapshot(
            agentTargets: [
                .init(descriptor: runnableAgent, state: .runnable),
                .init(descriptor: staleAgent, state: .missing),
            ]
        )

        let agentTool = SpawnAgentTool.constrainedSpec(
            SpawnAgentTool().asOpenAITool(),
            allowedAgentIDs: snapshot.runnableAgentIDs
        )

        func directEnum(_ tool: Tool, field: String) -> [String] {
            guard case .object(let root)? = tool.function.parameters,
                case .object(let properties)? = root["properties"],
                case .object(let target)? = properties[field],
                case .array(let values)? = target["enum"]
            else { return [] }
            return values.compactMap {
                if case .string(let value) = $0 { return value }
                return nil
            }
        }

        #expect(directEnum(agentTool, field: "agent") == [runnableAgentID.uuidString])

        let guidance = SystemPromptTemplates.spawnGuidance(
            agents: snapshot.agents,
            maxParallel: 2
        )
        #expect(guidance.contains("Researcher"))
        #expect(!guidance.contains("Deleted Agent"))
    }

    @Test("passing display names widens the schema enum to accept name or UUID")
    func schemaEnumAcceptsAgentDisplayNames() {
        let agentID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

        func directEnum(_ tool: Tool, field: String) -> [String] {
            guard case .object(let root)? = tool.function.parameters,
                case .object(let properties)? = root["properties"],
                case .object(let target)? = properties[field],
                case .array(let values)? = target["enum"]
            else { return [] }
            return values.compactMap {
                if case .string(let value) = $0 { return value }
                return nil
            }
        }
        let agentTool = SpawnAgentTool.constrainedSpec(
            SpawnAgentTool().asOpenAITool(),
            allowedAgentIDs: [agentID],
            allowedAgentNames: ["Transcript Cleaner"]
        )
        // Both the UUID and the display name are offered; the UUID leads so the
        // enum stays byte-stable against the frozen-prefix cache contract.
        #expect(
            directEnum(agentTool, field: "agent")
                == [agentID.uuidString, "Transcript Cleaner"]
        )
    }

    @Test("missing configured agent remains visible in state but never runnable")
    func missingAgentIsRetainedForRepair() {
        let deletedID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let snapshot = resolve(
            agents: [deletedID],
            localAuthoritative: true
        )
        #expect(snapshot.agentTargets.first?.descriptor.id == deletedID)
        #expect(snapshot.agentTargets.first?.descriptor.name == deletedID.uuidString)
        #expect(snapshot.agentTargets.first?.state == .missing)
        #expect(snapshot.agents.isEmpty)
    }

    @Test("case-colliding display names remain distinct by UUID")
    func caseCollidingNamesResolveExactIdentity() {
        let upperID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let lowerID = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
        let upper = SpawnDescriptors.AgentSource(
            id: upperID,
            name: "Helper",
            description: "Read-only helper",
            modelId: "local/helper-read"
        )
        let lower = SpawnDescriptors.AgentSource(
            id: lowerID,
            name: "helper",
            description: "Writable helper",
            modelId: "local/helper-write"
        )
        let snapshot = resolve(
            agents: [lowerID, upperID],
            sources: [upper, lower],
            locals: [
                localModel("local/helper-read"),
                localModel("local/helper-write"),
            ],
            localAuthoritative: true
        )

        #expect(snapshot.runnableAgentIDs == [lowerID, upperID])
        #expect(snapshot.agents.map(\.name) == ["helper", "Helper"])
        #expect(snapshot.agents.map(\.modelId) == ["local/helper-write", "local/helper-read"])
        #expect(snapshot.agents.map(\.description) == ["Writable helper", "Read-only helper"])
    }
    @Test("missing descriptions never exclude local or workspace targets")
    func blankDescriptionsStayRunnable() {
        let modelID = "local/description-fixture"
        for description in ["", "   "] {
            let snapshot = resolve(
                agents: [researcherID],
                sources: [.init(id: researcherID, name: "Legacy Helper", description: description, modelId: modelID)],
                locals: [localModel(modelID)], localAuthoritative: true)
            #expect(snapshot.agentTargets.first?.descriptor.id == researcherID)
            #expect(snapshot.agentTargets.first?.state == .runnable)
            #expect(snapshot.agentTargets.first?.descriptor.description == nil)
            #expect(snapshot.runnableAgentIDs == [researcherID])
        }
        let ref = WorkspaceAgentRef(workspaceId: "description-test", agentAddress: "0x0123456789abcdef0123456789abcdef01234567")
        let blank = SpawnDescriptors.resolveWorkspaceTargets(configured: [ref], sources: [
            .init(ref: ref, name: "Remote Helper", description: "", workspaceName: "Team", ownerName: "Owner")
        ])
        #expect(blank.first?.state == .runnable)
        #expect(blank.first?.descriptor.ref == ref)
        #expect(blank.first?.descriptor.description == nil)
        let described = SpawnDescriptors.resolveWorkspaceTargets(configured: [ref], sources: [
            .init(ref: ref, name: "Remote Helper", description: "Reviews research sources.", workspaceName: "Team", ownerName: "Owner")
        ])
        #expect(described.first?.state == .runnable)
        #expect(described.first?.descriptor.description == "Reviews research sources.")
    }

    @Test("blank workspace blurbs do not hide a usable paired description")
    func workspaceDescriptionFallback() {
        let host = "Reviews supplied research sources."
        let blankBlurbs: [String?] = [nil, "", "   "]
        for listed in blankBlurbs {
            #expect(SpawnDescriptors.workspaceRoutingDescription(listed: listed, paired: host) == host)
        }
        #expect(SpawnDescriptors.workspaceRoutingDescription(listed: "  Reviews code.  ", paired: host) == "Reviews code.")
        #expect(SpawnDescriptors.workspaceRoutingDescription(listed: "two\nlines", paired: host) == "two lines")
        #expect(SpawnDescriptors.workspaceRoutingDescription(listed: "", paired: " ") == "")
        #expect(SpawnDescriptors.workspaceRoutingDescription(listed: nil, paired: nil) == "")
    }

}
