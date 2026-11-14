//
//  PeerInferenceExposureTests.swift
//  OsaurusCoreTests
//
//  Receiver side of the owner-level "share my models for inference" switch
//  (`PeerInferenceSharing` on the host). A host that has not opted in
//  answers a paired peer's `/models` probe with an empty catalog; this side
//  must (a) take that answer at face value instead of synthesizing a model
//  from `default_model`, (b) still connect the pairing so Mode 2 agent runs
//  keep routing by provider id, and (c) keep such peers off every inference
//  surface — Cloud Models, the picker source, `/v1/models`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Peer inference exposure (receiver)")
struct PeerInferenceExposureTests {

    // MARK: - /models answer → catalog decision

    @Test func explicitEmptyCatalogIsAuthoritative() {
        let empty = Data(#"{"object":"list","data":[]}"#.utf8)
        #expect(RemoteProviderService.peerModelCatalog(status: 200, data: empty) == [])
    }

    @Test func populatedCatalogIsReturnedInOrder() {
        let body = Data(
            """
            {"object":"list","data":[
              {"id":"gemma-3-12b","object":"model","created":0,"owned_by":"osaurus"},
              {"id":"foundation","object":"model","created":0,"owned_by":"osaurus"}
            ]}
            """.utf8
        )
        #expect(RemoteProviderService.peerModelCatalog(status: 200, data: body) == ["gemma-3-12b", "foundation"])
    }

    /// Error statuses and unparseable bodies mean "no catalog here" — the
    /// caller falls through to the `default_model` probe (older hosts).
    @Test func errorOrUnparseableAnswersFallThrough() {
        let empty = Data(#"{"object":"list","data":[]}"#.utf8)
        #expect(RemoteProviderService.peerModelCatalog(status: 403, data: empty) == nil)
        #expect(RemoteProviderService.peerModelCatalog(status: 404, data: Data("not found".utf8)) == nil)
        #expect(RemoteProviderService.peerModelCatalog(status: 200, data: Data("<html>".utf8)) == nil)
        #expect(RemoteProviderService.peerModelCatalog(status: 200, data: Data()) == nil)
    }

    // MARK: - Inference-surface visibility rule

    @Test func onlyNativePeersWithNoModelsAreHidden() {
        #expect(!RemoteProviderManager.exposesModelsForInference(providerType: .osaurus, discoveredModels: []))
        #expect(RemoteProviderManager.exposesModelsForInference(providerType: .osaurus, discoveredModels: ["m"]))
        // Third-party providers are never hidden by this rule, even with an
        // empty catalog (e.g. Azure deployments configured by hand).
        #expect(RemoteProviderManager.exposesModelsForInference(providerType: .openaiLegacy, discoveredModels: []))
        #expect(RemoteProviderManager.exposesModelsForInference(providerType: .anthropic, discoveredModels: []))
        #expect(RemoteProviderManager.exposesModelsForInference(providerType: .osaurusRouter, discoveredModels: []))
    }

    // MARK: - Live manager: connect with an empty catalog

    private static func makePeer(name: String) -> RemoteProvider {
        RemoteProvider(
            name: name,
            host: "127.0.0.1",
            providerProtocol: .http,
            port: 1234,
            basePath: "/v1",
            authType: .none,
            providerType: .osaurus,
            remoteAgentId: UUID(),
            remoteAgentAddress: "0x" + String(repeating: "a", count: 40)
        )
    }

    /// The host has not opted in: the pairing connects with zero models. It is
    /// absent from the picker source and from `/v1/models`, and it is not an
    /// inference-surface provider — but its service is still resolvable by
    /// provider id, which is all a Mode 2 agent run needs.
    @Test @MainActor func emptyCatalogConnectsForAgentRunsButHidesFromInference() async throws {
        try await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let peer = Self.makePeer(name: "Teammate")
            defer {
                manager.testFetchModelsOverride = nil
                manager._testRemoveProviders(ids: [peer.id])
            }
            manager.testFetchModelsOverride = { provider in
                provider.id == peer.id ? [] : ["unrelated"]
            }
            manager.addProvider(peer, apiKey: nil, isEphemeral: true)
            try await manager.connect(providerId: peer.id)

            let state = try #require(manager.providerStates[peer.id])
            #expect(state.isConnected)
            #expect(state.lastError == nil)
            #expect(state.discoveredModels.isEmpty)

            #expect(!manager.exposesModelsForInference(peer))
            #expect(!manager.cachedAvailableModels().contains { $0.providerId == peer.id })
            #expect(!manager.getOpenAIModels().contains { $0.owned_by == peer.name })

            // Mode 2 routes by provider id and never consults the catalog.
            let service = try #require(manager.service(for: peer.id))
            let routed = ChatEngine.remoteAgentService(providerId: peer.id, in: manager.connectedServices())
            #expect((routed as? RemoteProviderService) === service)
        }
    }

    /// The host opted in: the same pairing now carries a catalog and is an
    /// ordinary inference provider (picker source + `/v1/models`).
    @Test @MainActor func sharedCatalogExposesThePeerForInference() async throws {
        try await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let peer = Self.makePeer(name: "Sharing Teammate")
            defer {
                manager.testFetchModelsOverride = nil
                manager._testRemoveProviders(ids: [peer.id])
            }
            manager.testFetchModelsOverride = { provider in
                provider.id == peer.id ? ["gemma-3-12b"] : []
            }
            manager.addProvider(peer, apiKey: nil, isEphemeral: true)
            try await manager.connect(providerId: peer.id)

            #expect(manager.providerStates[peer.id]?.isConnected == true)
            #expect(manager.exposesModelsForInference(peer))
            // Picker ids carry the provider prefix; the tail is the host's model.
            let cached = try #require(manager.cachedAvailableModels().first { $0.providerId == peer.id })
            #expect(cached.models.count == 1)
            #expect(cached.models.first?.hasSuffix("/gemma-3-12b") == true, "\(cached.models)")
        }
    }
}
