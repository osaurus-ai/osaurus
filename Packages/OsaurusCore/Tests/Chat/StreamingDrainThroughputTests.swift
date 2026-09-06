//
//  StreamingDrainThroughputTests.swift
//  osaurusTests
//
//  Synthetic reproduction of the chat streaming CONSUMER pipeline, measured
//  in-process so the display path can be timed without a model.
//
//  Background: a field measurement of `ChatTurn.completedAt` showed
//  27–30 tok/s for a 930-token answer whether the engine decoded at 31.6
//  tok/s (plain AR) or 47–56 tok/s (native MTP). The field logs for the same
//  runs put every one of those seconds UPSTREAM of the UI: the ChatEngine
//  stream wrapper (a detached task, before any UI code) received the MTP
//  deltas at 47.7/s and its last delta landed at +20.3 s, exactly where
//  vmlx's own decode clock ends (submit + 0.9 s TTFT + 19.7 s decode); the
//  remaining ~12.7 s to stream termination is vmlx's post-generation cache
//  store, which the osaurus adapter deliberately serialises ahead of `.info`.
//  The UI's stream loop ended 0.09 s after the wrapper's.
//
//  What the field logs could NOT show is whether the display itself also
//  lagged (900 deltas × 33 ms would coincidentally end inside that tail).
//  This harness answers that: it pushes a realistic 890-delta answer through
//  the real StreamingDeltaProcessor → ChatTurn → BlockMemoizer →
//  NativeMarkdownView (AppKit text layout + height measurement) pipeline at
//  100 and 300 deltas/s and asserts that the drain finishes within 1.2× the
//  producer's own wall time plus the smooth-streaming reveal tail, with
//  byte-identical content. It also pins coalescing correctness: order,
//  reasoning/content interleave, and finalize draining a burst.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct StreamingDrainThroughputTests {

    // MARK: - Fixtures

    /// The "count from 1 to 250" answer split the way a BPE stream delivers
    /// it: a comma, then a space + leading digit, then one delta per
    /// remaining digit. 250 numbers → 892 deltas over ~1,040 characters,
    /// matching the field run (847 content deltas, 893 chars).
    static func countingDeltas(upTo n: Int = 250) -> [String] {
        var deltas: [String] = []
        for i in 1 ... n {
            let digits = Array(String(i))
            if i > 1 { deltas.append(",") }
            deltas.append((i > 1 ? " " : "") + String(digits[0]))
            for d in digits.dropFirst() { deltas.append(String(d)) }
        }
        return deltas
    }

    /// Scoped override of the smooth-streaming user default.
    private struct SmoothStreamingOverride {
        private static let key = "chatSmoothStreamingEnabled"
        private let previous: Any?
        init(_ enabled: Bool) {
            previous = UserDefaults.standard.object(forKey: Self.key)
            UserDefaults.standard.set(enabled, forKey: Self.key)
        }
        func restore() {
            if let previous {
                UserDefaults.standard.set(previous, forKey: Self.key)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.key)
            }
        }
    }

    /// Per-run counters. A class so the processor's `onSync` closure can
    /// mutate it without capturing `inout` state.
    private final class DrainStats {
        var syncCount = 0
        var syncSeconds: Double = 0
        var peakSyncSeconds: Double = 0
        var lastAppendedLength = 0
        var lastAppendAt: CFAbsoluteTime = 0
    }

    private struct DrainResult {
        let deltaCount: Int
        let producerSeconds: Double
        /// Producer end → every character visible in the turn.
        let tailSeconds: Double
        /// Producer start → `finalize()` returned.
        let wallSeconds: Double
        let syncCount: Int
        let syncSeconds: Double
        let peakSyncMs: Double
    }

    /// Runs the real consumer pipeline against a paced synthetic producer.
    ///
    /// - `smooth`: the user-facing smooth-streaming toggle.
    /// - `ratePerSecond`: producer pace (deltas/s). 100 is ~2× the fastest
    ///   local engine measured (56 tok/s); 300 is headroom.
    /// - `renderAppKit`: when true every sync also runs the streaming
    ///   paragraph through `NativeMarkdownView.configure` + `measuredHeight`
    ///   — the same calls `NativeMessageCellView.configureAsParagraph` makes
    ///   for the streaming row, i.e. the O(content) part of the display path.
    private func runDrain(
        smooth: Bool,
        ratePerSecond: Double,
        deltas: [String],
        renderAppKit: Bool
    ) async throws -> DrainResult {
        let override = SmoothStreamingOverride(smooth)
        defer { override.restore() }

        let user = ChatTurn(role: .user, content: "count from 1 to 250")
        let turn = ChatTurn(role: .assistant, content: "")
        let memoizer = BlockMemoizer()
        let markdown = NativeMarkdownView(frame: NSRect(x: 0, y: 0, width: 700, height: 10))
        let theme = ThemeManager.shared.currentTheme
        let stats = DrainStats()
        let width: CGFloat = 700 - 32

        let processor = StreamingDeltaProcessor(turn: turn) {
            let t0 = CFAbsoluteTimeGetCurrent()
            stats.syncCount += 1
            // ChatView.rebuildVisibleBlocks → BlockMemoizer (incremental path).
            let blocks = memoizer.blocks(
                from: [user, turn],
                streamingTurnId: turn.id,
                agentName: "Osaurus"
            )
            if renderAppKit {
                // MessageTableRepresentable.applyBlocks path 2 → configureCell →
                // NativeMarkdownView.configure for the streaming paragraph.
                for block in blocks.reversed() {
                    guard case let .paragraph(_, text, isStreaming, role) = block.kind,
                        role == .assistant
                    else { continue }
                    markdown.configure(
                        text: text,
                        width: width,
                        theme: theme,
                        cacheKey: block.id,
                        isStreaming: isStreaming
                    )
                    _ = markdown.measuredHeight(for: width)
                    break
                }
            }
            if turn.contentLength != stats.lastAppendedLength {
                stats.lastAppendedLength = turn.contentLength
                stats.lastAppendAt = CFAbsoluteTimeGetCurrent()
            }
            let dt = CFAbsoluteTimeGetCurrent() - t0
            stats.syncSeconds += dt
            if dt > stats.peakSyncSeconds { stats.peakSyncSeconds = dt }
        }

        let interval = UInt64(1_000_000_000.0 / ratePerSecond)
        var expected = ""
        let start = CFAbsoluteTimeGetCurrent()
        for delta in deltas {
            expected += delta
            processor.receiveDelta(delta)
            // Mirrors the real consumer: between deltas the MainActor is
            // yielded, so the processor's pacing/flush timers can fire.
            try await Task.sleep(nanoseconds: interval)
        }
        let producerEnd = CFAbsoluteTimeGetCurrent()
        await processor.finalize()
        let wallEnd = CFAbsoluteTimeGetCurrent()

        #expect(turn.content == expected, "drained content must be byte-identical")
        #expect(turn.contentLength == expected.count)

        let result = DrainResult(
            deltaCount: deltas.count,
            producerSeconds: producerEnd - start,
            tailSeconds: max(0, stats.lastAppendAt - producerEnd),
            wallSeconds: wallEnd - start,
            syncCount: stats.syncCount,
            syncSeconds: stats.syncSeconds,
            peakSyncMs: stats.peakSyncSeconds * 1000
        )
        let line = String(
            format:
                "[drain] smooth=%@ appkit=%@ rate=%.0f/s deltas=%d producer=%.2fs wall=%.2fs "
                + "tail=%.2fs ratio=%.3f syncs=%d syncTotal=%.1fms syncMean=%.2fms syncPeak=%.2fms\n",
            smooth ? "on" : "off",
            renderAppKit ? "on" : "off",
            ratePerSecond,
            result.deltaCount,
            result.producerSeconds,
            result.wallSeconds,
            result.tailSeconds,
            result.wallSeconds / result.producerSeconds,
            result.syncCount,
            result.syncSeconds * 1000,
            result.syncCount > 0 ? result.syncSeconds * 1000 / Double(result.syncCount) : 0,
            result.peakSyncMs
        )
        FileHandle.standardError.write(Data(line.utf8))
        return result
    }

    /// Smooth streaming may legitimately keep revealing after the producer
    /// stops: `pacingDrainTicks` (60 × 16 ms) bounds that tail to ~1 s by
    /// design. The synthetic producer never lets the buffer grow past a
    /// few characters, so the observed tail is one or two ticks.
    private static let smoothRevealTailAllowance: Double = 1.0

    // MARK: - Throughput

    @Test("890 one-token deltas at 100/s drain within 1.2× producer time (smooth on, AppKit render)")
    func drainKeepsUpAt100PerSecondSmoothOn() async throws {
        let deltas = Self.countingDeltas()
        let r = try await runDrain(smooth: true, ratePerSecond: 100, deltas: deltas, renderAppKit: true)
        #expect(r.wallSeconds <= r.producerSeconds * 1.2 + Self.smoothRevealTailAllowance)
        #expect(r.tailSeconds <= Self.smoothRevealTailAllowance)
        // One UI publish per ~16 ms frame, not one per delta.
        #expect(r.syncCount < deltas.count)
    }

    @Test("890 one-token deltas at 100/s drain within 1.2× producer time (smooth off, AppKit render)")
    func drainKeepsUpAt100PerSecondSmoothOff() async throws {
        let deltas = Self.countingDeltas()
        let r = try await runDrain(smooth: false, ratePerSecond: 100, deltas: deltas, renderAppKit: true)
        #expect(r.wallSeconds <= r.producerSeconds * 1.2)
        #expect(r.tailSeconds <= 0.2)
        #expect(r.syncCount < deltas.count)
    }

    @Test("300 deltas/s (5× the fastest measured engine) still drains within 1.2× producer time")
    func drainKeepsUpAt300PerSecond() async throws {
        let deltas = Self.countingDeltas()
        let on = try await runDrain(smooth: true, ratePerSecond: 300, deltas: deltas, renderAppKit: true)
        #expect(on.wallSeconds <= on.producerSeconds * 1.2 + Self.smoothRevealTailAllowance)
        let off = try await runDrain(smooth: false, ratePerSecond: 300, deltas: deltas, renderAppKit: true)
        #expect(off.wallSeconds <= off.producerSeconds * 1.2)
    }

    // MARK: - Coalescing correctness

    @Test("burst of 890 deltas: order preserved and content byte-identical (smooth on and off)")
    func burstPreservesOrderAndBytes() async {
        let deltas = Self.countingDeltas()
        let expected = deltas.joined()
        for smooth in [true, false] {
            let override = SmoothStreamingOverride(smooth)
            defer { override.restore() }
            let turn = ChatTurn(role: .assistant, content: "")
            let processor = StreamingDeltaProcessor(turn: turn)
            for d in deltas { processor.receiveDelta(d) }
            await processor.finalize()
            #expect(turn.content == expected, "smooth=\(smooth)")
        }
    }

    @Test("reasoning and content interleave: each channel keeps its own order, nothing crosses over")
    func reasoningContentInterleave() async {
        for smooth in [true, false] {
            let override = SmoothStreamingOverride(smooth)
            defer { override.restore() }
            let turn = ChatTurn(role: .assistant, content: "")
            var syncs = 0
            let processor = StreamingDeltaProcessor(turn: turn) { syncs += 1 }
            var expectedThinking = ""
            var expectedContent = ""
            for i in 0 ..< 300 {
                if i % 3 == 0 {
                    let r = "r\(i) "
                    expectedThinking += r
                    processor.receiveReasoning(r)
                } else {
                    let c = "c\(i) "
                    expectedContent += c
                    processor.receiveDelta(c)
                }
            }
            await processor.finalize()
            #expect(turn.thinking == expectedThinking, "smooth=\(smooth)")
            #expect(turn.content == expectedContent, "smooth=\(smooth)")
            #expect(syncs >= 1)
        }
    }

    @Test("finalize drains a 4,000-character burst that arrived after the last sync (smooth on)")
    func finalizeDrainsLargeSmoothTail() async {
        let override = SmoothStreamingOverride(true)
        defer { override.restore() }
        let turn = ChatTurn(role: .assistant, content: "")
        let processor = StreamingDeltaProcessor(turn: turn)
        let text = String(repeating: "abcdefghij", count: 400)
        processor.receiveDelta(text)
        let t0 = CFAbsoluteTimeGetCurrent()
        await processor.finalize()
        let seconds = CFAbsoluteTimeGetCurrent() - t0
        #expect(turn.content == text)
        // Designed reveal window is ~1 s (pacingDrainTicks). CI runners are slow and
            // shared (3.5 s observed on osaurus-ai CI); the bound guards against a hang,
            // not against scheduler slack — keep it generous.
        #expect(seconds < 10.0, "finalize took \(seconds)s")
    }

    @Test("smooth-off path: no delta is dropped when the fallback flush timer is the only trigger")
    func smoothOffFallbackTimerFlushesTail() async throws {
        let override = SmoothStreamingOverride(false)
        defer { override.restore() }
        let turn = ChatTurn(role: .assistant, content: "")
        let processor = StreamingDeltaProcessor(turn: turn)
        processor.receiveDelta("tail")
        // 100 ms fallback timer must land the text without finalize().
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(turn.content == "tail")
        await processor.finalize()
        #expect(turn.content == "tail")
    }
}
