// Copyright © 2026 osaurus.

import Foundation
import Testing

@Suite("Runtime source policy")
struct RuntimePolicySourceTests {
    private static func packageRoot() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        var cursor = here.deletingLastPathComponent()  // Service/
        cursor.deleteLastPathComponent()  // Tests/
        return cursor.deletingLastPathComponent()  // OsaurusCore/
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = packageRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func swiftFiles(under relativePath: String) throws -> [URL] {
        let root = packageRoot().appendingPathComponent(relativePath)
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            )
        else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    @Test("AppDelegate leaves DSV4 cache topology to vmlx")
    func appDelegateDoesNotForceDSV4DiagnosticCacheMode() throws {
        let source = try Self.source("AppDelegate.swift")

        #expect(
            !source.contains("setenv(\"DSV4_KV_MODE\""),
            "osaurus must not force DSV4_KV_MODE; unset keeps vmlx's SWA+CSA+HSA default"
        )
        #expect(
            !source.contains("DSV4_KV_MODE=full"),
            "full KV mode is diagnostic-only and drops DSV4 hybrid pool cache"
        )
        #expect(source.contains("SWA+CSA+HSA"))
    }

    @Test("vmlx pin uses consolidated package with runtime hardening")
    func vmlxPinIncludesRuntimeHardening() throws {
        let manifest = try Self.source("Package.swift")
        let workspaceResolved = try Self.source(
            "../../osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        let appResolved = try Self.source(
            "../../App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )

        // This revision keeps the consolidated vmlx-swift pin for Osaurus
        // with vendored Jinja/Hub/Tokenizers/Transformers exposed through
        // VMLX-prefixed products. That avoids Xcode PIF duplicate-product
        // collisions with the app graph while keeping yyjson as one shared C
        // dependency. Osaurus must not carry SwiftPM moduleAliases for that
        // collision.
        let currentVmlxRevision = "78858890ce37db28c69870363d04f24796eac961"
        #expect(manifest.contains(currentVmlxRevision))
        #expect(workspaceResolved.contains(currentVmlxRevision))
        #expect(appResolved.contains(currentVmlxRevision))
        #expect(manifest.contains("https://github.com/osaurus-ai/vmlx-swift"))
        #expect(!manifest.contains("https://github.com/osaurus-ai/vmlx-swift-lm"))
        #expect(!manifest.contains("https://github.com/osaurus-ai/mlx-swift"))
        #expect(!manifest.contains("https://github.com/osaurus-ai/swift-transformers"))
        #expect(!manifest.contains("https://github.com/osaurus-ai/Jinja.git"))
        #expect(manifest.contains(".product(name: \"MLX\", package: \"vmlx-swift\")"))
        #expect(manifest.contains(".product(name: \"MLXLLM\", package: \"vmlx-swift\")"))
        #expect(manifest.contains(".product(name: \"MLXVLM\", package: \"vmlx-swift\")"))
        #expect(manifest.contains(".product(name: \"MLXLMCommon\", package: \"vmlx-swift\")"))
        #expect(manifest.contains(".product(name: \"VMLXTokenizers\", package: \"vmlx-swift\")"))
        #expect(manifest.contains(".product(name: \"VMLXJinja\", package: \"vmlx-swift\")"))
    }

    @Test("SwiftPM graph keeps vmlx inference modules unshadowed")
    func swiftPMGraphUsesConsolidatedVMLXRuntime() throws {
        let manifest = try Self.source("Package.swift")
        let workspaceMirrors = try Self.source(
            "../../osaurus.xcworkspace/xcshareddata/swiftpm/configuration/mirrors.json"
        )
        let appProjectMirrors = try Self.source(
            "../../App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration/mirrors.json"
        )
        let contributing = try Self.source("../../docs/CONTRIBUTING.md")

        let tokenizerLoader = try Self.source(
            "Services/ModelRuntime/SwiftTransformersTokenizerLoader.swift"
        )
        let jinjaTests = try Self.source("Tests/Service/JinjaTemplateCompatibilityTests.swift")

        #expect(!manifest.contains("vmlxRuntimeModuleAliases"))
        #expect(!manifest.contains("moduleAliases:"))
        #expect(manifest.contains("https://github.com/mattt/eventsource.git"))
        #expect(manifest.contains("traits: [.trait(name: \"AsyncHTTPClient\")]"))
        #expect(!manifest.contains("https://github.com/ibireme/yyjson.git"))
        #expect(manifest.contains(".product(name: \"MCP\", package: \"swift-sdk\")"))
        #expect(manifest.contains(".product(name: \"VecturaKit\", package: \"VecturaKit\")"))
        #expect(tokenizerLoader.contains("import VMLXTokenizers"))
        #expect(!tokenizerLoader.contains("import Tokenizers"))
        #expect(jinjaTests.contains("import VMLXJinja"))
        #expect(!jinjaTests.contains("import Jinja"))

        for mirrors in [workspaceMirrors, appProjectMirrors] {
            #expect(mirrors.contains("\"original\" : \"https://github.com/huggingface/swift-transformers\""))
            #expect(mirrors.contains("\"original\" : \"https://github.com/huggingface/swift-transformers.git\""))
            #expect(mirrors.contains("\"mirror\" : \"https://github.com/osaurus-ai/swift-transformers\""))
            #expect(mirrors.contains("\"original\" : \"https://github.com/huggingface/swift-jinja\""))
            #expect(mirrors.contains("\"original\" : \"https://github.com/huggingface/swift-jinja.git\""))
            #expect(mirrors.contains("\"mirror\" : \"https://github.com/osaurus-ai/Jinja.git\""))
        }

        #expect(contributing.contains("single consolidated `vmlx-swift` pin"))
        #expect(contributing.contains("prefixed inside `vmlx-swift`"))
        #expect(contributing.contains("Keep the two mirror files in sync"))
    }

    /// Lock the post-generation SSM re-derive opt-out. vmlx defaults
    /// `enableSSMReDerive=true`. Pre-`b9da180` this ran a FULL second
    /// prefill BEFORE yielding `.info` (the Ling stuck-before-end
    /// symptom). vmlx pin `b9da180` reordered the pass to run AFTER
    /// `.info`, fixing the stream-stays-open UX. We KEEP the opt-out
    /// regardless because osaurus's chat workload mutates the system
    /// prefix every turn (memory injection, preflight capability search,
    /// dynamic skills) so the SSM cache rarely lands a boundary-matching
    /// hit on the next turn — re-derive cost is paid without warm-cache
    /// payoff. If a future refactor drops or inverts the knob, this
    /// assertion breaks first.
    @Test("CacheCoordinatorConfig disables SSM re-derive for chat workflow")
    func cacheConfigDisablesSSMReDerive() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")

        #expect(
            runtime.contains("enableSSMReDerive: false"),
            "ModelRuntime.buildCacheCoordinatorConfig must opt out of vmlx's default SSM re-derive — osaurus's mutating-system-prefix chat workload doesn't amortize the cost across turns"
        )
    }

    @Test("Flexible model residency respects load-time memory budget")
    func flexibleModelResidencyEvictsBeforeOversizedLoads() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")

        #expect(runtime.contains("flexibleResidentBudgetBytes"))
        #expect(runtime.contains("ProcessInfo.processInfo.physicalMemory) * 0.70"))
        #expect(runtime.contains("unloadForFlexibleResidentBudget"))
        #expect(runtime.contains("policy == .manualMultiModel"))
        #expect(runtime.contains("flexible budget eviction"))
        #expect(runtime.contains("incomingWeightsSizeBytes"))
    }

    /// Lock the `.engineShutdown` evict-and-rebuild path. If
    /// `BatchEngine.updateMaxBatchSize(_:)` throws `engineShutdown`
    /// (the cached engine has been torn down between calls), the
    /// adapter MUST evict the dead handle and rebuild — leaving it in
    /// `coalescer.values` would loop forever, contradicting the
    /// "coalescer rebuilds on next first-fetch" doc claim.
    @Test("MLXBatchAdapter handles BatchEngine.updateMaxBatchSize engineShutdown by evicting + rebuilding")
    func mlxBatchAdapterEvictsAndRebuildsOnEngineShutdown() throws {
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")

        #expect(
            adapter.contains("BatchEngineConfigurationError.engineShutdown"),
            "Registry.engine(...) must catch BatchEngineConfigurationError.engineShutdown specifically — a generic catch loses the eviction signal and the dead engine stays in the coalescer forever"
        )
        #expect(
            adapter.contains("evicting and rebuilding at maxBatchSize"),
            "The eviction log line must be present so future debug sessions can confirm the dead-engine path was taken"
        )
        // Eviction goes through the coalescer's dispose variant so the
        // tombstone protects racers from building on a half-shut-down
        // engine. The exact call shape is what locks the discipline.
        #expect(
            adapter.contains("await coalescer.remove(modelName) { engine in"),
            "Eviction must call `coalescer.remove(_:dispose:)` so the tombstone stays alive across the defensive `engine.shutdown()` call (mirrors the shutdownEngine path)"
        )
        // After eviction, recurse so the next first-fetch builds fresh.
        #expect(
            adapter.contains("return await self.engine("),
            "Post-eviction must recurse into engine(...) so the rebuild lands through the coalescer's first-fetch path"
        )
    }

    /// With the default `maxBatchSize == 1`, vmlx can use its solo
    /// TokenIterator-backed fast path. Osaurus must not let a second same-model
    /// request run prompt tokenization / `MLXArray.asArray(...)` while that
    /// decode is still active. vmlx emits `.info` before its post-generation
    /// cache store finishes, so Osaurus also must not release the solo lease
    /// at `.info`; otherwise a second request can enter `prepareInput` while
    /// the first one is still materializing safetensors cache tensors on Metal.
    @Test("MLXBatchAdapter gates same-model solo generation and propagates stream cancellation")
    func mlxBatchAdapterGatesSoloGenerationAndCancelsProducer() throws {
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")

        #expect(adapter.contains("actor SoloGenerationGate"))
        #expect(adapter.contains("maxBatchSize == 1"))
        #expect(adapter.contains("acquireSoloLease"))
        #expect(adapter.contains("await soloLease.release()"))
        #expect(
            adapter.contains("post-generation disk-cache store")
                && adapter.contains("for await event in upstream")
                && adapter.contains(
                    "if case .info = event {\n                        continuation.yield(event)\n                        continue\n                    }"
                ),
            "adapter must forward terminal info but keep draining vmlx until the upstream stream finishes, so the solo lease covers post-generation cache persistence"
        )
        #expect(
            adapter.contains("continuation.onTermination = { @Sendable _ in")
                && adapter.contains("producerTask.cancel()"),
            "adapter stream termination must cancel the producer so UI Stop reaches vmlx's upstream AsyncStream termination handler"
        )
    }

    /// The terminal `.info` event carries stopReason, token counts, and
    /// `unclosedReasoning`. Dropping it is exactly how a reasoning-only MiniMax
    /// run can finish with a visible Thinking pane but no "thinking did not
    /// close" diagnostic. Cancellation must not be checked before preserving
    /// `.info` / stats sentinels at any Osaurus stream boundary.
    @Test("Generation stream wrappers preserve terminal info before honoring cancellation")
    func generationWrappersPreserveTerminalInfoBeforeCancellation() throws {
        let mapper = try Self.source("Services/ModelRuntime/GenerationEventMapper.swift")
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")
        let runtime = try Self.source("Services/ModelRuntime.swift")
        let chatEngine = try Self.source("Services/Chat/ChatEngine.swift")

        #expect(
            !mapper.contains(
                "for await event in events {\n                    if Task.isCancelled { break }\n                    switch event"
            ),
            "GenerationEventMapper must switch on `.info` before checking Task.isCancelled, otherwise final stats/unclosedReasoning can be lost"
        )
        #expect(
            !adapter.contains(
                "for await event in upstream {\n                    if Task.isCancelled { break }\n                    continuation.yield(event)\n                }"
            ),
            "MLXBatchAdapter must preserve upstream `.info` before honoring cancellation, otherwise vmlx's final cancelled/length/stop event is dropped"
        )
        #expect(
            adapter.contains(
                "if !Task.isCancelled {\n                        continuation.yield(event)\n                    }"
            ),
            "MLXBatchAdapter must keep draining cancelled upstream streams until `.info`, while suppressing only non-terminal deltas after cancellation"
        )
        #expect(
            !adapter.contains(
                "onCancel: {\n                // The upstream stream is bound to a single request inside\n                // the engine; cancelling the consumer task closes it\n                // cooperatively (engine emits a final `.info(.cancelled)`\n                // and finishes the stream).\n                continuation.finish()\n            }"
            ),
            "MLXBatchAdapter's cancellation handler must not immediately finish the wrapper stream while its producer can still drain vmlx's terminal `.info`"
        )
        #expect(
            !runtime.contains(
                "for try await ev in events {\n                    if Task.isCancelled {\n                        continuation.finish()\n                        return\n                    }\n                    switch ev"
            ),
            "ModelRuntime.streamWithTools must encode `.completionInfo` into StreamingStatsHint before honoring cancellation"
        )
        #expect(
            !chatEngine.contains(
                "for try await delta in inner {\n                    // Check for task cancellation to allow early termination\n                    if Task.isCancelled"
            ),
            "ChatEngine stream logging wrapper must pass StreamingStatsHint through before honoring cancellation"
        )
    }

    /// Preflight tool selection is a background prompt-ranking call, not the user's
    /// answer. It can fall back to the active chat model, so reasoning families
    /// must be forced onto their short non-thinking path or they can monopolize
    /// the single B=1 engine slot before the real chat request starts.
    @Test("Preflight fallback LLM forces no-think model options")
    func preflightFallbackLLMForcesNoThinkOptions() throws {
        let coreModel = try Self.source("Services/Inference/CoreModelService.swift")
        let preflight = try Self.source("Services/Context/PreflightCapabilitySearch.swift")

        #expect(
            coreModel.contains("modelOptions: [String: ModelOptionValue]"),
            "CoreModelService.generate must provide an internal per-call modelOptions path so background callers can choose non-thinking rails without exposing internal option types as public API"
        )
        #expect(
            coreModel.contains("modelOptions: modelOptions"),
            "CoreModelService.generate must thread modelOptions into GenerationParameters before routing to MLX/remote services"
        )
        #expect(
            preflight.contains("modelOptions: [\"reasoningEffort\": .string(\"no_think\")]"),
            "PreflightCapabilitySearch.defaultLLM must force no_think so Hy3/ZAYA/Qwen-style reasoning templates do not spend the tool-ranking timeout generating long reasoning traces"
        )
    }

    @Test("MLXBatchAdapter image preprocessing preserves media, reasoning, and tool metadata")
    func mlxBatchAdapterPreprocessingPreservesMediaReasoningAndToolMetadata() throws {
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")
        guard let rebuildRange = adapter.range(of: "return MLXLMCommon.Chat.Message(") else {
            Issue.record("Could not find Chat.Message rebuild in MLXBatchAdapter.preprocessImages")
            return
        }
        let rebuild = adapter[rebuildRange.lowerBound...]
            .prefix(while: { $0 != ")" })

        #expect(rebuild.contains("images: processedImages"))
        #expect(rebuild.contains("videos: message.videos"))
        #expect(
            rebuild.contains("audios: message.audios"),
            "preprocessImages must not drop audio inputs before vmlx omni/audio tokenization"
        )
        #expect(
            rebuild.contains("reasoningContent: message.reasoningContent"),
            "preprocessImages must not drop assistant reasoning history before vmlx Jinja templates render message.reasoning_content"
        )
        #expect(rebuild.contains("toolCalls: message.toolCalls"))
        #expect(rebuild.contains("toolCallId: message.toolCallId"))
    }

    @Test("HTTP streams preserve stats hints before generic sentinel filters")
    func httpStreamsPreserveStatsHintsBeforeGenericSentinelFilters() throws {
        let handler = try Self.source("Networking/HTTPHandler.swift")

        let segments = handler.components(separatedBy: "StreamingToolHint.isSentinel(delta)")

        #expect(
            segments.count == 6,
            "HTTPHandler should have five generic StreamingToolHint sentinel filters; update this guard when adding another HTTP stream writer"
        )

        for segment in segments.dropLast() {
            #expect(
                segment.contains("StreamingStatsHint.decode(delta)"),
                "Each HTTP stream writer must decode StreamingStatsHint before the generic U+FFFE sentinel filter, otherwise API usage stats and unclosedReasoning are dropped"
            )
        }
    }

    /// Lock the removal of the `activeGenerationTask?.value` gate at
    /// the entry of `generateEventStream`. The gate was serializing
    /// every same-model overlapping request before vmlx's `BatchEngine`
    /// could see it, defeating continuous batching. The field's own
    /// doc (lines 82-87) says "lease drives correctness — many can be
    /// active simultaneously"; if a future refactor reintroduces the
    /// gate, this test breaks first and forces the discussion.
    @Test("ModelRuntime.generateEventStream does not serialize on activeGenerationTask")
    func generateEventStreamDoesNotSerializeOnActiveGenerationTask() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")

        // The gate would look like `_ = await activeGenerationTask?.value`
        // anywhere outside `cancelActiveGeneration()` (which legitimately
        // awaits the task on shutdown). The pattern here is narrow: any
        // `await activeGenerationTask?.value` on a line whose enclosing
        // function is NOT `cancelActiveGeneration` is the gate we removed.
        // We assert the public-side gate is gone by spot-checking the
        // generation entry point's neighborhood and the explanatory
        // comment that locks the rationale.
        #expect(
            runtime.contains("// No serialization gate against `activeGenerationTask` here:"),
            "ModelRuntime.generateEventStream must keep the explanatory comment that documents why the gate was removed; if the comment goes away, the policy is undocumented and the next refactor may silently reintroduce serialization"
        )
        #expect(
            runtime.contains("ModelLease` is the authoritative"),
            "Comment must call out that the lease is the authoritative concurrency signal"
        )
        // The cancelActiveGeneration helper still legitimately awaits
        // the task; that's fine and remains in the file.
        #expect(
            runtime.contains("private func cancelActiveGeneration(for modelName: String? = nil) async {"),
            "cancelActiveGeneration() must still exist for shutdown / clearAll cancellation paths"
        )
        #expect(
            runtime.contains("if let modelName, record.modelName != modelName { return }"),
            "ModelRuntime.unload(name:) must not cancel a generation belonging to a different model"
        )
        #expect(
            runtime.contains("await cancelActiveGeneration(for: name)"),
            "ModelRuntime.unload(name:) must scope defensive cancellation to the model being unloaded"
        )
    }

    /// Lock the cold-load drain discipline. Swift task cancellation is
    /// cooperative; a cancelled `loadModelContainer` can still be inside MLX
    /// weight materialization. Starting a replacement load before the old task
    /// drains leaves two independent MLX load/eval paths racing on Metal.
    @Test("ModelRuntime drains superseded cold loads before starting replacements")
    func modelRuntimeDrainsSupersededColdLoads() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")

        #expect(runtime.contains("private struct LoadingTaskRecord"))
        #expect(runtime.contains("supersededLoadingTaskIDs"))
        #expect(runtime.contains("private func cancelAndDrainLoadingTasks"))
        #expect(runtime.contains("record.task.cancel()"))
        #expect(runtime.contains("try? await record.task.value"))
        #expect(runtime.contains("holder.container.disableCaching()"))
        #expect(runtime.contains("loadContainer: strict drain of in-flight load"))
        #expect(runtime.contains("return try await finishLoadedContainer"))
        #expect(
            !runtime.contains("loadingTasks[other]?.cancel()"),
            "Strict single-model replacement must not fire-and-forget cancel an in-flight model load"
        )
    }

    @Test("ModelRuntime uses typed vmlx load configuration")
    func modelRuntimeUsesTypedVMLXLoadConfiguration() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")

        #expect(runtime.contains("loadConfiguration: .default"))
        #expect(
            !runtime.contains(
                "loadModelContainer(\n                from: localURL,\n                using: tokenizerLoader\n            )"
            ),
            "ModelRuntime must not use the plain local-directory load overload; it bypasses vmlx LoadConfiguration.default, including load-time memory caps, mmap safetensors, and JANGTQ prestack/alignment"
        )
    }

    @Test("ModelRuntime wires idle residency around model leases")
    func modelRuntimeWiresIdleResidencyAroundLeases() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")
        let manager = try Self.source("Services/ModelRuntime/ModelResidencyManager.swift")

        #expect(runtime.contains("ModelResidencyManager.shared.markActive(modelName: modelName)"))
        #expect(runtime.contains("ModelResidencyManager.shared.markActive(modelName: holder.name)"))
        #expect(runtime.contains("private func scheduleIdleResidency(for modelName: String) async"))
        #expect(runtime.contains("ServerConfigurationStore.load()?.modelIdleResidencyPolicy"))
        #expect(runtime.contains("ModelResidencyManager.shared.scheduleIdleUnload"))
        #expect(runtime.contains("ModelLease.shared.count(for: name)"))
        #expect(runtime.contains("await ModelResidencyManager.shared.cancel(modelName: name)"))
        #expect(runtime.contains("await ModelResidencyManager.shared.cancelAll()"))
        #expect(manager.contains("guard await leaseCount(modelName) == 0"))
        #expect(manager.contains("guard await isResident(modelName)"))
    }

    @Test("UI and health expose model idle residency")
    func uiAndHealthExposeModelIdleResidency() throws {
        let settings = try Self.source("Views/Settings/ConfigurationView.swift")
        let health = try Self.source("Networking/HTTPHandler.swift")
        let windows = try Self.source("Managers/Chat/ChatWindowManager.swift")

        #expect(settings.contains("tempIdleResidencyPolicy"))
        #expect(settings.contains("Keep model loaded after use"))
        #expect(settings.contains("ModelIdleResidencyPolicy.presets"))
        #expect(health.contains("\"resident_models\": residentModels"))
        #expect(health.contains("\"idle_unload_at\""))
        #expect(health.contains("\"idle_seconds_remaining\""))
        #expect(windows.contains("modelIdleResidencyPolicy"))
        #expect(windows.contains("if idlePolicy == .immediately"))
    }

    @Test("ModelRuntime does not block model-ready on hidden Hy3 warmup generation")
    func modelRuntimeDoesNotBlockModelReadyOnHy3WarmupGeneration() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")

        #expect(
            !runtime.contains("runPostLoadWarmupIfNeeded("),
            "ModelRuntime must not await a hidden Hy3 generation inside loadContainer; it makes the UI report first-forward materialization as model loading / TTFT"
        )
        #expect(!runtime.contains("loadContainer: post-load warmup completed"))
        #expect(!runtime.contains("input.additionalContext = [\"reasoning_effort\": \"no_think\"]"))
    }

    @Test("Inference docs match max-batch hot-resize semantics")
    func inferenceDocsDescribeMaxBatchDefaultsAndHotResize() throws {
        let flags = try Self.source("Services/ModelRuntime/InferenceFeatureFlags.swift")
        let runtimeDoc = try Self.source("../../docs/INFERENCE_RUNTIME.md")
        let featuresDoc = try Self.source("../../docs/FEATURES.md")
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")

        #expect(flags.contains("Defaults to **1**"))
        #expect(flags.contains("return raw > 0 ? min(raw, 32) : 1"))
        #expect(runtimeDoc.contains("Defaults to `1`, clamped to `[1, 32]`"))
        #expect(runtimeDoc.contains("mutable at runtime"))
        #expect(runtimeDoc.contains("updateMaxBatchSize"))
        #expect(featuresDoc.contains("default `1`, clamped to `[1, 32]`"))
        #expect(featuresDoc.contains("hot-resized via `BatchEngine.updateMaxBatchSize(_:)`"))
        #expect(!runtimeDoc.contains("Defaults to `4`"))
        #expect(!featuresDoc.contains("default `4`"))
        #expect(adapter.contains("hot-resized BatchEngine"))
        #expect(adapter.contains("rejected updateMaxBatchSize"))
    }

    @Test("Runtime docs keep upstream Metal fault boundaries explicit")
    func inferenceDocsKeepUpstreamMetalFaultBoundaries() throws {
        let runtimeDoc = try Self.source("../../docs/INFERENCE_RUNTIME.md")
        let lingDoc = try Self.source("../../docs/LING_JANGTQ2_LONG_PROMPT_CRASH.md")

        #expect(runtimeDoc.contains("BailingLinearAttention.recurrentGLA"))
        #expect(runtimeDoc.contains("enableSSMReDerive=false"))
        #expect(runtimeDoc.contains("convertToBFloat16(model:)"))
        #expect(runtimeDoc.contains("mlx::core::Fence::wait"))
        #expect(runtimeDoc.contains("AGX::ComputeContext::endComputePass"))
        #expect(lingDoc.contains("EXC_BAD_ACCESS"))
        #expect(lingDoc.contains("BatchEngine.stepPrefill"))
    }

    @Test("SwiftUI previews are gated out of CLI SwiftPM builds")
    func swiftUIPreviewsArePreviewMacroGated() throws {
        var failures: [String] = []

        for url in try Self.swiftFiles(under: "Views") {
            let source = try String(contentsOf: url, encoding: .utf8)
            let lines = source.components(separatedBy: .newlines)
            let previewLines = lines.indices.filter { lines[$0].hasPrefix("#Preview") }
            guard let firstPreviewLine = previewLines.first,
                let lastPreviewLine = previewLines.last
            else {
                continue
            }

            let relativePath = url.path.replacingOccurrences(
                of: Self.packageRoot().path + "/",
                with: ""
            )

            let guardLine = firstPreviewLine > 0 ? lines[firstPreviewLine - 1] : ""
            if guardLine != "#if DEBUG && canImport(PreviewsMacros)" {
                failures.append("\(relativePath): first #Preview is not preceded by the PreviewsMacros gate")
                continue
            }

            var braceDepth = 0
            var sawOpeningBrace = false
            var previewCloseLine: Int?
            for index in lastPreviewLine ..< lines.count {
                for character in lines[index] {
                    switch character {
                    case "{":
                        braceDepth += 1
                        sawOpeningBrace = true
                    case "}":
                        if sawOpeningBrace {
                            braceDepth -= 1
                        }
                    default:
                        break
                    }
                }

                if sawOpeningBrace, braceDepth == 0 {
                    previewCloseLine = index
                    break
                }
            }

            guard let previewCloseLine else {
                failures.append("\(relativePath): last #Preview block did not close")
                continue
            }

            let searchStart = previewCloseLine + 1
            let nextContentLine =
                searchStart < lines.endIndex
                ? lines.indices[searchStart...]
                    .first { !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                : nil
            if nextContentLine == nil || lines[nextContentLine!] != "#endif" {
                failures.append(
                    "\(relativePath): PreviewsMacros gate must close immediately after the last preview block"
                )
            }
        }

        if !failures.isEmpty {
            let message = failures.joined(separator: "\n")
            Issue.record("\(message)")
        }
    }
}
