//
//  BonjourRunLoop.swift
//  osaurus
//
//  A dedicated background thread with its own run loop for `NetService`
//  registration.
//
//  `NetService.publish()` opens a synchronous IPC connection to mDNSResponder
//  (DNSServiceRegister) in the calling thread. When the daemon is slow to
//  answer (cold launch, system under load) that call blocks for seconds, and
//  because both advertisers are `@MainActor` it used to hang the UI
//  (APPLE-MACOS-3NA). Services handed to this class are moved onto the worker's
//  run loop and published, stopped and updated there, so the blocking IPC and
//  the delegate callbacks happen off the main thread. Delegates must be
//  `nonisolated` and hop back to the main actor themselves (both advertisers
//  already do). Every operation goes through the same serial run loop, so a
//  stop queued after a publish always runs after it.
//

import Foundation

final class BonjourRunLoop: NSObject, @unchecked Sendable {
    static let shared = BonjourRunLoop()

    /// Carries a non-Sendable value onto the worker thread. Safe because the
    /// value is only touched on that thread once handed over.
    private final class Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private final class RunLoopHolder: @unchecked Sendable {
        var runLoop: CFRunLoop?
    }

    private let runLoop: CFRunLoop

    private override init() {
        let holder = RunLoopHolder()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            holder.runLoop = CFRunLoopGetCurrent()
            // A port keeps the run loop alive while no service is scheduled.
            RunLoop.current.add(Port(), forMode: .default)
            ready.signal()
            while true {
                _ = RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "com.osaurus.bonjour"
        thread.qualityOfService = .utility
        thread.start()
        // Only waits for the thread to start, never for mDNSResponder.
        ready.wait()
        runLoop = holder.runLoop!
        super.init()
    }

    /// Run `block` on the Bonjour thread, asynchronously.
    func perform(_ block: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Move `service` onto the Bonjour thread and publish it there.
    func publish(_ service: NetService) {
        let box = Box(service)
        perform {
            box.value.remove(from: .main, forMode: .default)
            box.value.schedule(in: .current, forMode: .default)
            box.value.publish()
        }
    }

    /// Stop `service` on the Bonjour thread (after any publish queued before).
    func stop(_ service: NetService) {
        let box = Box(service)
        perform { box.value.stop() }
    }

    /// Update a live service's TXT record on the Bonjour thread.
    func setTXTRecord(_ txt: Data, on service: NetService) {
        let box = Box(service)
        perform { _ = box.value.setTXTRecord(txt) }
    }
}
