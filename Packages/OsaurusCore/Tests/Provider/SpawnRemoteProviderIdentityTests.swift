//
//  SpawnRemoteProviderIdentityTests.swift
//  OsaurusCoreTests
//
//  Spawn-only remote identity coverage. Ordinary chat picker ids remain
//  human-readable and name-prefixed; subagent targets use provider UUIDs so
//  duplicate names and renames cannot silently retarget work.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Spawn remote provider identity", .serialized)
@MainActor
struct SpawnRemoteProviderIdentityTests {
    private func provider(
        id: UUID = UUID(),
        name: String
    ) -> RemoteProvider {
        RemoteProvider(
            id: id,
            name: name,
            host: "127.0.0.1",
            basePath: "/v1",
            authType: .none,
            providerType: .openaiLegacy
        )
    }

    @Test("duplicate provider names and model slugs remain exactly routable")
    func duplicateProviderNamesRemainDistinct() async throws {
        try await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            manager.testIdentityExistsOverride = false
            let first = provider(name: "Duplicate")
            let second = provider(name: "Duplicate")
            let firstService = try #require(
                manager._testInstallConnectedProvider(
                    first,
                    discoveredModels: ["org/shared-model"],
                    installService: true
                )
            )
            let secondService = try #require(
                manager._testInstallConnectedProvider(
                    second,
                    discoveredModels: ["org/shared-model"],
                    installService: true
                )
            )
            defer { manager._testRemoveProviders(ids: [first.id, second.id]) }

            // The ordinary chat picker contract is intentionally unchanged,
            // including its ambiguous human-readable ids.
            let chatIDs = manager.cachedAvailableModels()
                .filter { $0.providerId == first.id || $0.providerId == second.id }
                .flatMap(\.models)
            #expect(chatIDs == ["duplicate/org/shared-model", "duplicate/org/shared-model"])

            let targets = manager.connectedSpawnModelTargets()
                .filter { $0.providerId == first.id || $0.providerId == second.id }
            #expect(targets.count == 2)
            #expect(Set(targets.map(\.id)).count == 2)

            let firstTarget = try #require(targets.first { $0.providerId == first.id })
            let secondTarget = try #require(targets.first { $0.providerId == second.id })
            #expect(firstTarget.id != secondTarget.id)
            let index = manager.connectedSpawnModelTargetIndex()
            #expect(index.target(forStoredId: firstTarget.id) == firstTarget)
            #expect(index.target(forStoredId: secondTarget.id) == secondTarget)
            #expect(
                index.targetID(
                    forPickerModelId: firstTarget.pickerModelId,
                    providerId: first.id
                ) == firstTarget.id
            )
            #expect(
                index.targetID(
                    forPickerModelId: secondTarget.pickerModelId,
                    providerId: second.id
                ) == secondTarget.id
            )
            #expect(firstService.handles(requestedModel: firstTarget.id))
            #expect(!firstService.handles(requestedModel: secondTarget.id))
            #expect(secondService.handles(requestedModel: secondTarget.id))
            #expect(!secondService.handles(requestedModel: firstTarget.id))
            #expect(await firstService.extractModelName(firstTarget.id) == "org/shared-model")
            #expect(await secondService.extractModelName(secondTarget.id) == "org/shared-model")
            #expect(manager.findService(forModel: firstTarget.id) === firstService)
            #expect(manager.findService(forModel: secondTarget.id) === secondService)

            // A legacy id cannot choose between the duplicates by iteration
            // order. It becomes valid again only once it is unambiguous.
            #expect(
                manager.connectedSpawnModelTarget(
                    forStoredId: "duplicate/org/shared-model"
                ) == nil
            )
            #expect(index.target(forStoredId: "duplicate/org/shared-model") == nil)
            manager._testRemoveProviders(ids: [second.id])
            let unambiguousIndex = manager.connectedSpawnModelTargetIndex()
            let migrated = try #require(
                unambiguousIndex.target(forStoredId: "duplicate/org/shared-model")
            )
            #expect(migrated.id == firstTarget.id)
        }
    }

    @Test("UUID target survives provider rename and persisted relaunch")
    func targetSurvivesRenameAndRelaunch() async throws {
        try await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            manager.testIdentityExistsOverride = false
            let fixedID = UUID(uuidString: "C9412118-D6C8-4BC0-90D9-5C686C5A54C8")!
            var original = provider(id: fixedID, name: "Before Rename")
            let service = try #require(
                manager._testInstallConnectedProvider(
                    original,
                    discoveredModels: ["vendor/model"],
                    installService: true
                )
            )
            defer { manager._testRemoveProviders(ids: [fixedID]) }

            let before = try #require(
                manager.connectedSpawnModelTargets().first { $0.providerId == fixedID }
            )
            original.name = "After Rename"
            manager._testUpdateProviderRecord(original)

            let after = try #require(
                manager.connectedSpawnModelTarget(forStoredId: before.id)
            )
            #expect(after.id == before.id)
            #expect(after.providerName == "After Rename")
            #expect(after.pickerModelId == "after-rename/vendor/model")
            #expect(service.handles(requestedModel: after.id))
            #expect(await service.extractModelName(after.id) == "vendor/model")

            let relaunched = try JSONDecoder().decode(
                RemoteProvider.self,
                from: JSONEncoder().encode(original)
            )
            #expect(relaunched.id == fixedID)
            #expect(
                SpawnRemoteModelIdentity.make(
                    providerId: relaunched.id,
                    modelId: "vendor/model"
                ) == before.id
            )
        }
    }

    @Test("canonical target fails closed after disconnect and removal")
    func targetFailsClosedWhenProviderUnavailable() async throws {
        try await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            manager.testIdentityExistsOverride = false
            let remote = provider(name: "Disconnect Test")
            manager._testInstallConnectedProvider(
                remote,
                discoveredModels: ["model-a"],
                installService: true
            )
            defer { manager._testRemoveProviders(ids: [remote.id]) }

            let target = try #require(
                manager.connectedSpawnModelTargets().first { $0.providerId == remote.id }
            )
            #expect(manager.connectedSpawnModelTarget(forStoredId: target.id) != nil)

            var disconnected = try #require(manager.providerStates[remote.id])
            disconnected.isConnected = false
            manager._testSetState(disconnected, for: remote.id)
            #expect(manager.connectedSpawnModelTarget(forStoredId: target.id) == nil)
            #expect(SubagentModelResolution.currentRequestedTarget(target.id) == nil)

            manager._testRemoveProviders(ids: [remote.id])
            #expect(manager.connectedSpawnModelTarget(forStoredId: target.id) == nil)
        }
    }
}
