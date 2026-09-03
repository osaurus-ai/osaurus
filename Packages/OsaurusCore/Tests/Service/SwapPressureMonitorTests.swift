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

    /// The review's core attribution contract, proven with an injected swap
    /// sampler (no real thrash): growth during load/prefill/TTFT — before
    /// the first emitted output — is included in the model's window and
    /// drives severity; growth AFTER first output is excluded, so later
    /// machine behavior can neither escalate the warning nor be pinned on
    /// the model.
    @Test("swap growth before first output counts; growth after is excluded")
    func attributionWindowClosesAtFirstOutput() {
        let monitor = SwapPressureMonitor()
        let gib: UInt64 = 1 << 30
        var used: UInt64 = 1 * gib
        monitor.swapSampler = { (used: used, total: 16 << 30) }

        monitor.beginResidencyEpisode(model: "M")  // baseline 1 GiB

        // Prefill/TTFT span: swap grows 2 GiB before ANY output token.
        used = 3 * gib
        let during = monitor.currentState()
        #expect(during.growthSinceBaselineBytes == Int64(2 * gib))
        #expect(during.peakGrowthBytes == Int64(2 * gib))
        #expect(during.severity == .elevated)
        #expect(during.modelName == "M")

        // First emitted output closes the window (the mapper fires this at
        // the first chunk/reasoning/tool event, after prefill).
        monitor.markLoadCompleted(model: "M")
        monitor.noteFirstOutput(model: "M")

        // Decode-time growth (+3 GiB more) is visible as raw growth but no
        // longer attributed: the peak is frozen, severity cannot escalate
        // to critical, and the model keeps its frozen 2 GiB window.
        used = 6 * gib
        let after = monitor.currentState()
        #expect(after.growthSinceBaselineBytes == Int64(5 * gib))
        #expect(after.peakGrowthBytes == Int64(2 * gib))
        #expect(after.severity == .elevated)
        #expect(after.modelName == "M")
    }

    @Test("episode lifecycle: per-load records, matched completion, in-flight-safe failure")
    func episodeLifecycle() {
        let monitor = SwapPressureMonitor()
        monitor.swapSampler = { (used: 2 << 30, total: 8 << 30) }
        monitor.beginResidencyEpisode(model: "A")
        let first = monitor.currentState()
        #expect(first.phase == .loading)
        #expect(first.baselineUsedBytes == 2 << 30)

        // Second cold load appends its OWN record; completing B by name
        // must not flip A: episode stays .loading while A is in flight.
        monitor.beginResidencyEpisode(model: "B")
        monitor.markLoadCompleted(model: "B")
        #expect(monitor.currentState().phase == .loading)

        // A's failure removes only A's record; B's episode survives, and
        // with no in-flight loads the phase is resident.
        monitor.endEpisodeOnLoadFailure(model: "A", residentCount: 1)
        #expect(monitor.currentState().phase == .resident)

        // First output closes B's attribution window; the episode persists.
        monitor.noteFirstOutput(model: "B")
        #expect(monitor.currentState().phase == .resident)

        // Idle teardown ends it.
        monitor.endEpisodeIfIdle(residentCount: 0)
        #expect(monitor.currentState().phase == .idle)

        // Failure with nothing resident clears a fresh single-load episode.
        monitor.beginResidencyEpisode(model: "C")
        monitor.endEpisodeOnLoadFailure(model: "C", residentCount: 0)
        #expect(monitor.currentState().phase == .idle)

        // An unload during another model's in-flight cold load must NOT end
        // the episode.
        monitor.beginResidencyEpisode(model: "D")
        monitor.endEpisodeIfIdle(residentCount: 0)
        #expect(monitor.currentState().phase == .loading)
        monitor.endEpisodeOnLoadFailure(model: "D", residentCount: 0)
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
