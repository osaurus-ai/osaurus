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
    /// Identity of what this payload warms: model + static prefix hash +
    /// history shape + options. A fingerprint match means the KV prefix is
    /// already hot.
    let fingerprint: String
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

    @Published private(set) var state: WarmState = .cold

    /// True when the UI should render the green "warm" dot.
    var isWarmForDisplay: Bool { state == .warm }

    private var warmedFingerprint: String?
    private var scheduleTask: Task<Void, Never>?
    private var inFlightWarmup: Task<Void, Never>?
    private var inFlightWarmupID: UUID?
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
    /// Monotonic counter bumped by every switch-affecting entry point
    /// (selection change, reset). Handlers that suspend re-check it
    /// afterwards so a stale resume can't cancel or restore state installed
    /// by a newer event.
    private var switchEpoch: UInt64 = 0

    /// True once the owning window began teardown. `session.stop()` during
    /// window close runs the normal run-completed cleanup, which schedules a
    /// fresh warm-up — pointless model work for a session that is about to be
    /// deallocated. Once shut down, all scheduling entry points are inert.
    private var isShutDown = false

    deinit {
        scheduleTask?.cancel()
        activeModelSwitch?.cancel()
        inFlightWarmup?.cancel()
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
        scheduleTask = nil
        activeModelSwitch = nil
        activeModelSwitchID = nil
        inFlightWarmup = nil
        inFlightWarmupID = nil
        warmedFingerprint = nil
        state = .cold
    }

    /// Drop the warm claim (dot leaves green) without cancelling in-flight
    /// work. Called when the prompt shape changes (tools / agent / soul).
    func invalidateWarmState() {
        warmedFingerprint = nil
        if state == .warm { state = .cold }
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
        let previousSwitch = activeModelSwitch
        activeModelSwitchID = switchID
        activeModelSwitch = Task { @MainActor in
            // Serialize with a still-running earlier switch so evictions
            // never interleave, then wait for the cancelled warm-up to
            // actually unwind — its generation lease would otherwise make
            // the runtime skip (not defer) the old model's unload.
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

    // MARK: - Warm-up

    func scheduleWarmup(
        session: ChatWarmupSessionContext,
        debounce: Duration = scheduleDebounce
    ) {
        guard shouldAttemptWarmup(session: session) else {
            if !ChatConfigurationStore.load().warmModelsOnLoad {
                state = .cold
            }
            return
        }

        if state == .cold { state = .warming }

        scheduleTask?.cancel()
        scheduleTask = Task { @MainActor in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Task.isCancelled else { return }
            await performWarmup(session: session)
        }
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
        activeModelSwitch != nil || inFlightWarmup != nil
    }

    /// Drop a scheduled-but-not-started warm-up so it can't fire mid-run.
    func cancelScheduledWarmup() {
        scheduleTask?.cancel()
        scheduleTask = nil
    }

    /// Wait for an in-flight warm-up generation to finish. Called before a
    /// real send: cancelling a running warm-up would discard its partial
    /// prefill (vmlx stores the cache post-generation), so waiting is what
    /// makes the real request prefix-hit — the effective "resume".
    func awaitInFlightWarmup() async {
        await inFlightWarmup?.value
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

    private func performWarmup(session: ChatWarmupSessionContext) async {
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
        let userIntent = consumeUserIntent(for: payload.model)

        if !userIntent,
            await ModelRuntime.shared.hasResidentModelOther(than: payload.model)
        {
            state = .cold
            debugLog(
                "[ChatWarmup] skipped model=\(payload.model): a different model is resident and this warm-up lacks user intent"
            )
            return
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
