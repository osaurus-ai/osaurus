//
//  CacheSectionWiringTests.swift
//  OsaurusCoreTests
//
//  Source-coverage for the Clear SSD Cache control.
//
//  The purge ACTION is proven by execution in vmlx's
//  DiskCacheQuotaEnforcementTests, which drives a real DiskCache and asserts
//  that clear() removes indexed payloads and orphaned safetensors alike. What
//  that cannot cover is whether the button in Settings is actually connected to
//  it — a button wired to nothing compiles, renders, and does nothing, which is
//  the exact shape of the decode-path defect earlier in this campaign (vmlx
//  populated nativeMTPStats every turn and the app never read it).
//
//  This is deliberately source-coverage rather than a UI-driven test: the
//  Settings window cannot be driven reliably in this harness, and a wiring
//  assertion that only passes when someone can click is a wiring assertion that
//  silently stops running.
//

import XCTest

final class CacheSectionWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        // Tests/Chat/... -> package root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The button must call the purge, not merely exist.
    func testClearButtonCallsClearDiskCaches() throws {
        let src = try source("Views/Settings/ServerSettings/CacheSection.swift")
        XCTAssertTrue(src.contains("Clear SSD Cache"), "the control is missing entirely")
        XCTAssertTrue(
            src.contains("await ModelRuntime.shared.clearDiskCaches()"),
            "Clear SSD Cache is not wired to the purge")
    }

    /// It must report the outcome. A purge that silently does nothing — because
    /// no model was resident and the sweep found no files — is indistinguishable
    /// from a working one without a result line.
    func testClearButtonReportsItsOutcome() throws {
        let src = try source("Views/Settings/ServerSettings/CacheSection.swift")
        XCTAssertTrue(src.contains("result.reclaimedBytes"), "outcome is not read")
        XCTAssertTrue(src.contains("Cleared %@"), "no success summary")
        XCTAssertTrue(src.contains("Cache was already empty"), "no empty-cache summary")
    }

    /// Guards against double-firing a destructive action while it runs.
    func testClearButtonDisablesItselfWhileRunning() throws {
        let src = try source("Views/Settings/ServerSettings/CacheSection.swift")
        XCTAssertTrue(src.contains("isClearingDiskCache = true"))
        XCTAssertTrue(src.contains(".disabled(isClearingDiskCache)"))
    }

    /// The purge must route through the coordinator when a model is resident,
    /// because that path takes MLXDiskCacheIOLock before deleting. Sweeping the
    /// directory directly while a restore is mid-read is the race this avoids.
    func testPurgeRoutesThroughTheCoordinatorWhenResident() throws {
        let src = try source("Services/ModelRuntime.swift")
        XCTAssertTrue(src.contains("coordinator.clear()"), "does not use the locked path")
        XCTAssertTrue(
            src.contains("clearedWithoutResidentModel"),
            "the no-resident-model case is not reported back to the caller")
    }

    /// The footer readout must measure the CONFIGURED cache directory. Reading
    /// the default path while a custom Disk Cache Directory is set reports a
    /// plausible number about the wrong folder — found live, fixed, pinned here.
    func testFooterMeasuresTheConfiguredCacheDirectory() throws {
        let src = try source("Views/Chat/FloatingInputCard.swift")
        XCTAssertTrue(
            src.contains("ModelRuntime.cacheDiskDirectoryOverride(for: settings.cache)"),
            "footer ignores a configured Disk Cache Directory")
        XCTAssertFalse(
            src.contains("usedBytes: OsaurusPaths.diskKVCacheUsageBytes()"),
            "footer reverted to the hardcoded default cache path")
    }

    /// The row must survive an idle chat. Gating it on a resident model's cap
    /// made the whole readout vanish with nothing loaded.
    func testFooterFallsBackWhenNoModelIsResident() throws {
        let src = try source("Views/Chat/FloatingInputCard.swift")
        XCTAssertTrue(src.contains("directorySizeIfExists(at: dir)"))
        XCTAssertTrue(
            src.contains("diskCache.usedBytes > 0 || diskCache.maxBytes > 0"),
            "the section is gated such that it disappears without a cap")
    }
}
