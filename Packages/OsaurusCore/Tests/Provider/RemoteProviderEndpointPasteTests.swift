//
//  RemoteProviderEndpointPasteTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Remote provider endpoint paste")
struct RemoteProviderEndpointPasteTests {
    @Test func lemonadeModelsURLPasteKeepsApiV1AsBasePath() throws {
        let components = try #require(
            parsePastedEndpoint("http://172.16.6.146:8000/api/v1/models")
        )

        #expect(components.providerProtocol == .http)
        #expect(components.host == "172.16.6.146")
        #expect(components.port == 8000)
        #expect(components.basePath == "/api/v1")

        let provider = RemoteProvider(
            name: "Lemonade",
            host: components.host,
            providerProtocol: components.providerProtocol ?? .https,
            port: components.port,
            basePath: components.basePath ?? "/v1",
            authType: .none,
            providerType: .openaiLegacy
        )

        #expect(provider.url(for: "/models")?.absoluteString == "http://172.16.6.146:8000/api/v1/models")
    }

    @Test func chatCompletionsPasteKeepsV1AsBasePath() throws {
        let components = try #require(
            parsePastedEndpoint("https://api.example.test/v1/chat/completions")
        )

        #expect(components.providerProtocol == .https)
        #expect(components.host == "api.example.test")
        #expect(components.port == nil)
        #expect(components.basePath == "/v1")
    }

    @Test func baseURLPasteKeepsPathWhenNoOperationEndpointIsPresent() throws {
        let components = try #require(
            parsePastedEndpoint("https://api.example.test/openai/v1")
        )

        #expect(components.basePath == "/openai/v1")
    }
}
