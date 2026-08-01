//
//  ChatWarmupController.swift
//  osaurus
//
//  Proactive KV-cache warm-up for chat sessions: load the selected local
//  model and run a one-token prefill over the session's static prompt prefix
//  (system + tools + history, excluding the pending user turn) so the first
//  real send can prefix-hit and pay less time-to-first-token cost.
//
//  Also owns the model-switch policy: a selection change acts immediately —
//  any in-flight warm-up of the previous model is cancelled (waiting it out
//  made switches feel stuck), the previous model is evicted per the
//  residency policy, and the new model starts warming right away so the
//  user gets instant visual feedback.
//

import Foundation

/// Payload assembled from the same composition path as a real send, minus
/// the in-flight user turn.
struct ChatWarmupPayload: Sendable {
    let model: String
    let messages: [ChatMessage]
    let tools: [Tool]?
    /// The session's active model options (Thinking toggle, reasoning
    /// effort, …). MUST match the real send: `enable_thinking` both changes
    /// the rendered prompt tokens (e.g. Gemma 4 injects `<|think|>` into the
    /// system turn) and is mixed into the runtime's cache-scope salt — a
    /// mismatch on either side makes every cache lookup miss.
    let modelOptions: [String: ModelOptionValue]?
    /// Exact static-system-prefix hint used by real chat requests. Warm-up
    /// must carry the same tokenizer boundary hint so vMLX persists the
    /// boundary the real send later looks up.
    let cacheStableSystemPrefix: String?
    /// Identity of what this payload warms: model + static prefix hash +
    /// full rendered-prompt hash + history shape + options. The rendered
    /// hash matters: dynamic prompt sections (channel destinations, agent DB
    /// schema, sandbox state) are outside the static prefix hash, and a
    /// stale warm claim over changed dynamic bytes makes the real send
    /// cold-re-prefill the whole conversation. A fingerprint match means
    /// the KV prefix is already hot.
    let fingerprint: String

    init(
        model: String,
        messages: [ChatMessage],
        tools: [Tool]?,
        modelOptions: [String: ModelOptionValue]?,
        cacheStableSystemPrefix: String? = nil,
        fingerprint: String
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.modelOptions = modelOptions
        self.cacheStableSystemPrefix = cacheStableSystemPrefix
        self.fingerprint = fingerprint
    }
}

@MainActor
protocol ChatWarmupSessionContext: AnyObject {
    var selectedModel: String? { get }
    var selectedModelIsLocal: Bool { get }
    var isRemoteAgentTarget: Bool { get }
    var isStreaming: Bool { get }
    func isImageGenerationModel(_ id: String?) -> Bool
    func makeWarmupPayload() async -> ChatWarmupPayload?
    func makeWarmupEngine() -> ChatEngineProtocol
}

@MainActor
final class ChatWarmupController: ObservableObject {
    enum WarmState: Equatable {
        case cold
        case warming
        case warm
    }

    /// Debounce coalescing fingerprint-invalidating warm-up retriggers.
    static let scheduleDebounce: Duration = .milliseconds(500)

    /// Projected RAM feasibility for a candidate warm-up load (test seam;
    /// production queries the shared runtime). Warm-up is Osaurus-initiated
    /// background work, so a projection past the hard RAM ceiling skips it
    /// entirely — proactively loading a model that can't fit is how a
    /// window-open warm-up turns into a fatal Metal OOM
    /// (kIOGPUCommandBufferCallbackErrorOutOfMemory) on small machines.
    var projectedLoadFeasibility: @MainActor (String) async -> ModelRuntime.RAMFeasibility? =
        { model in
            await ModelRuntime.shared.projectedLoadFeasibility(for: model)
        }

    /// Resident-model preflight (test seam; production queries the shared
    /// runtime). This actor hop is a cancellation boundary: a reset may cancel
    /// the scheduled warm-up while the runtime answers, so callers must
    /// re-check cancellation and session eligibility after awaiting it.
    var hasResidentModelOther: @MainActor (String) async -> Bool = { model in
        await ModelRuntime.shared.hasResidentModelOther(than: model)
    }

    /// Typed runtime snapshots make activation and notification delivery use
    /// the same monotonic residency timeline. Tests replace these seams to
    /// hold the exact focus/idle-unload race without wall-clock sleeps.
    var runtimeResidencySnapshot: @MainActor () async -> ModelRuntimeResidencySnapshot = {
        await ModelRuntime.shared.residencySnapshot()
    }
    var chatActivationResidencySnapshot:
        @MainActor (String?) async -> ModelRuntimeChatActivationResidencySnapshot = { model in
            await ModelRuntime.shared.chatActivationResidencySnapshot(selectedModel: model)
    }

    /// Debounce suspension seam. Production uses the real clock; lifecycle
    /// tests can hold this boundary so residency changes that occur after the
    /// activation snapshot are exercised without timing sleeps.
    var scheduleDebounceSleep: @MainActor (Duration) async -> Void = { duration in
        try? await Task.sleep(for: duration)
    }

    @Published private(set) var state: WarmState = .cold

    /// Whether the session's selected model is currently resident in the
    /// runtime, tracked from the same monotonic residency snapshots that
    /// drive warm-claim reconciliation. The model-selector dot reads this so
    /// it never claims readiness for a model that is not actually loaded —
    /// in particular when warm-on-load is disabled (no warm-up pass exists
    /// in that mode, so readiness IS residency) and after an idle unload.
    @Published private(set) var selectedModelResident: Bool = false
    /// Resident-name set from the newest accepted residency snapshot, kept so
    /// a selection change can re-evaluate residency immediately without
    /// waiting for the next runtime notification.
    private var lastKnownResidentNames: [String] = []

    /// True when the UI should render the green "warm" dot.
    var isWarmForDisplay: Bool { state == .warm }

    private var warmedFingerprint: String?
    private var scheduleTask: Task<Void, Never>?
    private var scheduleTaskID: UUID?
    /// Non-nil only when `scheduleTask` was created by a window-focus
    /// activation. A newer non-recoverable eviction may cancel that exact
    /// speculative task without disturbing model-switch or user-intent work.
    private var scheduledActivationID: UUID?
    private var inFlightWarmup: Task<Void, Never>?
    private var inFlightWarmupID: UUID?
    /// A prompt-shape change is different from an idle speculative warm-up:
    /// the next real send is known to need these exact rendered bytes. Track
    /// that rewarm separately so `send()` can keep cancelling ordinary
    /// scheduled work without cancelling the only warm-up for a freshly
    /// changed system prompt.
    private var requiredContextWarmup: Task<Void, Never>?
    private var requiredContextWarmupID: UUID?
    /// The model of the most recent user-driven selection change. A warm-up
    /// for this model may displace a resident model; all other (speculative)
    /// warm-ups may only fill an empty slot — see `performWarmup`.
    private var userIntentWarmupModel: String?
    /// The immediate switch operation in flight (cancel stale warm-up →
    /// evict per policy → schedule the new model's warm-up). Tracked so the
    /// pre-send handshake can wait for the eviction to settle and so rapid
    /// consecutive switches serialize instead of interleaving unloads.
    private var activeModelSwitch: Task<Void, Never>?
    private var activeModelSwitchID: UUID?
    /// Cancelled work from a previous chat/reset that may still own a model
    /// residency or generation lease while it unwinds. This stays separate
    /// from the current chat's switch and warm-up slots so new work can be
    /// scheduled, but runtime-touching paths drain it before proceeding.
    private var retiringWork: Task<Void, Never>?
    private var retiringWorkID: UUID?
    /// Runtime-residency reconciliation launched when a chat becomes active.
    /// This is controller-owned (rather than an untracked Task in ChatSession)
    /// so reset, Stop, shutdown, and model selection can invalidate a
    /// suspended residency snapshot before it schedules hidden warm-up work.
    private var sessionActivation: Task<Void, Never>?
    private var sessionActivationID: UUID?
    /// One-shot identity for the *exact* idle decision that crossed into
    /// teardown while this chat was being activated. A later idle timer,
    /// memory-pressure eviction, handoff, explicit unload, or model switch can
    /// never match this token and therefore can never create unload/rewarm
    /// ping-pong merely because the window remains key.
    private struct ActivationRecovery: Equatable {
        let model: String
        let idleDecisionID: UInt64
    }
    private var activationRecovery: ActivationRecovery?
    /// Highest runtime residency revision consumed by this controller. This
    /// rejects delayed and duplicate NotificationCenter delivery.
    private var lastResidencyRevision: UInt64?
    /// Monotonic counter bumped by every switch-affecting entry point
    /// (selection change, reset). Handlers that suspend re-check it
    /// afterwards so a stale resume can't cancel or restore state installed
    /// by a newer event.
    private var switchEpoch: UInt64 = 0

    #if DEBUG
        /// Deterministic lifecycle tests retain the outgoing scheduled task
        /// across reset so they can await its actual cancellation unwind.
        var scheduledWarmupTaskForTests: Task<Void, Never>? { scheduleTask }
        var sessionActivationTaskForTests: Task<Void, Never>? { sessionActivation }
    #endif

    /// True once the owning window began teardown. `session.stop()` during
    /// window close runs the normal run-completed cleanup, which schedules a
    /// fresh warm-up — pointless model work for a session that is about to be
    /// deallocated. Once shut down, all scheduling entry points are inert.
    private var isShutDown = false

    deinit {
        scheduleTask?.cancel()
        activeModelSwitch?.cancel()
        inFlightWarmup?.cancel()
        requiredContextWarmup?.cancel()
        retiringWork?.cancel()
        sessionActivation?.cancel()
    }

    /// Permanently stop this controller: cancel pending and in-flight warm-up
    /// work and refuse any future scheduling. Called from window teardown
    /// (`ChatWindowState.cleanup()`) before `session.stop()`.
    func shutdown() {
        isShutDown = true
        reset()
    }

    func reset() {
        switchEpoch &+= 1
        scheduleTask?.cancel()
        activeModelSwitch?.cancel()
        inFlightWarmup?.cancel()
        requiredContextWarmup?.cancel()
        cancelSessionActivation()

        let previousRetiringWork = retiringWork
        let retiringSwitch = activeModelSwitch
        let retiringWarmup = inFlightWarmup
        if retiringSwitch != nil || retiringWarmup != nil {
            let id = UUID()
            retiringWorkID = id
            retiringWork = Task { @MainActor [weak self] in
                await previousRetiringWork?.value
                await retiringSwitch?.value
                await retiringWarmup?.value
                guard let self, self.retiringWorkID == id else { return }
                self.retiringWork = nil
                self.retiringWorkID = nil
            }
        }

        scheduleTask = nil
        scheduleTaskID = nil
        scheduledActivationID = nil
        activeModelSwitch = nil
        activeModelSwitchID = nil
        inFlightWarmup = nil
        inFlightWarmupID = nil
        requiredContextWarmup = nil
        requiredContextWarmupID = nil
        userIntentWarmupModel = nil
        warmedFingerprint = nil
        state = .cold
    }

    /// Drop the warm claim (dot leaves green) without cancelling in-flight
    /// work. Called when the prompt shape changes (tools / agent / soul).
    func invalidateWarmState() {
        warmedFingerprint = nil
        if state == .warm { state = .cold }
    }

    /// Rewarm a newly composed prompt shape and make that work part of the
    /// pre-send handshake. Unlike an idle `scheduleWarmup`, this task is not
    /// cancelled by `send()` before dispatch: doing so made a settings edit
    /// reliably fall back to a visible full cold prefill whenever the user
    /// returned to chat inside the normal debounce window.
    func handleContextShapeChange(session: ChatWarmupSessionContext) {
        guard !isShutDown else { return }

        invalidateWarmState()
        cancelScheduledWarmup()

        let previousRequiredWarmup = requiredContextWarmup
        previousRequiredWarmup?.cancel()

        let id = UUID()
        requiredContextWarmupID = id
        requiredContextWarmup = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.requiredContextWarmupID == id {
                    self.requiredContextWarmup = nil
                    self.requiredContextWarmupID = nil
                }
            }

            // A prior prompt edit may already have reached generation. Let
            // that cancellation unwind before composing the latest payload;
            // `performWarmup` will then compare the current full-prompt
            // fingerprint and issue a second warm-up only when necessary.
            await previousRequiredWarmup?.value
            guard !Task.isCancelled else { return }
            await self.activeModelSwitch?.value
            guard !Task.isCancelled else { return }
            await self.performWarmup(session: session)
        }
    }

    /// A load from another surface (HTTP, plugin, subagent, another window)
    /// can evict this session's selected model without touching its warm-up
    /// controller. Drop the green-dot claim and its fingerprint when the
    /// runtime snapshot no longer contains the selected model. Do not schedule
    /// a replacement warm-up here: doing so would immediately evict the model
    /// the other surface intentionally loaded.
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

    // MARK: - Model switch

    /// Handle a model selection change immediately: cancel any warm-up still
    /// running for the previous model (letting it finish deferred the
    /// eviction and made switches feel stuck), evict per the residency
    /// policy, and start warming the new model right away so the dot /
    /// progress feedback reacts the moment the user picks a model.
    ///
    /// The `$selectedModel` sink fires at `willSet` time; the Task hop
    /// defers the switch until after the property (and the rest of the view
    /// update) has settled, so session reads see the new selection and
    /// `@Published` state isn't mutated mid-publish.
    func handleModelSelectionChange(
        session: ChatWarmupSessionContext,
        to newModel: String?,
        performSwitch: @escaping @MainActor (_ evictOthers: Bool) async -> Void
    ) {
        // Invalidate an activation snapshot immediately, before the deferred
        // switch task runs. Otherwise a slow runtime actor response can resume
        // in this gap and schedule a warm-up for the outgoing selection.
        cancelSessionActivation()
        Task { @MainActor in
            self.performModelSelectionChange(
                session: session,
                to: newModel,
                performSwitch: performSwitch
            )
        }
    }

    private func performModelSelectionChange(
        session: ChatWarmupSessionContext,
        to newModel: String?,
        performSwitch: @escaping @MainActor (_ evictOthers: Bool) async -> Void
    ) {
        guard !isShutDown else { return }
        switchEpoch &+= 1
        let epoch = switchEpoch

        invalidateWarmState()
        // Re-evaluate the residency-backed dot against the new selection
        // immediately (from the last known resident set); the switch's own
        // eviction/load publishes fresh snapshots that keep it current.
        updateSelectedModelResidency(selectedModel: newModel)

        // A scheduled warm-up targets the old selection — drop it. A warm-up
        // generation already in flight is cancelled AND detached: clearing
        // the ID makes its stale-writer guards drop its state writes, so the
        // cancelled unwind can't flip the fresh `.warming` below back to
        // `.cold` (or claim a stale warm fingerprint).
        cancelScheduledWarmup()
        let staleWarmup = inFlightWarmup
        if staleWarmup != nil {
            inFlightWarmup = nil
            inFlightWarmupID = nil
            staleWarmup?.cancel()
        }

        guard let newModel, !newModel.isEmpty else { return }

        // The user just picked this model by hand — the follow-up warm-up is
        // allowed to displace whatever is resident. Speculative warm-ups
        // (session became active, post-run re-warm) are not; see
        // `performWarmup`'s resident-model guard.
        //
        // This is a ONE-SHOT grant, consumed by the warm-up it authorizes (see
        // `consumeUserIntent(for:)`). It used to be set here and never cleared,
        // which quietly turned "the user just picked A" into "any warm-up of A,
        // forever, may evict" — so a re-warm of A minutes later, triggered by
        // nothing the user did, could still unload the model an API client was
        // using. The privilege has to expire with the intent that created it.
        userIntentWarmupModel = newModel

        let policy =
            ServerConfigurationStore.load()?.modelEvictionPolicy ?? .strictSingleModel

        // Immediate visual feedback: the chip dot goes yellow the moment the
        // selection changes (remote/non-warmable selections ignore state).
        state = .warming

        let switchID = UUID()
        let retiringWork = retiringWork
        let previousSwitch = activeModelSwitch
        activeModelSwitchID = switchID
        activeModelSwitch = Task { @MainActor in
            // A user Stop can cancel this switch while `performSwitch` (or an
            // older switch/warm-up awaited below) is suspended. Always retire
            // our tracked task when it eventually unwinds; otherwise
            // `needsPreSendHandshake` stays true forever and the next send
            // appears permanently queued.
            defer {
                if self.activeModelSwitchID == switchID {
                    self.activeModelSwitch = nil
                    self.activeModelSwitchID = nil
                }
            }
            // Serialize with a still-running earlier switch so evictions
            // never interleave, then wait for the cancelled warm-up to
            // actually unwind — its generation lease would otherwise make
            // the runtime skip (not defer) the old model's unload.
            await retiringWork?.value
            await previousSwitch?.value
            await staleWarmup?.value
            guard !Task.isCancelled else { return }

            // Evict models no window points at anymore (strict single-model
            // only). Multi-model residency never evicts on switch.
            await performSwitch(policy == .strictSingleModel)

            guard self.activeModelSwitchID == switchID else { return }
            self.activeModelSwitch = nil
            self.activeModelSwitchID = nil
            guard epoch == self.switchEpoch, !Task.isCancelled else { return }
            self.scheduleWarmup(session: session, debounce: .zero)
        }
    }

    /// Wait for an in-flight immediate model switch (stale warm-up unwind +
    /// eviction) to settle. Called by the pre-send handshake so a send right
    /// after a switch generates against a clean residency state.
    func awaitActiveModelSwitch() async {
        await activeModelSwitch?.value
    }

    /// Drain cancellation-ignoring lease owners from the previous chat before
    /// a new switch, warm-up, or real send touches the shared runtime.
    func awaitRetiringWork() async {
        await retiringWork?.value
    }

    // MARK: - Warm-up

    func scheduleWarmup(
        session: ChatWarmupSessionContext,
        debounce: Duration = scheduleDebounce,
        revalidateResidencyAfterDebounce: Bool = false,
        activationID: UUID? = nil
    ) {
        guard shouldAttemptWarmup(session: session) else {
            if !ChatConfigurationStore.load().warmModelsOnLoad {
                state = .cold
            } else if session.isImageGenerationModel(session.selectedModel) {
                // Image models never take a KV warm-up. Clear the provisional
                // `.warming` the selection switch set, or the dot stays stuck
                // yellow for as long as the model is selected. (Transient
                // refusals — streaming, switch settling — keep state as-is.)
                state = .cold
            }
            return
        }

        if state == .cold { state = .warming }

        scheduleTask?.cancel()
        scheduledActivationID = activationID
        let taskID = UUID()
        scheduleTaskID = taskID
        scheduleTask = Task { @MainActor in
            defer {
                if self.scheduleTaskID == taskID {
                    self.scheduleTask = nil
                    self.scheduleTaskID = nil
                    self.scheduledActivationID = nil
                }
            }
            if debounce > .zero {
                await scheduleDebounceSleep(debounce)
            }
            guard !Task.isCancelled else { return }

            // A focus activation takes an initial snapshot before scheduling,
            // but an idle unload can remove the selected model during this
            // debounce. Reconcile again at the last boundary before payload
            // fingerprint coalescing; otherwise the stale warm fingerprint can
            // turn the required replacement warm-up into a no-op.
            if revalidateResidencyAfterDebounce {
                let snapshot = await runtimeResidencySnapshot()
                guard !Task.isCancelled else { return }
                let selectedModel = session.selectedModel
                if acceptResidencySnapshot(snapshot, selectedModel: selectedModel),
                    let selectedModel,
                    !Self.isSelectedModelResident(selectedModel, in: snapshot.names)
                {
                    activationRecovery = nil
                }
            }
            guard !Task.isCancelled else { return }
            await performWarmup(session: session)
        }
    }

    /// Re-arm speculative warm-up when a chat window becomes active.
    ///
    /// Runtime residency is checked first because the idle-unload notification
    /// and the AppKit focus event are delivered independently. Without this
    /// ordering, focus can observe a stale `warmedFingerprint` and coalesce
    /// away the exact warm-up needed after eviction.
    func handleSessionBecameActive(
        session: ChatWarmupSessionContext,
        debounce: Duration = scheduleDebounce
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

            guard self.acceptResidencySnapshot(
                activation.residency,
                selectedModel: selectedModel,
                allowDuplicateRevision: true
            ) else { return }

            if let selectedModel,
                Self.isSelectedModelResident(selectedModel, in: activation.residency.names),
                let idleDecisionID = activation.recoverableIdleDecisionID
            {
                self.activationRecovery = ActivationRecovery(
                    model: selectedModel,
                    idleDecisionID: idleDecisionID
                )
            } else {
                self.activationRecovery = nil
            }
            self.scheduleWarmup(
                session: session,
                debounce: debounce,
                revalidateResidencyAfterDebounce: true,
                activationID: id
            )
        }
    }

    /// Await the currently active focus reconciliation. Production send paths
    /// cancel this before dispatch; this await primarily makes lifecycle tests
    /// deterministic without sleeping through the debounce interval.
    func awaitSessionActivation() async {
        await sessionActivation?.value
    }

    /// Reconcile a runtime removal and recover the one activation race that
    /// cannot be closed by a second snapshot alone.
    ///
    /// Recovery is allowed only when this exact selected model was armed by a
    /// recent focus activation, that activation already coalesced to `.warm`,
    /// and this window is still the visible key chat. The token is consumed
    /// before scheduling, so later idle expiry cannot create a periodic
    /// unload/rewarm loop. `performWarmup` still applies RAM and competing-
    /// residency gates, so the retry cannot displace another surface's model.
    func handleRuntimeResidencyChanged(
        session: ChatWarmupSessionContext,
        snapshot: ModelRuntimeResidencySnapshot,
        isSessionActive: Bool,
        debounce: Duration = .zero
    ) {
        let selectedModel = session.selectedModel
        let wasWarm = state == .warm
        // Captured before the snapshot is applied: distinguishes "this event
        // removed MY model" (recovery rules below apply) from "this event
        // freed a slot another surface was holding" (freed-slot rewarm).
        let wasSelectedModelResident = selectedModelResident
        guard acceptResidencySnapshot(snapshot, selectedModel: selectedModel) else { return }

        guard let selectedModel,
            !Self.isSelectedModelResident(selectedModel, in: snapshot.names)
        else { return }

        let recovery = activationRecovery
        activationRecovery = nil
        let matchesActivationIdleDecision = isSessionActive
            && snapshot.reason == .idlePolicy
            && snapshot.idleDecisionID != nil
            && recovery?.idleDecisionID == snapshot.idleDecisionID
            && recovery.map({ Self.isSelectedModelResident(selectedModel, in: [$0.model]) }) == true

        // When focus begins from `.cold`, `scheduleWarmup` immediately moves
        // the UI to `.warming`. If the exact idle removal lands during that
        // debounce, the activation-owned task is already the required
        // replacement. Preserve it instead of cancelling it and reproducing
        // the stuck yellow/no-warmup state.
        if matchesActivationIdleDecision,
            state == .warming,
            scheduledActivationID != nil
        {
            return
        }

        let mayRecover = wasWarm
            && state == .cold
            && matchesActivationIdleDecision

        if !mayRecover, scheduledActivationID != nil {
            scheduleTask?.cancel()
            scheduleTask = nil
            scheduleTaskID = nil
            scheduledActivationID = nil
            state = .cold
        }

        if mayRecover, snapshot.idleDecisionID != nil {
            scheduleWarmup(
                session: session,
                debounce: debounce,
                revalidateResidencyAfterDebounce: true
            )
            return
        }

        // Freed-slot rewarm: an idle-policy removal of ANOTHER surface's
        // model (a finished background task's accelerated release, or its
        // natural idle expiry) emptied the runtime while this chat's
        // speculative warm-ups were being refused ("a different model is
        // resident and this warm-up lacks user intent"). Nothing else
        // re-triggers a warm-up until the user refocuses the window, so
        // without this the visible chat stays cold indefinitely.
        //
        // `wasSelectedModelResident == false` keeps every removal of the
        // chat's OWN model on the strict recovery rules above — this path
        // can never recreate the idle unload/rewarm ping-pong they close.
        // The reason gate keeps shutdown / settings-clear / explicit-unload
        // removals from resurrecting a load the user just tore down, and
        // the warm-up itself still runs with background load intent.
        guard !wasSelectedModelResident,
            isSessionActive,
            snapshot.reason == .idlePolicy,
            snapshot.names.isEmpty
        else { return }

        scheduleWarmup(
            session: session,
            debounce: debounce,
            revalidateResidencyAfterDebounce: true
        )
    }

    /// Re-warm the completed transcript only after a natural, successful
    /// plain-chat run. A user Stop intentionally abandons the active prompt;
    /// warming that abandoned (often very large) turn immediately starts a
    /// second hidden prefill after the UI has returned to idle. Besides
    /// wasting work, that hidden generation owns the solo-generation lease and
    /// makes the next chat appear permanently queued. Errors are excluded for
    /// the same reason: the failed prompt is not a stable checkpoint to
    /// precompute. Tool transcripts are also excluded: the real tool-loop
    /// turns already store SSD-L2 blocks, while the post-success hidden
    /// completed-transcript warm-up can cold-prefill a large tool history and
    /// block the next visible user turn.
    func handleRunCompleted(
        session: ChatWarmupSessionContext,
        wasCancelled: Bool,
        hadError: Bool,
        hadToolActivity: Bool = false
    ) {
        guard !wasCancelled, !hadError, !hadToolActivity else {
            cancelScheduledWarmup()
            return
        }
        scheduleWarmup(session: session)
    }

    /// True when a send must run the async pre-send handshake first
    /// (model switch settling or a warm-up generation in flight).
    /// When false, sends can dispatch synchronously — preserving the
    /// "user turn is appended synchronously inside send()" contract.
    var needsPreSendHandshake: Bool {
        retiringWork != nil
            || activeModelSwitch != nil
            || inFlightWarmup != nil
            || requiredContextWarmup != nil
    }

    /// Drop a scheduled-but-not-started warm-up so it can't fire mid-run.
    func cancelScheduledWarmup() {
        scheduleTask?.cancel()
        scheduleTask = nil
        scheduleTaskID = nil
        scheduledActivationID = nil
        cancelSessionActivation()
    }

    /// Cancel speculative work owned by a user-stopped pre-send handshake.
    ///
    /// Keep active switch / warm-up tasks tracked until they actually unwind:
    /// the next send must await their residency and generation leases rather
    /// than racing work that ignored cooperative cancellation. `switchEpoch`
    /// prevents a suspended switch from scheduling a hidden warm-up when it
    /// resumes after Stop.
    func cancelPendingWorkForUserStop() {
        let hadPendingWork =
            scheduleTask != nil
            || activeModelSwitch != nil
            || inFlightWarmup != nil
            || requiredContextWarmup != nil
            || sessionActivation != nil
        guard hadPendingWork else { return }

        switchEpoch &+= 1
        scheduleTask?.cancel()
        scheduleTask = nil
        scheduleTaskID = nil
        scheduledActivationID = nil
        activeModelSwitch?.cancel()
        inFlightWarmup?.cancel()
        requiredContextWarmup?.cancel()
        cancelSessionActivation()
        userIntentWarmupModel = nil
        warmedFingerprint = nil
        state = .cold
    }

    /// Cancel every speculative load owned by this chat before the user
    /// explicitly unloads its selected model. Unlike an idle-policy eviction,
    /// an explicit unload is a durable user action for the current idle
    /// lifecycle: a scheduled activation, model-switch warm-up, or post-run
    /// re-warm must not immediately load the model again behind the inspector.
    ///
    /// `reset()` keeps any cancellation unwind tracked in `retiringWork`, so a
    /// later real send still waits for the old warm-up's generation lease
    /// before loading the model on demand.
    func cancelPendingWorkForExplicitModelUnload() {
        reset()
    }

    /// Wait for an in-flight warm-up generation to finish. Called before a
    /// real send: cancelling a running warm-up would discard its partial
    /// prefill (vmlx stores the cache post-generation), so waiting is what
    /// makes the real request prefix-hit — the effective "resume".
    func awaitInFlightWarmup() async {
        await inFlightWarmup?.value
    }

    /// Wait for a prompt-shape rewarm that the next send depends on.
    func awaitRequiredContextWarmup() async {
        await requiredContextWarmup?.value
    }

    // MARK: - Private

    private func shouldAttemptWarmup(session: ChatWarmupSessionContext) -> Bool {
        guard !isShutDown else { return false }
        guard ChatConfigurationStore.load().warmModelsOnLoad else { return false }
        // Never load the new model while a switch is still settling — the
        // switch task itself schedules the warm-up once eviction completes,
        // and loading early would race the old model's teardown.
        guard activeModelSwitch == nil else { return false }
        guard let model = session.selectedModel, !model.isEmpty else { return false }
        guard session.selectedModelIsLocal, !session.isRemoteAgentTarget else { return false }
        guard !session.isStreaming else { return false }
        guard !session.isImageGenerationModel(model) else { return false }
        if ChatWindowManager.shared.isAnyWindowStreamingLocalModel { return false }
        return true
    }

    private func cancelSessionActivation() {
        sessionActivationID = nil
        sessionActivation?.cancel()
        sessionActivation = nil
        activationRecovery = nil
    }

    /// Apply a typed residency snapshot if it is not older than the newest
    /// state already observed. Activation is allowed to consume an equal
    /// revision because its atomic runtime reply may additionally carry the
    /// exact in-flight idle-decision identity absent from the notification.
    @discardableResult
    private func acceptResidencySnapshot(
        _ snapshot: ModelRuntimeResidencySnapshot,
        selectedModel: String?,
        allowDuplicateRevision: Bool = false
    ) -> Bool {
        // The residency-backed dot state follows the newest snapshot even
        // when the warm-claim machinery below rejects it as a duplicate:
        // an equal-revision snapshot carries the same names, and the
        // selected model may have changed since they were last evaluated.
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
    /// runtime notification arrives. Without this, a freshly opened chat has
    /// no basis for the dot until the first residency change.
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

    private func performWarmup(session: ChatWarmupSessionContext) async {
        guard shouldAttemptWarmup(session: session) else { return }

        await retiringWork?.value
        guard !Task.isCancelled else { return }
        guard shouldAttemptWarmup(session: session) else { return }

        // Coalesce: let any in-flight warm-up finish first, then decide
        // whether its result already covers the current payload.
        if let inflight = inFlightWarmup {
            await inflight.value
        }
        guard !Task.isCancelled else { return }
        guard shouldAttemptWarmup(session: session) else { return }

        guard let payload = await session.makeWarmupPayload() else { return }
        guard !Task.isCancelled else { return }

        if warmedFingerprint == payload.fingerprint {
            state = .warm
            return
        }

        // RAM gate: never proactively load a model whose projection exceeds
        // the hard ceiling (documented `modelLoadRAMHardThreshold`) or that
        // outright exceeds physical memory. The send path stays gated by the
        // input card's red banner, which tells the user why; a nil projection
        // (model already resident, or size unknown) proceeds normally.
        if let feasibility = await projectedLoadFeasibility(payload.model),
            feasibility.loadPressureSeverity == .block
        {
            state = .cold
            debugLog(
                "[ChatWarmup] skipped model=\(payload.model): projected load "
                    + "\(feasibility.projectedBytes)B exceeds hard limit \(feasibility.hardLimitBytes)B"
            )
            return
        }
        guard !Task.isCancelled else { return }
        guard shouldAttemptWarmup(session: session) else { return }

        // Speculative warm-ups must not evict. Loading a non-resident model
        // under strict single-model residency evicts whoever IS resident —
        // observed live as a launch-time warm-up for the restored UI
        // selection unloading the 94 GB model an API client had just
        // loaded. Only the warm-up that follows the user's own model pick
        // may displace a resident model.
        //
        // Resolved ONCE here and threaded down, so the early gate below and the
        // load intent in `runWarmupGeneration` can never disagree about whether
        // this warm-up carries the user's intent. Do not preflight the
        // runtime's load-in-flight state here: that snapshot is stale after
        // the actor hop and made a new chat permanently skip its static-prefix
        // warm-up while the same model was still finishing a cancelled prior
        // warm-up. The background load intent below is the atomic gate: it
        // coalesces a same-model load and refuses a conflicting load before it
        // can evict or cancel anything.
        // Consume the one-shot pick grant before any further suspension. If a
        // real send cancels this warm-up, the grant must not survive for a
        // later speculative re-warm and regain permission to evict a model.
        let userIntent = consumeUserIntent(for: payload.model)
        if !userIntent {
            let hasOtherResidentModel = await hasResidentModelOther(payload.model)
            guard !Task.isCancelled else { return }
            guard shouldAttemptWarmup(session: session) else { return }

            if hasOtherResidentModel {
                state = .cold
                debugLog(
                    "[ChatWarmup] skipped model=\(payload.model): a different model is resident and this warm-up lacks user intent"
                )
                return
            }
        }

        state = .warming
        let id = UUID()
        let task = Task { @MainActor in
            await runWarmupGeneration(
                session: session,
                payload: payload,
                id: id,
                userIntent: userIntent
            )
        }
        inFlightWarmup = task
        inFlightWarmupID = id
        await task.value
        if inFlightWarmupID == id {
            inFlightWarmup = nil
            inFlightWarmupID = nil
        }
    }

    /// Claim the one-shot "the user picked this model by hand" grant, if this
    /// warm-up is the one it was issued for. Returns `true` at most once per
    /// pick: the grant authorizes a single warm-up to displace a resident model,
    /// and every later re-warm of the same model is speculative again.
    ///
    /// Only consumed on the path that actually proceeds to warm up. A warm-up
    /// refused for lacking intent never had the grant, so there is nothing to
    /// consume and nothing is lost.
    private func consumeUserIntent(for model: String) -> Bool {
        guard userIntentWarmupModel == model else { return false }
        userIntentWarmupModel = nil
        return true
    }

    private func runWarmupGeneration(
        session: ChatWarmupSessionContext,
        payload: ChatWarmupPayload,
        id: UUID,
        userIntent: Bool
    ) async {
        // `.auto` renders the same tokenizer tool specs as a real send's
        // resolved tool choice (`.auto`/`.required` are byte-identical in
        // `makeTokenizerTools`), keeping the prompt prefix stable.
        var request = ChatCompletionRequest(
            model: payload.model,
            messages: payload.messages,
            temperature: 0.0,
            max_tokens: 1,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: payload.tools,
            tool_choice: payload.tools == nil ? nil : .auto,
            session_id: nil,
            suppressProgressUI: true
        )
        // Prompt-affecting request options must mirror the real send exactly
        // (see `ChatWarmupPayload.modelOptions`).
        request.modelOptions = payload.modelOptions
        request.cacheStableSystemPrefix = payload.cacheStableSystemPrefix
        // Prefill only up to the canonical history boundary — the prompt
        // rendered WITHOUT the generation prompt. The KV stored for that
        // token sequence is an exact prefix of the next real send, which is
        // what makes the send's cache lookup hit (critical for
        // sliding-window models like Gemma 4, whose caches cannot be
        // trimmed back to a boundary at store time).
        request.warmupPrefill = true
        // A warm-up that follows the user's own model pick carries their intent
        // and may displace a resident model. A speculative one (launch-time
        // restore of the last UI selection, an idle re-warm) may not — that is
        // the warm-up that was observed unloading a 94 GB model an API client
        // had just finished loading. The runtime enforces this atomically, at
        // the eviction itself; the early-outs above are only a fast path.
        request.backgroundModelLoad = !userIntent

        let startedAt = Date()
        let engine = session.makeWarmupEngine()
        // The runtime layers clear the per-model progress entry on their
        // normal finish paths; this covers cancellation/early-throw paths
        // where no finish event ever fires.
        defer { WarmupProgressHub.shared.finish(model: payload.model) }
        do {
            let stream = try await engine.streamChat(request: request)
            for try await _ in stream { /* discard warm-up output */  }
            // Some engines finish normally even after the consumer task was
            // cancelled. A user Stop must not let that late completion
            // resurrect the green warm claim for an abandoned pre-send
            // handshake.
            guard !Task.isCancelled else { return }
            // Stale-writer guard: a reset() (chat cleared / agent switched)
            // during the generation dropped this warm-up's claim; its result
            // must not resurrect a warm dot for a payload that no longer
            // reflects the session.
            guard inFlightWarmupID == id else { return }
            warmedFingerprint = payload.fingerprint
            state = .warm
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog("[ChatWarmup] warmed model=\(payload.model) elapsedMs=\(ms)")
        } catch {
            guard inFlightWarmupID == id else { return }
            warmedFingerprint = nil
            state = .cold
            guard !Task.isCancelled else { return }
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugLog("[ChatWarmup] failed model=\(payload.model) elapsedMs=\(ms) error=\(error)")
        }
    }
}
