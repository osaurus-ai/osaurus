import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

/// Locks the Phase-1 CPU telemetry: `ProcessCpuProbe` is monotonic and the
/// combined RAM+CPU `ResourceSampler` returns real, non-negative readings —
/// the per-case CPU% the perf loop now records alongside tok/s and RAM.
///
/// Gated behind `OSAURUS_EVALS_ENABLED=1` per the package README so it never
/// runs in an accidental `swift test` sweep (it spins the CPU briefly). It
/// invokes no model, so it burns no tokens.
@Suite
struct ResourceSamplerTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["OSAURUS_EVALS_ENABLED"] == "1"
    }

    /// Spin enough to (very likely) advance the CPU clock, but assert only the
    /// invariants that always hold so the test can't flake on a busy host.
    private func burnCpu(_ iterations: Int) {
        var sink = 0.0
        for i in 0 ..< iterations { sink += Double(i).squareRoot() }
        // Force the loop to have an observable effect so it isn't elided.
        #expect(sink >= 0)
    }

    @Test(.enabled(if: ResourceSamplerTests.enabled))
    func cpuProbeIsMonotonicAndNonNegative() {
        guard let first = ProcessCpuProbe.cumulativeCpuSeconds() else {
            Issue.record("ProcessCpuProbe.cumulativeCpuSeconds() returned nil")
            return
        }
        burnCpu(2_000_000)
        guard let second = ProcessCpuProbe.cumulativeCpuSeconds() else {
            Issue.record("ProcessCpuProbe.cumulativeCpuSeconds() returned nil on re-read")
            return
        }
        #expect(first >= 0)
        #expect(second >= first)  // cumulative CPU time never decreases
    }

    @Test(.enabled(if: ResourceSamplerTests.enabled))
    func samplerReportsPeakRamAndCpu() {
        let sampler = ResourceSampler.start(intervalMs: 20)
        // Stay busy long enough for several sampling ticks to land.
        let deadline = Date().addingTimeInterval(0.3)
        var i = 0
        while Date() < deadline {
            burnCpu(50_000)
            i &+= 1
        }
        let sample = sampler.stop()

        #expect(sample.peakPhysFootprintMb != nil)
        if let mb = sample.peakPhysFootprintMb { #expect(mb > 0) }
        // getrusage always succeeds on macOS and the window is > 0, so a mean
        // is always derivable; utilization is a non-negative percentage.
        #expect(sample.meanCpuPercent != nil)
        if let cpu = sample.meanCpuPercent { #expect(cpu >= 0) }
        if let peak = sample.peakCpuPercent { #expect(peak >= 0) }
    }

    /// Regression pin for the 123,571% "peak CPU" row in the live matrix:
    /// when the sampler thread is preempted between its CPU-clock and
    /// wall-clock reads, one tick's anchors skew and the next tick divides a
    /// real CPU delta by a near-zero wall delta. Instantaneous rates are now
    /// (a) dropped when the wall window is under the trust threshold and
    /// (b) clamped to the physical all-cores ceiling. This test hammers the
    /// tick path with a 1 ms interval (forcing tiny windows) under real CPU
    /// burn and asserts the recorded peak never exceeds the machine ceiling.
    @Test(.enabled(if: ResourceSamplerTests.enabled))
    func peakCpuNeverExceedsPhysicalCoreCeiling() {
        let sampler = ResourceSampler.start(intervalMs: 1)
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            burnCpu(50_000)
        }
        let sample = sampler.stop()

        let ceiling = Double(ProcessInfo.processInfo.activeProcessorCount) * 100.0
        if let peak = sample.peakCpuPercent {
            #expect(peak >= 0)
            #expect(
                peak <= ceiling,
                "peak \(peak)% exceeds \(ceiling)% physical ceiling — wall/cpu read skew leaked through"
            )
        }
        if let mean = sample.meanCpuPercent {
            #expect(mean <= ceiling)
        }
    }
}
