import Foundation
import Testing

@testable import OsaurusCore

/// When a chat used from the phone comes forward on the Mac: only on the
/// user's return, and only when the phone was used while they were away.
struct PhoneChatHandoffTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let chat = UUID()

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    @Test
    func unlockAfterPhoneUseBringsTheChatForward() {
        var tracker = PhoneChatHandoffTracker()
        // Locked at 0 (last input then), phone used at 10, unlocked at 30.
        tracker.notePhoneActivity(chat, at: at(10))
        #expect(tracker.observe(now: at(10), idle: 600, locked: true) == nil)
        #expect(tracker.observe(now: at(20), idle: 1200, locked: true) == nil)
        #expect(tracker.observe(now: at(30), idle: 0, locked: false) == chat)
        #expect(!tracker.isWatching)
    }

    @Test
    func inputAfterALongIdleCountsAsComingBack() {
        var tracker = PhoneChatHandoffTracker()
        tracker.notePhoneActivity(chat, at: at(10))
        #expect(tracker.observe(now: at(10), idle: 400, locked: false) == nil)
        #expect(tracker.observe(now: at(15), idle: 1, locked: false) == chat)
    }

    @Test
    func phoneUseAtTheDeskIsNotAHandoff() {
        var tracker = PhoneChatHandoffTracker()
        // The Mac was in use a minute ago: the user is here.
        tracker.notePhoneActivity(chat, at: at(10))
        #expect(tracker.observe(now: at(10), idle: 60, locked: false) == nil)
        // They leave afterwards (last input at 11) without using the phone
        // again, and come back.
        #expect(tracker.observe(now: at(20), idle: 540, locked: false) == nil)
        #expect(tracker.observe(now: at(40), idle: 0, locked: false) == nil)
        #expect(!tracker.isWatching)
    }

    @Test
    func theLatestPhoneChatWins() {
        var tracker = PhoneChatHandoffTracker()
        let later = UUID()
        tracker.notePhoneActivity(chat, at: at(10))
        _ = tracker.observe(now: at(10), idle: 600, locked: true)
        tracker.notePhoneActivity(later, at: at(12))
        #expect(tracker.observe(now: at(30), idle: 0, locked: false) == later)
    }

    @Test
    func aStaleChatIsDropped() {
        var tracker = PhoneChatHandoffTracker()
        tracker.notePhoneActivity(chat, at: at(10))
        _ = tracker.observe(now: at(10), idle: 600, locked: true)
        #expect(tracker.observe(now: at(10 + 181), idle: 0, locked: false) == nil)
        #expect(!tracker.isWatching)
    }

    @Test
    func typingAtTheLockScreenWaitsForTheUnlock() {
        var tracker = PhoneChatHandoffTracker()
        tracker.notePhoneActivity(chat, at: at(10))
        _ = tracker.observe(now: at(10), idle: 600, locked: true)
        // Password keystrokes reset idle, but the screen is still locked.
        #expect(tracker.observe(now: at(30), idle: 1, locked: true) == nil)
        #expect(tracker.observe(now: at(30.1), idle: 0, locked: false) == chat)
    }
}
