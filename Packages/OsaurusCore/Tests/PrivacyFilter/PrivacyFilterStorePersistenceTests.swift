//
//  PrivacyFilterStorePersistenceTests.swift
//  osaurus / PrivacyFilter Tests
//
//  Regression coverage for the "toggle resets to off after restart"
//  bug. The two contributing causes were:
//
//    1. `PrivacyView.save()` deferred the JSON write through
//       `Task.detached`, racing a quick Cmd-Q. `save()` is now
//       synchronous; we cover that callers reach the disk before
//       returning by writing + immediately reading a fresh snapshot
//       through the override directory.
//    2. Other privacy tests (`PrivacyReviewServiceTests`,
//       `PrivacyFilterPipelineCancelTests`) called
//       `PrivacyFilterStore.save(PrivacyFilterConfiguration())`
//       directly, clobbering `~/.osaurus/config/privacy-filter.json`
//       on every `swift test` run. This suite both
//       a) verifies the override directory path takes effect, and
//       b) leaves the real config path untouched.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("PrivacyFilterStore persistence", .serialized)
struct PrivacyFilterStorePersistenceTests {

    /// Per-test sandbox so the serial cases never see each other's
    /// writes. The returned guard MUST be released via `defer`
    /// (`guard.release()`) — it holds the cross-suite
    /// `PrivacyFilterStoreTestLock` for the test body and resets
    /// the override directory at release.
    ///
    /// `async` because the cross-suite lock is actor-backed (see
    /// `PrivacyFilterStoreTestLock` for the MainActor-deadlock
    /// rationale).
    private func makeSandbox() async -> PrivacyStoreSandboxGuard {
        await acquirePrivacyStoreSandbox("PrivacyFilterStorePersistenceTests")
    }

    /// The canonical "did the toggle stick?" round-trip:
    ///   • Toggle ON via `save()`.
    ///   • Drop the in-memory cache (simulates a fresh app launch).
    ///   • `snapshot()` should re-hydrate from disk and report
    ///     `enabled == true`.
    /// If this regresses, the chat will silently send unscrubbed
    /// data after the user closed the app expecting the filter to
    /// be on.
    @Test func enabledTrue_persistsAcrossSnapshotInvalidation() async throws {
        let guard_ = await makeSandbox()
        defer { guard_.release() }

        var config = PrivacyFilterConfiguration()
        config.enabled = true
        PrivacyFilterStore.save(config)

        // File must exist immediately after `save` returns — this is
        // the exact contract that broke when `save()` was deferred
        // through `Task.detached`.
        let onDisk = guard_.sandbox.appendingPathComponent("privacy-filter.json")
        #expect(FileManager.default.fileExists(atPath: onDisk.path))

        PrivacyFilterStore.invalidateSnapshot()
        let reloaded = PrivacyFilterStore.snapshot()
        #expect(reloaded.enabled == true)
    }

    /// Non-default mutable fields round-trip through encode + decode
    /// without losing their `enabled` setting. This catches a
    /// `Codable` regression that drops `enabled` in favour of the
    /// `decodeIfPresent` default (`false`), which would also surface
    /// to the user as "I turned it on and it forgot".
    @Test func fullConfiguration_persistsAcrossInvalidation() async throws {
        let guard_ = await makeSandbox()
        defer { guard_.release() }

        var config = PrivacyFilterConfiguration()
        config.enabled = true
        config.skipCodeBlocks = false
        config.alwaysApproveByDefault = true
        config.builtinPatternEnabled[.url] = false
        PrivacyFilterStore.save(config)

        PrivacyFilterStore.invalidateSnapshot()
        let reloaded = PrivacyFilterStore.snapshot()
        #expect(reloaded.enabled == true)
        #expect(reloaded.skipCodeBlocks == false)
        #expect(reloaded.alwaysApproveByDefault == true)
        #expect(reloaded.isBuiltinPatternEnabled(.url) == false)
    }

    /// Confirms `setOverrideDirectory(_:)` actually re-routes writes
    /// when swapped between sandboxes. The earlier shape of this
    /// test just read the same file twice and asserted equality,
    /// which proved nothing — this one writes through two distinct
    /// override paths and asserts each landed at the right place.
    /// If the override mechanism silently kept the first sandbox,
    /// the second sandbox would stay empty and we'd catch it here.
    @Test func overrideDirectory_swapsBetweenSandboxes() async throws {
        let guard_ = await makeSandbox()
        defer { guard_.release() }
        let sandboxA = guard_.sandbox

        var configA = PrivacyFilterConfiguration()
        configA.enabled = true
        PrivacyFilterStore.save(configA)

        let fileA = sandboxA.appendingPathComponent("privacy-filter.json")
        #expect(FileManager.default.fileExists(atPath: fileA.path))

        // Swap to a second sandbox mid-flight (production callers
        // never do this, but tests routinely tear down and re-init
        // — verifies the override is hot-swap safe). We swap the
        // override DIRECTLY rather than going through
        // `acquirePrivacyStoreSandbox` again, which would re-acquire
        // the cross-suite lock the outer guard already holds.
        let sandboxB = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "osaurus-PrivacyFilterStorePersistenceTests-swap-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(at: sandboxB, withIntermediateDirectories: true)
        PrivacyFilterStore.setOverrideDirectory(sandboxB)

        var configB = PrivacyFilterConfiguration()
        configB.skipCodeBlocks = false
        PrivacyFilterStore.save(configB)

        let fileB = sandboxB.appendingPathComponent("privacy-filter.json")
        #expect(FileManager.default.fileExists(atPath: fileB.path))
        // The second write must NOT have touched sandboxA — that's
        // the assertion that proves the override path actually
        // changed rather than the second save piggy-backing on the
        // first directory.
        let aData = try Data(contentsOf: fileA)
        let aDecoded = try JSONDecoder().decode(PrivacyFilterConfiguration.self, from: aData)
        #expect(aDecoded.enabled == true)
        #expect(aDecoded.skipCodeBlocks == true)  // default

        let bData = try Data(contentsOf: fileB)
        let bDecoded = try JSONDecoder().decode(PrivacyFilterConfiguration.self, from: bData)
        #expect(bDecoded.enabled == false)  // default
        #expect(bDecoded.skipCodeBlocks == false)
    }
}
