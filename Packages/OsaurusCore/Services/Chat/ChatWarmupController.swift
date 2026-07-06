//
//  ChatWarmupController.swift
//  osaurus
//
//  Proactive KV-cache warm-up for chat sessions: load the selected local
//  model and run a one-token prefill over the session's static prompt prefix
//  (system + tools + history, excluding the pending user turn) so the first
//  real send can prefix-hit and pay less time-to-first-token cost.
//
//  Also owns the debounced model-switch policy: under strict single-model
//  residency, eviction of the previous model is delayed ~2.5s so a quick
//  switch-back keeps the prior model resident with its KV/coordinator state.
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

    /// Debounce before acting on a model switch under strict single-model
    /// residency so a quick switch-back keeps the prior model's cache.
    static let modelSwitchDebounce: Duration = .milliseconds(2_500)
    /// Debounce coalescing fingerprint-invalidating warm-up retriggers.
    static let scheduleDebounce: Duration = .milliseconds(500)

    @Published private(set) var state: WarmState = .cold

    /// True when the UI should render the green "warm" dot.
    var isWarmForDisplay: Bool { state == .warm }

    private var warmedFingerprint: String?
    private var scheduleTask: Task<Void, Never>?
    private var modelSwitchTask: Task<Void, Never>?
    private var inFlightWarmup: Task<Void, Never>?
    private var inFlightWarmupID: UUID?
    /// Model selected before the pending debounced switch — the "switch back
    /// to this and nothing is lost" target.
    private var modelBeforePendingSwitch: String?
    /// Warm fingerprint held when the pending switch started, restored on a
    /// quick switch-back so the dot snaps straight back to green.
    private var fingerprintBeforePendingSwitch: String?
    /// Monotonic counter bumped by every switch-affecting entry point
    /// (selection change, flush, reset). Handlers that suspend re-check it
    /// afterwards so a stale resume can't cancel or restore state installed
    /// by a newer event.
    private var switchEpoch: UInt64 = 0

    deinit {
        scheduleTask?.cancel()
        modelSwitchTask?.cancel()
        inFlightWarmup?.cancel()
    }

    func reset() {
        switchEpoch &+= 1
        scheduleTask?.cancel()
        modelSwitchTask?.cancel()
        inFlightWarmup?.cancel()
        scheduleTask = nil
        modelSwitchTask = nil
        inFlightWarmup = nil
        inFlightWarmupID = nil
        warmedFingerprint = nil
        modelBeforePendingSwitch = nil
        fingerprintBeforePendingSwitch = nil
        state = .cold
    }

    /// Drop the warm claim (dot leaves green) without cancelling in-flight
    /// work. Called when the prompt shape changes (tools / agent / soul).
    func invalidateWarmState() {
        warmedFingerprint = nil
        if state == .warm { state = .cold }
    }

    // MARK: - Model switch

    /// Handle a model selection change: debounce eviction under strict
    /// single-model residency (quick switch-back keeps the old model's
    /// cache), evict-then-warm when the debounce fires, and skip eviction
    /// entirely under multi-model residency.
    func handleModelSelectionChange(
        session: ChatWarmupSessionContext,
        from previous: String?,
        to newModel: String?,
        performSwitch: @escaping @MainActor (_ evictOthers: Bool) async -> Void
    ) {
        Task { @MainActor in
            await self.handleModelSelectionChangeAsync(
                session: session,
                from: previous,
                to: newModel,
                performSwitch: performSwitch
            )
        }
    }

    private func handleModelSelectionChangeAsync(
        session: ChatWarmupSessionContext,
        from previous: String?,
        to newModel: String?,
        performSwitch: @escaping @MainActor (_ evictOthers: Bool) async -> Void
    ) async {
        switchEpoch &+= 1
        let epoch = switchEpoch
        // Quick switch-back inside the debounce window: the old model is
        // still resident (nothing was evicted yet), so cancel the pending
        // switch and restore the warm claim it had.
        if let newModel,
            modelSwitchTask != nil,
            newModel == modelBeforePendingSwitch,
            await ModelRuntime.shared.isResident(name: newModel)
        {
            // The residency check suspended; a newer selection change, send
            // flush, or reset may have replaced the pending-switch state this
            // branch is about to cancel/restore.
            guard epoch == switchEpoch else { return }
            modelSwitchTask?.cancel()
            modelSwitchTask = nil
            modelBeforePendingSwitch = nil
            let restored = fingerprintBeforePendingSwitch
            fingerprintBeforePendingSwitch = nil
            if let restored, restored.hasPrefix("\(newModel)|") {
                warmedFingerprint = restored
                state = .warm
            } else {
                invalidateWarmState()
                scheduleWarmup(session: session, debounce: .zero)
            }
            return
        }
        // Same staleness rule for the fall-through: if the residency check
        // above suspended and a newer event ran meanwhile, defer to it.
        guard epoch == switchEpoch else { return }

        let priorFingerprint = warmedFingerprint
        invalidateWarmState()
        modelSwitchTask?.cancel()
        modelSwitchTask = nil
        modelBeforePendingSwitch = nil
        fingerprintBeforePendingSwitch = nil

        guard let newModel, !newModel.isEmpty else { return }

        let policy =
            ServerConfigurationStore.load()?.modelEvictionPolicy ?? .strictSingleModel

        // Multi-model residency: nothing is ever evicted on switch, so
        // there is no cache to protect — load + warm the new model now.
        if policy == .manualMultiModel {
            await performSwitch(false)
            scheduleWarmup(session: session, debounce: .zero)
            return
        }

        // Strict single-model: debounce before evicting so a quick
        // switch-back keeps the prior model resident. Loading early is not
        // an option — `loadContainer` performs strict eviction itself, so
        // starting the new load would destroy the old cache immediately.
        modelBeforePendingSwitch = previous
        fingerprintBeforePendingSwitch = priorFingerprint
        state = .warming

        modelSwitchTask = Task { @MainActor in
            try? await Task.sleep(for: Self.modelSwitchDebounce)
            guard !Task.isCancelled else { return }
            modelSwitchTask = nil
            modelBeforePendingSwitch = nil
            fingerprintBeforePendingSwitch = nil
            await performSwitch(true)
            scheduleWarmup(session: session, debounce: .zero)
        }
    }

    /// Flush a pending model-switch debounce immediately (evict per policy).
    /// Called on send so the user never waits out the debounce timer.
    func flushPendingModelSwitch(
        performSwitch: @escaping @MainActor (_ evictOthers: Bool) async -> Void
    ) async {
        guard modelSwitchTask != nil else { return }
        switchEpoch &+= 1
        modelSwitchTask?.cancel()
        modelSwitchTask = nil
        modelBeforePendingSwitch = nil
        fingerprintBeforePendingSwitch = nil

        let policy =
            ServerConfigurationStore.load()?.modelEvictionPolicy ?? .strictSingleModel
        await performSwitch(policy == .strictSingleModel)
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

    /// True when a send must run the async pre-send handshake first
    /// (pending debounced model switch or a warm-up generation in flight).
    /// When false, sends can dispatch synchronously — preserving the
    /// "user turn is appended synchronously inside send()" contract.
    var needsPreSendHandshake: Bool {
        modelSwitchTask != nil || inFlightWarmup != nil
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
        guard ChatConfigurationStore.load().warmModelsOnLoad else { return false }
        // Never load the new model while a debounced switch is pending —
        // strict eviction inside `loadContainer` would tear down the old
        // model and defeat the switch-back grace period.
        guard modelSwitchTask == nil else { return false }
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

        state = .warming
        let id = UUID()
        let task = Task { @MainActor in
            await runWarmupGeneration(session: session, payload: payload, id: id)
        }
        inFlightWarmup = task
        inFlightWarmupID = id
        await task.value
        if inFlightWarmupID == id {
            inFlightWarmup = nil
            inFlightWarmupID = nil
        }
    }

    private func runWarmupGeneration(
        session: ChatWarmupSessionContext,
        payload: ChatWarmupPayload,
        id: UUID
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

        let startedAt = Date()
        let engine = session.makeWarmupEngine()
        // The runtime layers clear the per-model progress entry on their
        // normal finish paths; this covers cancellation/early-throw paths
        // where no finish event ever fires.
        defer { WarmupProgressHub.shared.finish(model: payload.model) }
        do {
            let stream = try await engine.streamChat(request: request)
            for try await _ in stream { /* discard warm-up output */ }
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
