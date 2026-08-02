//
//  ChatWarmupControllerTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ChatConfiguration warmModelsOnLoad")
struct ChatConfigurationWarmModelsOnLoadTests {

    @Test("defaults to on")
    func defaultOn() {
        #expect(ChatConfiguration.default.warmModelsOnLoad == true)
    }

    @Test("Codable round-trip preserves explicit off")
    func codableRoundTripOff() throws {
        var cfg = ChatConfiguration.default
        cfg.warmModelsOnLoad = false
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        #expect(decoded.warmModelsOnLoad == false)
    }

    @Test("missing key decodes to on")
    func missingFieldDefaultsOn() throws {
        let json = #"{"systemPrompt":""}"#
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: Data(json.utf8))
        #expect(decoded.warmModelsOnLoad == true)
    }
}

@Suite("ChatWarmupController prompt-shape rewarm")
@MainActor
struct ChatWarmupControllerPromptShapeTests {

    @Test("DSV4 cold local send requires pre-send warm-up")
    func dsv4ColdSendRequiresWarmup() {
        #expect(
            ChatWarmupController.requiresDSV4PreSendWarmup(
                model: "DeepSeek-V4-Flash-0731-JANG",
                selectedModelIsLocal: true,
                isRemoteAgentTarget: false,
                warmModelsOnLoad: true,
                state: .cold,
                selectedModelResident: false
            )
        )
    }

    @Test("DSV4 warm resident send retains the existing synchronous path")
    func dsv4WarmResidentSendDoesNotRequireWarmup() {
        #expect(
            !ChatWarmupController.requiresDSV4PreSendWarmup(
                model: "DeepSeek-V4-Flash-0731-JANG",
                selectedModelIsLocal: true,
                isRemoteAgentTarget: false,
                warmModelsOnLoad: true,
                state: .warm,
                selectedModelResident: true
            )
        )
    }

    @Test("ordinary local models keep the existing send path")
    func ordinaryModelDoesNotRequireDSV4Warmup() {
        #expect(
            !ChatWarmupController.requiresDSV4PreSendWarmup(
                model: "Qwen3-8B",
                selectedModelIsLocal: true,
                isRemoteAgentTarget: false,
                warmModelsOnLoad: true,
                state: .cold,
                selectedModelResident: false
            )
        )
    }

    @Test("DSV4 pre-send warm-up carries foreground load intent")
    func dsv4PreSendWarmupMayReplaceStaleResidentModel() async throws {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "DeepSeek-V4-Flash-0731-JANG"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "DeepSeek-V4-Flash-0731-JANG",
            messages: [ChatMessage(role: "system", content: "DSV4 warm-up")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "dsv4|required-pre-send"
        )

        let controller = ChatWarmupController()
        controller.projectedLoadFeasibility = { _ in nil }
        // A smaller model may still be resident when the restored DSV4
        // selection becomes available.  A speculative warm-up would refuse;
        // an explicit Send must be allowed to replace it.
        controller.hasResidentModelOther = { _ in true }

        controller.requireDSV4PreSendWarmupIfNeeded(session: session)
        #expect(controller.needsPreSendHandshake)
        controller.cancelScheduledWarmup()
        await controller.awaitRequiredContextWarmup()
        await controller.awaitInFlightWarmup()

        #expect(engine.requestCount == 1)
        let request = try #require(engine.lastRequest)
        #expect(request.backgroundModelLoad == false)
        #expect(controller.state == .warm)
    }

    @Test("DSV4 pre-send warm-up does not re-prefill an already-warm identical payload")
    func dsv4PreSendWarmupDoesNotReprefillIdenticalPayload() async throws {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "DeepSeek-V4-Flash-0731-JANG"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "DeepSeek-V4-Flash-0731-JANG",
            messages: [ChatMessage(role: "system", content: "DSV4 warm-up")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "dsv4|identical-payload"
        )

        let controller = ChatWarmupController()
        controller.projectedLoadFeasibility = { _ in nil }
        controller.hasResidentModelOther = { _ in false }

        // First warm-up establishes the fingerprint for this exact payload.
        controller.handleContextShapeChange(session: session)
        await controller.awaitRequiredContextWarmup()
        await controller.awaitInFlightWarmup()
        #expect(engine.requestCount == 1)
        #expect(controller.state == .warm)

        // `selectedModelResident` lags the runtime by a residency snapshot, so
        // the DSV4 pre-send guard fires routinely on a prompt that is already
        // warm. Routing that through the shape-change path discarded
        // `warmedFingerprint`, which defeated `performWarmup`'s identical-payload
        // check and prefilled the same tokens a second time — the visible
        // "prefill runs twice". The prompt shape has NOT changed here, so the
        // fingerprint must survive and no second request may be issued.
        controller.requireDSV4PreSendWarmupIfNeeded(session: session)
        await controller.awaitRequiredContextWarmup()
        await controller.awaitInFlightWarmup()

        #expect(engine.requestCount == 1)
        #expect(controller.state == .warm)
    }

    @Test("settings prompt change survives send cancellation and warms the newest payload")
    func settingsPromptChangeWarmsNewestPayload() async throws {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "settings revision A")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|settings-a"
        )

        let controller = ChatWarmupController()
        controller.scheduleWarmup(session: session, debounce: .zero)
        for _ in 0 ..< 100 {
            if controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await controller.awaitInFlightWarmup()
        #expect(engine.requestCount == 1)

        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "settings revision B")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|settings-b"
        )
        controller.handleContextShapeChange(session: session)

        // `ChatSession.send` cancels ordinary scheduled warm-up work before
        // its handshake. The settings rewarm is required work and must
        // survive that exact operation.
        controller.cancelScheduledWarmup()
        await controller.awaitRequiredContextWarmup()
        await controller.awaitInFlightWarmup()

        #expect(engine.requestCount == 2)
        let request = try #require(engine.lastRequest)
        #expect(request.messages.first?.content == "settings revision B")
        #expect(controller.state == .warm)
        #expect(!controller.needsPreSendHandshake)
    }

    @Test("chat prompt-shape signal inventory includes app configuration changes")
    func appConfigurationChangeIsPromptShapeSignal() {
        #expect(
            ChatSession.promptShapeNotificationNames.contains(
                .appConfigurationChanged
            )
        )
    }
}

@Suite("ChatSession immediate prompt-shape reconciliation", .serialized)
@MainActor
struct ChatSessionImmediatePromptShapeTests {

    @Test("first preview primes a baseline without creating a required rewarm")
    func firstPreviewIsInitializationNotRevision() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            session.agentId = Agent.defaultId

            #expect(!session.reconcilePromptShapeBeforeSendForTests())
            #expect(!session.warmupController.needsPreSendHandshake)
        }
    }

    @Test("Settings Save then immediate Send sees the newest rendered prompt before debounce")
    func immediateSendReconcilesCurrentPrompt() async throws {
        try await ChatHistoryTestStorage.run {
            var configuration = DefaultAgentConfigurationStore.load()
            configuration.systemPrompt = "settings revision A"
            DefaultAgentConfigurationStore.save(configuration)

            let session = ChatSession()
            session.agentId = Agent.defaultId

            // Seed the same cached preview that made the live chip green.
            _ = session.resyncBudgetEstimateForTests()

            configuration.systemPrompt = "settings revision B"
            DefaultAgentConfigurationStore.save(configuration)

            // Do not flush the main queue or wait for the 80 ms Combine
            // debounce. Production `send()` calls this exact reconciliation
            // before checking whether it needs a warm-up handshake.
            #expect(session.reconcilePromptShapeBeforeSendForTests())

            // The delayed notification will see identical bytes and remain a
            // no-op rather than scheduling duplicate required warm-up work.
            #expect(!session.reconcilePromptShapeBeforeSendForTests())
        }
    }
}

@Suite("ChatWarmupController immediate model switch")
@MainActor
struct ChatWarmupControllerModelSwitchTests {

    @Test("selection change performs the residency switch immediately")
    func selectionChangeSwitchesImmediately() async {
        var evictionCount = 0
        var lastEvictOthers: Bool?
        let session = WarmupTestSession()
        let controller = ChatWarmupController()

        controller.handleModelSelectionChange(
            session: session,
            to: "other-model",
            performSwitch: { evictOthers in
                evictionCount += 1
                lastEvictOthers = evictOthers
            }
        )

        // No debounce: the switch (and its eviction) must run promptly, not
        // after a multi-second grace timer.
        for _ in 0 ..< 100 {
            if evictionCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(evictionCount == 1)
        // Default policy in the test environment is strict single-model, so
        // the switch must ask for eviction of the previous model.
        #expect(lastEvictOthers == true)
        #expect(controller.state != .warm)
    }

    @Test("rapid consecutive switches all settle without losing an eviction")
    func rapidSwitchesSerialize() async {
        var evictionCount = 0
        let session = WarmupTestSession()
        let controller = ChatWarmupController()

        controller.handleModelSelectionChange(
            session: session,
            to: "other-model",
            performSwitch: { _ in evictionCount += 1 }
        )
        controller.handleModelSelectionChange(
            session: session,
            to: "test-model",
            performSwitch: { _ in evictionCount += 1 }
        )

        for _ in 0 ..< 100 {
            if evictionCount == 2 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(evictionCount == 2)
    }

    @Test("selection change cancels an in-flight warm-up generation")
    func selectionChangeCancelsInFlightWarmup() async {
        let engine = HangingWarmupEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|hint|"
        )

        let controller = ChatWarmupController()
        controller.scheduleWarmup(session: session, debounce: .zero)

        // Wait until the warm-up generation is actually streaming.
        for _ in 0 ..< 100 {
            if engine.started { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.started)

        // Keep the post-switch re-warm from starting another hanging stream:
        // shouldAttemptWarmup bails while the session reports streaming.
        session.isStreaming = true

        var evictionCount = 0
        controller.handleModelSelectionChange(
            session: session,
            to: "other-model",
            performSwitch: { _ in evictionCount += 1 }
        )

        // The stale warm-up must be cancelled (stream terminated) and the
        // eviction must not wait for the warm-up to finish on its own.
        for _ in 0 ..< 100 {
            if engine.terminated && evictionCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.terminated)
        #expect(evictionCount == 1)
        #expect(controller.state == .warming)
    }
}

@Suite("ChatWarmupController RAM gate")
@MainActor
struct ChatWarmupControllerRAMGateTests {

    private static func feasibility(
        projected: Int64,
        soft: Int64,
        hard: Int64,
        physical: Int64,
        requiredAvailable: Int64
    ) -> ModelRuntime.RAMFeasibility {
        ModelRuntime.RAMFeasibility(
            modelName: "test-model",
            verdict: projected > soft ? .tight : .ok,
            incomingWeightsBytes: projected,
            incomingLoadFootprintBytes: projected,
            residentWeightsBytes: 0,
            kvHeadroomBytes: 0,
            projectedBytes: projected,
            physicalMemoryBytes: physical,
            availableMemoryBytes: physical,
            requiredAvailableBytes: requiredAvailable,
            softLimitBytes: soft,
            hardLimitBytes: hard,
            automaticMemoryLimitsDisabled: false,
            // Budget unknown, so it never influences these warmup assertions.
            gpuBudgetBytes: 0,
            timestamp: Date()
        )
    }

    /// Sentry APPLE-MACOS-3T: a window-open warm-up of a 31B model on a
    /// 24GB machine died in a fatal Metal OOM. Proactive warm-up must skip
    /// entirely when the projection is block-severity.
    @Test("warm-up is skipped when the projected load exceeds the hard RAM ceiling")
    func warmupSkippedWhenProjectionBlocks() async {
        let gib: Int64 = 1_073_741_824
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|hint|"
        )

        let controller = ChatWarmupController()
        controller.projectedLoadFeasibility = { _ in
            Self.feasibility(
                projected: 23 * gib,
                soft: Int64(16.8 * Double(gib)),
                hard: Int64(21.6 * Double(gib)),
                physical: 24 * gib,
                requiredAvailable: 23 * gib
            )
        }
        controller.scheduleWarmup(session: session, debounce: .zero)

        try? await Task.sleep(for: .milliseconds(150))
        await controller.awaitInFlightWarmup()

        // No generation was started, and the dot must not claim warming.
        #expect(engine.lastRequest == nil)
        #expect(controller.state == .cold)
    }

    @Test("warn-severity projection still warms up")
    func warnSeverityStillWarms() async {
        let gib: Int64 = 1_073_741_824
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|hint|"
        )

        let controller = ChatWarmupController()
        controller.projectedLoadFeasibility = { _ in
            Self.feasibility(
                projected: 18 * gib,
                soft: Int64(16.8 * Double(gib)),
                hard: Int64(21.6 * Double(gib)),
                physical: 24 * gib,
                requiredAvailable: 18 * gib
            )
        }
        controller.scheduleWarmup(session: session, debounce: .zero)

        for _ in 0 ..< 100 {
            if controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()

        #expect(engine.lastRequest != nil)
        #expect(controller.state == .warm)
    }
}

@Suite("ChatWarmupController request fidelity")
@MainActor
struct ChatWarmupControllerRequestTests {

    /// Warm-up must mirror every cache-identity input used by the real send.
    /// Model options alter rendered tokens/scope salt, while the stable prefix
    /// tells vMLX which reusable boundary to persist.
    @Test("warm-up request carries model options and stable prefix")
    func warmupRequestCarriesCacheIdentityInputs() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: ["disableThinking": .bool(true)],
            cacheStableSystemPrefix: "stable system prefix",
            fingerprint: "test-model|hint|opts|"
        )

        let controller = ChatWarmupController()
        controller.scheduleWarmup(session: session, debounce: .zero)

        for _ in 0 ..< 100 {
            if controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()

        #expect(engine.lastRequest?.modelOptions?["disableThinking"] == .bool(true))
        #expect(engine.lastRequest?.cacheStableSystemPrefix == "stable system prefix")
        #expect(engine.lastRequest?.suppressProgressUI == true)
        #expect(engine.lastRequest?.warmupPrefill == true)
        #expect(engine.lastRequest?.backgroundModelLoad == true)
    }
}

@Suite("ChatWarmupController completed-run policy")
@MainActor
struct ChatWarmupControllerCompletedRunTests {

    @Test("stopped run does not launch a hidden transcript warm-up")
    func stoppedRunDoesNotWarm() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [
                ChatMessage(role: "system", content: "sys"),
                ChatMessage(
                    role: "user",
                    content: String(repeating: "cancelled prompt ", count: 2_000)
                ),
            ],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|cancelled-run"
        )

        let controller = ChatWarmupController()
        controller.handleRunCompleted(
            session: session,
            wasCancelled: true,
            hadError: false
        )

        try? await Task.sleep(for: .milliseconds(650))
        await controller.awaitInFlightWarmup()

        #expect(engine.requestCount == 0)
        #expect(controller.state == .cold)
    }

    @Test("errored run does not launch a hidden transcript warm-up")
    func erroredRunDoesNotWarm() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [
                ChatMessage(role: "system", content: "sys"),
                ChatMessage(role: "user", content: "needs a tool"),
                ChatMessage(
                    role: "assistant",
                    content: "",
                    tool_calls: [
                        ToolCall(
                            id: "call_failed",
                            type: "function",
                            function: ToolCallFunction(
                                name: "unstable_tool",
                                arguments: #"{"bad":true}"#
                            )
                        )
                    ],
                    tool_call_id: nil
                ),
                ChatMessage(
                    role: "tool",
                    content: ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "bad input",
                        tool: "unstable_tool"
                    ),
                    tool_calls: nil,
                    tool_call_id: "call_failed"
                ),
            ],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|errored-tool-run"
        )

        let controller = ChatWarmupController()
        controller.handleRunCompleted(
            session: session,
            wasCancelled: false,
            hadError: true
        )

        try? await Task.sleep(for: .milliseconds(650))
        await controller.awaitInFlightWarmup()

        #expect(engine.requestCount == 0)
        #expect(controller.state == .cold)
    }

    @Test("successful tool run does not launch a hidden transcript warm-up")
    func successfulToolRunDoesNotWarmCompletedTranscript() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [
                ChatMessage(role: "system", content: "sys"),
                ChatMessage(role: "user", content: "read a file"),
                ChatMessage(
                    role: "assistant",
                    content: "",
                    tool_calls: [
                        ToolCall(
                            id: "call_ok",
                            type: "function",
                            function: ToolCallFunction(
                                name: "read_file",
                                arguments: #"{"path":"README.md"}"#
                            )
                        )
                    ],
                    tool_call_id: nil
                ),
                ChatMessage(
                    role: "tool",
                    content: ToolEnvelope.success(tool: "read_file", text: "ok"),
                    tool_calls: nil,
                    tool_call_id: "call_ok"
                ),
                ChatMessage(role: "assistant", content: "Done."),
            ],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|successful-tool-run"
        )

        let controller = ChatWarmupController()
        controller.handleRunCompleted(
            session: session,
            wasCancelled: false,
            hadError: false,
            hadToolActivity: true
        )

        try? await Task.sleep(for: .milliseconds(650))
        await controller.awaitInFlightWarmup()

        #expect(engine.requestCount == 0)
        #expect(controller.state == .cold)
    }

    @Test("successful run still refreshes the completed transcript checkpoint")
    func successfulRunStillWarms() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|successful-run"
        )

        let controller = ChatWarmupController()
        controller.handleRunCompleted(
            session: session,
            wasCancelled: false,
            hadError: false
        )

        for _ in 0 ..< 100 {
            if controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()

        #expect(engine.requestCount == 1)
        #expect(controller.state == .warm)
    }
}

@Suite("ChatWarmupController runtime residency")
@MainActor
struct ChatWarmupControllerRuntimeResidencyTests {

    @Test("reset cancels a warm-up suspended in resident-model preflight")
    func resetCancelsSuspendedResidentPreflight() async throws {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|resident-preflight"
        )

        let gate = FirstResidentPreflightGate()
        let controller = ChatWarmupController()
        controller.projectedLoadFeasibility = { _ in nil }
        controller.hasResidentModelOther = { _ in
            await gate.check()
        }

        controller.scheduleWarmup(session: session, debounce: .zero)
        for _ in 0 ..< 100 {
            if await gate.firstCallStarted { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await gate.firstCallStarted)
        let staleScheduledTask = try #require(controller.scheduledWarmupTaskForTests)

        controller.reset()
        controller.scheduleWarmup(session: session, debounce: .zero)

        for _ in 0 ..< 100 {
            if engine.requestCount == 1, controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.requestCount == 1)
        #expect(controller.state == .warm)

        // The cancelled first preflight ignores cooperative cancellation.
        // Releasing it must not let the outgoing chat create a second,
        // untracked warm-up after reset.
        await gate.releaseFirst()
        await staleScheduledTask.value

        #expect(engine.requestCount == 1)
        #expect(controller.state == .warm)
    }

    @Test("external eviction clears the warm claim and cached fingerprint")
    func externalEvictionClearsWarmClaimAndFingerprint() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "org/test-model"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|hint|"
        )

        let controller = ChatWarmupController()
        controller.scheduleWarmup(session: session, debounce: .zero)

        for _ in 0 ..< 100 {
            if controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()
        #expect(controller.state == .warm)
        #expect(engine.requestCount == 1)

        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(
                names: ["different-model"],
                revision: 1,
                reason: .modelSwitch
            ),
            isSessionActive: false
        )
        #expect(controller.state == .cold)

        controller.scheduleWarmup(session: session, debounce: .zero)
        for _ in 0 ..< 100 {
            if engine.requestCount == 2, controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()

        // A second request proves eviction cleared the cached fingerprint;
        // otherwise scheduleWarmup would immediately restore the green state
        // without touching the runtime.
        #expect(engine.requestCount == 2)
        #expect(controller.state == .warm)
    }

    @Test("focus-style rearm after external eviction remains speculative")
    func focusRearmAfterExternalEvictionRemainsSpeculative() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "org/test-model"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|focus-rearm"
        )

        let controller = ChatWarmupController()
        controller.projectedLoadFeasibility = { _ in nil }
        controller.hasResidentModelOther = { _ in false }
        controller.chatActivationResidencySnapshot = { _ in
            activationResidencySnapshot(
                names: [],
                revision: 1,
                reason: .modelSwitch
            )
        }
        controller.runtimeResidencySnapshot = {
            residencySnapshot(names: [], revision: 1, reason: .modelSwitch)
        }
        controller.scheduleWarmup(session: session, debounce: .zero)

        for _ in 0 ..< 100 {
            if controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()
        #expect(engine.requestCount == 1)
        #expect(engine.lastRequest?.backgroundModelLoad == true)

        // `ChatWindowManager.windowDidBecomeKey` reaches this same scheduling
        // path through `ChatSession.notifySessionBecameActive()`. Deliberately
        // leave the stale warm claim intact: the activation-time runtime check
        // must clear it without relying on notification delivery ordering.
        controller.handleSessionBecameActive(session: session, debounce: .zero)
        await controller.awaitSessionActivation()
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()

        #expect(engine.requestCount == 2)
        #expect(engine.lastRequest?.backgroundModelLoad == true)
        #expect(controller.state == .warm)
    }

    @Test("eviction during the focus debounce cannot reuse a stale warm fingerprint")
    func focusEvictionDuringDebounceRearmsWarmup() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "org/test-model"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|focus-debounce-eviction"
        )

        let controller = ChatWarmupController()
        controller.projectedLoadFeasibility = { _ in nil }
        controller.hasResidentModelOther = { _ in false }
        controller.scheduleWarmup(session: session, debounce: .zero)
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()
        #expect(engine.requestCount == 1)
        #expect(controller.state == .warm)

        // The activation snapshot still sees the selected model. Hold the
        // following debounce, then make the execution-time snapshot report the
        // idle eviction. Without the second reconciliation, fingerprint
        // equality suppresses the required replacement request.
        let snapshots = ResidentSnapshotSequence([
            residencySnapshot(names: ["test-model"], revision: 1),
            residencySnapshot(
                names: [],
                revision: 2,
                reason: .idlePolicy,
                idleDecisionID: 41
            ),
        ])
        let debounce = WarmupDebounceGate()
        controller.chatActivationResidencySnapshot = { _ in
            ModelRuntimeChatActivationResidencySnapshot(
                residency: await snapshots.next(),
                recoverableIdleDecisionID: nil
            )
        }
        controller.runtimeResidencySnapshot = { await snapshots.next() }
        controller.scheduleDebounceSleep = { _ in await debounce.wait() }

        controller.handleSessionBecameActive(session: session, debounce: .seconds(30))
        await controller.awaitSessionActivation()
        await debounce.waitUntilBlocked()
        #expect(await snapshots.callCount() == 1)

        await debounce.release()
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()

        #expect(await snapshots.callCount() == 2)
        #expect(engine.requestCount == 2)
        #expect(controller.state == .warm)
    }

    @Test("matching idle decision after focus coalescing performs exactly one replacement warmup")
    func focusRemovalAfterCoalescingRearmsExactlyOnce() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "org/test-model"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|post-coalesce-removal"
        )

        let controller = ChatWarmupController()
        controller.projectedLoadFeasibility = { _ in nil }
        controller.hasResidentModelOther = { _ in false }
        controller.scheduleWarmup(session: session, debounce: .zero)
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()
        #expect(engine.requestCount == 1)
        #expect(controller.state == .warm)

        // Both focus snapshots report resident, so the activation request
        // legitimately coalesces on the existing fingerprint. Only after that
        // return does the runtime publish the completed removal. The active
        // chat must receive one replacement warm-up instead of staying cold.
        let snapshots = ResidentSnapshotSequence([
            residencySnapshot(names: ["test-model"], revision: 10),
            residencySnapshot(names: ["test-model"], revision: 10),
            residencySnapshot(
                names: [],
                revision: 11,
                reason: .idlePolicy,
                idleDecisionID: 71
            ),
        ])
        let debounce = WarmupDebounceGate()
        controller.chatActivationResidencySnapshot = { _ in
            ModelRuntimeChatActivationResidencySnapshot(
                residency: await snapshots.next(),
                recoverableIdleDecisionID: 71
            )
        }
        controller.runtimeResidencySnapshot = { await snapshots.next() }
        controller.scheduleDebounceSleep = { _ in await debounce.wait() }

        controller.handleSessionBecameActive(session: session, debounce: .seconds(30))
        await controller.awaitSessionActivation()
        await debounce.waitUntilBlocked()
        await debounce.release()
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()

        #expect(await snapshots.callCount() == 2)
        #expect(engine.requestCount == 1)
        #expect(controller.state == .warm)

        controller.scheduleDebounceSleep = { _ in }
        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(
                names: [],
                revision: 11,
                reason: .idlePolicy,
                idleDecisionID: 71
            ),
            isSessionActive: true
        )
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()

        #expect(await snapshots.callCount() == 3)
        #expect(engine.requestCount == 2)
        #expect(controller.state == .warm)

        // Duplicate and stale delivery from the same runtime timeline cannot
        // invalidate the replacement warm claim or create another warm-up.
        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(
                names: [],
                revision: 11,
                reason: .idlePolicy,
                idleDecisionID: 71
            ),
            isSessionActive: true
        )
        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(
                names: [],
                revision: 9,
                reason: .idlePolicy,
                idleDecisionID: 71
            ),
            isSessionActive: true
        )
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()

        #expect(engine.requestCount == 2)
        #expect(controller.state == .warm)
    }

    @Test("matching idle removal while focus is warming preserves the activation warmup")
    func focusRemovalWhileWarmingPreservesScheduledWarmup() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "org/test-model"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|focus-warming-removal"
        )

        let controller = ChatWarmupController()
        controller.projectedLoadFeasibility = { _ in nil }
        controller.hasResidentModelOther = { _ in false }
        let debounce = WarmupDebounceGate()
        controller.chatActivationResidencySnapshot = { _ in
            activationResidencySnapshot(
                names: ["test-model"],
                revision: 10,
                recoverableIdleDecisionID: 71
            )
        }
        controller.runtimeResidencySnapshot = {
            residencySnapshot(
                names: [],
                revision: 11,
                reason: .idlePolicy,
                idleDecisionID: 71
            )
        }
        controller.scheduleDebounceSleep = { _ in await debounce.wait() }

        controller.handleSessionBecameActive(session: session, debounce: .seconds(30))
        await controller.awaitSessionActivation()
        await debounce.waitUntilBlocked()
        #expect(controller.state == .warming)

        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(
                names: [],
                revision: 11,
                reason: .idlePolicy,
                idleDecisionID: 71
            ),
            isSessionActive: true
        )
        #expect(controller.state == .warming)

        await debounce.release()
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()

        #expect(engine.requestCount == 1)
        #expect(controller.state == .warm)
    }

    @Test("mismatched idle-decision identity does not rewarm")
    func mismatchedIdleDecisionDoesNotRewarm() async {
        await expectArmedRecoveryToStayCold(
            reason: .idlePolicy,
            idleDecisionID: 72,
            isSessionActive: true
        )
    }

    @Test("non-idle removal reasons do not rewarm")
    func nonIdleRemovalReasonsDoNotRewarm() async {
        let reasons: [ModelRuntimeResidencyChangeReason] = [
            .initial,
            .load,
            .memoryPressure,
            .handoff,
            .modelSwitch,
            .explicit,
            .settingsClear,
            .shutdown,
        ]
        for reason in reasons {
            await expectArmedRecoveryToStayCold(
                reason: reason,
                idleDecisionID: 71,
                isSessionActive: true
            )
        }
    }

    @Test("matching idle decision does not rewarm an inactive session")
    func inactiveSessionDoesNotRewarm() async {
        await expectArmedRecoveryToStayCold(
            reason: .idlePolicy,
            idleDecisionID: 71,
            isSessionActive: false
        )
    }

    @Test("duplicate and stale residency revisions are ignored")
    func duplicateAndStaleRevisionsAreIgnored() async {
        let fixture = await makeArmedRecoveryFixture()

        for revision: UInt64 in [10, 9] {
            fixture.controller.handleRuntimeResidencyChanged(
                session: fixture.session,
                snapshot: residencySnapshot(
                    names: [],
                    revision: revision,
                    reason: .idlePolicy,
                    idleDecisionID: 71
                ),
                isSessionActive: true
            )
        }
        await fixture.controller.scheduledWarmupTaskForTests?.value
        await fixture.controller.awaitInFlightWarmup()

        #expect(fixture.engine.requestCount == 1)
        #expect(fixture.controller.state == .warm)
    }

    @Test("focus-style rearm does not displace another resident model")
    func focusRearmDoesNotDisplaceAnotherResidentModel() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "org/test-model"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|focus-rearm"
        )

        let controller = ChatWarmupController()
        controller.projectedLoadFeasibility = { _ in nil }
        controller.hasResidentModelOther = { _ in false }
        controller.scheduleWarmup(session: session, debounce: .zero)
        for _ in 0 ..< 100 {
            if controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()
        #expect(engine.requestCount == 1)

        controller.chatActivationResidencySnapshot = { _ in
            activationResidencySnapshot(
                names: ["different-model"],
                revision: 1,
                reason: .load
            )
        }
        controller.runtimeResidencySnapshot = {
            residencySnapshot(names: ["different-model"], revision: 1)
        }
        controller.hasResidentModelOther = { _ in true }
        controller.handleSessionBecameActive(session: session, debounce: .zero)
        await controller.awaitSessionActivation()
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()

        #expect(engine.requestCount == 1)
        #expect(controller.state == .cold)
    }

    @Test("focus-style activation preserves a valid resident warm claim")
    func focusActivationPreservesResidentWarmClaim() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "org/test-model"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|focus-resident"
        )

        let controller = ChatWarmupController()
        controller.chatActivationResidencySnapshot = { _ in
            activationResidencySnapshot(names: ["test-model"], revision: 1)
        }
        controller.runtimeResidencySnapshot = {
            residencySnapshot(names: ["test-model"], revision: 1)
        }
        controller.scheduleWarmup(session: session, debounce: .zero)
        for _ in 0 ..< 100 {
            if controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()
        #expect(engine.requestCount == 1)

        controller.handleSessionBecameActive(session: session, debounce: .zero)
        await controller.awaitSessionActivation()
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()

        #expect(controller.state == .warm)
        #expect(engine.requestCount == 1)
    }

    @Test("newest activation snapshot wins when an older runtime reply resumes last")
    func newestActivationSnapshotWins() async throws {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "org/test-model"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|activation-order"
        )

        let controller = ChatWarmupController()
        controller.scheduleWarmup(session: session, debounce: .zero)
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()
        #expect(controller.state == .warm)
        #expect(engine.requestCount == 1)

        let gate = ResidentSnapshotGate()
        controller.chatActivationResidencySnapshot = { _ in await gate.snapshot() }
        controller.runtimeResidencySnapshot = {
            residencySnapshot(names: ["test-model"], revision: 2)
        }

        controller.handleSessionBecameActive(session: session, debounce: .zero)
        await gate.waitForCallCount(1)
        let staleActivation = try #require(controller.sessionActivationTaskForTests)

        controller.handleSessionBecameActive(session: session, debounce: .zero)
        await gate.waitForCallCount(2)
        await gate.resume(
            call: 2,
            with: activationResidencySnapshot(names: ["test-model"], revision: 2)
        )
        await controller.awaitSessionActivation()
        await controller.scheduledWarmupTaskForTests?.value

        // The cancelled first runtime lookup deliberately ignores cooperative
        // cancellation. Its late empty snapshot must not clear the valid warm
        // claim or create another hidden warm-up.
        await gate.resume(
            call: 1,
            with: activationResidencySnapshot(
                names: [],
                revision: 1,
                reason: .modelSwitch
            )
        )
        await staleActivation.value

        #expect(controller.state == .warm)
        #expect(engine.requestCount == 1)
    }

    @Test("reset invalidates a suspended activation snapshot")
    func resetInvalidatesSuspendedActivationSnapshot() async throws {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "org/test-model"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|activation-reset"
        )

        let controller = ChatWarmupController()
        controller.scheduleWarmup(session: session, debounce: .zero)
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()
        #expect(controller.state == .warm)

        let gate = ResidentSnapshotGate()
        controller.chatActivationResidencySnapshot = { _ in await gate.snapshot() }
        controller.handleSessionBecameActive(session: session, debounce: .zero)
        await gate.waitForCallCount(1)
        let staleActivation = try #require(controller.sessionActivationTaskForTests)

        controller.reset()
        await gate.resume(
            call: 1,
            with: activationResidencySnapshot(
                names: [],
                revision: 1,
                reason: .modelSwitch
            )
        )
        await staleActivation.value

        #expect(controller.state == .cold)
        #expect(engine.requestCount == 1)
        #expect(controller.sessionActivationTaskForTests == nil)
    }

    @Test("user Stop invalidates a suspended activation snapshot")
    func userStopInvalidatesSuspendedActivationSnapshot() async throws {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "org/test-model"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|activation-stop"
        )

        let controller = ChatWarmupController()
        controller.scheduleWarmup(session: session, debounce: .zero)
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()

        let gate = ResidentSnapshotGate()
        controller.chatActivationResidencySnapshot = { _ in await gate.snapshot() }
        controller.handleSessionBecameActive(session: session, debounce: .zero)
        await gate.waitForCallCount(1)
        let staleActivation = try #require(controller.sessionActivationTaskForTests)

        controller.cancelPendingWorkForUserStop()
        await gate.resume(
            call: 1,
            with: activationResidencySnapshot(
                names: [],
                revision: 1,
                reason: .modelSwitch
            )
        )
        await staleActivation.value

        #expect(controller.state == .cold)
        #expect(engine.requestCount == 1)
        #expect(controller.sessionActivationTaskForTests == nil)
    }

    @Test("canonical and tail model identifiers preserve the warm claim")
    func equivalentResidentIdentifierPreservesWarmClaim() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "org/test-model"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|hint|"
        )

        let controller = ChatWarmupController()
        controller.scheduleWarmup(session: session, debounce: .zero)
        for _ in 0 ..< 100 {
            if controller.state == .warm { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await controller.awaitInFlightWarmup()
        #expect(controller.state == .warm)

        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(names: ["test-model"], revision: 1),
            isSessionActive: false
        )

        #expect(controller.state == .warm)
        #expect(engine.requestCount == 1)
    }

    private func expectArmedRecoveryToStayCold(
        reason: ModelRuntimeResidencyChangeReason,
        idleDecisionID: UInt64?,
        isSessionActive: Bool
    ) async {
        let fixture = await makeArmedRecoveryFixture()
        fixture.controller.handleRuntimeResidencyChanged(
            session: fixture.session,
            snapshot: residencySnapshot(
                names: [],
                revision: 11,
                reason: reason,
                idleDecisionID: idleDecisionID
            ),
            isSessionActive: isSessionActive
        )
        await fixture.controller.scheduledWarmupTaskForTests?.value
        await fixture.controller.awaitInFlightWarmup()

        #expect(fixture.engine.requestCount == 1, "unexpected rewarm for \(reason.rawValue)")
        #expect(fixture.controller.state == .cold, "unexpected state for \(reason.rawValue)")
    }

    private func makeArmedRecoveryFixture() async -> (
        controller: ChatWarmupController,
        session: WarmupTestSession,
        engine: WarmupRecordingEngine
    ) {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "org/test-model"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|armed-idle-recovery"
        )

        let controller = ChatWarmupController()
        controller.projectedLoadFeasibility = { _ in nil }
        controller.hasResidentModelOther = { _ in false }
        controller.chatActivationResidencySnapshot = { _ in
            activationResidencySnapshot(
                names: ["test-model"],
                revision: 10,
                recoverableIdleDecisionID: 71
            )
        }
        controller.runtimeResidencySnapshot = {
            residencySnapshot(names: ["test-model"], revision: 10)
        }

        controller.scheduleWarmup(session: session, debounce: .zero)
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()
        controller.handleSessionBecameActive(session: session, debounce: .zero)
        await controller.awaitSessionActivation()
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()

        #expect(engine.requestCount == 1)
        #expect(controller.state == .warm)
        return (controller, session, engine)
    }
}

@Suite("ChatWarmupController shutdown")
@MainActor
struct ChatWarmupControllerShutdownTests {

    /// Window close calls `cleanup()` → `shutdown()` before `session.stop()`.
    /// `stop()`'s run-completed path calls `scheduleWarmup` again; after
    /// shutdown that must be inert so teardown can't start model work.
    @Test("scheduleWarmup after shutdown does not run a warm-up")
    func scheduleAfterShutdownIsInert() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|hint|"
        )

        let controller = ChatWarmupController()
        controller.shutdown()
        controller.scheduleWarmup(session: session, debounce: .zero)

        try? await Task.sleep(for: .milliseconds(150))
        await controller.awaitInFlightWarmup()

        #expect(engine.lastRequest == nil)
        #expect(controller.state == .cold)
    }

    @Test("shutdown cancels a scheduled-but-not-started warm-up")
    func shutdownCancelsScheduledWarmup() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|hint|"
        )

        let controller = ChatWarmupController()
        controller.scheduleWarmup(session: session, debounce: .milliseconds(80))
        controller.shutdown()

        try? await Task.sleep(for: .milliseconds(200))
        await controller.awaitInFlightWarmup()

        #expect(engine.lastRequest == nil)
        #expect(controller.state == .cold)
    }

    @Test("explicit model unload cancels scheduled warm-up without shutting down the chat")
    func explicitUnloadCancelsScheduledWarmup() async {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "test-model|explicit-unload"
        )

        let controller = ChatWarmupController()
        controller.scheduleWarmup(session: session, debounce: .milliseconds(80))
        controller.cancelPendingWorkForExplicitModelUnload()

        try? await Task.sleep(for: .milliseconds(200))
        await controller.awaitInFlightWarmup()

        #expect(engine.lastRequest == nil)
        #expect(controller.state == .cold)

        // Explicit unload leaves the chat usable: a later user interaction may
        // intentionally warm/load the selected model again.
        controller.scheduleWarmup(session: session, debounce: .zero)
        await controller.scheduledWarmupTaskForTests?.value
        await controller.awaitInFlightWarmup()
        #expect(engine.requestCount == 1)
        #expect(controller.state == .warm)
    }
}

@Suite("ChatWarmupController residency-backed dot state")
@MainActor
struct ChatWarmupControllerResidencyDotTests {

    @Test("residency snapshots drive selectedModelResident for the selected model")
    func residencySnapshotsDriveSelectedModelResident() {
        let session = WarmupTestSession()
        let controller = ChatWarmupController()
        #expect(!controller.selectedModelResident)

        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(names: ["test-model"], revision: 1),
            isSessionActive: false
        )
        #expect(controller.selectedModelResident)

        // An idle unload removes the model; the dot claim must drop with it —
        // this is the exact "green while nothing is loaded" report.
        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(names: [], revision: 2, reason: .idlePolicy),
            isSessionActive: false
        )
        #expect(!controller.selectedModelResident)
    }

    @Test("a stale lower-revision snapshot cannot resurrect residency")
    func staleSnapshotCannotResurrectResidency() {
        let session = WarmupTestSession()
        let controller = ChatWarmupController()

        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(names: [], revision: 5, reason: .idlePolicy),
            isSessionActive: false
        )
        // Delayed NotificationCenter delivery of an older load event.
        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(names: ["test-model"], revision: 3),
            isSessionActive: false
        )
        #expect(!controller.selectedModelResident)
    }

    @Test("org-prefixed resident names match a bare selected model id")
    func fuzzyTailMatchingCountsAsResident() {
        let session = WarmupTestSession()
        let controller = ChatWarmupController()

        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(names: ["OsaurusAI/test-model"], revision: 1),
            isSessionActive: false
        )
        #expect(controller.selectedModelResident)
    }

    @Test("selection change re-evaluates residency immediately from last known names")
    func selectionChangeReevaluatesResidencyImmediately() async {
        let session = WarmupTestSession()
        let controller = ChatWarmupController()

        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(names: ["other-model"], revision: 1),
            isSessionActive: false
        )
        #expect(!controller.selectedModelResident)

        session.selectedModel = "other-model"
        controller.handleModelSelectionChange(
            session: session,
            to: "other-model",
            performSwitch: { _ in }
        )
        for _ in 0 ..< 100 {
            if controller.selectedModelResident { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.selectedModelResident)
    }

    @Test("seedRuntimeResidency populates the dot state before any notification")
    func seedPopulatesResidency() async {
        let session = WarmupTestSession()
        let controller = ChatWarmupController()
        controller.runtimeResidencySnapshot = {
            residencySnapshot(names: ["test-model"], revision: 1)
        }

        controller.seedRuntimeResidency(session: session)
        for _ in 0 ..< 100 {
            if controller.selectedModelResident { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.selectedModelResident)
    }

    @Test("image model selection does not leave the dot stuck on warming")
    func imageModelSelectionDoesNotStickWarming() async {
        let session = WarmupTestSession()
        session.imageGenerationModelIDs = ["image-model"]
        let controller = ChatWarmupController()

        session.selectedModel = "image-model"
        controller.handleModelSelectionChange(
            session: session,
            to: "image-model",
            performSwitch: { _ in }
        )
        // The switch sets a provisional `.warming`; the follow-up warm-up
        // must clear it (image models never take a KV warm-up) instead of
        // leaving a permanent yellow dot.
        await controller.awaitActiveModelSwitch()
        for _ in 0 ..< 100 {
            if controller.state == .cold { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.state == .cold)
    }
}

/// A dispatched background run (schedule, plugin, HTTP dispatch, watcher)
/// holds the runtime slot while an open chat's speculative warm-ups are
/// refused. When the finished run's residency release (or its natural idle
/// expiry) empties the runtime, the active session must warm again — no
/// other trigger fires until the user refocuses the window.
@Suite("ChatWarmupController freed-slot rewarm")
@MainActor
struct ChatWarmupControllerFreedSlotRewarmTests {

    @Test("idle removal of another surface's model rewarms the active session")
    func freedSlotRewarmsActiveSession() async {
        let fixture = makeFixture()

        // Another surface's model occupies the slot; no rewarm on load.
        fixture.controller.handleRuntimeResidencyChanged(
            session: fixture.session,
            snapshot: residencySnapshot(names: ["background-task-model"], revision: 1),
            isSessionActive: true
        )
        #expect(fixture.controller.state == .cold)
        #expect(fixture.engine.requestCount == 0)

        fixture.controller.handleRuntimeResidencyChanged(
            session: fixture.session,
            snapshot: residencySnapshot(
                names: [],
                revision: 2,
                reason: .idlePolicy,
                idleDecisionID: 51
            ),
            isSessionActive: true
        )
        await fixture.controller.scheduledWarmupTaskForTests?.value
        await fixture.controller.awaitInFlightWarmup()

        #expect(fixture.engine.requestCount == 1)
        // Still speculative: the freed-slot warm-up may only fill the empty
        // slot, never displace whatever loads in between.
        #expect(fixture.engine.lastRequest?.backgroundModelLoad == true)
        #expect(fixture.controller.state == .warm)
    }

    @Test("freed slot does not rewarm an inactive session")
    func freedSlotDoesNotRewarmInactiveSession() async {
        await expectNoRewarm(
            removal: residencySnapshot(
                names: [],
                revision: 2,
                reason: .idlePolicy,
                idleDecisionID: 51
            ),
            isSessionActive: false
        )
    }

    @Test("a removal that leaves another model resident does not rewarm")
    func removalLeavingAnotherResidentDoesNotRewarm() async {
        await expectNoRewarm(
            removal: residencySnapshot(
                names: ["third-model"],
                revision: 2,
                reason: .idlePolicy,
                idleDecisionID: 51
            ),
            isSessionActive: true
        )
    }

    @Test("non-idle removal reasons do not trigger the freed-slot rewarm")
    func nonIdleReasonsDoNotRewarmFreedSlot() async {
        for reason: ModelRuntimeResidencyChangeReason in [
            .explicit, .settingsClear, .shutdown, .memoryPressure, .modelSwitch,
        ] {
            await expectNoRewarm(
                removal: residencySnapshot(names: [], revision: 2, reason: reason),
                isSessionActive: true
            )
        }
    }

    @Test("removal of the chat's own resident model stays on the recovery rules")
    func ownModelRemovalStaysOnRecoveryRules() async {
        let fixture = makeFixture()

        fixture.controller.handleRuntimeResidencyChanged(
            session: fixture.session,
            snapshot: residencySnapshot(names: ["org/test-model"], revision: 1),
            isSessionActive: true
        )

        // The selected model itself is removed. Without an armed activation
        // recovery this must NOT warm — the freed-slot path may never relax
        // the anti-ping-pong rules for the chat's own idle unload.
        fixture.controller.handleRuntimeResidencyChanged(
            session: fixture.session,
            snapshot: residencySnapshot(
                names: [],
                revision: 2,
                reason: .idlePolicy,
                idleDecisionID: 51
            ),
            isSessionActive: true
        )
        await fixture.controller.scheduledWarmupTaskForTests?.value
        await fixture.controller.awaitInFlightWarmup()

        #expect(fixture.engine.requestCount == 0)
        #expect(fixture.controller.state == .cold)
    }

    private func expectNoRewarm(
        removal: ModelRuntimeResidencySnapshot,
        isSessionActive: Bool
    ) async {
        let fixture = makeFixture()
        fixture.controller.handleRuntimeResidencyChanged(
            session: fixture.session,
            snapshot: residencySnapshot(names: ["background-task-model"], revision: 1),
            isSessionActive: isSessionActive
        )
        fixture.controller.handleRuntimeResidencyChanged(
            session: fixture.session,
            snapshot: removal,
            isSessionActive: isSessionActive
        )
        await fixture.controller.scheduledWarmupTaskForTests?.value
        await fixture.controller.awaitInFlightWarmup()

        #expect(
            fixture.engine.requestCount == 0,
            "unexpected rewarm for \(removal.reason.rawValue) active=\(isSessionActive)"
        )
        #expect(fixture.controller.state == .cold)
    }

    private func makeFixture() -> (
        controller: ChatWarmupController,
        session: WarmupTestSession,
        engine: WarmupRecordingEngine
    ) {
        let engine = WarmupRecordingEngine()
        let session = WarmupTestSession()
        session.selectedModel = "org/test-model"
        session.engine = engine
        session.payload = ChatWarmupPayload(
            model: "org/test-model",
            messages: [ChatMessage(role: "system", content: "sys")],
            tools: nil,
            modelOptions: nil,
            fingerprint: "org/test-model|freed-slot"
        )
        let controller = ChatWarmupController()
        controller.projectedLoadFeasibility = { _ in nil }
        controller.hasResidentModelOther = { _ in false }
        controller.runtimeResidencySnapshot = {
            residencySnapshot(names: [], revision: 2, reason: .idlePolicy)
        }
        return (controller, session, engine)
    }
}

@MainActor
private final class WarmupTestSession: ChatWarmupSessionContext {
    var selectedModel: String? = "test-model"
    var selectedModelIsLocal: Bool = true
    var isRemoteAgentTarget: Bool = false
    var isStreaming: Bool = false
    var payload: ChatWarmupPayload?
    var engine: ChatEngineProtocol = WarmupTestEngine()
    var imageGenerationModelIDs: Set<String> = []

    func isImageGenerationModel(_ id: String?) -> Bool {
        id.map { imageGenerationModelIDs.contains($0) } ?? false
    }

    func makeWarmupPayload() async -> ChatWarmupPayload? { payload }

    func makeWarmupEngine() -> ChatEngineProtocol { engine }
}

private func residencySnapshot(
    names: [String],
    revision: UInt64,
    reason: ModelRuntimeResidencyChangeReason = .load,
    idleDecisionID: UInt64? = nil
) -> ModelRuntimeResidencySnapshot {
    ModelRuntimeResidencySnapshot(
        names: names,
        revision: revision,
        reason: reason,
        idleDecisionID: idleDecisionID
    )
}

private func activationResidencySnapshot(
    names: [String],
    revision: UInt64,
    reason: ModelRuntimeResidencyChangeReason = .load,
    idleDecisionID: UInt64? = nil,
    recoverableIdleDecisionID: UInt64? = nil
) -> ModelRuntimeChatActivationResidencySnapshot {
    ModelRuntimeChatActivationResidencySnapshot(
        residency: residencySnapshot(
            names: names,
            revision: revision,
            reason: reason,
            idleDecisionID: idleDecisionID
        ),
        recoverableIdleDecisionID: recoverableIdleDecisionID
    )
}

private final class WarmupRecordingEngine: ChatEngineProtocol, @unchecked Sendable {
    var lastRequest: ChatCompletionRequest?
    var requestCount = 0

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        lastRequest = request
        requestCount += 1
        return AsyncThrowingStream { $0.finish() }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        lastRequest = request
        return ChatCompletionResponse(
            id: "test",
            object: "chat.completion",
            created: 0,
            model: request.model,
            choices: [],
            usage: Usage(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
        )
    }
}

private actor FirstResidentPreflightGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var firstCallStarted = false
    private var callCount = 0

    func check() async -> Bool {
        callCount += 1
        guard callCount == 1 else { return false }
        firstCallStarted = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func releaseFirst() {
        continuation?.resume(returning: false)
        continuation = nil
    }
}

private actor ResidentSnapshotGate {
    private var callCount = 0
    private var continuations: [
        Int: CheckedContinuation<ModelRuntimeChatActivationResidencySnapshot, Never>
    ] = [:]

    func snapshot() async -> ModelRuntimeChatActivationResidencySnapshot {
        callCount += 1
        let call = callCount
        return await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func waitForCallCount(_ expected: Int) async {
        while callCount < expected {
            await Task.yield()
        }
    }

    func resume(call: Int, with snapshot: ModelRuntimeChatActivationResidencySnapshot) {
        continuations.removeValue(forKey: call)?.resume(returning: snapshot)
    }
}

private actor ResidentSnapshotSequence {
    private var snapshots: [ModelRuntimeResidencySnapshot]
    private var calls = 0

    init(_ snapshots: [ModelRuntimeResidencySnapshot]) {
        self.snapshots = snapshots
    }

    func next() -> ModelRuntimeResidencySnapshot {
        calls += 1
        precondition(!snapshots.isEmpty, "unexpected residency snapshot request")
        return snapshots.removeFirst()
    }

    func callCount() -> Int { calls }
}

private actor WarmupDebounceGate {
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        blocked = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async {
        while !blocked {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// Engine whose stream never finishes on its own — only cancellation
/// terminates it. Lets tests prove a model switch cancels the in-flight
/// warm-up instead of waiting it out.
private final class HangingWarmupEngine: ChatEngineProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _terminated = false

    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _started
    }

    var terminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _terminated
    }

    private func markStarted() {
        lock.lock()
        _started = true
        lock.unlock()
    }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        markStarted()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self._terminated = true
                self.lock.unlock()
            }
            // Never finish: the warm-up only ends via task cancellation.
        }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        ChatCompletionResponse(
            id: "test",
            object: "chat.completion",
            created: 0,
            model: request.model,
            choices: [],
            usage: Usage(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
        )
    }
}

private struct WarmupTestEngine: ChatEngineProtocol {
    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        ChatCompletionResponse(
            id: "test",
            object: "chat.completion",
            created: 0,
            model: request.model,
            choices: [],
            usage: Usage(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
        )
    }
}
