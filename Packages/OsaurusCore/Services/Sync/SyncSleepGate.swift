//
//  SyncSleepGate.swift
//  osaurus
//
//  Holds system sleep, off the main thread, until sync has written this
//  Mac's sleeping presence and suspended the core.
//

import Foundation
import IOKit
import IOKit.pwr_mgt
import os

/// Registers for IOKit system power messages on a private queue. On
/// will-sleep it runs `work` and acknowledges the sleep when the work ends or
/// `timeout` passes, whichever comes first. The main thread never waits.
///
/// Replaces an `NSWorkspace.willSleepNotification` observer that blocked the
/// main thread for up to 5 s (App Hanging, APPLE-MACOS-3ZE) while the presence
/// write and suspend queued behind a core compaction pass.
final class SyncSleepGate: @unchecked Sendable {
    // iokit_common_msg macros, not imported into Swift.
    private static let messageCanSystemSleep: natural_t = 0xE000_0270
    private static let messageSystemWillSleep: natural_t = 0xE000_0280

    private static let log = Logger(subsystem: "ai.osaurus", category: "sync")

    private let timeout: TimeInterval
    private let work: @Sendable () async -> Void
    private let queue = DispatchQueue(label: "ai.osaurus.sync.sleep", qos: .userInitiated)

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    /// The sleep being held, if any; touched only on `queue`.
    private var pending: (id: Int, timer: DispatchWorkItem)?

    init(timeout: TimeInterval, work: @escaping @Sendable () async -> Void) {
        self.timeout = timeout
        self.work = work
    }

    func start() {
        queue.sync {
            guard rootPort == 0 else { return }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let port = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, type, argument in
                guard let refcon else { return }
                Unmanaged<SyncSleepGate>.fromOpaque(refcon).takeUnretainedValue()
                    .handle(type: type, argument: argument)
            }, &notifier)
            guard port != 0, let notifyPort else {
                Self.log.error("sleep gate: IORegisterForSystemPower failed")
                return
            }
            rootPort = port
            IONotificationPortSetDispatchQueue(notifyPort, queue)
        }
    }

    func stop() {
        queue.sync {
            if let pending {
                pending.timer.cancel()
                IOAllowPowerChange(rootPort, pending.id)
                self.pending = nil
            }
            guard rootPort != 0 else { return }
            IODeregisterForSystemPower(&notifier)
            IOServiceClose(rootPort)
            if let notifyPort { IONotificationPortDestroy(notifyPort) }
            notifyPort = nil
            rootPort = 0
        }
    }

    /// Runs on `queue`, where IOKit delivers power messages.
    private func handle(type: natural_t, argument: UnsafeMutableRawPointer?) {
        let id = Int(bitPattern: argument)
        switch type {
        case Self.messageCanSystemSleep:
            IOAllowPowerChange(rootPort, id)
        case Self.messageSystemWillSleep:
            hold(id: id)
        default:
            break
        }
    }

    private func hold(id: Int) {
        if let previous = pending {
            previous.timer.cancel()
            IOAllowPowerChange(rootPort, previous.id)
        }
        let started = DispatchTime.now()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.pending?.id == id else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
            Self.log.error(
                "sleep gate: presence write and suspend still running after \(elapsed, privacy: .public)s; allowing sleep"
            )
            self.release(id: id)
        }
        pending = (id, timer)
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        let work = self.work
        Task.detached(priority: .userInitiated) { [weak self] in
            await work()
            self?.queue.async { self?.release(id: id) }
        }
    }

    /// Acknowledges the held sleep once; runs on `queue`.
    private func release(id: Int) {
        guard let pending, pending.id == id else { return }
        pending.timer.cancel()
        self.pending = nil
        IOAllowPowerChange(rootPort, id)
    }
}
