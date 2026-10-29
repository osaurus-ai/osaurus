import Foundation
import Testing
@preconcurrency import MLXLMCommon

@testable import OsaurusCore

struct AgentSpeculationSettingsTests {
    @Test("agent preference is nullable, lossless, and part of the frozen turn")
    func persistenceAndSnapshots() throws {
        #expect(try JSONDecoder().decode(AgentGenerationSettings.self, from: Data("{}".utf8)).speculativeDecoding == nil)
        for value: Bool? in [nil, false, true] {
            let settings = AgentGenerationSettings(speculativeDecoding: value)
            #expect(settings.isEmpty == (value == nil))
            let draft = AgentGenerationDraft(settings: settings)
            #expect(draft.overrideCount == (value == nil ? 0 : 1))
            #expect(try draft.validated().settings?.speculativeDecoding == value)
            var controls = ChatTurnGenerationControls.capture(activeModelOptions: [:])
            controls.agentSettings = settings
            let frozen = try JSONDecoder().decode(ChatTurnGenerationControls.self, from: JSONEncoder().encode(controls))
            #expect(frozen.agentSettings?.speculativeDecoding == value)
            for _ in 0..<3 {
                var request = ResponsesInferenceRequest(model: "fixture", input: [])
                frozen.apply(to: &request)
                #expect(request.context.speculativeDecoding == value)
                let chat = request.chatCompletionsCompatibilityRequest()
                #expect(ResponsesInferenceRequest(chatCompletion: chat).context.speculativeDecoding == value)
                let wire = String(decoding: try JSONEncoder().encode(chat), as: UTF8.self)
                #expect(!wire.contains("speculativeDecoding"))
                #expect(!wire.contains("speculative_decoding"))
            }
        }
    }

    @Test("chat readout projects the same explicit reasoning as the frozen request")
    func reasoningReadout() {
        let model = "allosaurus-v0.1-125b-a6b-jangh2"
        let inherited: [String: ModelOptionValue] = ["reasoningEffort": .string("xhigh"), "unrelated": .bool(true)]
        var controls = ChatTurnGenerationControls.capture(activeModelOptions: inherited)
        #expect(controls.reasoningOptions(for: model) == inherited)
        controls.agentSettings = .init(reasoningEffort: "low")
        #expect(controls.reasoningOptions(for: model)["reasoningEffort"] == .string("low"))
        controls.overrides.reasoningEffort = "medium"
        #expect(controls.reasoningOptions(for: model)["reasoningEffort"] == .string("medium"))
        controls.agentSettings = .init(enableThinking: false, templateKwargs: ["thinking": .bool(true)])
        controls.overrides = .init()
        #expect(controls.reasoningOptions(for: model)["disableThinking"] == .bool(true))
        controls.agentSettings = .init(templateKwargs: ["thinking": .bool(true)])
        #expect(controls.reasoningOptions(for: model)["disableThinking"] == .bool(false))
        controls = .capture(activeModelOptions: [:])
        controls.agentSettings = .init(templateKwargs: ["reasoning_effort": .string(" high ")])
        #expect(controls.reasoningOptions(for: model)["reasoningEffort"] == .string("high"))
        var request = ResponsesInferenceRequest(model: model, input: [])
        controls.apply(to: &request)
        #expect(controls.reasoningOptions(for: model) == AgentReasoningPolicy.applyingExplicitReasoning(
            request.generation, to: request.context.modelOptions ?? [:], modelID: model))
        #expect(inherited["reasoningEffort"] == .string("xhigh"))
    }

    @Test("On is adaptive; Off and inheritance do not mutate the original Server snapshot")
    func resolvesWithoutGlobalWrites() {
        var server = VMLXServerMTPSettings()
        server.mode = .off
        server.explicitDepth = 3
        server.draftTokenLimit = 2
        server.dflash2BlockSize = 8
        server.dflash2DrafterPath = "/fixture/drafter"
        let adaptive = AgentSpeculationPolicy.resolve(true, inheriting: server)
        #expect(adaptive.mode == .auto)
        #expect(adaptive.explicitDepth == nil)
        #expect(adaptive.draftTokenLimit == nil)
        #expect(adaptive.dflash2BlockSize == nil)
        #expect(adaptive.dflash2DrafterPath == server.dflash2DrafterPath)
        #expect(adaptive.keepDraftCacheSeparate == server.keepDraftCacheSeparate)
        #expect(adaptive.acceptedTokensOnlyEnterBaseCache == server.acceptedTokensOnlyEnterBaseCache)
        #expect(server.mode == .off)
        #expect(server.explicitDepth == 3)
        #expect(AgentSpeculationPolicy.resolve(nil, inheriting: server) == server)
        let off = AgentSpeculationPolicy.resolve(false, inheriting: adaptive)
        #expect(off.mode == .off)
        #expect(AgentSpeculationPolicy.resolve(nil, inheriting: adaptive) == adaptive)
        #expect(AgentSpeculationPolicy.resolve(true, inheriting: off) == adaptive)
        var generation = VMLXServerGenerationDefaults()
        generation.temperature = 0.37
        generation.topP = 0.83
        let snapshot = RuntimeConfig(generation: generation, concurrency: .init(), mtp: server)
        let request = snapshot.resolvingSpeculation(true)
        #expect(request.mtp == adaptive)
        #expect(request.generation == snapshot.generation)
        #expect(request.concurrency == snapshot.concurrency)
        #expect(snapshot.mtp == server)
    }

    @Test("missing heads prepare once; Off and returning to Default reuse a compatible graph")
    func graphTransitions() {
        var off = VMLXServerMTPSettings()
        off.mode = .off
        var adaptive = off
        adaptive.mode = .auto
        var inherited = off
        inherited.mode = .familyDefault
        #expect(AgentSpeculationPolicy.requiresPreparation(previous: off, next: adaptive))
        #expect(AgentSpeculationPolicy.requiresPreparation(previous: inherited, next: adaptive))
        #expect(!AgentSpeculationPolicy.requiresPreparation(
            previous: inherited, next: adaptive, hasLoadedStrategy: true))
        #expect(!AgentSpeculationPolicy.requiresPreparation(previous: adaptive, next: off))
        #expect(!AgentSpeculationPolicy.requiresPreparation(previous: adaptive, next: adaptive))
        #expect(!AgentSpeculationPolicy.requiresPreparation(previous: adaptive, next: inherited))
        var changedDrafter = adaptive
        changedDrafter.dflash2DrafterPath = "/fixture/new-drafter"
        #expect(AgentSpeculationPolicy.requiresPreparation(previous: adaptive, next: changedDrafter))
    }

    @Test("Off disables native and external strategy execution even when their weights remain loaded")
    func offDisablesEverySelectedStrategy() throws {
        var off = VMLXServerMTPSettings()
        off.mode = .off
        let strategies: [DraftStrategy] = [
            .nativeMTP(depth: 3), .dspark(drafterPath: URL(fileURLWithPath: "/fixture/d")),
            .uno(adapterPath: URL(fileURLWithPath: "/fixture/u")), .dflash2(drafterPath: URL(fileURLWithPath: "/fixture/d")),
            .dflash(drafterPath: URL(fileURLWithPath: "/fixture/d"), blockSize: 8),
            .ddtree(drafterPath: URL(fileURLWithPath: "/fixture/d"), branchingBudget: 8, blockSize: 8),
        ]
        for external in [false, true] {
            var admission = NativeMTPAdmission()
            admission.externalDrafterSelected = external
            for strategy in strategies {
                #expect(try admission.requestStrategy(loaded: strategy, mtp: off) == nil)
            }
        }
    }

    @Test("capability follows bundle/drafter evidence, not an architecture name list")
    func capabilityMatrix() throws {
        func choices(native: Bool = false, blocked: Bool = false, dflash: Bool = false,
            selected: Bool = false, dspark: Bool = false, uno: Bool = false) -> AgentGenerationReasoningChoices
        {
            .init(efforts: nil, supportsThinking: false,
                speculation: .init(name: "fixture", bundleHasMTP: native, isTargetMTPFamily: native,
                    isBlocked: blocked, measuredFamilyAutoDepth: nil, bundledDFlash2: dflash,
                    selectedDFlash2: selected, bundledUno: uno, bundledDSpark: dspark, statusLine: "fixture"))
        }
        for available in [choices(native: true), choices(dflash: true), choices(selected: true),
            choices(dspark: true), choices(uno: true), choices(blocked: true, dspark: true)]
        {
            #expect(available.speculation?.speculationAvailable == true)
            try available.validate(settings: .init(speculativeDecoding: true))
        }
        for unavailable in [choices(), choices(native: true, blocked: true)] {
            #expect(throws: (any Error).self) { try unavailable.validate(settings: .init(speculativeDecoding: true)) }
            try unavailable.validate(settings: .init(speculativeDecoding: false))
            try unavailable.validate(settings: .init())
        }
    }

    @Test("cancelling a queued graph upgrade leaves the active generation leased")
    func cancelledWaitDoesNotReleaseAnotherRequest() async throws {
        let name = "agent-preparation-test-\(UUID())"
        await ModelLease.shared.acquire(name)
        let waiting = Task { try await ModelLease.shared.waitForZeroCancellable(name) }
        await Task.yield()
        waiting.cancel()
        do { try await waiting.value; Issue.record("Cancelled wait must throw") } catch is CancellationError {} catch { throw error }
        #expect(await ModelLease.shared.count(for: name) == 1)
        await ModelLease.shared.release(name)
        try await ModelLease.shared.waitForZeroCancellable(name)
        #expect(await ModelLease.shared.count(for: name) == 0)
    }
}

@MainActor
@Suite(.serialized)
struct AgentSpeculationPersistenceTests {
    @Test("reasoning picker replaces only this agent's reasoning and preserves other fields")
    func reasoningPickerScope() async throws {
        try await ChatHistoryTestStorage.run {
            let original = AgentGenerationSettings(topK: 17, enableThinking: false, reasoningEffort: "low",
                templateKwargs: ["thinking": .bool(false), "extraction_schema": .string("kept")],
                speculativeDecoding: true)
            let first = Agent(name: "Reasoning first", generationSettings: original,
                autonomousExec: .init(enabled: false))
            let second = Agent(name: "Reasoning second", generationSettings: original,
                autonomousExec: .init(enabled: false))
            AgentStore.save(first)
            AgentStore.save(second)
            AgentManager.shared.refresh()
            AgentManager.shared.updateReasoning(enableThinking: nil, effort: "medium", for: first.id)
            var saved = try #require(AgentStore.load(id: first.id)?.generationSettings)
            #expect(saved.reasoningEffort == "medium")
            #expect(saved.enableThinking == nil)
            #expect(saved.templateKwargs == ["extraction_schema": .string("kept")])
            #expect(saved.topK == 17 && saved.speculativeDecoding == true)
            #expect(AgentStore.load(id: second.id)?.generationSettings == original)
            AgentManager.shared.updateReasoning(enableThinking: false, effort: nil, for: first.id)
            saved = try #require(AgentStore.load(id: first.id)?.generationSettings)
            #expect(saved.enableThinking == false && saved.reasoningEffort == nil)
            AgentManager.shared.updateReasoning(enableThinking: nil, effort: nil, for: first.id)
            saved = try #require(AgentStore.load(id: first.id)?.generationSettings)
            #expect(!saved.hasReasoningOverride)
            #expect(saved.topK == 17 && saved.speculativeDecoding == true)
            #expect(saved.templateKwargs == ["extraction_schema": .string("kept")])
        }
    }

    @Test("chat picker updates only this agent and reset preserves unrelated overrides")
    func pickerScope() async throws {
        try await ChatHistoryTestStorage.run {
            let first = Agent(name: "Speculation first", generationSettings: .init(topK: 17, speculativeDecoding: false),
                autonomousExec: .init(enabled: false))
            let second = Agent(name: "Speculation second", generationSettings: .init(speculativeDecoding: false),
                autonomousExec: .init(enabled: false))
            AgentStore.save(first)
            AgentStore.save(second)
            AgentManager.shared.refresh()
            AgentManager.shared.updateSpeculativeDecoding(true, for: first.id)
            #expect(AgentStore.load(id: first.id)?.generationSettings?.speculativeDecoding == true)
            #expect(AgentManager.shared.effectiveGenerationSettings(for: first.id)?.speculativeDecoding == true)
            #expect(AgentStore.load(id: second.id)?.generationSettings?.speculativeDecoding == false)
            AgentManager.shared.updateSpeculativeDecoding(nil, for: first.id)
            #expect(AgentStore.load(id: first.id)?.generationSettings == .init(topK: 17))
            AgentManager.shared.updateSpeculativeDecoding(nil, for: second.id)
            #expect(AgentStore.load(id: second.id)?.generationSettings == nil)
            AgentManager.shared.updateSpeculativeDecoding(true, for: Agent.defaultId)
            #expect(AgentManager.shared.effectiveGenerationSettings(for: Agent.defaultId) == nil)
        }
    }
}
