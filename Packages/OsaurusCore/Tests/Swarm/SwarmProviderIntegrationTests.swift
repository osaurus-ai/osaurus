//
//  SwarmProviderIntegrationTests.swift
//  OsaurusCoreTests
//
//  Swarm as a provider on the picker surfaces.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Swarm provider integration")
struct SwarmProviderIntegrationTests {
    @MainActor @Test func pickerRowsGroupUnderOsaurusSwarm() throws {
        let pool = SwarmPool(
            id: "p1",
            name: "Qwen 27B #1",
            modelIds: ["org/a"],
            nodeIds: ["n1"],
            leaseSeconds: 60,
            maxQueueWaitSeconds: 10,
            contextLength: 65_536
        )
        let entry = try #require(
            SwarmCatalogEntry.entries(pools: [pool], nodes: [SwarmIdentityTests.node("n1", models: [("org/a", .warm)])])
                .first
        )
        let result = ModelPickerItemCache.remoteModelItems(
            providers: [
                .init(
                    providerId: SwarmModelIdentity.providerId,
                    providerName: SwarmModelIdentity.providerName,
                    providerType: .openaiLegacy,
                    host: "",
                    models: [entry.pickerModelId]
                )
            ],
            codexMetadata: [:],
            osaurusRouterProviderId: UUID(),
            routerMetadata: { _ in nil },
            swarmEntries: [entry.pickerModelId: entry]
        )
        let item = try #require(result.items.first)
        #expect(item.id == "osaurus-swarm/qwen-27b-1/org/a")
        #expect(item.displayName == "a · Qwen 27B #1")
        #expect(item.description == "1 of 1 nodes available · 1 warm")
        #expect(item.contextLength == 65_536)
        guard case .remote(let providerName, let providerId) = item.source else {
            Issue.record("Swarm rows must be remote-provider rows")
            return
        }
        #expect(providerName == "Osaurus Swarm")
        #expect(providerId == SwarmModelIdentity.providerId)
    }
}
