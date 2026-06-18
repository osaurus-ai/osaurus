//
//  PrefillDebugLog.swift
//  osaurus
//
//  Lightweight, append-only diagnostic log for prefill / KV-cache analysis.
//  Writes timestamped lines to a single file in /tmp so a full request —
//  prompt composition, per-step prefill token counts, and the cache
//  hit/miss deltas around each model step — can be reconstructed offline.
//
//  This is an investigation aid, not a product feature. It is OFF by default
//  and enabled with `OSAURUS_PREFILL_DEBUG=1` (the same env var the vmlx
//  TokenizeDebugLog honors, so one switch lights up both logs). All file
//  I/O runs on a dedicated serial queue so logging never blocks the main
//  thread or the inference path.
//

import Foundation

/// Append-only `/tmp` logger for prefill + KV-cache diagnostics.
final class PrefillDebugLog: @unchecked Sendable {

    static let shared = PrefillDebugLog()

    /// Destination file. Stable name so repeated runs accumulate into one
    /// file; each compose writes a `===` banner so turns are easy to find.
    static let path = "/tmp/osaurus-prefill-debug.log"

    /// Off-main serial queue: keeps file opens/writes off the inference and
    /// UI threads (see the no-main-thread-blocking project rule).
    private let queue = DispatchQueue(label: "com.osaurus.prefill-debug-log")

    /// Resolved once: enabled only when `OSAURUS_PREFILL_DEBUG=1`.
    /// Public so call sites can skip building diagnostic payloads (e.g. a
    /// cache-stats snapshot) when logging is off.
    let isEnabled: Bool

    /// Monotonic clock origin so each line carries a precise relative offset
    /// (wall-clock alone is too coarse to read prefill timing from).
    private let startedAt = CFAbsoluteTimeGetCurrent()

    /// Previous step's tokenized prompt, per model, for prefix-divergence
    /// analysis. Guarded by `tokensLock`.
    private let tokensLock = NSLock()
    private var lastTokensByModel: [String: [Int]] = [:]

    /// Record this step's prompt token ids and report how they relate to the
    /// previous step's prompt for the same model. `lcp` is the longest common
    /// prefix length — exactly what the KV prefix cache can reuse. `lcp` near
    /// `min(prev, current)` means the new prompt prefix-EXTENDS the old (reuse
    /// works); a small `lcp` means early divergence → cold re-prefill.
    func recordPromptTokens(_ tokens: [Int], model: String) -> (lcp: Int, prevCount: Int) {
        tokensLock.lock()
        defer { tokensLock.unlock() }
        let prev = lastTokensByModel[model] ?? []
        let n = min(prev.count, tokens.count)
        var lcp = 0
        while lcp < n, prev[lcp] == tokens[lcp] { lcp += 1 }
        lastTokensByModel[model] = tokens
        return (lcp, prev.count)
    }

    private init() {
        let flag = ProcessInfo.processInfo.environment["OSAURUS_PREFILL_DEBUG"]
        self.isEnabled = (flag == "1")
        guard isEnabled else { return }
        // Mark process start so separate runs are visually separable in the
        // accumulated file.
        write(
            "\n######## prefill-debug session start "
                + "pid=\(ProcessInfo.processInfo.processIdentifier) ########"
        )
    }

    /// Append one line with wall-clock + monotonic-offset prefixes.
    func log(_ message: String) {
        guard isEnabled else { return }
        write(message)
    }

    private func write(_ message: String) {
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        // Compute the wall-clock stamp on the calling thread (cheap) so the
        // queue only does the file write.
        let wall = Self.wallClockStamp()
        queue.async {
            let line = "[\(wall)] [+\(String(format: "%8.3f", elapsed))s] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let url = URL(fileURLWithPath: Self.path)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func wallClockStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
