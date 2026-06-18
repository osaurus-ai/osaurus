//
//  RemoteProviderManagerTestConnectionTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct RemoteProviderManagerTestConnectionTests {
    @Test func testConnectionUsesManualModelsWhenModelsEndpointIsMissing() async throws {
        try await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            defer { manager._testRemoveProviders(ids: []) }

            manager.testConnectionTransportOverride = { request in
                #expect(request.url?.absoluteString == "https://api.example.test/v1/models")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (Data(#"{"error":{"message":"not found"}}"#.utf8), response)
            }

            let models = try await manager.testConnection(
                host: "api.example.test",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .none,
                providerType: .openaiLegacy,
                apiKey: nil,
                headers: [:],
                manualModelIds: [" direct-chat ", "DIRECT-CHAT", ""]
            )

            #expect(models == ["direct-chat"])
        }
    }
}
