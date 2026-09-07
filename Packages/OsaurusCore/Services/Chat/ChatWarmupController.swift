//
//  ChatWarmupController.swift
//  osaurus
//
//  Residency observation for the chat model chip — and nothing speculative.
//
//  Chat model loading is lazy: selecting a model records the choice, and the
//  first Send loads the model and prefills the real request. This controller
//  used to load the selected model and run a hidden one-token prefill on
//  every window focus, model pick, prompt-shape change, run completion and
//  idle-unload recovery (proactive warm-up, #1897 and its follow-ups). Those
//  hidden requests are gone: every scheduling entry point below is inert and
//  the only thing the controller still does is track whether the selected
//  model is resident, from the runtime's monotonic residency snapshots, so
//  the chip never claims readiness for a model that is not loaded.
//
//  The entry points keep their names so the send handshake, window manager
//  and stop paths need no rewiring; each documents what it no longer does.
//

import Foundation
import os

@MainActor
protocol ChatWarmupSessionContext: AnyObject {
    var selectedModel: String? { get }
    var selectedModelIsLocal: Bool { get }
    var isRemoteAgentTarget: Bool { get }
    var isStreaming: Bool { get }
    func isImageGenerationModel(_ id: String?) -> Bool
}

@MainActor
final class ChatWarmupController: ObservableObject {
    /// Kept for the chip's API. With lazy loading there is no speculative
    /// warm-up, so the state never leaves `.cold`; readiness is residency
    /// (`selectedModelResident`) and actual load/prefill progress after Send
    /// is reported by the runtime through `WarmupProgressHub`.
    enum WarmState: Equatable {
        case cold
        case warming
        case warm
    }

    /// Typed runtime snapshots keep activation and notification delivery on
    /// the same monotonic residency timeline. Tests replace these seams.
    var runtimeResidencySnapshot: @MainActor () async -> ModelRuntimeResidencySnapshot = {
        await ModelRuntime.shared.residencySnapshot()
    }
    var chatActivationResidencySnapshot:
        @MainActor (String?) async -> ModelRuntimeChatActivationResidencySnapshot = { model in
            await ModelRuntime.shared.chatActivationResidencySnapshot(selectedModel: model)
    }

    @Published private(set) var state: WarmState = .cold

    /// Whether the session's selected model is currently resident in the
    /// runtime, tracked from the newest accepted residency snapshot. The
    /// model-selector dot reads this so it never claims readiness for a
    /// model that is not actually loaded (after an idle unload, an eviction
    /// by another surface, or simply before the first Send).
    @Published private(set) var selectedModelResident: Bool = false
    /// Resident-name set from the newest accepted residency snapshot, kept so
    /// a selection change can re-evaluate residency immediately without
    /// waiting for the next runtime notification.
    private var lastKnownResidentNames: [String] = []

    /// True when the UI should render the green "warm" dot. Always false
    /// under lazy loading; the dot is residency-based.
    var isWarmForDisplay: Bool { state == .warm }

    /// Runtime-residency reconciliation launched when a chat becomes active
    /// (window focus, background work finished). Controller-owned so reset,
    /// Stop, shutdown and model selection can invalidate a suspended snapshot.
    private var sessionActivation: Task<Void, Never>?
    private var sessionActivationID: UUID?
    /// Highest runtime residency revision consumed by this controller. This
    /// rejects delayed and duplicate NotificationCenter delivery.
    private var lastResidencyRevision: UInt64?
    /// Monotonic counter bumped by every selection change and reset, so a
    /// suspended activation cannot apply a snapshot for an older selection.
    private var switchEpoch: UInt64 = 0

    #if DEBUG
        var sessionActivationTaskForTests: Task<Void, Never>? { sessionActivation }
    #endif

    /// True once the owning window began teardown; every entry point is
    /// inert afterwards.
    private var isShutDown = false

    deinit {
        sessionActivation?.cancel()
    }

    /// Permanently stop this controller. Called from window teardown
    /// (`ChatWindowState.cleanup()`) before `session.stop()`.
    func shutdown() {
        isShutDown = true
        reset()
    }

    func reset() {
        switchEpoch &+= 1
        cancelSessionActivation()
        state = .cold
    }

    /// Drop the warm claim (dot leaves green). There is no warm claim under
    /// lazy loading; kept because prompt-shape changes still call it.
    func invalidateWarmState() {
        if state != .cold { state = .cold }
    }

    /// A prompt-shape change (tools / agent / system prompt / model options)
    /// used to rewarm the new prefix as required pre-send work. The next real
    /// Send renders the authoritative prompt itself; nothing to do here.
    func handleContextShapeChange(
        session: ChatWarmupSessionContext,
        invalidatingShape: Bool = true
    ) {
        guard !isShutDown else { return }
        if invalidatingShape {
            invalidateWarmState()
        }
    }

    /// A load from another surface (HTTP, plugin, subagent, another window)
    /// can evict this session's selected model. Drop any warm claim when the
    /// runtime snapshot no longer contains the selected model. Never schedule
    /// a replacement load here.
    func reconcileRuntimeResidency(
        selectedModel: String?,
        residentModelNames: [String]
    ) {
        guard state == .warm, let selectedModel, !selectedModel.isEmpty else { return }
        guard !Self.isSelectedModelResident(selectedModel, in: residentModelNames) else { return }
        invalidateWarmState()
    }

    nonisolated static func isSelectedModelResident(
        _ selectedModel: String,
        in residentModelNames: [String]
    ) -> Bool {
        let selectedTail = selectedModel.split(separator: "/").last.map(String.init) ?? selectedModel
        return residentModelNames.contains { resident in
            let residentTail = resident.split(separator: "/").last.map(String.init) ?? resident
            return resident.caseInsensitiveCompare(selectedModel) == .orderedSame
                || resident.caseInsensitiveCompare(selectedTail) == .orderedSame
                || residentTail.caseInsensitiveCompare(selectedModel) == .orderedSame
                || residentTail.caseInsensitiveCompare(selectedTail) == .orderedSame
        }
    }

    // MARK: - Model selection

    /// Record a model selection: re-evaluate the residency-backed dot against
    /// the new selection from the last known resident set. Nothing is loaded,
    /// evicted or prefilled — the first Send does that, and the runtime's own
    /// residency policy decides eviction at load time.
    func handleModelSelectionChange(
        session: ChatWarmupSessionContext,
        to newModel: String?
    ) {
        guard !isShutDown else { return }
        switchEpoch &+= 1
        cancelSessionActivation()
        invalidateWarmState()
        updateSelectedModelResidency(selectedModel: newModel)
    }

    /// No model switch is ever in flight under lazy loading; the send
    /// handshake awaits this for API stability.
    func awaitActiveModelSwitch() async {}

    /// No retiring runtime work exists under lazy loading.
    func awaitRetiringWork() async {}

    // MARK: - Activation and residency

    /// Formerly the speculative warm-up scheduler (focus, post-run rewarm,
    /// freed-slot rewarm, model family refresh). Inert: no chat model is
    /// loaded or prefilled before the user sends.
    func scheduleWarmup(
        session: ChatWarmupSessionContext,
        debounce: Duration = .zero,
        revalidateResidencyAfterDebounce: Bool = false,
        activationID: UUID? = nil
    ) {
        invalidateWarmState()
    }

    /// A chat window became active: refresh the residency-backed dot from the
    /// runtime's atomic activation snapshot (idle unload and the AppKit focus
    /// event are delivered independently). No load is scheduled.
    func handleSessionBecameActive(
        session: ChatWarmupSessionContext,
        debounce: Duration = .zero
    ) {
        guard !isShutDown else { return }
        cancelSessionActivation()

        let selectedModel = session.selectedModel
        let epoch = switchEpoch
        let id = UUID()
        sessionActivationID = id
        sessionActivation = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            defer {
                if self.sessionActivationID == id {
                    self.sessionActivation = nil
                    self.sessionActivationID = nil
                }
            }

            let activation = await self.chatActivationResidencySnapshot(selectedModel)
            guard
                !Task.isCancelled,
                !self.isShutDown,
                self.sessionActivationID == id,
                self.switchEpoch == epoch,
                session.selectedModel == selectedModel
            else { return }

            self.acceptResidencySnapshot(
                activation.residency,
                selectedModel: selectedModel,
                allowDuplicateRevision: true
            )
        }
    }

    /// Await the currently active focus reconciliation (tests).
    func awaitSessionActivation() async {
        await sessionActivation?.value
    }

    /// Apply a runtime residency change to the dot. An idle-policy removal of
    /// this chat's model, or of another surface's model, never schedules a
    /// replacement load: the next Send loads what it needs.
    func handleRuntimeResidencyChanged(
        session: ChatWarmupSessionContext,
        snapshot: ModelRuntimeResidencySnapshot,
        isSessionActive: Bool,
        debounce: Duration = .zero
    ) {
        let selectedModel = session.selectedModel
        guard acceptResidencySnapshot(snapshot, selectedModel: selectedModel) else { return }
    }

    /// A finished run used to rewarm the completed transcript with a hidden
    /// one-token generation. The real request already stored its cache;
    /// nothing else runs after the answer.
    func handleRunCompleted(
        session: ChatWarmupSessionContext,
        wasCancelled: Bool,
        hadError: Bool,
        hadToolActivity: Bool = false
    ) {}

    /// True when a send must run the async pre-send handshake first. Nothing
    /// speculative can be pending under lazy loading, so sends always take
    /// the synchronous path (the user turn is appended inside `send()`).
    var needsPreSendHandshake: Bool { false }

    /// Nothing is scheduled; kept for the send path and Stop.
    func cancelScheduledWarmup() {
        cancelSessionActivation()
    }

    /// User Stop: drop a suspended activation snapshot so it cannot apply
    /// state for a run the user just abandoned.
    func cancelPendingWorkForUserStop() {
        switchEpoch &+= 1
        cancelSessionActivation()
        state = .cold
    }

    /// Explicit model unload from the inspector: same as reset — no
    /// scheduled load may resurrect the model behind the user's back.
    func cancelPendingWorkForExplicitModelUnload() {
        reset()
    }

    /// No warm-up generation exists to wait for.
    func awaitInFlightWarmup() async {}

    /// No prompt-shape rewarm exists to wait for.
    func awaitRequiredContextWarmup() async {}

    // MARK: - Private

    private func cancelSessionActivation() {
        sessionActivationID = nil
        sessionActivation?.cancel()
        sessionActivation = nil
    }

    /// Apply a typed residency snapshot if it is not older than the newest
    /// state already observed. Activation may consume an equal revision
    /// because its atomic runtime reply is the authoritative current set.
    @discardableResult
    private func acceptResidencySnapshot(
        _ snapshot: ModelRuntimeResidencySnapshot,
        selectedModel: String?,
        allowDuplicateRevision: Bool = false
    ) -> Bool {
        if snapshot.revision >= (lastResidencyRevision ?? 0) {
            lastKnownResidentNames = snapshot.names
        }
        updateSelectedModelResidency(selectedModel: selectedModel)
        if let lastResidencyRevision {
            if snapshot.revision < lastResidencyRevision { return false }
            if snapshot.revision == lastResidencyRevision, !allowDuplicateRevision { return false }
        }
        lastResidencyRevision = max(lastResidencyRevision ?? 0, snapshot.revision)
        reconcileRuntimeResidency(
            selectedModel: selectedModel,
            residentModelNames: snapshot.names
        )
        return true
    }

    private func updateSelectedModelResidency(selectedModel: String?) {
        let resident =
            selectedModel.map { Self.isSelectedModelResident($0, in: lastKnownResidentNames) }
            ?? false
        if selectedModelResident != resident { selectedModelResident = resident }
    }

    /// Seed the residency-backed dot state at session start, before any
    /// runtime notification arrives.
    func seedRuntimeResidency(session: ChatWarmupSessionContext) {
        guard !isShutDown else { return }
        Task { @MainActor [weak self, weak session] in
            guard let self else { return }
            let snapshot = await self.runtimeResidencySnapshot()
            guard !self.isShutDown else { return }
            self.acceptResidencySnapshot(
                snapshot,
                selectedModel: session?.selectedModel,
                allowDuplicateRevision: true
            )
        }
    }
}
