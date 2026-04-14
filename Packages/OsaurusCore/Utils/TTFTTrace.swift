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

    private struct Mark {
        let name: String
        let time: CFAbsoluteTime
    }

    private let created: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var marks: [Mark] = []
    private var metadata: [(String, String)] = []
    private let lock = NSLock()

    private static let path = "/tmp/osaurus_ttft_trace.log"

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

    /// Write the full trace block to disk. Call once per generation.
    func emit() {
        lock.lock()
        let snapshot = marks
        let meta = metadata
        lock.unlock()

        guard !snapshot.isEmpty else { return }

        var lines: [String] = []
        let dateStr = ISO8601DateFormatter().string(from: Date())
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
