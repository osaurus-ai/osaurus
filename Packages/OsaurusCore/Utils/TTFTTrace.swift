//
//  TTFTTrace.swift
//  osaurus
//
//  Structured TTFT (Time-To-First-Token) phase tracing.
//  Writes a human-readable timing breakdown to /tmp/osaurus_ttft_trace.log
//  after each generation completes, so bottlenecks are immediately visible.
//
//  Usage:
//    let trace = TTFTTrace()
//    trace.mark("phaseName")
//    // ... do work ...
//    trace.mark("nextPhase")
//    trace.set("promptTokens", 3200)
//    trace.emit()   // writes the full breakdown to disk
//

import Foundation

final class TTFTTrace: @unchecked Sendable {

    /// A trace when tracing is on for this build, `nil` otherwise.
    ///
    /// Phase timings existed but were `#if DEBUG` only, so the build users
    /// actually run recorded nothing — which is why "did prefill get slower"
    /// could not be answered either way from a user's machine. The load phase
    /// in particular (`load_container_start` → `load_container_done`) is the
    /// one a user waits through and the one the reported TTFT excludes.
    ///
    /// Release keeps tracing OFF by default; `OSAURUS_TTFT_TRACE=1` turns it
    /// on so a real report can come back with real phase numbers.
    /// `start` backdates the trace's origin. The phase a user actually waits
    /// through can begin before there is anything to attach a trace to — a send
    /// can block on an in-flight warm-up that loads the whole container first,
    /// and that happens before generation, so a trace created at generation time
    /// starts the clock after the wait is over and reports a TTFT that excludes
    /// it. Passing the moment the user hit send puts that phase back inside.
    static func makeIfEnabled(
        start: CFAbsoluteTime? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TTFTTrace? {
        isEnabled(environment: environment) ? TTFTTrace(start: start) : nil
    }

    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let raw = environment["OSAURUS_TTFT_TRACE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        {
            // An explicit setting wins in every configuration, so a debug
            // build can be quietened and a release build can be opened up.
            return !["0", "false", "no", "off", ""].contains(raw)
        }
        #if DEBUG
            return true
        #else
            return false
        #endif
    }

    private struct Mark {
        let name: String
        let time: CFAbsoluteTime
    }

    private let created: CFAbsoluteTime
    private var marks: [Mark] = []
    private var metadata: [(String, String)] = []
    private let lock = NSLock()

    private static let path = "/tmp/osaurus_ttft_trace.log"

    init(start: CFAbsoluteTime? = nil) {
        created = start ?? CFAbsoluteTimeGetCurrent()
    }

    /// Record a named checkpoint. Call this at the boundary between phases.
    func mark(_ name: String) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        marks.append(Mark(name: name, time: now))
        lock.unlock()
    }

    /// Attach a key-value metric (e.g. token counts, cache hit type).
    func set(_ key: String, _ value: Any) {
        lock.lock()
        metadata.append((key, "\(value)"))
        lock.unlock()
    }

    /// Render the trace block. Separate from `emit()` so the phase arithmetic —
    /// in particular that a backdated start lands in the first phase rather than
    /// being dropped — can be asserted without writing to a shared file.
    func render(now: Date = Date()) -> String? {
        lock.lock()
        let snapshot = marks
        let meta = metadata
        lock.unlock()

        guard !snapshot.isEmpty else { return nil }

        var lines: [String] = []
        let dateStr = ISO8601DateFormatter().string(from: now)
        lines.append("═══ TTFT Trace \(dateStr) ═══")

        // Phase durations: time between consecutive marks
        var prev = created
        var totalMs: Double = 0
        for m in snapshot {
            let ms = (m.time - prev) * 1000
            totalMs += ms
            let padded = m.name.padding(toLength: 40, withPad: " ", startingAt: 0)
            lines.append("  \(padded) \(String(format: "%8.1f", ms)) ms")
            prev = m.time
        }
        let totalPad = "TOTAL".padding(toLength: 40, withPad: " ", startingAt: 0)
        lines.append("  \(totalPad) \(String(format: "%8.1f", totalMs)) ms")

        // Metadata
        if !meta.isEmpty {
            lines.append("  ── metrics ──")
            for (k, v) in meta {
                let kPad = k.padding(toLength: 40, withPad: " ", startingAt: 0)
                lines.append("  \(kPad) \(v)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Write the full trace block to disk. Call once per generation.
    func emit() {
        guard let block = render() else { return }
        guard let data = block.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: Self.path) {
            // Throwing Swift APIs only: the legacy `write(_:)` raises an
            // uncatchable ObjC `NSException` on a full disk that kills the
            // process. A trace writer must never crash its host.
            if let fh = FileHandle(forWritingAtPath: Self.path) {
                try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
                try? fh.close()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: Self.path))
        }
    }
}
