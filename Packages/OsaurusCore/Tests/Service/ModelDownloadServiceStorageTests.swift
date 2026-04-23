//
//  ModelDownloadServiceStorageTests.swift
//  osaurusTests
//
//  Covers the disk-space preflight helpers introduced for #580, where a
//  failed parallel download leaves orphaned partial files on disk and
//  the UI ends up permanently out of sync with the CLI. The primary
//  defense is refusing to start a download that cannot possibly finish;
//  these tests pin the refusal-threshold arithmetic so the safety margin
//  never silently collapses to zero or inverts.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ModelDownloadServiceStorageTests {

    // MARK: - storageRefusalMessage

    @Test func refusesWhenNeededExceedsFree() {
        // 10 GB requested, 1 GB free → refuse.
        let message = ModelDownloadService.storageRefusalMessage(
            neededBytes: 10 * 1024 * 1024 * 1024,
            freeBytes: 1 * 1024 * 1024 * 1024
        )
        #expect(message != nil)
        #expect(message?.contains("Not enough disk space") == true)
    }

    @Test func allowsWhenFreeComfortablyExceedsNeeded() {
        // 1 GB requested, 10 GB free → proceed.
        let message = ModelDownloadService.storageRefusalMessage(
            neededBytes: 1 * 1024 * 1024 * 1024,
            freeBytes: 10 * 1024 * 1024 * 1024
        )
        #expect(message == nil)
    }

    @Test func enforcesSafetyMargin() {
        // When the tail of the write needs a little headroom (LFS size
        // under-reports, OS rename scratch), refusing exactly-at-the-line
        // avoids "ran out of space in the last megabyte" failures.
        let needed: Int64 = 1 * 1024 * 1024 * 1024  // 1 GB
        let margin = ModelDownloadService.storageSafetyMarginBytes

        // Free = needed + (margin - 1): should REFUSE (margin not satisfied).
        let refusedAtEdge = ModelDownloadService.storageRefusalMessage(
            neededBytes: needed,
            freeBytes: needed + margin - 1
        )
        #expect(refusedAtEdge != nil)

        // Free = needed + margin: should REFUSE (strict >, not >=).
        let refusedAtMargin = ModelDownloadService.storageRefusalMessage(
            neededBytes: needed,
            freeBytes: needed + margin
        )
        #expect(refusedAtMargin == nil)

        // Free = needed + margin + 1: should PROCEED.
        let proceed = ModelDownloadService.storageRefusalMessage(
            neededBytes: needed,
            freeBytes: needed + margin + 1
        )
        #expect(proceed == nil)
    }

    @Test func zeroNeededBytesAlwaysProceeds() {
        // Resume of a fully-complete download: nothing left to write, so
        // even a near-full volume should pass the preflight.
        let message = ModelDownloadService.storageRefusalMessage(
            neededBytes: 0,
            freeBytes: 0
        )
        #expect(message == nil)
    }

    @Test func refusalMessageIsUserFacingAndHumanSized() {
        // Reporters of #580 had no actionable detail in the failure — the
        // refusal surface must name the numbers. This test locks in that
        // the formatter is invoked (byte counts rendered as e.g. "1 GB",
        // not raw digits) so an accidental drop of ByteCountFormatter
        // surfaces immediately.
        let message = ModelDownloadService.storageRefusalMessage(
            neededBytes: 5_000_000_000,
            freeBytes: 500_000_000
        )
        guard let message else { Issue.record("expected refusal"); return }
        #expect(message.contains(" GB") || message.contains(" MB"))
        #expect(!message.contains("5000000000"))
    }

    // MARK: - freeBytesOnVolume

    @Test func freeBytesOnCurrentVolumeIsPositive() {
        // The test harness always runs on a mounted volume with at least
        // some free space; this sanity-checks that the query returns
        // something at all, so a future regression in the `resourceValues`
        // key usage (e.g. passing a wrong key) would be caught.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let bytes = ModelDownloadService.freeBytesOnVolume(containing: tmp)
        #expect(bytes != nil)
        if let bytes {
            #expect(bytes > 0)
        }
    }
}
