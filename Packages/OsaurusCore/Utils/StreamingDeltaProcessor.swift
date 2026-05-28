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

/// Temporary pacing diagnostic logger — writes to /tmp/osaurus-pacing.log.
enum PacingLog {
    static let url = URL(fileURLWithPath: "/tmp/osaurus-pacing.log")
    private static let queue = DispatchQueue(label: "osaurus.pacing.log")
    nonisolated(unsafe) private static var sessionStartLogged = false
    static func log(_ msg: String) {
        let t = CFAbsoluteTimeGetCurrent()
        queue.async {
            if !sessionStartLogged {
                sessionStartLogged = true
                let header = "===== session start \(Date()) (CACurrentMediaTime=\(t)) =====\n"
                if let d = header.data(using: .utf8) {
                    try? d.write(to: url)
                }
            }
            let line = "[\(String(format: "%.4f", t))] \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path),
               let fh = try? FileHandle(forWritingTo: url) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// Processes streaming LLM deltas into a ChatTurn with buffering and
/// throttled UI updates.
@MainActor
final class StreamingDeltaProcessor {

    // MARK: - State

    private var turn: ChatTurn
    private let onSync: (() -> Void)?

    private var deltaBuffer = ""

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
        deltaBuffer += delta

        PacingLog.log("receiveDelta size=\(delta.count) bufferAfter=\(deltaBuffer.count) smooth=\(smoothStreamingEnabled) pacingTimerActive=\(pacingTimer != nil)")

        if smoothStreamingEnabled {
            startPacingTimerIfNeeded()
            return
        }

        let now = Date()
        let timeSinceFlush = now.timeIntervalSince(lastFlushTime) * 1000

        if deltaBuffer.count >= maxBufferSize || timeSinceFlush >= flushIntervalMs {
            flush()
            syncIfNeeded(now: now)
        }

        // Fallback timer in case no more deltas arrive
        if flushTimer == nil, !deltaBuffer.isEmpty {
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
        guard !deltaBuffer.isEmpty else { return }

        let flushStart = Date()
        let textToProcess = deltaBuffer
        deltaBuffer = ""

        appendContent(textToProcess)

        lastFlushTime = Date()
        let flushMs = lastFlushTime.timeIntervalSince(flushStart) * 1000
        if flushMs > longestFlushMs { longestFlushMs = flushMs }
    }

    /// Finalize streaming: drain any remaining buffer and sync to UI.
    ///
    /// In smooth-streaming mode we deliberately keep the pacing timer
    /// running so the buffered tail continues to type out at the same
    /// cadence as it did during streaming — otherwise small responses
    /// (which arrive entirely in one network burst, finalize ~60ms
    /// later) would show no animation at all, and long responses with
    /// big tail buffers would dump the last several hundred chars at
    /// once after a smooth start.
    func finalize() {
        PacingLog.log("finalize() called bufferSize=\(deltaBuffer.count) smooth=\(smoothStreamingEnabled) pacingTimerActive=\(pacingTimer != nil)")
        invalidateTimer()

        if smoothStreamingEnabled {
            // Sync whatever's already been appended (pre-pacing). Leave
            // the deltaBuffer alone — pacingTick will continue draining
            // it and stop the timer when empty.
            syncToTurn()
            if !deltaBuffer.isEmpty {
                startPacingTimerIfNeeded()
            }
            return
        }

        stopPacingTimer()
        if !deltaBuffer.isEmpty {
            let remaining = deltaBuffer
            deltaBuffer = ""
            PacingLog.log("finalize() DRAINED \(remaining.count) chars immediately")
            appendContent(remaining)
        }
        syncToTurn()
    }

    /// Reset for a new streaming session with a new turn.
    func reset(turn: ChatTurn) {
        invalidateTimer()
        stopPacingTimer()
        self.turn = turn
        deltaBuffer = ""
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
        PacingLog.log("startPacingTimer pending=\(deltaBuffer.count)")
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
        if pacingTimer != nil {
            PacingLog.log("stopPacingTimer pending=\(deltaBuffer.count)")
        }
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
        let pending = deltaBuffer.count
        if pending == 0 {
            PacingLog.log("pacingTick EMPTY → stop timer")
            stopPacingTimer()
            return
        }
        let scaled = pending / Self.pacingDrainTicks
        let take = min(pending, max(Self.pacingCharsPerTick, scaled))
        let chunk = String(deltaBuffer.prefix(take))
        deltaBuffer = String(deltaBuffer.dropFirst(take))
        PacingLog.log("pacingTick pending=\(pending) take=\(take) remaining=\(deltaBuffer.count)")
        appendContent(chunk)
        lastFlushTime = Date()
        syncToTurn()
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
