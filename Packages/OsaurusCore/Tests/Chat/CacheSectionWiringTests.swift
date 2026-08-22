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

    /// The size control must edit the PERCENT, not the legacy GB field.
    ///
    /// The cap auto-sized to 10% of the disk while the control still asked for
    /// gigabytes — two units for one idea, which is the confusion this change
    /// exists to remove. Binding back to `maxSizeGB` would restore it, and the
    /// field is now nil on every migrated install so the box would also read
    /// empty while a real cap was in force.
    func testSizeControlEditsThePercentNotGigabytes() throws {
        let src = try source("Views/Settings/ServerSettings/CacheSection.swift")
        XCTAssertTrue(
            src.contains("$draft.cache.blockDisk.maxSizePercent"),
            "the size control is not bound to the percent")
        XCTAssertFalse(
            src.contains("$draft.cache.blockDisk.maxSizeGB"),
            "the control reverted to editing gigabytes")
        XCTAssertTrue(src.contains("Disk Cache Size (% of disk)"), "label still says GB")
    }

    /// The "≈ X GB" readout must come from the engine's own resolver. A second
    /// estimate in the UI can disagree with the cap actually enforced, and the
    /// user has no way to tell which one is real.
    func testResolvedSizeLabelUsesTheEngineResolver() throws {
        let src = try source("Views/Settings/ServerSettings/CacheSection.swift")
        XCTAssertTrue(
            src.contains("VMLXServerRuntimeSettings.resolveDiskCacheMaxGB("),
            "the readout does not use the resolver the coordinator uses")
        XCTAssertTrue(src.contains("VMLXServerRuntimeSettings.cacheVolumeCapacityGB("))
    }

    /// Diagnostics must not report `null` for a cache that has a real cap.
    /// `maxSizeGB` is nil on every migrated install, so reporting it raw would
    /// say "no limit" while a limit was being enforced.
    func testDiagnosticsReportTheResolvedCapNotTheStaleField() throws {
        let src = try source("Networking/HTTPHandler.swift")
        XCTAssertTrue(src.contains("\"block_disk_max_size_percent\""))
        XCTAssertTrue(
            src.contains("\"block_disk_max_size_gb\": VMLXServerRuntimeSettings.resolveDiskCacheMaxGB("),
            "diagnostics still report the raw stored field")
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

    /// The readout must show the cap the ENGINE enforces, not the share in
    /// isolation.
    ///
    /// Caught live: with 10% of a 3.7 TB volume the share resolved to 372 GB,
    /// but `applyHostAwareDiskCacheCeiling` additionally bounds the cap to a
    /// quarter of free bytes, and only 969 GB was free — so the coordinator
    /// enforced 242 GB. A label showing 372 would over-promise by 130 GB and
    /// contradict the "Active" row a few lines below it in the same panel.
    func testReadoutsApplyTheHostAwareCeiling() throws {
        for path in [
            "Views/Settings/ServerSettings/CacheSection.swift",
            "Views/Chat/FloatingInputCard.swift",
        ] {
            let src = try source(path)
            XCTAssertTrue(
                src.contains("ModelRuntime.hostAwareDiskCacheDecision("),
                "\(path) reports the raw share and would over-promise on a full disk")
            XCTAssertTrue(
                src.contains("OsaurusPaths.volumeFreeBytes("),
                "\(path) never measures free space, so it cannot apply the ceiling")
        }
    }

    /// When the ceiling bites, the label has to say WHY. A user who set 10%
    /// and sees a smaller number otherwise reads it as the setting being
    /// ignored.
    func testLimitedLabelNamesTheReason() throws {
        let src = try source("Views/Settings/ServerSettings/CacheSection.swift")
        XCTAssertTrue(src.contains("disk is nearly full"), "the lower cap is unexplained")
    }
}
