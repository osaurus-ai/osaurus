import Foundation
import Testing

@testable import OsaurusCore

/// Unit coverage for the local startup-metrics store: ring-buffer cap,
/// first-agent-ready stamping semantics, and the closed telemetry
/// bucket set. Serialized because the store persists to a single file
/// under the (test-root-redirected) container directory; file-touching
/// tests additionally take `StoragePathsTestLock` so suites that swap
/// `OsaurusPaths.overrideRoot` mid-run can't move the store out from
/// under them.
@Suite(.serialized)
struct SandboxStartupMetricsTests {
    private func withStore(_ body: @Sendable () async throws -> Void) async rethrows {
        try await StoragePathsTestLock.shared.run {
            clearStore()
            defer { clearStore() }
            try await body()
        }
    }

    private func clearStore() {
        try? FileManager.default.removeItem(
            at: OsaurusPaths.container().appendingPathComponent("startup-metrics.json")
        )
    }

    private func makeSample(kind: SandboxBootSample.BootKind = .cold) -> SandboxBootSample {
        SandboxBootSample(
            kind: kind,
            startedAt: Date(),
            assetResolution: 1.5,
            containerCreate: kind == .warm ? nil : 12.0,
            vmBoot: 2.0,
            configure: 0.8,
            totalToRunning: 16.5
        )
    }

    @Test
    func record_roundTripsAndCapsAtMaxSamples() async {
        await withStore {
            for _ in 0..<(SandboxStartupMetricsStore.maxSamples + 5) {
                SandboxStartupMetricsStore.record(makeSample())
            }

            let samples = SandboxStartupMetricsStore.load()
            #expect(samples.count == SandboxStartupMetricsStore.maxSamples)
            #expect(samples.last?.kind == .cold)
            #expect(samples.last?.containerCreate == 12.0)
        }
    }

    @Test
    func recordFirstAgentReady_stampsOnlyTheLatestUnstampedSample() async {
        await withStore {
            SandboxStartupMetricsStore.record(makeSample(kind: .cold))
            SandboxStartupMetricsStore.record(makeSample(kind: .warm))

            SandboxStartupMetricsStore.recordFirstAgentReady(seconds: 3.25)
            // Second stamp (a later agent on the same boot) must be a no-op.
            SandboxStartupMetricsStore.recordFirstAgentReady(seconds: 99.0)

            let samples = SandboxStartupMetricsStore.load()
            #expect(samples.count == 2)
            #expect(samples[0].firstAgentReady == nil)
            #expect(samples[1].firstAgentReady == 3.25)
        }
    }

    @Test
    func recordFirstAgentReady_withEmptyStoreIsANoOp() async {
        await withStore {
            SandboxStartupMetricsStore.recordFirstAgentReady(seconds: 1.0)
            #expect(SandboxStartupMetricsStore.load().isEmpty)
        }
    }

    @Test
    func latencyBucket_coversTheClosedSet() {
        #expect(SandboxStartupMetricsStore.latencyBucket(0.4) == "lt_1s")
        #expect(SandboxStartupMetricsStore.latencyBucket(3.0) == "1_5s")
        #expect(SandboxStartupMetricsStore.latencyBucket(10.0) == "5_15s")
        #expect(SandboxStartupMetricsStore.latencyBucket(45.0) == "15_60s")
        #expect(SandboxStartupMetricsStore.latencyBucket(180.0) == "1_5m")
        #expect(SandboxStartupMetricsStore.latencyBucket(600.0) == "gte_5m")
    }
}
