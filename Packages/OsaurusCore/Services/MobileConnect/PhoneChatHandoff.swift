//
//  PhoneChatHandoff.swift
//  osaurus
//
//  Settings → Mobile → Continue Phone Chats on This Mac: when the
//  user worked on a chat from their paired iPhone while away from the Mac,
//  that chat comes to the front as they return (the screen unlocks, or the
//  mouse or keyboard moves after a while untouched). On by default: it only
//  acts when the phone was used during the absence, so someone at the desk,
//  or who never uses the phone, never sees it.
//
//  Nothing runs until the phone touches a chat. From then until the handoff
//  lands or goes stale, a light timer reads the screen-lock state and the
//  time since the last input event; there are no always-on observers.
//

import AppKit
import CoreGraphics
import Foundation

/// The away / back decision, apart from the clock and the system readings so
/// it can be tested.
struct PhoneChatHandoffTracker {
    /// Input untouched this long counts as away, locked or not.
    static let idleThreshold: TimeInterval = 5 * 60
    /// A phone chat older than this is not "what you were working on".
    static let staleAfter: TimeInterval = 3 * 60 * 60

    /// The chat the phone touched last, and when.
    private(set) var pending: (sessionId: UUID, at: Date)?
    /// When the user left the Mac: their last input before it went idle or
    /// locked. Nil while they are at it.
    private(set) var awaySince: Date?

    var isWatching: Bool { pending != nil }

    /// The phone ran something in `sessionId`.
    mutating func notePhoneActivity(_ sessionId: UUID, at now: Date) {
        pending = (sessionId, now)
    }

    /// One reading of the Mac. Returns the chat to bring forward when this
    /// reading is the user coming back to a chat the phone used while they
    /// were gone.
    mutating func observe(now: Date, idle: TimeInterval, locked: Bool) -> UUID? {
        guard let current = pending else { return nil }
        if now.timeIntervalSince(current.at) > Self.staleAfter {
            pending = nil
            awaySince = nil
            return nil
        }
        if locked || idle >= Self.idleThreshold {
            // The last input is when they left, however long ago that was.
            if awaySince == nil { awaySince = now.addingTimeInterval(-idle) }
            return nil
        }
        guard let left = awaySince else { return nil }
        // Back at the Mac.
        awaySince = nil
        pending = nil
        // Phone use before leaving was at the desk: not a handoff.
        return current.at > left ? current.sessionId : nil
    }
}

@MainActor
final class PhoneChatHandoff {
    static let shared = PhoneChatHandoff()

    /// UserDefaults key. Absent = enabled.
    static let defaultsKey = "ai.osaurus.connect.continuePhoneChats"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    private static let pollInterval: TimeInterval = 2

    private var tracker = PhoneChatHandoffTracker()
    private var timer: Timer?

    private init() {}

    /// A run from the paired phone touched `sessionId` (started, continued
    /// or finished).
    func notePhoneActivity(sessionId: UUID) {
        guard Self.isEnabled else { return }
        tracker.notePhoneActivity(sessionId, at: Date())
        MobileConnectLog.write("handoff: phone used chat \(sessionId)")
        // Read the Mac straight away: if it is already locked or idle, the
        // absence started before this run, not at the next tick.
        tick()
        startTimer()
    }

    /// For a phone run on one of the Mac's own chats: `keyNonce` is the
    /// caller's access key, which must be the paired phone's.
    func notePhoneRun(sessionId: UUID, keyNonce: String?) {
        guard let keyNonce, MobilePairingService.shared.isPairedKey(nonce: keyNonce) else { return }
        notePhoneActivity(sessionId: sessionId)
    }

    private func startTimer() {
        guard timer == nil, tracker.isWatching else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, so this is the main actor.
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let sessionId = tracker.observe(
            now: Date(),
            idle: Self.secondsSinceLastInput(),
            locked: Self.isScreenLocked()
        )
        if !tracker.isWatching {
            timer?.invalidate()
            timer = nil
        }
        guard let sessionId, Self.isEnabled else { return }
        MobileConnectLog.write("handoff: user is back, bringing chat \(sessionId) forward")
        reveal(sessionId)
    }

    /// Focus the chat's tab (in whichever window has it), else open it in
    /// the front window, else in a new one; the app comes forward with it.
    private func reveal(_ sessionId: UUID) {
        if BackgroundTaskManager.shared.taskState(for: sessionId) != nil {
            // A chat the phone started is a hosted run: reveal the live task
            // rather than a second copy loaded from disk.
            ChatWindowManager.shared.revealTask(sessionId)
        } else if let session = ChatSessionsManager.shared.session(for: sessionId) {
            ChatWindowManager.shared.openHistorySession(session)
        }
    }

    // MARK: System readings

    private static func secondsSinceLastInput() -> TimeInterval {
        // kCGAnyInputEventType: keyboard, mouse, trackpad, tablet.
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
