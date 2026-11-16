//
//  MainRunLoopTick.swift
//  osaurus
//
//  Main-actor delivery for main-run-loop timer callbacks.
//

import Foundation

/// Runs `body` on the main actor from a timer scheduled on the main run loop.
///
/// Such a callback is NOT always on the main thread: while an `NSAppleScript`
/// waits for an Apple-event reply, AppleScript's default active proc pumps the
/// main run loop from its worker thread, and main-run-loop timers fire there.
/// `MainActor.assumeIsolated` (or a main-actor Combine sink) traps on that
/// thread, so off-main ticks hop to the main queue instead.
func onMainRunLoopTick(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}
