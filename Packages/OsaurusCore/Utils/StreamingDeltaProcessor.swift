//
//  StreamingDeltaProcessor.swift
//  osaurus
//
//  Streaming delta processing pipeline used by ChatView. Handles delta
//  buffering and per-frame UI sync.
//
//  Reasoning routing is owned by the engine layer:
//    - Local MLX models: vmlx-swift's `BatchEngine.generate` emits
//      `Generation.reasoning(String)` deltas on a dedicated channel.
//      `GenerationEventMapper` translates each one to
//      `ModelRuntimeEvent.reasoning(_:)`, which `streamWithTools`
//      encodes as a `StreamingReasoningHint` sentinel.
//    - Remote providers: `RemoteProviderService` emits
//      `StreamingReasoningHint.encode(_:)` for streamed `reasoning_content`.
//  ChatView decodes the sentinel and forwards the text to
//  `receiveReasoning(_:)`, which appends to the Think panel.
//

import Foundation

/// Processes streaming LLM deltas into a ChatTurn with buffering and
/// throttled UI updates.
@MainActor
final class StreamingDeltaProcessor {

    // MARK: - State

    private var turn: ChatTurn
    private let onSync: (() -> Void)?

    /// Pending (unrevealed) deltas held as a character array with a head
    /// cursor. Draining advances `bufferHead` instead of rebuilding the
    /// string, so paced reveal of a large burst is O(total) — the previous
    /// `String(deltaBuffer.dropFirst(take))` rebuilt the whole remainder on
    /// every 16ms tick (O(n²)), and `deltaBuffer.count` walked the grapheme
    /// boundaries on every delta and tick. Both showed up as main-thread
    /// hangs while streaming long responses.
    private var deltaBuffer: [Character] = []
    private var bufferHead = 0

    /// Fallback timer — safety net for push-based consumers where no more
    /// deltas may arrive to trigger an inline flush.
    private var flushTimer: Timer?
    private static let fallbackFlushInterval: TimeInterval = 0.1

    /// Adaptive flush tuning — tracked lengths avoid calling String.count on large buffers
    private var contentLength = 0
    private var thinkingLength = 0
    private var flushIntervalMs: Double = 16
    private var maxBufferSize: Int = 64
    private var longestFlushMs: Double = 0

    /// Sync batching — flush parses tags and appends to turn,
    /// sync triggers UI update at a slower cadence to prevent churn.
    private var hasPendingContent = false
    private var lastSyncTime = Date()
    private var lastFlushTime = Date()
    private var syncCount = 0

    /// Continuation resumed by `pacingTick` the first time it observes
    /// an empty `deltaBuffer` after `finalize()` started awaiting. Lets
    /// the caller's `await processor.finalize()` block until the smooth
    /// streaming tail has fully typed out — without this, the processor
    /// deallocates the moment `send()` returns and the residual buffer
    /// is silently dropped.
    private var pacingDoneContinuation: CheckedContinuation<Void, Never>?

    /// Paced-reveal state. When `smoothStreamingEnabled` is on, incoming
    /// deltas accumulate in `deltaBuffer` but are revealed to the UI at a
    /// fixed rate via `pacingTimer` instead of flushing immediately. This
    /// hides server-side SSE micro-batching from remote providers and the
    /// peak burst behavior of ultra-fast providers (Cerebras-class), so
    /// streaming looks like a typewriter regardless of network delivery
    /// pattern. Local MLX at typical token rates is unaffected — its
    /// natural pace is below the reveal rate.
    private var pacingTimer: Timer?

    /// User-facing reveal rate floor. ~12 chars per 16ms ≈ 750 chars/s ≈
    /// ~180 tok/s display rate. Fast enough not to drag, slow enough that
    /// the fade-in is perceptible. Per-tick chunk size scales up
    /// adaptively when the pending buffer is large (see `pacingTick`).
    private static let pacingTickInterval: TimeInterval = 0.016
    private static let pacingCharsPerTick: Int = 12

    /// Number of pacing ticks (~16ms each) we aim to drain a fully-arrived
    /// burst over. 60 ticks ≈ 1 second. Smaller bursts paced at the
    /// natural floor rate finish sooner; larger ones accelerate to stay
    /// within this window. Tuned so that even a 4000-char response after
    /// finalize() drains in roughly 1s without feeling rushed.
    private static let pacingDrainTicks: Int = 60

    /// Reads `chatSmoothStreamingEnabled` from `UserDefaults` (default
    /// true). Cheap to re-read per delta — `UserDefaults.bool(forKey:)`
    /// is an in-memory dictionary lookup.
    private var smoothStreamingEnabled: Bool {
        UserDefaults.standard.object(forKey: "chatSmoothStreamingEnabled") as? Bool ?? true
    }

    // MARK: - Init

    init(
        turn: ChatTurn,
        onSync: (() -> Void)? = nil
    ) {
        self.turn = turn
        self.onSync = onSync
    }

    // MARK: - Public API

    /// Receive a streaming content delta. Buffers it, checks flush conditions
    /// inline (O(1) integer comparisons), and flushes if thresholds are met.
    func receiveDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        ChatPerfTrace.shared.count("stream.delta")
        ChatPerfTrace.shared.count("stream.deltaBytes", delta.utf8.count)
        deltaBuffer.append(contentsOf: delta)

        if smoothStreamingEnabled {
            startPacingTimerIfNeeded()
            return
        }

        let now = Date()
        let timeSinceFlush = now.timeIntervalSince(lastFlushTime) * 1000

        if pendingCount >= maxBufferSize || timeSinceFlush >= flushIntervalMs {
            flush()
            syncIfNeeded(now: now)
        }

        // Fallback timer in case no more deltas arrive
        if flushTimer == nil, pendingCount > 0 {
            flushTimer = Timer.scheduledTimer(
                withTimeInterval: Self.fallbackFlushInterval,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.flush()
                    self.syncToTurn()
                }
            }
        }
    }

    /// Receive a streaming reasoning (thinking) delta. Routed directly to the
    /// turn's thinking channel, which the Think panel renders. Reasoning text
    /// arrives via the engine's parsed reasoning channel — no tag scanning
    /// happens here, so partial `<think>` fragments cannot leak.
    func receiveReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        appendThinking(text)
        let now = Date()
        syncIfNeeded(now: now)
    }

    /// Force-flush all buffered deltas to the turn's content channel.
    func flush() {
        invalidateTimer()
        guard pendingCount > 0 else { return }

        let flushStart = Date()
        let textToProcess = consume(pendingCount)

        appendContent(textToProcess)

        lastFlushTime = Date()
        let flushMs = lastFlushTime.timeIntervalSince(flushStart) * 1000
        if flushMs > longestFlushMs { longestFlushMs = flushMs }
    }

    /// Finalize streaming: drain any remaining buffer and sync to UI.
    ///
    /// In smooth-streaming mode the residual `deltaBuffer` continues to
    /// type out via the pacing timer. We `await` here until that buffer
    /// is fully drained — without the await, this processor instance
    /// deallocates the moment `send()` returns, the pacing timer's
    /// `[weak self]` closure goes nil on the next tick, and the rest of
    /// the response is silently dropped (the visible text ends
    /// mid-sentence even though the model produced the full content).
    func finalize() async {
        invalidateTimer()

        if smoothStreamingEnabled && pendingCount > 0 {
            startPacingTimerIfNeeded()
            // Block here until `pacingTick` empties the buffer and
            // resumes us. The processor stays alive for the duration
            // because the surrounding `send(...)` is awaiting.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.pacingDoneContinuation = continuation
            }
        } else if pendingCount > 0 {
            // Non-smooth path: drain immediately.
            stopPacingTimer()
            appendContent(consume(pendingCount))
        }
        syncToTurn()
    }

    /// Reset for a new streaming session with a new turn.
    func reset(turn: ChatTurn) {
        invalidateTimer()
        stopPacingTimer()
        self.turn = turn
        clearBuffer()
        contentLength = 0
        thinkingLength = 0
        flushIntervalMs = 16
        maxBufferSize = 64
        longestFlushMs = 0
        hasPendingContent = false
        lastSyncTime = Date()
        lastFlushTime = Date()
        syncCount = 0
    }

    // MARK: - Private

    private func invalidateTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
    }

    private func startPacingTimerIfNeeded() {
        guard pacingTimer == nil else { return }
        pacingTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pacingTickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pacingTick()
            }
        }
    }

    private func stopPacingTimer() {
        pacingTimer?.invalidate()
        pacingTimer = nil
    }

    /// Drain a chunk from the head of `deltaBuffer` into the turn + push
    /// one sync. Chunk size adapts to the pending buffer so a giant
    /// response that arrived in one shot still finishes typing out within
    /// ~2 seconds, while normal bursts stay at the perceptible floor rate.
    /// Stops the timer once the buffer is drained so it doesn't idle-tick
    /// between bursts.
    private func pacingTick() {
        let pending = pendingCount
        if pending == 0 {
            stopPacingTimer()
            // Wake up `finalize()` if it's waiting for the tail to drain.
            if let cont = pacingDoneContinuation {
                pacingDoneContinuation = nil
                cont.resume()
            }
            return
        }
        let scaled = pending / Self.pacingDrainTicks
        let take = min(pending, max(Self.pacingCharsPerTick, scaled))
        appendContent(consume(take))
        lastFlushTime = Date()
        syncToTurn()
    }

    /// Pending (unrevealed) character count. O(1) — replaces the O(n)
    /// `String.count` that ran on every delta and pacing tick.
    private var pendingCount: Int { deltaBuffer.count - bufferHead }

    /// Take up to `n` characters from the head of the pending region,
    /// advancing the cursor rather than rebuilding the buffer. Once fully
    /// drained the backing storage is released so a long stream doesn't
    /// retain every consumed character.
    private func consume(_ n: Int) -> String {
        let end = min(bufferHead + n, deltaBuffer.count)
        let chunk = String(deltaBuffer[bufferHead ..< end])
        bufferHead = end
        if bufferHead == deltaBuffer.count { clearBuffer() }
        return chunk
    }

    private func clearBuffer() {
        deltaBuffer.removeAll(keepingCapacity: true)
        bufferHead = 0
    }

    private func appendContent(_ s: String) {
        guard !s.isEmpty else { return }
        turn.appendContent(s)
        contentLength += s.count
        hasPendingContent = true
    }

    private func appendThinking(_ s: String) {
        guard !s.isEmpty else { return }
        turn.appendThinking(s)
        thinkingLength += s.count
        hasPendingContent = true
    }

    private func syncToTurn() {
        guard hasPendingContent else { return }
        syncCount += 1
        ChatPerfTrace.shared.count("stream.syncToTurn")
        turn.notifyContentChanged()
        hasPendingContent = false
        lastSyncTime = Date()
        onSync?()
    }

    private func syncIfNeeded(now: Date) {
        let syncIntervalMs: Double = 16

        let timeSinceSync = now.timeIntervalSince(lastSyncTime) * 1000
        if (syncCount == 0 && hasPendingContent)
            || (timeSinceSync >= syncIntervalMs && hasPendingContent)
        {
            syncToTurn()
        }
    }

}
