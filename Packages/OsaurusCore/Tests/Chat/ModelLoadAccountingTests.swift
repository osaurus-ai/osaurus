//
//  ModelLoadAccountingTests.swift
//  OsaurusCoreTests
//
//  Global model-load union/clipping diagnostics. These intervals do not
//  identify an individual request, so ChatView must not subtract them from
//  that request's TTFT. Request-owned TTFT coverage is in
//  ResponsesVisualLifecycleTests.
//

import XCTest

@testable import OsaurusCore

@MainActor
final class ModelLoadAccountingTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 10_000)

    private func manager() -> InferenceProgressManager {
        InferenceProgressManager._testMake()
    }

    // MARK: - The reported case

    /// The reported 212s global load interval is measurable, but not enough
    /// to assign that interval to a particular request.
    func testGlobalColdLoadIntervalIsRecordedWithoutRequestAttribution() {
        let m = manager()
        let sendAt = t0
        m._testBeginModelLoad(at: sendAt.addingTimeInterval(0.1))
        m._testEndModelLoad(at: sendAt.addingTimeInterval(212.1))

        let firstToken = sendAt.addingTimeInterval(215.61)
        let load = m.modelLoadSeconds(from: sendAt, to: firstToken)

        XCTAssertEqual(load, 212.0, accuracy: 0.01)
    }

    // MARK: - Union, not sum

    /// Two models loading concurrently is still ONE stretch of wall-clock the
    /// user waited through. Summing them would subtract more time than the
    /// window contains and report a TTFT of zero.
    func testConcurrentLoadsCountAsOneStretchNotTwo() {
        let m = manager()
        m._testBeginModelLoad(at: t0.addingTimeInterval(1))
        m._testBeginModelLoad(at: t0.addingTimeInterval(2))
        m._testEndModelLoad(at: t0.addingTimeInterval(9))
        m._testEndModelLoad(at: t0.addingTimeInterval(11))

        let load = m.modelLoadSeconds(from: t0, to: t0.addingTimeInterval(20))
        XCTAssertEqual(load, 10.0, accuracy: 0.01, "union is 1s..11s = 10s, not 8+9=17s")
    }

    /// Sequential loads inside one window do add up — they are disjoint.
    func testSequentialLoadsAccumulate() {
        let m = manager()
        m._testBeginModelLoad(at: t0.addingTimeInterval(1))
        m._testEndModelLoad(at: t0.addingTimeInterval(3))
        m._testBeginModelLoad(at: t0.addingTimeInterval(5))
        m._testEndModelLoad(at: t0.addingTimeInterval(6))

        XCTAssertEqual(
            m.modelLoadSeconds(from: t0, to: t0.addingTimeInterval(10)), 3.0, accuracy: 0.01)
    }

    // MARK: - Clipping

    /// A load that began before this send contributes only its overlap. The
    /// user did not wait through the part that happened before they hit send.
    func testLoadStartingBeforeTheWindowIsClipped() {
        let m = manager()
        m._testBeginModelLoad(at: t0.addingTimeInterval(-30))
        m._testEndModelLoad(at: t0.addingTimeInterval(5))

        XCTAssertEqual(
            m.modelLoadSeconds(from: t0, to: t0.addingTimeInterval(10)), 5.0, accuracy: 0.01)
    }

    /// A load still running when the first token arrives is the COLD case we
    /// care about most. Ignoring an unclosed interval would leave the whole
    /// load billed as TTFT — the original defect.
    func testStillRunningLoadCountsUpToTheFirstToken() {
        let m = manager()
        m._testBeginModelLoad(at: t0.addingTimeInterval(1))
        // deliberately never ended

        XCTAssertEqual(
            m.modelLoadSeconds(from: t0, to: t0.addingTimeInterval(9)), 8.0, accuracy: 0.01)
    }

    func testLoadEntirelyOutsideTheWindowContributesNothing() {
        let m = manager()
        m._testBeginModelLoad(at: t0.addingTimeInterval(-100))
        m._testEndModelLoad(at: t0.addingTimeInterval(-50))

        XCTAssertEqual(m.modelLoadSeconds(from: t0, to: t0.addingTimeInterval(10)), 0)
    }

    // MARK: - Never over-subtract

    /// The floor that stops a reassuring lie: subtracted load can never exceed
    /// the window, so the reported TTFT can never go negative.
    func testLoadCanNeverExceedTheWindowItIsMeasuredAgainst() {
        let m = manager()
        m._testBeginModelLoad(at: t0.addingTimeInterval(-500))

        let window: TimeInterval = 4
        let load = m.modelLoadSeconds(from: t0, to: t0.addingTimeInterval(window))
        XCTAssertLessThanOrEqual(load, window)
        XCTAssertGreaterThanOrEqual(window - load, 0)
    }

    func testInvertedWindowYieldsZero() {
        let m = manager()
        m._testBeginModelLoad(at: t0)
        m._testEndModelLoad(at: t0.addingTimeInterval(5))
        XCTAssertEqual(m.modelLoadSeconds(from: t0.addingTimeInterval(10), to: t0), 0)
    }

    /// A finish stamped before its start (clock adjustment, or a caller pairing
    /// out of order) must not create a negative-length interval that subtracts
    /// time never spent.
    func testOutOfOrderPairingIsDiscarded() {
        let m = manager()
        m._testBeginModelLoad(at: t0.addingTimeInterval(5))
        m._testEndModelLoad(at: t0.addingTimeInterval(1))
        XCTAssertEqual(m.modelLoadSeconds(from: t0, to: t0.addingTimeInterval(10)), 0)
    }

    // MARK: - Warm path

    /// The overwhelmingly common case: model already resident, no load at all,
    /// so the reported TTFT is unchanged. This feature must be invisible when
    /// nothing loaded.
    func testWarmModelReportsNoLoadTime() {
        let m = manager()
        XCTAssertEqual(m.modelLoadSeconds(from: t0, to: t0.addingTimeInterval(3)), 0)
    }

    /// The refcount still drives the "Loading Model…" UI, so the existing
    /// behaviour must survive the accounting change.
    func testRefcountStillTracksLoadingState() {
        let m = manager()
        XCTAssertFalse(m.isLoadingModel)
        m._testBeginModelLoad(at: t0)
        XCTAssertTrue(m.isLoadingModel)
        m._testBeginModelLoad(at: t0.addingTimeInterval(1))
        XCTAssertTrue(m.isLoadingModel)
        m._testEndModelLoad(at: t0.addingTimeInterval(2))
        XCTAssertTrue(m.isLoadingModel, "still one load in flight")
        m._testEndModelLoad(at: t0.addingTimeInterval(3))
        XCTAssertFalse(m.isLoadingModel)
    }

    /// Unbalanced finishes must not drive the refcount negative and poison
    /// every later load.
    func testExtraFinishCannotDriveRefcountNegative() {
        let m = manager()
        m._testEndModelLoad(at: t0)
        m._testEndModelLoad(at: t0.addingTimeInterval(1))
        XCTAssertEqual(m.loadInFlightCount, 0)
        m._testBeginModelLoad(at: t0.addingTimeInterval(2))
        XCTAssertTrue(m.isLoadingModel, "a later load must still register")
    }
}
