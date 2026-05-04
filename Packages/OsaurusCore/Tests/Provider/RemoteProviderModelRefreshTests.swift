//
//  RemoteProviderModelRefreshTests.swift
//  osaurusTests
//
//  Covers issue #1010: custom OpenAI-compatible providers can change their
//  `/models` response while Osaurus is already running. The picker refresh path
//  must re-fetch connected providers instead of relying on the launch-time
//  connection snapshot.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct RemoteProviderModelRefreshTests {

    @Test("connected custom provider refresh updates manager state and service")
    func connectedCustomProviderRefresh_updatesStateAndService() async throws {
        try await runWithCleanProviderManager { manager in
            let provider = makeCustomProvider()
            let fetchScript = ModelFetchScript([
                ["llama-3.2", "qwen3-coder"]
            ])

            await manager._resetForTesting(configuration: RemoteProviderConfiguration(providers: [provider]))
            manager._setModelFetchOverrideForTesting { _ in fetchScript.next() }
            let serviceBefore = manager._seedConnectedProviderForTesting(provider, models: ["llama-3.2"])

            #expect(
                manager.cachedAvailableModels().first?.models == ["omlx/llama-3.2"]
            )

            await manager.refreshConnectedProviderModels(notifyOnChange: false)

            #expect(
                manager.cachedAvailableModels().first?.models == [
                    "omlx/llama-3.2",
                    "omlx/qwen3-coder",
                ]
            )
            let serviceAfter = try #require(manager.service(for: provider.id))
            #expect(serviceBefore === serviceAfter)
            #expect(await serviceAfter.getRawModels() == ["llama-3.2", "qwen3-coder"])
        }
    }

    @Test("picker cache refresh fetches new custom provider models without restart")
    func pickerCacheRefresh_fetchesNewCustomProviderModelsWithoutRestart() async throws {
        try await runWithCleanProviderManager { manager in
            let provider = makeCustomProvider()
            let fetchScript = ModelFetchScript([
                ["llama-3.2", "qwen3-coder"]
            ])

            await manager._resetForTesting(configuration: RemoteProviderConfiguration(providers: [provider]))
            manager._setModelFetchOverrideForTesting { _ in fetchScript.next() }
            manager._seedConnectedProviderForTesting(provider, models: ["llama-3.2"])

            let initialItems = await ModelPickerItemCache.shared.buildModelPickerItems()
            #expect(initialItems.contains { $0.id == "omlx/llama-3.2" })
            #expect(!initialItems.contains { $0.id == "omlx/qwen3-coder" })

            let refreshedItems = await ModelPickerItemCache.shared.refreshRemoteProvidersAndBuildModelPickerItems()

            #expect(refreshedItems.contains { $0.id == "omlx/llama-3.2" })
            #expect(refreshedItems.contains { $0.id == "omlx/qwen3-coder" })
        }
    }

    private func runWithCleanProviderManager(
        _ body: @MainActor @Sendable (RemoteProviderManager) async throws -> Void
    ) async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let manager = RemoteProviderManager.shared
            await manager._resetForTesting()

            do {
                try await body(manager)
            } catch {
                await manager._resetForTesting()
                _ = await ModelPickerItemCache.shared.buildModelPickerItems()
                throw error
            }

            await manager._resetForTesting()
            _ = await ModelPickerItemCache.shared.buildModelPickerItems()
        }
    }

    private func makeCustomProvider() -> RemoteProvider {
        RemoteProvider(
            id: UUID(),
            name: "oMLX",
            host: "localhost",
            providerProtocol: .http,
            port: 11434,
            basePath: "/v1",
            authType: .none,
            providerType: .openaiLegacy,
            enabled: true,
            autoConnect: true
        )
    }

    private final class ModelFetchScript {
        private var responses: [[String]]

        init(_ responses: [[String]]) {
            self.responses = responses
        }

        func next() -> [String] {
            if responses.isEmpty {
                return []
            }
            return responses.removeFirst()
        }
    }
}
