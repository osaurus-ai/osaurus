//
//  IgnoredDiskCapIsAnnouncedTests.swift
//  OsaurusCoreTests
//
//  `resolveDiskCacheMaxGB` consults `maxSizePercent` first and only falls
//  through to `maxSizeGB` when the percent is nil or zero. The app writes a
//  percent by default, so a GB cap written into the config is accepted,
//  persisted, and then not enforced — measured live, a config asking for
//  0.5 GB let the cache reach 3897 MB.
//
//  These pin the precedence itself, so a future change to which field wins
//  cannot happen quietly: if the resolver is ever changed to honour the GB
//  value, the first test fails and whoever changed it has to update the
//  warning that tells users otherwise.
//

import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("An ignored disk cap is announced, not swallowed")
struct IgnoredDiskCapIsAnnouncedTests {

    private func volumeDir() -> URL {
        FileManager.default.temporaryDirectory
    }

    @Test("percent wins over an explicitly configured GB value")
    func percentTakesPrecedence() {
        let resolved = VMLXServerRuntimeSettings.resolveDiskCacheMaxGB(
            percent: 10,
            legacyGB: 0.5,
            directory: volumeDir()
        )
        // 10% of any real volume is far more than the 0.5 GB the user asked
        // for. The exact number depends on the machine; the point is that the
        // GB value is not what comes back.
        #expect(
            resolved > 0.5,
            "maxSizeGB is documented as ignored while a percent is set — if this now fails, the warning text is wrong"
        )
    }

    @Test("the GB value is honoured only when no percent is set")
    func gbHonouredWithoutPercent() {
        #expect(
            VMLXServerRuntimeSettings.resolveDiskCacheMaxGB(
                percent: nil, legacyGB: 0.5, directory: volumeDir()) == 0.5)
        // Zero is not "a share of zero", it is "unset" — the resolver requires
        // percent > 0, which is why a UI that rounded 0.005 down to 0.0 handed
        // the user the 10% default instead of a small cap.
        #expect(
            VMLXServerRuntimeSettings.resolveDiskCacheMaxGB(
                percent: 0, legacyGB: 0.5, directory: volumeDir()) == 0.5)
    }

    @Test("a percent alone resolves to a share, with no floor applied")
    func explicitShareHasNoFloor() {
        let tiny = VMLXServerRuntimeSettings.resolveDiskCacheMaxGB(
            percent: 0.001, legacyGB: nil, directory: volumeDir())
        #expect(
            tiny < VMLXServerRuntimeSettings.autoDiskCacheFloorGB,
            "an explicit share must not be clamped up to the auto floor — that would override a deliberate choice"
        )
    }
}
