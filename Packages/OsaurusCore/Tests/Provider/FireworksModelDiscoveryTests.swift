//
//  FireworksModelDiscoveryTests.swift
//  osaurusTests
//
//  Covers Fireworks gateway catalog discovery: host detection and
//  serverless-chat filtering of catalog pages.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Fireworks model discovery")
struct FireworksModelDiscoveryTests {

    @Test func fireworksHost_isDetectedForOpenAICompatibleProviders() {
        #expect(RemoteProviderService.isFireworksProvider(makeProvider(host: "api.fireworks.ai")))
        #expect(RemoteProviderService.isFireworksProvider(makeProvider(host: "API.Fireworks.AI")))
        #expect(
            RemoteProviderService.isFireworksProvider(
                makeProvider(host: "api.fireworks.ai/inference", basePath: "/v1")
            )
        )
    }

    @Test func nonFireworksHost_isNotDetected() {
        #expect(!RemoteProviderService.isFireworksProvider(makeProvider(host: "api.openai.com")))
        #expect(!RemoteProviderService.isFireworksProvider(makeProvider(host: "fireworks.ai.evil.com")))
        #expect(!RemoteProviderService.isFireworksProvider(makeProvider(host: "notfireworks.ai")))
    }

    @Test func fireworksHost_isNotDetectedForNonOpenAICompatibleProviders() {
        #expect(
            !RemoteProviderService.isFireworksProvider(
                makeProvider(host: "api.fireworks.ai", providerType: .anthropic)
            )
        )
    }

    @Test func catalogPage_filtersToServerlessChatModels() throws {
        let body = Data(
            """
            {
              "models": [
                {
                  "name": "accounts/fireworks/models/llama-v3p1-70b-instruct",
                  "state": "READY",
                  "supportsServerless": true,
                  "conversationConfig": {"style": "openai"}
                },
                {
                  "name": "accounts/fireworks/models/not-serverless",
                  "state": "READY",
                  "supportsServerless": false,
                  "conversationConfig": {}
                },
                {
                  "name": "accounts/fireworks/models/no-chat-embedding",
                  "state": "READY",
                  "supportsServerless": true
                },
                {
                  "name": "accounts/fireworks/models/embedding-with-chat-template",
                  "state": "READY",
                  "kind": "EMBEDDING_MODEL",
                  "supportsServerless": true,
                  "conversationConfig": {"style": "jinja"}
                },
                {
                  "name": "accounts/fireworks/models/still-uploading",
                  "state": "UPLOADING",
                  "supportsServerless": true,
                  "conversationConfig": {}
                }
              ],
              "nextPageToken": "token-2",
              "totalSize": 400
            }
            """.utf8
        )

        let page = try RemoteProviderService.decodeFireworksCatalogPage(data: body)

        #expect(page.models == ["accounts/fireworks/models/llama-v3p1-70b-instruct"])
        #expect(page.nextPageToken == "token-2")
    }

    @Test func catalogPage_toleratesMissingModelsAndToken() throws {
        let page = try RemoteProviderService.decodeFireworksCatalogPage(data: Data("{}".utf8))

        #expect(page.models.isEmpty)
        #expect(page.nextPageToken == nil)
    }

    private func makeProvider(
        host: String,
        basePath: String = "/inference/v1",
        providerType: RemoteProviderType = .openaiLegacy
    ) -> RemoteProvider {
        RemoteProvider(
            name: "fireworks.ai",
            host: host,
            providerProtocol: .https,
            port: nil,
            basePath: basePath,
            authType: .apiKey,
            providerType: providerType
        )
    }
}
