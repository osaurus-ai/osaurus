//
//  ChatWarmupControllerTests.swift
//  osaurusTests
//
//  Lazy chat loading: selecting a model records the choice; the first Send
//  loads the model and prefills the real request. The controller only
//  observes residency for the chip. Every former speculative trigger —
//  window focus, model pick, prompt-shape change, run completion, idle
//  unload recovery, freed-slot rewarm, DSV4 pre-send — must schedule no
//  model work, for legacy warm-up settings absent, true and false.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
private final class LazySession: ChatWarmupSessionContext {
    var selectedModel: String? = "org/test-model"
    var selectedModelIsLocal = true
    var isRemoteAgentTarget = false
    var isStreaming = false
    var imageModels: Set<String> = []
    func isImageGenerationModel(_ id: String?) -> Bool { id.map { imageModels.contains($0) } ?? false }
}

private func residencySnapshot(
    names: [String],
    revision: UInt64,
    reason: ModelRuntimeResidencyChangeReason = .modelSwitch,
    idleDecisionID: UInt64? = nil
) -> ModelRuntimeResidencySnapshot {
    ModelRuntimeResidencySnapshot(
        names: names, revision: revision, reason: reason, idleDecisionID: idleDecisionID)
}

private func activationSnapshot(
    names: [String],
    revision: UInt64,
    reason: ModelRuntimeResidencyChangeReason = .modelSwitch,
    recoverableIdleDecisionID: UInt64? = nil
) -> ModelRuntimeChatActivationResidencySnapshot {
    ModelRuntimeChatActivationResidencySnapshot(
        residency: residencySnapshot(names: names, revision: revision, reason: reason),
        recoverableIdleDecisionID: recoverableIdleDecisionID)
}

@Suite("ChatConfiguration warmModelsOnLoad is retired")
struct ChatConfigurationWarmModelsOnLoadTests {
    @Test("legacy values absent, true and false all decode")
    func legacyValuesDecode() throws {
        let absent = try JSONDecoder().decode(
            ChatConfiguration.self, from: Data(#"{"systemPrompt":""}"#.utf8))
        let on = try JSONDecoder().decode(
            ChatConfiguration.self, from: Data(#"{"systemPrompt":"","warmModelsOnLoad":true}"#.utf8))
        let off = try JSONDecoder().decode(
            ChatConfiguration.self, from: Data(#"{"systemPrompt":"","warmModelsOnLoad":false}"#.utf8))
        #expect(absent.warmModelsOnLoad == true)
        #expect(on.warmModelsOnLoad == true)
        #expect(off.warmModelsOnLoad == false)
    }

    @Test("no production code reads the setting any more")
    func settingHasNoAuthority() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let readers = [
            "Services/Chat/ChatWarmupController.swift",
            "Services/Chat/ChatSessionWarmup.swift",
            "Views/Chat/ChatView.swift",
            "Views/Chat/FloatingInputCard.swift",
            "Views/Settings/ChatSettingsView.swift",
        ]
        for rel in readers {
            let src = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            let reads = src.components(separatedBy: ".warmModelsOnLoad").count - 1
            if rel.hasSuffix("ChatSettingsView.swift") {
                // The settings snapshot still round-trips the stored value so
                // old files keep decoding, but no toggle is offered.
                #expect(!src.contains("Automatically Warm Models on Load"), Comment(rawValue: rel))
            } else {
                #expect(reads == 0, Comment(rawValue: "\(rel) still reads warmModelsOnLoad"))
            }
        }
    }
}

@Suite("ChatWarmupController is a residency observer only")
@MainActor
struct ChatWarmupControllerLazyLoadTests {
    /// The controller has no engine, runtime-load or preload seam left: the
    /// absence is enforced at the source, and every entry point below must
    /// leave the controller with nothing pending.
    @Test("no entry point schedules model work")
    func noEntryPointSchedulesWork() async {
        let session = LazySession()
        let controller = ChatWarmupController()
        controller.runtimeResidencySnapshot = { residencySnapshot(names: [], revision: 1) }
        controller.chatActivationResidencySnapshot = { _ in activationSnapshot(names: [], revision: 2) }

        controller.seedRuntimeResidency(session: session)
        controller.handleModelSelectionChange(session: session, to: "org/other-model")
        controller.scheduleWarmup(session: session)
        controller.handleContextShapeChange(session: session)
        controller.handleSessionBecameActive(session: session)
        await controller.awaitSessionActivation()
        controller.handleRunCompleted(session: session, wasCancelled: false, hadError: false)
        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(names: [], revision: 3, reason: .idlePolicy, idleDecisionID: 7),
            isSessionActive: true
        )
        try? await Task.sleep(for: .milliseconds(50))

        #expect(!controller.needsPreSendHandshake)
        #expect(controller.state == .cold)
        #expect(!controller.isWarmForDisplay)
        #expect(controller.sessionActivationTaskForTests == nil)
    }

    @Test("selection records the choice and re-evaluates residency without evicting")
    func selectionRecordsOnly() async {
        let session = LazySession()
        let controller = ChatWarmupController()
        controller.runtimeResidencySnapshot = { residencySnapshot(names: ["org/resident-model"], revision: 1) }
        controller.seedRuntimeResidency(session: session)
        for _ in 0 ..< 50 where controller.selectedModelResident == false {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!controller.selectedModelResident, "org/test-model is not resident")

        controller.handleModelSelectionChange(session: session, to: "org/resident-model")
        #expect(controller.selectedModelResident, "the dot follows the last known resident set")
        #expect(controller.state == .cold, "a merely selected model is never 'warming'")
        #expect(!controller.needsPreSendHandshake, "Send stays synchronous after a selection")

        controller.handleModelSelectionChange(session: session, to: "org/unloaded-model")
        #expect(!controller.selectedModelResident)
    }

    @Test("focus refreshes the dot from the activation snapshot and schedules nothing")
    func focusRefreshesResidency() async {
        let session = LazySession()
        let controller = ChatWarmupController()
        controller.chatActivationResidencySnapshot = { model in
            activationSnapshot(
                names: ["org/test-model"], revision: 5, reason: .idlePolicy, recoverableIdleDecisionID: 42)
        }
        controller.handleSessionBecameActive(session: session)
        await controller.awaitSessionActivation()
        #expect(controller.selectedModelResident)
        #expect(controller.state == .cold)

        // Idle unload of THIS model with the exact recoverable decision id:
        // the old controller scheduled a replacement warm-up here.
        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(names: [], revision: 6, reason: .idlePolicy, idleDecisionID: 42),
            isSessionActive: true
        )
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!controller.selectedModelResident)
        #expect(controller.state == .cold)
        #expect(controller.sessionActivationTaskForTests == nil)
    }

    @Test("a freed slot after another surface's idle unload does not rewarm")
    func freedSlotDoesNotRewarm() async {
        let session = LazySession()
        let controller = ChatWarmupController()
        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(names: ["org/other-model"], revision: 1),
            isSessionActive: true
        )
        controller.handleRuntimeResidencyChanged(
            session: session,
            snapshot: residencySnapshot(names: [], revision: 2, reason: .idlePolicy, idleDecisionID: 9),
            isSessionActive: true
        )
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!controller.selectedModelResident)
        #expect(controller.state == .cold)
        #expect(!controller.needsPreSendHandshake)
    }

    @Test("stale and duplicate residency revisions are ignored, canonical and tail names match")
    func revisionGateAndNameMatching() {
        let session = LazySession()
        session.selectedModel = "org/test-model"
        let controller = ChatWarmupController()
        controller.handleRuntimeResidencyChanged(
            session: session, snapshot: residencySnapshot(names: ["test-model"], revision: 5), isSessionActive: true)
        #expect(controller.selectedModelResident, "tail name matches the canonical selection")
        // Older revision: ignored.
        controller.handleRuntimeResidencyChanged(
            session: session, snapshot: residencySnapshot(names: [], revision: 4), isSessionActive: true)
        #expect(controller.selectedModelResident)
        // Newer revision without the model: dot goes gray.
        controller.handleRuntimeResidencyChanged(
            session: session, snapshot: residencySnapshot(names: ["org/another"], revision: 6), isSessionActive: true)
        #expect(!controller.selectedModelResident)
        #expect(ChatWarmupController.isSelectedModelResident("org/test-model", in: ["TEST-MODEL"]))
        #expect(!ChatWarmupController.isSelectedModelResident("org/test-model", in: ["org/test-model-2"]))
    }

    @Test("reset, Stop and shutdown leave nothing pending")
    func lifecycleLeavesNothingPending() async {
        let session = LazySession()
        let controller = ChatWarmupController()
        controller.chatActivationResidencySnapshot = { _ in
            try? await Task.sleep(for: .milliseconds(200))
            return activationSnapshot(names: ["org/test-model"], revision: 1)
        }
        controller.handleSessionBecameActive(session: session)
        controller.cancelPendingWorkForUserStop()
        #expect(controller.sessionActivationTaskForTests == nil)
        controller.handleSessionBecameActive(session: session)
        controller.reset()
        #expect(controller.sessionActivationTaskForTests == nil)
        controller.shutdown()
        controller.handleSessionBecameActive(session: session)
        controller.handleModelSelectionChange(session: session, to: "org/x")
        #expect(controller.sessionActivationTaskForTests == nil)
        #expect(!controller.needsPreSendHandshake)
        await controller.awaitActiveModelSwitch()
        await controller.awaitRetiringWork()
        await controller.awaitInFlightWarmup()
        await controller.awaitRequiredContextWarmup()
    }
}
