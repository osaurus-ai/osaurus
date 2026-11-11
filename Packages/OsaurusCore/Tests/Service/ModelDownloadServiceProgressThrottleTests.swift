//
//  ModelDownloadServiceProgressThrottleTests.swift
//  osaurusTests
//
//  Download progress used to be published to `@Published` state on every
//  per-file callback, re-rendering the whole model grid many times per
//  second and tripping the app-hang watchdog. These tests pin the
//  coalescing rule in `shouldPublishProgress`.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelDownloadServiceProgressThrottleTests {

    @Test func publishesFirstUpdate() {
        #expect(
            ModelDownloadService.shouldPublishProgress(
                now: 100, fraction: 0.0, lastTime: nil, lastFraction: nil
            )
        )
    }

    @Test func suppressesSmallRapidUpdates() {
        #expect(
            !ModelDownloadService.shouldPublishProgress(
                now: 100.1, fraction: 0.405, lastTime: 100, lastFraction: 0.40
            )
        )
    }

    @Test func publishesAfterInterval() {
        #expect(
            ModelDownloadService.shouldPublishProgress(
                now: 100 + ModelDownloadService.progressPublishInterval,
                fraction: 0.401, lastTime: 100, lastFraction: 0.40
            )
        )
    }

    @Test func publishesLargeJumpImmediately() {
        #expect(
            ModelDownloadService.shouldPublishProgress(
                now: 100.05, fraction: 0.42, lastTime: 100, lastFraction: 0.40
            )
        )
    }

    @Test func alwaysPublishesCompletion() {
        #expect(
            ModelDownloadService.shouldPublishProgress(
                now: 100.01, fraction: 1.0, lastTime: 100, lastFraction: 0.995
            )
        )
    }

    @Test func burstOfCallbacksIsCoalesced() {
        // 4 files × 4 callbacks/s for 2s, tiny increments each.
        var lastTime: TimeInterval?
        var lastFraction: Double?
        var published = 0
        var fraction = 0.0
        var now: TimeInterval = 0
        for _ in 0..<32 {
            now += 0.0625
            fraction += 0.0005
            if ModelDownloadService.shouldPublishProgress(
                now: now, fraction: fraction, lastTime: lastTime, lastFraction: lastFraction
            ) {
                published += 1
                lastTime = now
                lastFraction = fraction
            }
        }
        #expect(published <= 5)
        #expect(published >= 1)
    }
}
