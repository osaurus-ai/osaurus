import Foundation
import Testing

@testable import OsaurusCore

/// The swap-pressure classifier's contract: severity keys on the episode's
/// MONOTONIC PEAK growth over the cold-load baseline (never absolute swap),
/// enters fast, exits only after the CURRENT growth recedes for sustained
/// samples, and the designer/QA emulation override parses strictly. The
/// episode lifecycle: cold loads begin/extend, warm reuse never resets,
/// failures with nothing resident clear, multi-model keeps one baseline.
@Suite struct SwapPressureMonitorTests {

    private func classify(
        current: Int64, peak: Int64? = nil,
        used: UInt64 = 6 << 30, total: UInt64 = 8 << 30,
        previous: SwapPressureMonitor.Severity, streak: inout Int
    ) -> SwapPressureMonitor.Severity {
        SwapPressureMonitor.classify(
            currentGrowthBytes: current,
            peakGrowthBytes: peak ?? current,
            usedBytes: used, totalBytes: total,
            previous: previous, exitStreak: &streak)
    }

    @Test("a Mac already deep in swap with no episode growth stays quiet")
    func absoluteSwapWithoutGrowthIsNone() {
        var streak = 0
        let severity = classify(
            current: 100 << 20, used: 7_500 << 20, total: 8 << 30,
            previous: .none, streak: &streak)
        #expect(severity == .none)
    }

    @Test("peak growth thresholds enter immediately")
    func enterThresholds() {
        var streak = 0
        #expect(classify(current: (3 << 29) - 1, previous: .none, streak: &streak) == .none)
        #expect(classify(current: 3 << 29, previous: .none, streak: &streak) == .elevated)
        #expect(classify(current: 4 << 30, previous: .none, streak: &streak) == .critical)
    }

    @Test("severity is judged on peak, so a transient dip cannot clear it alone")
    func peakIsMonotonicForEntry() {
        var streak = 0
        // Peak crossed critical, current dipped to zero: still critical
        // until the exit streak completes.
        #expect(
            classify(current: 0, peak: 5 << 30, previous: .critical, streak: &streak)
                == .critical)
        #expect(
            classify(current: 0, peak: 5 << 30, previous: .critical, streak: &streak)
                == .critical)
        #expect(
            classify(current: 0, peak: 5 << 30, previous: .critical, streak: &streak)
                == .none)
    }

    @Test("near-exhausted swap is critical only when the episode coincided with growth")
    func nearFullNeedsGrowth() {
        var streak = 0
        #expect(
            classify(
                current: 512 << 20, used: (8 << 30) - (60 << 20), total: 8 << 30,
                previous: .none, streak: &streak) == .none)
        #expect(
            classify(
                current: 2 << 30, used: (8 << 30) - (60 << 20), total: 8 << 30,
                previous: .none, streak: &streak) == .critical)
    }

    @Test("exit needs sustained current-growth calm below half the enter threshold")
    func hysteresis() {
        var streak = 0
        #expect(classify(current: 2 << 30, previous: .none, streak: &streak) == .elevated)
        #expect(
            classify(current: 100 << 20, peak: 2 << 30, previous: .elevated, streak: &streak)
                == .elevated)
        // Calm interrupted: streak resets.
        #expect(
            classify(current: 1 << 30, peak: 2 << 30, previous: .elevated, streak: &streak)
                == .elevated)
        #expect(
            classify(current: 100 << 20, peak: 2 << 30, previous: .elevated, streak: &streak)
                == .elevated)
        #expect(
            classify(current: 100 << 20, peak: 2 << 30, previous: .elevated, streak: &streak)
                == .elevated)
        #expect(
            classify(current: 100 << 20, peak: 2 << 30, previous: .elevated, streak: &streak)
                == .none)
    }

    @Test("worsening re-enters instantly regardless of streak")
    func worseningWins() {
        var streak = 2
        #expect(
            classify(current: 5 << 30, previous: .elevated, streak: &streak) == .critical)
        #expect(streak == 0)
    }

    @Test("episode lifecycle: warm reuse keeps the baseline, failure with nothing resident clears")
    func episodeLifecycle() {
        let monitor = SwapPressureMonitor()
        monitor.beginResidencyEpisode(model: "A")
        let first = monitor.currentState()
        #expect(first.phase == .loading)
        #expect(first.modelName == "A")

        // Second cold load extends the SAME episode (multi-model): the
        // label updates but the baseline persists (elapsed keeps counting).
        monitor.beginResidencyEpisode(model: "B")
        #expect(monitor.currentState().modelName == "B")

        monitor.markLoadCompleted(model: "B")
        #expect(monitor.currentState().phase == .resident)

        // Failure while another model remains resident keeps the episode.
        monitor.endEpisodeOnLoadFailure(residentCount: 1)
        #expect(monitor.currentState().phase == .resident)

        // Idle teardown ends it.
        monitor.endEpisodeIfIdle(residentCount: 0)
        #expect(monitor.currentState().phase == .idle)

        // Failure with nothing resident clears a fresh baseline too.
        monitor.beginResidencyEpisode(model: "C")
        monitor.endEpisodeOnLoadFailure(residentCount: 0)
        #expect(monitor.currentState().phase == .idle)
    }

    @Test("emulation override parses strictly and is tagged")
    func emulationParsing() {
        #expect(SwapPressureMonitor.parseEmulation("elevated") == .elevated)
        #expect(SwapPressureMonitor.parseEmulation(" CRITICAL\n") == .critical)
        #expect(SwapPressureMonitor.parseEmulation("warn") == .elevated)
        #expect(SwapPressureMonitor.parseEmulation("block") == .critical)
        #expect(SwapPressureMonitor.parseEmulation("nonsense") == nil)
        #expect(SwapPressureMonitor.parseEmulation("") == nil)
    }

    @Test("flag file drives the override and cleans up live")
    func flagFileOverride() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swap-emulate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("debug"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SwapPressureMonitor.emulationOverride(dataRoot: root) == nil)
        try "critical".write(
            to: root.appendingPathComponent("debug/swap-emulate"),
            atomically: true, encoding: .utf8)
        #expect(SwapPressureMonitor.emulationOverride(dataRoot: root) == .critical)
        let state = SwapPressureMonitor().currentState(dataRoot: root)
        #expect(state.severity == .critical)
        #expect(state.emulated)
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("debug/swap-emulate"))
        #expect(SwapPressureMonitor.emulationOverride(dataRoot: root) == nil)
    }

    @Test("real swap and footprint samples parse on this host")
    func hostSamplesParse() {
        let usage = SwapPressureMonitor.readSwapUsage()
        #expect(usage != nil)
        if let usage { #expect(usage.total >= usage.used) }
        #expect(SwapPressureMonitor.processFootprintBytes() > 0)
    }
}
