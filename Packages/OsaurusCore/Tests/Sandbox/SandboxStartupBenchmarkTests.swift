import Foundation
import Testing

@testable import OsaurusCore

/// Opt-in startup benchmark. Boots the real sandbox VM three times —
/// truly cold (warm stamp AND base template cleared, forcing the full
/// image unpack), warm (reusing `rootfs.ext4`), and template-clone
/// (warm stamp cleared but template retained, exercising the CoW
/// clone fast path) — and prints the per-phase timings recorded by
/// `SandboxStartupMetricsStore` so optimization work is evidence-based.
///
/// Gated separately from the functional integration tests because it
/// deliberately destroys the warm cache: set
/// `OSAURUS_RUN_SANDBOX_BENCHMARK=1` to run. Requires Apple
/// Containerization and network access for the first (cold) provision.
///
/// NOTE: `VmnetNetwork` needs vmnet privileges the unsigned SwiftPM test
/// harness doesn't have — under plain `swift test` the boot fails with
/// "Container networking failed". Run this lane as root
/// (`sudo -E swift test …`) or drive the same three boots from a signed
/// app build; also stop any running Osaurus instance first so the VMs
/// don't contend for network resources.
private let isSandboxBenchmarkEnabled =
    ProcessInfo.processInfo.environment["OSAURUS_RUN_SANDBOX_BENCHMARK"] == "1"

@Suite(
    .serialized,
    .disabled(
        if: !isSandboxBenchmarkEnabled,
        "Set OSAURUS_RUN_SANDBOX_BENCHMARK=1 to run; boots the sandbox VM twice."
    )
)
struct SandboxStartupBenchmarkTests {
    @Test
    func coldWarmAndTemplateBoots_recordPhaseTimings() async throws {
        guard (await SandboxManager.shared.refreshAvailability()).isAvailable else { return }

        // Clear the warm-restart stamp AND the base template so the first
        // boot is a true cold path (full rootfs unpack) even when a
        // previous run left a reusable rootfs.ext4 or template behind.
        var config = SandboxConfigurationStore.load()
        config.lastBootedImageDigest = nil
        SandboxConfigurationStore.save(config)
        SandboxRootfsTemplateStore.removeAll()

        let baseline = SandboxStartupMetricsStore.load().count

        // Boot 1: cold (unpack, captures the base template).
        try await SandboxManager.shared.startContainer()
        try await SandboxManager.shared.stopContainer()
        // Boot 2: warm (reuses rootfs.ext4).
        try await SandboxManager.shared.startContainer()
        try await SandboxManager.shared.stopContainer()
        // Boot 3: template clone (warm stamp cleared, template retained).
        var invalidated = SandboxConfigurationStore.load()
        invalidated.lastBootedImageDigest = nil
        SandboxConfigurationStore.save(invalidated)
        try await SandboxManager.shared.startContainer()
        try await SandboxManager.shared.stopContainer()

        let samples = Array(SandboxStartupMetricsStore.load().dropFirst(baseline))
        try #require(samples.count == 3, "expected exactly three new boot samples")

        let cold = samples[0]
        let warm = samples[1]
        let template = samples[2]
        #expect(cold.kind == .cold)
        #expect(warm.kind == .warm || warm.kind == .warmFallback)
        #expect(template.kind == .template || template.kind == .cold)

        for sample in samples {
            print(
                """
                [SandboxBenchmark] kind=\(sample.kind.rawValue) \
                assets=\(format(sample.assetResolution)) \
                create=\(format(sample.containerCreate)) \
                vmBoot=\(format(sample.vmBoot)) \
                configure=\(format(sample.configure)) \
                total=\(format(sample.totalToRunning))
                """
            )
        }

        // The warm path exists to skip the unpack — require it to be
        // materially faster than the cold boot it follows, otherwise the
        // warm-restart machinery has silently regressed to cold work.
        if warm.kind == .warm {
            #expect(
                warm.totalToRunning < cold.totalToRunning,
                "warm boot (\(warm.totalToRunning)s) was not faster than cold (\(cold.totalToRunning)s)"
            )
        }
        // Same bar for the CoW clone path — it replaces the unpack.
        if template.kind == .template {
            #expect(
                template.totalToRunning < cold.totalToRunning,
                "template boot (\(template.totalToRunning)s) was not faster than cold (\(cold.totalToRunning)s)"
            )
        }
    }

    private func format(_ seconds: Double?) -> String {
        guard let seconds else { return "-" }
        return String(format: "%.2fs", seconds)
    }
}
