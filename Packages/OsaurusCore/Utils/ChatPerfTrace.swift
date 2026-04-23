//
//  ChatPerfTrace.swift
//  osaurus
//
//  Counter + timing trace for the chat streaming UI. Mirrors TTFTTrace's
//  file-backed format but is designed for a long-running session: begin()
//  at stream start, end() at stream end, and every hot-path site calls
//  `count(_:)` or `time(_:_:)` to accumulate totals.
//
//  Report lands in /tmp/osaurus_chat_perf.log as an append-only block per
//  stream, so multiple streams can be compared without clearing the file.
//
//  Usage:
//    ChatPerfTrace.shared.begin("stream-...")
//    ChatPerfTrace.shared.count("applyBlocks.path2")
//    ChatPerfTrace.shared.time("applyBlocks") { ... }
//    ChatPerfTrace.shared.end()   // flushes + writes report
//

import Foundation

final class ChatPerfTrace: @unchecked Sendable {

    static let shared = ChatPerfTrace()

    private let lock = NSLock()

    private var label: String = ""
    private var startedAt: CFAbsoluteTime?
    private var counters: [String: Int] = [:]
    /// Accumulated durations in seconds.
    private var durations: [String: Double] = [:]
    /// Peak single-call durations in seconds (useful for spotting stalls).
    private var peaks: [String: Double] = [:]

    private static let path = "/tmp/osaurus_chat_perf.log"

    // MARK: - Lifecycle

    /// Reset state and start a new trace window. Safe to call while a
    /// previous trace is still open — it emits the previous report first.
    /// Debug-only: compiles away to a no-op in release builds so the lock,
    /// timestamping, and file I/O have zero runtime cost in shipped binaries.
    func begin(_ label: String) {
        #if DEBUG
            lock.lock()
            let hadPrevious = startedAt != nil
            lock.unlock()
            if hadPrevious { end() }

            lock.lock()
            self.label = label
            self.startedAt = CFAbsoluteTimeGetCurrent()
            self.counters.removeAll(keepingCapacity: true)
            self.durations.removeAll(keepingCapacity: true)
            self.peaks.removeAll(keepingCapacity: true)
            lock.unlock()
        #endif
    }

    /// Flush the accumulated counters/durations to disk and clear state.
    /// A no-op if `begin()` was never called. Debug-only.
    func end() {
        #if DEBUG
            lock.lock()
            guard let start = startedAt else { lock.unlock(); return }
            let label = self.label
            let totalSec = CFAbsoluteTimeGetCurrent() - start
            let counters = self.counters
            let durations = self.durations
            let peaks = self.peaks
            self.startedAt = nil
            self.label = ""
            self.counters.removeAll(keepingCapacity: true)
            self.durations.removeAll(keepingCapacity: true)
            self.peaks.removeAll(keepingCapacity: true)
            lock.unlock()

            emit(
                label: label,
                totalSec: totalSec,
                counters: counters,
                durations: durations,
                peaks: peaks
            )
        #endif
    }

    // MARK: - Instrumentation API

    /// Increment a named counter (or add `n`). Zero-alloc on the hot path
    /// once the key exists in the dictionary. Debug-only — release builds
    /// get an empty body that -O optimizes to a no-op call.
    func count(_ key: String, _ n: Int = 1) {
        #if DEBUG
            lock.lock()
            // Only record when a trace is active; avoids polluting counters
            // between streams.
            if startedAt != nil {
                counters[key, default: 0] += n
            }
            lock.unlock()
        #endif
    }

    /// Time a block. Accumulates into `durations[key]` and tracks the
    /// peak single-call duration in `peaks[key]`. Debug-only — release
    /// builds skip the timestamping and just run the block.
    @discardableResult
    func time<T>(_ key: String, _ block: () -> T) -> T {
        #if DEBUG
            let t0 = CFAbsoluteTimeGetCurrent()
            let result = block()
            let dt = CFAbsoluteTimeGetCurrent() - t0
            lock.lock()
            if startedAt != nil {
                durations[key, default: 0] += dt
                if dt > (peaks[key] ?? 0) { peaks[key] = dt }
                counters[key + ".n", default: 0] += 1
            }
            lock.unlock()
            return result
        #else
            return block()
        #endif
    }

    // MARK: - Emit

    private func emit(
        label: String,
        totalSec: Double,
        counters: [String: Int],
        durations: [String: Double],
        peaks: [String: Double]
    ) {
        guard !counters.isEmpty || !durations.isEmpty else { return }

        var lines: [String] = []
        let dateStr = ISO8601DateFormatter().string(from: Date())
        lines.append("═══ ChatPerf \(dateStr) [\(label)] ═══")
        lines.append(String(format: "  duration                        %8.2f s", totalSec))

        // Counters, sorted alphabetically so reports diff cleanly.
        if !counters.isEmpty {
            lines.append("  ── counters ──")
            for key in counters.keys.sorted() {
                let n = counters[key] ?? 0
                let rate = totalSec > 0 ? Double(n) / totalSec : 0
                let padded = key.padding(toLength: 36, withPad: " ", startingAt: 0)
                lines.append(String(format: "  %@ %8d  (%.1f/s)", padded, n, rate))
            }
        }

        // Durations (total + peak ms).
        if !durations.isEmpty {
            lines.append("  ── timings ──")
            for key in durations.keys.sorted() {
                let total = (durations[key] ?? 0) * 1000
                let peak = (peaks[key] ?? 0) * 1000
                let n = counters[key + ".n"] ?? 0
                let mean = n > 0 ? total / Double(n) : 0
                let padded = key.padding(toLength: 36, withPad: " ", startingAt: 0)
                lines.append(
                    String(
                        format: "  %@ total=%7.1f ms  peak=%6.2f ms  mean=%6.2f ms",
                        padded,
                        total,
                        peak,
                        mean
                    )
                )
            }
        }
        lines.append("")

        let block = lines.joined(separator: "\n") + "\n"
        guard let data = block.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: Self.path) {
            if let fh = FileHandle(forWritingAtPath: Self.path) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: Self.path))
        }
    }
}
