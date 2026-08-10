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

    @Test("request discovery covers agent-only, model-only, and launcher-override pools")
    func requestDiscoveryCoverage() {
        #expect(
            SpawnDescriptors.requiresLocalDiscovery(
                agentIDs: [researcherID],
                modelNames: [],
                launcherModelOverride: nil
            )
        )
        #expect(
            SpawnDescriptors.requiresLocalDiscovery(
                agentIDs: [],
                modelNames: ["local/model"],
                launcherModelOverride: nil
            )
        )
        #expect(
            SpawnDescriptors.requiresLocalDiscovery(
                agentIDs: [],
                modelNames: [],
                launcherModelOverride: "local/override"
            )
        )
        #expect(
            !SpawnDescriptors.requiresLocalDiscovery(
                agentIDs: [],
                modelNames: [],
                launcherModelOverride: " \n "
            )
        )
    }

    private func resolve(
        agents: [UUID] = [],
        models: [String] = [],
        notes: [String: String] = [:],
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
            modelNames: models,
            modelNotes: notes,
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

    @Test("cold, warm, and removed local targets remain distinct")
    func localLifecycle() throws {
        let id = "local/availability-model"
        let cold = resolve(
            models: [id],
            notes: [id: "Use for local work"],
            localAuthoritative: false
        )
        #expect(cold.modelTargets.first?.state == .checking)
        #expect(cold.models.isEmpty)
        #expect(cold.modelTargets.first?.descriptor.note == "Use for local work")

        let warm = resolve(
            models: [id],
            locals: [localModel(id)],
            localAuthoritative: true
        )
        #expect(warm.modelTargets.first?.state == .runnable)
        #expect(warm.runnableModelIds == [id])

        let removed = resolve(models: [id], localAuthoritative: true)
        #expect(removed.modelTargets.first?.state == .missing)
        #expect(removed.models.isEmpty)
    }

    @Test("connected, disconnected, and removed remote targets fail closed")
    func remoteLifecycle() throws {
        let providerId = UUID(uuidString: "A2D41B56-44EB-4CFA-A2EC-61F24001EB77")!
        let canonical = try #require(
            SpawnRemoteModelIdentity.make(
                providerId: providerId,
                modelId: "vendor/remote-model"
            )
        )
        let target = RemoteProviderManager.ConnectedSpawnModelTarget(
            id: canonical,
            providerId: providerId,
            providerName: "Cloud",
            modelId: "vendor/remote-model",
            pickerModelId: "cloud/vendor/remote-model"
        )
        let picker = ModelPickerItem.fromRemoteModel(
            modelId: target.pickerModelId,
            providerName: target.providerName,
            providerId: target.providerId
        )

        let connected = resolve(
            models: [canonical],
            localAuthoritative: true,
            pickerItems: [picker],
            remoteTargets: [target],
            remoteProviderNames: [providerId: "Cloud"]
        )
        #expect(connected.modelTargets.first?.state == .runnable)
        #expect(connected.runnableModelIds == [canonical])
        #expect(connected.models.first?.providerName == "Cloud")

        let disconnected = resolve(
            models: [canonical],
            localAuthoritative: true,
            remoteProviderNames: [providerId: "Cloud"]
        )
        #expect(disconnected.modelTargets.first?.state == .disconnected)
        #expect(disconnected.models.isEmpty)

        let removed = resolve(models: [canonical], localAuthoritative: true)
        #expect(removed.modelTargets.first?.state == .missing)
        #expect(removed.models.isEmpty)
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

    @Test("one availability snapshot drives exact single, batch, and prompt targets")
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
        let runnableModel = SpawnModelDescriptor(
            id: "local/direct-model",
            displayName: "Direct Model",
            isLocal: true,
            providerName: nil,
            parameterCount: "7B",
            quantization: "4bit",
            isVLM: false,
            note: "Use for direct work"
        )
        let staleModel = SpawnModelDescriptor(
            id: "local/deleted-model",
            displayName: "Deleted Model",
            isLocal: nil,
            providerName: nil,
            parameterCount: nil,
            quantization: nil,
            isVLM: false,
            note: nil
        )
        let snapshot = SpawnTargetAvailabilitySnapshot(
            agentTargets: [
                .init(descriptor: runnableAgent, state: .runnable),
                .init(descriptor: staleAgent, state: .missing),
            ],
            modelTargets: [
                .init(descriptor: runnableModel, state: .runnable),
                .init(descriptor: staleModel, state: .missing),
            ]
        )

        let agentTool = SpawnAgentTool.constrainedSpec(
            SpawnAgentTool().asOpenAITool(),
            allowedAgentIDs: snapshot.runnableAgentIDs
        )
        let modelTool = SpawnModelTool.constrainedSpec(
            SpawnModelTool().asOpenAITool(),
            allowedModelIds: snapshot.runnableModelIds
        )
        let batchTool = SpawnBatchTool.constrainedSpec(
            SpawnBatchTool().asOpenAITool(),
            allowedAgentIDs: snapshot.runnableAgentIDs,
            allowedModelIds: snapshot.runnableModelIds,
            maxParallel: 2
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
        func batchEnum(_ tool: Tool) -> [String] {
            guard case .object(let root)? = tool.function.parameters,
                case .object(let properties)? = root["properties"],
                case .object(let jobs)? = properties["jobs"],
                case .object(let items)? = jobs["items"],
                case .object(let jobProperties)? = items["properties"],
                case .object(let target)? = jobProperties["target"],
                case .array(let values)? = target["enum"]
            else { return [] }
            return values.compactMap {
                if case .string(let value) = $0 { return value }
                return nil
            }
        }

        #expect(directEnum(agentTool, field: "agent") == [runnableAgentID.uuidString])
        #expect(directEnum(modelTool, field: "model") == ["local/direct-model"])
        #expect(
            Set(batchEnum(batchTool))
                == Set([runnableAgentID.uuidString, "local/direct-model"])
        )

        let guidance = SystemPromptTemplates.spawnGuidance(
            agents: snapshot.agents,
            models: snapshot.models,
            maxParallel: 2
        )
        #expect(guidance.contains("`\(runnableAgentID.uuidString)`"))
        #expect(guidance.contains("Researcher"))
        #expect(guidance.contains("`local/direct-model`"))
        #expect(!guidance.contains("Deleted Agent"))
        #expect(!guidance.contains("local/deleted-model"))
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
}
