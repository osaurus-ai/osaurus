//
//  MainThreadWatchdog.swift
//  osaurus
//
//  Watchdog that detects when the main thread is blocked. Runs a timer on a
//  background GCD queue and periodically checks whether the main thread
//  responds within a threshold.
//
//  Available in *release* builds too: a field hang (spinning beachball, frozen
//  UI) is otherwise undiagnosable without attaching a debugger. On breach it:
//
//  - names the in-flight operation(s) from `MainThreadOperationLedger`
//    (subsystem + operation identifiers only, never content), so the log
//    line is actionable instead of the old generic "main thread blocked";
//  - persists a last-stall record to `~/.osaurus/diagnostics/` for support;
//  - forwards a privacy-safe stall record to Sentry (breadcrumb + throttled
//    event with an operation-based fingerprint) so field hangs stop
//    collapsing into one omnibus issue group.
//
//  It never asserts or crashes — it only observes.
//

import Foundation
import os.log

/// Monitors the main thread for hangs. Start once at app launch via
/// `MainThreadWatchdog.shared.start()`.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private static let log = Logger(subsystem: "com.dinoki.osaurus", category: "MainThreadWatchdog")

    private let threshold: TimeInterval
    /// Where the last-stall record is written. Defaults to the live
    /// `~/.osaurus/diagnostics/` directory; injectable so fault-injection
    /// tests get a private file that parallel suites (which re-point
    /// `OsaurusPaths.overrideRoot` at will) cannot move or overwrite.
    private let diagnosticsDirectoryOverride: URL?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.osaurus.watchdog", qos: .background)

    /// Consecutive-breach tracking: one stall episode produces one Sentry
    /// event (on its first breach), not one per watchdog tick.
    private var inStallEpisode = false
    /// Wall-clock throttle between Sentry stall events, so a machine having
    /// a very bad day cannot flood the project.
    private var lastReportedAt: Date?
    private let minReportInterval: TimeInterval = 120

    /// Tighter threshold in DEBUG (catch jank early during development), more
    /// conservative in release (only report genuine, user-visible hangs).
    init(
        threshold: TimeInterval = {
            #if DEBUG
                return 3.0
            #else
                return 5.0
            #endif
        }(),
        diagnosticsDirectory: URL? = nil
    ) {
        self.threshold = threshold
        self.diagnosticsDirectoryOverride = diagnosticsDirectory
    }

    func start() {
        guard timer == nil else { return }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + threshold, repeating: threshold)
        source.setEventHandler { [weak self, threshold] in
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + threshold) == .timedOut {
                self?.handleBreach()
            } else {
                self?.inStallEpisode = false
            }
        }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Breach handling

    private func handleBreach() {
        let operations = MainThreadOperationLedger.shared.snapshot()
        let opsSummary =
            operations.isEmpty
            ? "no instrumented operation in flight"
            : operations
                .map { "\($0.subsystem).\($0.operation) (\(Int($0.ageSeconds()))s)" }
                .joined(separator: ", ")

        #if DEBUG
            print("[Watchdog] Main thread blocked for >\(threshold)s — \(opsSummary)")
        #endif
        Self.log.error(
            "Main thread blocked for >\(self.threshold, privacy: .public)s (possible hang) — \(opsSummary, privacy: .public)"
        )

        persistLastStall(operations: operations)

        // First breach of an episode only; subsequent ticks of the same
        // stall add nothing (the main thread hasn't moved).
        let isEpisodeStart = !inStallEpisode
        inStallEpisode = true
        guard isEpisodeStart else { return }

        let now = Date()
        if let last = lastReportedAt, now.timeIntervalSince(last) < minReportInterval {
            return
        }
        lastReportedAt = now
        CrashReportingService.recordMainThreadStall(
            thresholdSeconds: threshold,
            operations: operations.map {
                CrashReportingService.StallOperation(
                    subsystem: $0.subsystem,
                    operation: $0.operation,
                    ageSeconds: $0.ageSeconds()
                )
            }
        )
    }

    /// Persist a privacy-safe record of the most recent stall so support can
    /// ask for one file instead of a full sysdiagnose.
    private func persistLastStall(operations: [MainThreadOperationLedger.Entry]) {
        struct StallRecord: Codable {
            let at: Date
            let thresholdSeconds: TimeInterval
            let operations: [MainThreadOperationLedger.Entry]
            let appVersion: String?
        }
        let record = StallRecord(
            at: Date(),
            thresholdSeconds: threshold,
            operations: operations,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        let dir =
            diagnosticsDirectoryOverride
            ?? OsaurusPaths.root().appendingPathComponent("diagnostics", isDirectory: true)
        OsaurusPaths.ensureExistsSilent(dir)
        try? data.write(
            to: dir.appendingPathComponent("last-main-thread-stall.json"), options: [.atomic]
        )
    }
}
