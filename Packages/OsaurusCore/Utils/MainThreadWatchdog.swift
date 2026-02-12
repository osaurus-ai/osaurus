//
//  MainThreadWatchdog.swift
//  osaurus
//
//  Debug-only watchdog that detects when the main thread is blocked.
//  Runs a timer on a background GCD queue and periodically checks if the
//  main thread responds within a threshold. Logs a warning when it doesn't.
//

import Foundation

#if DEBUG
    /// Monitors the main thread for hangs in debug builds.
    /// Start once at app launch via `MainThreadWatchdog.shared.start()`.
    final class MainThreadWatchdog: @unchecked Sendable {
        static let shared = MainThreadWatchdog()

        private let threshold: TimeInterval
        private var timer: DispatchSourceTimer?
        private let queue = DispatchQueue(label: "com.osaurus.watchdog", qos: .background)

        init(threshold: TimeInterval = 3.0) {
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
                    print("[Watchdog] Main thread blocked for >\(threshold)s")
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
#endif
