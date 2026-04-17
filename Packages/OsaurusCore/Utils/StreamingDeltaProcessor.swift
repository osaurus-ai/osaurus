//
//  StreamingDeltaProcessor.swift
//  osaurus
//
//  Shared streaming delta processing pipeline used by both ChatView (chat mode)
//  and WorkSession (work mode). Handles delta buffering, <think> tag parsing,
//  adaptive flush tuning, and throttled UI sync.
//

import Foundation
@preconcurrency import MLXLMCommon

/// Processes streaming LLM deltas into a ChatTurn with buffering,
/// thinking tag parsing, and throttled UI updates.
@MainActor
final class StreamingDeltaProcessor {

    // MARK: - State

    private var turn: ChatTurn
    private let onSync: (() -> Void)?

    /// Model-specific delta preprocessing (resolved once from modelId + options)
    private let modelId: String
    private let modelOptions: [String: ModelOptionValue]
    private var middleware: StreamingMiddleware?

    /// Delta buffering
    private var deltaBuffer = ""

    /// Fallback timer — safety net for push-based consumers (e.g. WorkSession
    /// delegate callbacks) where no more deltas may arrive to trigger an inline flush.
    private var flushTimer: Timer?
    private static let fallbackFlushInterval: TimeInterval = 0.1

    /// Thinking tag parsing
    private var isInsideThinking = false
    private var pendingTagBuffer = ""

    /// vmlx-provided reasoning parser. Set when the active model is
    /// JANG-stamped (the JANG converter emits a `capabilities.reasoning_parser`
    /// field that `ParserResolution.reasoning` maps to a concrete parser).
    /// When non-nil, we route through `feed`/`flush` instead of the in-house
    /// `<think>` tag scanner below. Non-JANG models keep the old scanner so
    /// their behaviour is untouched by this change.
    private var vmlxReasoningParser: ReasoningParser?

    /// Adaptive flush tuning — tracked lengths avoid calling String.count on large buffers
    private var contentLength = 0
    private var thinkingLength = 0
    private var flushIntervalMs: Double = 50
    private var maxBufferSize: Int = 256
    private var longestFlushMs: Double = 0

    /// Sync batching — flush parses tags and appends to turn,
    /// sync triggers UI update at a slower cadence to prevent churn.
    private var hasPendingContent = false
    private var lastSyncTime = Date()
    private var lastFlushTime = Date()
    private var syncCount = 0

    // MARK: - Init

    init(
        turn: ChatTurn,
        modelId: String = "",
        modelOptions: [String: ModelOptionValue] = [:],
        vmlxReasoningParser: ReasoningParser? = nil,
        onSync: (() -> Void)? = nil
    ) {
        self.turn = turn
        self.modelId = modelId
        self.modelOptions = modelOptions
        self.onSync = onSync
        self.middleware = StreamingMiddlewareResolver.resolve(for: modelId, modelOptions: modelOptions)
        // Non-nil only when the caller resolved a JANG-stamped model AND
        // the user hasn't toggled thinking off — see callers in ChatView /
        // WorkSession. When non-nil, `parseAndRoute` defers to vmlx's
        // parser instead of the in-house `<think>` scanner.
        self.vmlxReasoningParser = vmlxReasoningParser
    }

    // MARK: - Public API

    /// Receive a streaming delta. Buffers it, checks flush conditions inline
    /// (O(1) integer comparisons), and flushes if thresholds are met.
    func receiveDelta(_ delta: String) {
        guard !delta.isEmpty else { return }

        let processed = middleware?.process(delta) ?? delta
        guard !processed.isEmpty else { return }
        deltaBuffer += processed

        let now = Date()
        let timeSinceFlush = now.timeIntervalSince(lastFlushTime) * 1000
        recomputeFlushTuning()

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

    /// Force-flush all buffered deltas: parse thinking tags, route to turn.
    func flush() {
        invalidateTimer()
        guard !deltaBuffer.isEmpty else { return }

        let flushStart = Date()
        var textToProcess = pendingTagBuffer + deltaBuffer
        pendingTagBuffer = ""
        deltaBuffer = ""

        // JANG-stamped models: delegate reasoning segmentation to vmlx's
        // `ReasoningParser` instead of the in-house scanner below. vmlx is
        // the authoritative source on which tags each family uses, and
        // keeping the logic in one place prevents osaurus and vmlx from
        // disagreeing on partial-tag handling for new families.
        if vmlxReasoningParser != nil {
            feedThroughVMLXParser(&textToProcess)
        } else {
            parseAndRoute(&textToProcess)
        }

        lastFlushTime = Date()
        let flushMs = lastFlushTime.timeIntervalSince(flushStart) * 1000
        if flushMs > longestFlushMs { longestFlushMs = flushMs }
    }

    /// Drains `text` through the vmlx reasoning parser, appending each
    /// segment to the correct channel on the turn. `text` is consumed.
    private func feedThroughVMLXParser(_ text: inout String) {
        guard var parser = vmlxReasoningParser else {
            appendContent(text)
            text = ""
            return
        }
        let segments = parser.feed(text)
        vmlxReasoningParser = parser  // value type — write back
        text = ""
        for segment in segments {
            switch segment {
            case .content(let s):
                appendContent(s)
                isInsideThinking = false
            case .reasoning(let s):
                appendThinking(s)
                isInsideThinking = true
            }
        }
    }

    /// Finalize streaming: drain remaining buffers and partial tags, sync to UI.
    func finalize() {
        invalidateTimer()

        if !deltaBuffer.isEmpty || !pendingTagBuffer.isEmpty {
            var remaining = pendingTagBuffer + deltaBuffer
            pendingTagBuffer = ""
            deltaBuffer = ""

            if vmlxReasoningParser != nil {
                // Push whatever's left through feed, then flush once so the
                // parser's internal hold-back buffer emits. Anything still
                // buffered at flush time is routed to the current-mode
                // channel by `ReasoningParser.flush` itself.
                feedThroughVMLXParser(&remaining)
                if var parser = vmlxReasoningParser {
                    let segments = parser.flush()
                    vmlxReasoningParser = parser
                    for segment in segments {
                        switch segment {
                        case .content(let s):    appendContent(s)
                        case .reasoning(let s):  appendThinking(s)
                        }
                    }
                }
            } else {
                // If the stream ended on an unresolved partial `<think` or
                // `</think` fragment, drop it rather than leaking literal
                // tag characters into user-visible content — the completing
                // byte never arrived.
                let lowered = remaining.lowercased()
                if let partial = Self.closePartials.first(where: { lowered.hasSuffix($0) })
                    ?? Self.openPartials.first(where: { lowered.hasSuffix($0) })
                {
                    remaining = String(remaining.dropLast(partial.count))
                }

                if !remaining.isEmpty {
                    if isInsideThinking {
                        appendThinking(remaining)
                    } else {
                        appendContent(remaining)
                    }
                }
            }
        }

        syncToTurn()
    }

    /// Reset for a new streaming session with a new turn.
    func reset(turn: ChatTurn) {
        invalidateTimer()
        self.turn = turn
        deltaBuffer = ""
        isInsideThinking = false
        pendingTagBuffer = ""
        contentLength = 0
        thinkingLength = 0
        flushIntervalMs = 50
        maxBufferSize = 256
        longestFlushMs = 0
        hasPendingContent = false
        lastSyncTime = Date()
        lastFlushTime = Date()
        syncCount = 0
        middleware = StreamingMiddlewareResolver.resolve(for: modelId, modelOptions: modelOptions)
        // Fresh parser buffer per turn — the old one may have held back a
        // partial `<think` prefix at the end of the previous turn that
        // would otherwise splice into the next turn's opening bytes.
        if vmlxReasoningParser != nil {
            vmlxReasoningParser = ReasoningParser()
        }
    }

    // MARK: - Private

    private func invalidateTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
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
        turn.notifyContentChanged()
        hasPendingContent = false
        lastSyncTime = Date()
        onSync?()
    }

    private func syncIfNeeded(now: Date) {
        let totalChars = contentLength + thinkingLength
        let syncIntervalMs: Double =
            switch totalChars {
            case 0 ..< 2_000: 100
            case 2_000 ..< 5_000: 150
            case 5_000 ..< 10_000: 200
            default: 250
            }

        let timeSinceSync = now.timeIntervalSince(lastSyncTime) * 1000
        if (syncCount == 0 && hasPendingContent)
            || (timeSinceSync >= syncIntervalMs && hasPendingContent)
        {
            syncToTurn()
        }
    }

    private func recomputeFlushTuning() {
        let totalChars = contentLength + thinkingLength

        switch totalChars {
        case 0 ..< 2_000:
            flushIntervalMs = 50; maxBufferSize = 256
        case 2_000 ..< 8_000:
            flushIntervalMs = 75; maxBufferSize = 512
        case 8_000 ..< 20_000:
            flushIntervalMs = 100; maxBufferSize = 768
        default:
            flushIntervalMs = 150; maxBufferSize = 1024
        }

        if longestFlushMs > 50 {
            flushIntervalMs = min(200, flushIntervalMs * 1.5)
        }
    }

    // MARK: - Thinking Tag Parsing

    /// Partial tag prefixes for `<think>` and `</think>`, longest first.
    private static let openPartials = ["<think", "<thin", "<thi", "<th", "<t", "<"]
    private static let closePartials = ["</think", "</thin", "</thi", "</th", "</t", "</"]

    private func parseAndRoute(_ text: inout String) {
        while !text.isEmpty {
            if isInsideThinking {
                if let closeRange = text.range(of: "</think>", options: .caseInsensitive) {
                    appendThinking(String(text[..<closeRange.lowerBound]))
                    text = String(text[closeRange.upperBound...])
                    isInsideThinking = false
                } else if let partial = Self.closePartials.first(where: { text.lowercased().hasSuffix($0) }) {
                    appendThinking(String(text.dropLast(partial.count)))
                    pendingTagBuffer = String(text.suffix(partial.count))
                    text = ""
                } else {
                    appendThinking(text)
                    text = ""
                }
            } else {
                // Look up both tags so we can choose the earliest one deterministically.
                let openRange = text.range(of: "<think>", options: .caseInsensitive)
                let closeRange = text.range(of: "</think>", options: .caseInsensitive)

                // Prefer the normal open-tag path whenever `<think>` appears at or
                // before the next `</think>` — otherwise a buffered opener tag
                // would get vacuumed into the thinking channel as literal text
                // by the retroactive branch.
                let takeOpen: Bool = {
                    switch (openRange, closeRange) {
                    case (nil, _): return false
                    case (_, nil): return true
                    case (let o?, let c?): return o.lowerBound <= c.lowerBound
                    }
                }()

                if takeOpen, let openRange {
                    appendContent(String(text[..<openRange.lowerBound]))
                    text = String(text[openRange.upperBound...])
                    isInsideThinking = true
                    continue
                }

                // Retroactive thinking: model emitted `</think>` without opening
                // a `<think>` block (either the template didn't inject it, or the
                // user disabled reasoning but this model reasons anyway). Move
                // everything we've accumulated — prior content on the turn plus
                // the in-buffer text up to the close tag — into the thinking
                // channel, then continue parsing remainder as normal content.
                if let closeRange {
                    let tailBeforeTag = String(text[..<closeRange.lowerBound])
                    let movedCount = turn.moveContentToThinking(tail: tailBeforeTag)
                    if movedCount > 0 {
                        thinkingLength += movedCount
                        contentLength = 0
                        hasPendingContent = true
                    }
                    text = String(text[closeRange.upperBound...])
                    continue
                }

                // No full tag in this chunk — check for partial tags at the tail
                // so a split tag across delta boundaries doesn't leak bytes.
                let lower = text.lowercased()
                if let partialClose = Self.closePartials.first(where: { lower.hasSuffix($0) }) {
                    appendContent(String(text.dropLast(partialClose.count)))
                    pendingTagBuffer = String(text.suffix(partialClose.count))
                    text = ""
                } else if let partial = Self.openPartials.first(where: { lower.hasSuffix($0) }) {
                    appendContent(String(text.dropLast(partial.count)))
                    pendingTagBuffer = String(text.suffix(partial.count))
                    text = ""
                } else {
                    appendContent(text)
                    text = ""
                }
            }
        }
    }
}
