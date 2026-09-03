//
//  ModelPickerItemCacheTests.swift
//  osaurusTests
//
//  Regression tests for the launch-time race that caused remote-provider
//  models to disappear from the model picker until the user disconnected
//  and reconnected the provider.
//
//  The cache is a process-wide singleton driven by NotificationCenter, so
//  these tests mostly verify invariants of the serialized rebuild path:
//
//  1. Concurrent callers of `buildModelPickerItems()` are coalesced and all
//     return the same final list.
//  2. `items` is never transiently emptied while a rebuild is in flight
//     (the bug previously was caused by `invalidateCache()` running inside
//     the notification observer).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ModelPickerItemCacheTests {

    /// Hammer the cache from many concurrent tasks. Because the underlying
    /// state (foundation availability, local models, remote providers) does
    /// not change during the test, every concurrent caller MUST observe the
    /// same final result. Before the fix, two concurrent rebuilds — one
    /// with `includeRemote: false` (the old `prewarmLocalModelsOnly`) and
    /// one with `includeRemote: true` — could finish in non-deterministic
    /// order, so callers could disagree about whether remote models were
    /// present.
    @Test func concurrentCallers_returnIdenticalResults() async throws {
        await RemoteProviderTestLock.shared.run {
            // Establish a baseline so we know what to compare against, and so
            // any work needed to populate the cache (e.g. local model
            // discovery) doesn't perturb the concurrent run below.
            let baselineItems = await ModelPickerItemCache.shared.buildModelPickerItems()
            let baselineIds = baselineItems.map(\.id)

            // Spawn many detached tasks that each call into the @MainActor
            // cache. Detached tasks are deliberately used so the calls hop
            // back into the MainActor at the await point and exercise the
            // serialized rebuild path the way real callers do (notification
            // observer Tasks, the AppDelegate prewarm Task, ChatView's
            // refresh Task, and so on).
            var tasks: [Task<[String], Never>] = []
            for _ in 0 ..< 32 {
                tasks.append(
                    Task.detached {
                        let items = await ModelPickerItemCache.shared.buildModelPickerItems()
                        return items.map(\.id)
                    }
                )
            }

            for task in tasks {
                let ids = await task.value
                #expect(ids == baselineIds)
            }
            #expect(ModelPickerItemCache.shared.isLoaded)
        }
    }

    /// Posting a burst of `.remoteProviderModelsChanged` notifications used
    /// to call `invalidateCache()` inside the observer Task, blanking
    /// `items` to `[]` until the rebuild's detached local-discovery task
    /// resumed. Anyone reading `cache.items` during that window — most
    /// notably `ChatView.init` — would snapshot an empty list. This test
    /// asserts the invariant that, once populated, `items` never goes
    /// empty across rebuilds.
    @Test func notificationBurst_doesNotTransientlyEmptyItems() async throws {
        await RemoteProviderTestLock.shared.run {
            let cache = ModelPickerItemCache.shared

            // Make sure we start populated. If this machine has no foundation
            // model, no local MLX models, and no connected remote providers,
            // the invariant is trivially satisfied - skip in that case so CI
            // doesn't false-positive.
            _ = await cache.buildModelPickerItems()
            guard !cache.items.isEmpty else { return }
            let initialCount = cache.items.count

            // Spam many notifications. Each one schedules an observer Task
            // that calls `buildModelPickerItems()`. Pre-fix, each Task would
            // first set `items = []` and `isLoaded = false`.
            for _ in 0 ..< 50 {
                NotificationCenter.default.post(
                    name: .remoteProviderModelsChanged,
                    object: nil
                )
            }

            // Drain the observer Tasks by repeatedly yielding the MainActor
            // and sampling `items`. With the fix, every sample must be
            // non-empty - the rebuild only assigns `items` when it has the
            // full list.
            var samples: [Int] = []
            for _ in 0 ..< 200 {
                samples.append(cache.items.count)
                try? await Task.sleep(nanoseconds: 200_000)  // 0.2ms
            }

            #expect(
                !samples.contains(0),
                "items must remain populated during rebuilds; observed sample counts: \(samples)"
            )

            // After the burst settles, the cache should still hold a
            // populated list (state hasn't actually changed, so it should
            // match the initial count).
            let final = await cache.buildModelPickerItems()
            #expect(!final.isEmpty)
            #expect(final.count == initialCount)
        }
    }

    /// Embedding/encoder-only bundles (e.g. potion-base-4M pulled into the
    /// HF cache by the memory feature) must be excluded from the chat
    /// picker's item list, while regular causal-LM bundles pass through.
    @Test func computeItems_excludesLocalEmbeddingBundles() async throws {
        try await RemoteProviderTestLock.shared.run {
            // Two on-disk fixture bundles classified purely via config.json.
            func makeBundle(config: [String: Any]) throws -> URL {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "osu-picker-cache-\(UUID().uuidString)",
                        isDirectory: true
                    )
                try FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true
                )
                try JSONSerialization.data(withJSONObject: config)
                    .write(to: dir.appendingPathComponent("config.json"))
                return dir
            }
            let chatDir = try makeBundle(config: [
                "model_type": "qwen2",
                "architectures": ["Qwen2ForCausalLM"],
            ])
            let embedDir = try makeBundle(config: [
                "model_type": "model2vec",
                "architectures": ["StaticModel"],
            ])

            let fixtures = [
                MLXModel(
                    id: "fixture/chat-model-4bit",
                    name: "Fixture Chat Model",
                    description: "fixture",
                    downloadURL: "https://example.invalid/chat",
                    bundleDirectory: chatDir
                ),
                MLXModel(
                    id: "fixture/potion-base-4M",
                    name: "Fixture Embedding Model",
                    description: "fixture",
                    downloadURL: "https://example.invalid/potion",
                    bundleDirectory: embedDir
                ),
            ]

            let prevScan = ModelManager.scanLocalModelsOverrideForTests
            let prevWait = ModelManager.localModelsScanWaitLimitOverrideForTests
            ModelManager.localModelsScanWaitLimitOverrideForTests = 2.0
            ModelManager.scanLocalModelsOverrideForTests = { _ in fixtures }
            ModelManager.invalidateLocalModelsCache()

            let items = await ModelPickerItemCache.shared.buildModelPickerItems()
            let ids = items.map(\.id)

            // Restore globals and rebuild before asserting so fixture
            // entries can't linger in the shared cache for later suites.
            ModelManager.scanLocalModelsOverrideForTests = prevScan
            ModelManager.localModelsScanWaitLimitOverrideForTests = prevWait
            ModelManager.invalidateLocalModelsCache()
            await ModelPickerItemCache.shared.buildModelPickerItems()
            try? FileManager.default.removeItem(at: chatDir)
            try? FileManager.default.removeItem(at: embedDir)

            #expect(ids.contains("fixture/chat-model-4bit"))
            #expect(!ids.contains("fixture/potion-base-4M"))
        }
    }

    // MARK: - Provider-scoped reasoning enrichment

    private static func providerEntry(
        name: String,
        type: RemoteProviderType,
        host: String,
        models: [String]
    ) -> RemoteProviderManager.CachedProviderModels {
        RemoteProviderManager.CachedProviderModels(
            providerId: UUID(),
            providerName: name,
            providerType: type,
            host: host,
            models: models
        )
    }

    /// Custom OpenAI-compatible providers surface the context window their
    /// `/models` endpoint advertised (vLLM `max_model_len` etc.); models the
    /// server reported no window for keep a nil contextLength so resolution
    /// falls through to the configured fallback.
    @Test func remoteModelItems_attachesAdvertisedContextLengths() throws {
        let provider = Self.providerEntry(
            name: "vLLM",
            type: .openaiLegacy,
            host: "vllm.internal",
            models: ["vllm/DeepSeek4-Flash", "vllm/no-window-model"]
        )

        let result = ModelPickerItemCache.remoteModelItems(
            providers: [provider],
            codexMetadata: [:],
            osaurusRouterProviderId: RemoteProviderManager.osaurusRouterProviderId,
            routerMetadata: { _ in nil },
            remoteContextLength: { providerId, unprefixedId in
                #expect(providerId == provider.providerId)
                return unprefixedId == "DeepSeek4-Flash" ? 524288 : nil
            }
        )
        let byId = Dictionary(uniqueKeysWithValues: result.items.map { ($0.id, $0) })

        #expect(byId["vllm/DeepSeek4-Flash"]?.contextLength == 524288)
        #expect(byId["vllm/no-window-model"]?.contextLength == nil)
    }

    /// Codex items take the live catalog's display name + capability set;
    /// official `api.openai.com` API-key GPT-5.6 models take the documented
    /// public profile; custom OpenAI-compatible providers get neither, even
    /// for identical slugs. The returned capability map is keyed by the full
    /// provider-prefixed id so the two routes never cross-contaminate.
    @Test func remoteModelItems_appliesProviderScopedReasoningEnrichment() throws {
        let codexMetadata = CodexModelMetadata(
            slug: "gpt-5.6-terra",
            displayName: "GPT-5.6 Terra",
            defaultReasoningLevel: "medium",
            supportedReasoningLevels: ["low", "medium", "high", "xhigh", "max", "ultra"].map {
                CodexReasoningLevel(effort: $0)
            },
            usesResponsesLite: true,
            contextWindow: 1_048_576
        )
        let providers = [
            Self.providerEntry(
                name: "OpenAI ChatGPT",
                type: .openAICodex,
                host: "chatgpt.com",
                models: ["openai-chatgpt/gpt-5.6-terra", "openai-chatgpt/gpt-5.5"]
            ),
            Self.providerEntry(
                name: "OpenAI",
                type: .openResponses,
                host: "api.openai.com",
                models: ["openai/gpt-5.6-sol", "openai/gpt-4.1"]
            ),
            Self.providerEntry(
                name: "Proxy",
                type: .openResponses,
                host: "my-proxy.example.com",
                models: ["proxy/gpt-5.6-sol"]
            ),
        ]

        let result = ModelPickerItemCache.remoteModelItems(
            providers: providers,
            codexMetadata: ["gpt-5.6-terra": codexMetadata],
            osaurusRouterProviderId: RemoteProviderManager.osaurusRouterProviderId,
            routerMetadata: { _ in nil }
        )
        let byId = Dictionary(uniqueKeysWithValues: result.items.map { ($0.id, $0) })

        // Codex + catalog metadata: display name and full level set (ultra).
        let terra = try #require(byId["openai-chatgpt/gpt-5.6-terra"])
        #expect(terra.displayName == "GPT-5.6 Terra")
        #expect(
            terra.reasoningCapabilities?.levels.map(\.id)
                == ["low", "medium", "high", "xhigh", "max", "ultra"]
        )
        #expect(terra.reasoningCapabilities?.defaultLevelId == "medium")
        #expect(terra.contextLength == 1_048_576)

        // Codex without catalog metadata: plain remote behavior, no window.
        let legacyCodex = try #require(byId["openai-chatgpt/gpt-5.5"])
        #expect(legacyCodex.displayName == "gpt-5.5")
        #expect(legacyCodex.reasoningCapabilities == nil)
        #expect(legacyCodex.contextLength == nil)

        // Official API key route: documented public GPT-5.6 profile, id/display
        // preserved, and never Codex-only ultra.
        let sol = try #require(byId["openai/gpt-5.6-sol"])
        #expect(sol.displayName == "gpt-5.6-sol")
        #expect(sol.reasoningCapabilities == .officialOpenAIGPT56)
        #expect(sol.reasoningCapabilities?.levels.map(\.id).contains("ultra") == false)
        #expect(sol.chatEndpointCapability == .unknown)
        #expect(sol.description?.contains("/v1/models") == true)
        // /v1/models never reports a window, so the official route falls back
        // to the documented per-family table instead of the generic default.
        #expect(sol.contextLength == 1_050_000)

        // Official route, non-GPT-5.6 id: no documented profile.
        let gpt41 = try #require(byId["openai/gpt-4.1"])
        #expect(gpt41.reasoningCapabilities == nil)

        // Custom OpenAI-compatible provider: never assumed to support the
        // official contract, even for a GPT-5.6 slug.
        let proxySol = try #require(byId["proxy/gpt-5.6-sol"])
        #expect(proxySol.reasoningCapabilities == nil)
        #expect(proxySol.chatEndpointCapability == .supported)
        // The static window table is scoped to api.openai.com only — a proxy
        // claiming an OpenAI slug must not inherit OpenAI's real window.
        #expect(proxySol.contextLength == nil)

        // Capability map holds exactly the enriched full ids.
        #expect(
            Set(result.reasoningCapabilities.keys)
                == ["openai-chatgpt/gpt-5.6-terra", "openai/gpt-5.6-sol"]
        )
    }

    /// A catalog refetch that changes metadata while model ids stay identical
    /// must still produce different items (so `ChatView.applyPickerItems`
    /// re-normalizes options) and an updated capability map.
    /// Longest matching prefix wins so dated snapshots resolve to their
    /// family's window, and an id outside the known families falls back to
    /// nil (never a guessed number) so resolution defers to the configured
    /// fallback instead of asserting a wrong window.
    @Test func officialOpenAIContextWindow_resolvesByLongestPrefixMatch() {
        #expect(ModelPickerItem.officialOpenAIContextWindow(forModelId: "gpt-5.6-luna") == 1_050_000)
        #expect(ModelPickerItem.officialOpenAIContextWindow(forModelId: "gpt-5.5-2026-01-01") == 1_050_000)
        // "gpt-5.2" must not fall through to the shorter "gpt-5" entry.
        #expect(ModelPickerItem.officialOpenAIContextWindow(forModelId: "gpt-5.2") == 400_000)
        #expect(ModelPickerItem.officialOpenAIContextWindow(forModelId: "gpt-5") == 400_000)
        #expect(ModelPickerItem.officialOpenAIContextWindow(forModelId: "gpt-4.1") == 1_047_576)
        #expect(ModelPickerItem.officialOpenAIContextWindow(forModelId: "gpt-4o-mini") == 128_000)
        #expect(ModelPickerItem.officialOpenAIContextWindow(forModelId: "gpt-3.5-turbo-0125") == 16_385)
        // Provider-prefixed id: only the bare slug is matched.
        #expect(ModelPickerItem.officialOpenAIContextWindow(forModelId: "openai/gpt-4.1") == 1_047_576)
        #expect(ModelPickerItem.officialOpenAIContextWindow(forModelId: "davinci-002") == nil)
    }

    @Test func remoteModelItems_sameIds_reflectMetadataRefresh() throws {
        let provider = Self.providerEntry(
            name: "OpenAI ChatGPT",
            type: .openAICodex,
            host: "chatgpt.com",
            models: ["openai-chatgpt/gpt-5.6-terra"]
        )
        func metadata(levels: [String]) -> CodexModelMetadata {
            CodexModelMetadata(
                slug: "gpt-5.6-terra",
                displayName: "GPT-5.6 Terra",
                defaultReasoningLevel: "medium",
                supportedReasoningLevels: levels.map { CodexReasoningLevel(effort: $0) },
                usesResponsesLite: true
            )
        }

        let before = ModelPickerItemCache.remoteModelItems(
            providers: [provider],
            codexMetadata: ["gpt-5.6-terra": metadata(levels: ["low", "medium", "high", "ultra"])],
            osaurusRouterProviderId: RemoteProviderManager.osaurusRouterProviderId,
            routerMetadata: { _ in nil }
        )
        let after = ModelPickerItemCache.remoteModelItems(
            providers: [provider],
            codexMetadata: ["gpt-5.6-terra": metadata(levels: ["low", "medium", "high"])],
            osaurusRouterProviderId: RemoteProviderManager.osaurusRouterProviderId,
            routerMetadata: { _ in nil }
        )

        #expect(before.items.map(\.id) == after.items.map(\.id))
        #expect(before.items != after.items, "metadata-only changes must be observable")
        #expect(
            after.reasoningCapabilities["openai-chatgpt/gpt-5.6-terra"]?.levels.map(\.id)
                == ["low", "medium", "high"]
        )
    }
}
