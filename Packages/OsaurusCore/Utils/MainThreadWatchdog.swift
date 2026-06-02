//
//  MainThreadWatchdog.swift
//  osaurus
//
//  Watchdog that detects when the main thread is blocked. Runs a timer on a
//  background GCD queue and periodically checks whether the main thread
//  responds within a threshold, logging when it doesn't.
//
//  Available in *release* builds too: a field hang (spinning beachball, frozen
//  UI) is otherwise undiagnosable without attaching a debugger. The release
//  path logs to the unified log via `os.Logger` (visible in Console.app or
//  `log show --predicate 'subsystem == "com.dinoki.osaurus"'`) so support can
//  see "main thread blocked for >Ns" after the fact. It never asserts or
//  crashes — it only observes.
//

import Foundation
import os.log

/// Monitors the main thread for hangs. Start once at app launch via
/// `MainThreadWatchdog.shared.start()`.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private static let log = Logger(subsystem: "com.dinoki.osaurus", category: "MainThreadWatchdog")

    private let threshold: TimeInterval
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.osaurus.watchdog", qos: .background)

    /// Tighter threshold in DEBUG (catch jank early during development), more
    /// conservative in release (only report genuine, user-visible hangs).
    init(
        threshold: TimeInterval = {
            #if DEBUG
                return 3.0
            #else
                return 5.0
            #endif
        }()
    ) {
        self.threshold = threshold
    }

    func start() {
        guard timer == nil else { return }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + threshold, repeating: threshold)
        source.setEventHandler { [threshold] in
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + threshold) == .timedOut {
                #if DEBUG
                    print("[Watchdog] Main thread blocked for >\(threshold)s")
                #endif
                // Always emit to the unified log so a release-build field hang
                // leaves a breadcrumb support can read without a debugger.
                MainThreadWatchdog.log.error(
                    "Main thread blocked for >\(threshold, privacy: .public)s (possible hang)"
                )
            }
        }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
