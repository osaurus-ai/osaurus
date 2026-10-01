//
//  DetachedPhoneRunsTests.swift
//  OsaurusCoreTests
//
//  Phone runs that outlive their connection (docs/MOBILE_PROTOCOL.md §6.4):
//  replay from an index, live following, stop, and retention.
//

import Foundation
import Testing

@testable import OsaurusCore

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [String] = []
    private var _ended = false

    var frames: [String] { lock.withLock { _frames } }
    var ended: Bool { lock.withLock { _ended } }

    var follower: DetachedPhoneRun.Follower {
        DetachedPhoneRun.Follower(
            frames: { frames in self.lock.withLock { self._frames += frames } },
            end: { self.lock.withLock { self._ended = true } }
        )
    }
}

struct DetachedPhoneRunsTests {
    @Test func rejoiningReplaysWhatWasMissedThenFollowsLive() {
        let run = DetachedPhoneRun(id: "r1")
        run.record("data: a\n\n")
        run.record("data: b\n\n")
        let received = Received()
        #expect(run.follow(after: 1, received.follower) != .gone)
        #expect(received.frames == ["data: b\n\n"])

        run.record("data: c\n\n")
        #expect(received.frames == ["data: b\n\n", "data: c\n\n"])
        #expect(!received.ended)
        run.finish()
        #expect(received.ended)
    }

    @Test func rejoiningAFinishedRunReplaysAndEnds() {
        let run = DetachedPhoneRun(id: "r2")
        run.record("data: a\n\n")
        run.finish()
        run.record("data: late\n\n")
        let received = Received()
        #expect(run.follow(after: 0, received.follower) != .gone)
        #expect(received.frames == ["data: a\n\n"])
        #expect(received.ended)
    }

    @Test func anIndexPastTheEndIsGone() {
        let run = DetachedPhoneRun(id: "r3")
        run.record("data: a\n\n")
        #expect(run.follow(after: 2, Received().follower) == .gone)
        #expect(run.follow(after: -1, Received().follower) == .gone)
    }

    @Test func anUnfollowedClientHearsNothingMore() {
        let run = DetachedPhoneRun(id: "r4")
        let received = Received()
        guard case .following(let token) = run.follow(after: 0, received.follower) else {
            Issue.record("expected to follow")
            return
        }
        run.unfollow(token)
        run.record("data: a\n\n")
        run.finish()
        #expect(received.frames.isEmpty)
        #expect(!received.ended)
    }

    @Test func stopRunsTheHandlerEvenWhenItArrivesFirst() {
        let run = DetachedPhoneRun(id: "r5")
        #expect(run.stop())
        let stopped = Received()
        run.onStop { stopped.follower.end() }
        #expect(stopped.ended)

        run.finish()
        #expect(!run.stop())
    }

    @Test func theSameIdWhileLiveJoinsTheRunningOne() {
        let runs = DetachedPhoneRuns()
        let first = runs.begin(id: "same")
        #expect(first.isNew)
        let again = runs.begin(id: "same")
        #expect(!again.isNew)
        #expect(again.run === first.run)

        first.run.finish()
        let after = runs.begin(id: "same")
        #expect(after.isNew)
        #expect(after.run !== first.run)
    }

    @Test func finishedRunsAreForgottenAfterTheRetention() {
        let runs = DetachedPhoneRuns()
        let run = runs.begin(id: "old").run
        run.finish()
        #expect(runs.run(id: "old") != nil)
        let later = Date().addingTimeInterval(DetachedPhoneRuns.retention + 1)
        #expect(runs.run(id: "old", now: later) == nil)
    }

    @Test func theRunRequestCarriesItsId() throws {
        let json = #"{"messages":[],"model":"","osaurus_run_id":"r-1"}"#
        let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        #expect(request.osaurus_run_id == "r-1")
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!encoded.contains("osaurus_run_id"))
    }

    @Test func runIdsArePlain() {
        #expect(DetachedPhoneRuns.isValidId(UUID().uuidString))
        #expect(!DetachedPhoneRuns.isValidId(""))
        #expect(!DetachedPhoneRuns.isValidId("../etc"))
        #expect(!DetachedPhoneRuns.isValidId(String(repeating: "a", count: 129)))
    }
}
