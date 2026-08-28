import Foundation
import Testing

@testable import OsaurusCore

/// The swap-pressure classifier's contract: severity keys on growth since
/// the load baseline (never absolute swap), enters fast, exits only after
/// sustained calm, and the designer/QA emulation override parses strictly.
@Suite struct SwapPressureMonitorTests {

    private func classify(
        growth: Int64, used: UInt64 = 6 << 30, total: UInt64 = 8 << 30,
        previous: SwapPressureMonitor.Severity, streak: inout Int
    ) -> SwapPressureMonitor.Severity {
        SwapPressureMonitor.classify(
            growthBytes: growth, usedBytes: used, totalBytes: total,
            previous: previous, exitStreak: &streak)
    }

    @Test("a Mac already deep in swap with no load growth stays quiet")
    func absoluteSwapWithoutGrowthIsNone() {
        var streak = 0
        // 7.5 of 8 GB used, but the model contributed nothing.
        let severity = classify(
            growth: 100 << 20, used: 7_500 << 20, total: 8 << 30,
            previous: .none, streak: &streak)
        #expect(severity == .none)
    }

    @Test("growth thresholds enter immediately")
    func enterThresholds() {
        var streak = 0
        #expect(classify(growth: (3 << 29) - 1, previous: .none, streak: &streak) == .none)
        #expect(classify(growth: 3 << 29, previous: .none, streak: &streak) == .elevated)
        #expect(classify(growth: 4 << 30, previous: .none, streak: &streak) == .critical)
    }

    @Test("near-exhausted swap is critical only when the load contributed")
    func nearFullNeedsGrowth() {
        var streak = 0
        // 60 MB free, but growth below the 1 GiB attribution floor.
        #expect(
            classify(
                growth: 512 << 20, used: (8 << 30) - (60 << 20), total: 8 << 30,
                previous: .none, streak: &streak) == .none)
        #expect(
            classify(
                growth: 2 << 30, used: (8 << 30) - (60 << 20), total: 8 << 30,
                previous: .none, streak: &streak) == .critical)
    }

    @Test("exit needs sustained calm below half the enter threshold")
    func hysteresis() {
        var streak = 0
        // Enter elevated.
        #expect(classify(growth: 2 << 30, previous: .none, streak: &streak) == .elevated)
        // One calm sample: still elevated.
        #expect(classify(growth: 100 << 20, previous: .elevated, streak: &streak) == .elevated)
        // Calm interrupted: streak resets.
        #expect(classify(growth: 1 << 30, previous: .elevated, streak: &streak) == .elevated)
        // Three consecutive calm samples clear it.
        #expect(classify(growth: 100 << 20, previous: .elevated, streak: &streak) == .elevated)
        #expect(classify(growth: 100 << 20, previous: .elevated, streak: &streak) == .elevated)
        #expect(classify(growth: 100 << 20, previous: .elevated, streak: &streak) == .none)
    }

    @Test("worsening re-enters instantly regardless of streak")
    func worseningWins() {
        var streak = 2
        #expect(classify(growth: 5 << 30, previous: .elevated, streak: &streak) == .critical)
        #expect(streak == 0)
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
        let state = SwapPressureMonitor.shared.currentState(dataRoot: root)
        #expect(state.severity == .critical)
        #expect(state.emulated)
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("debug/swap-emulate"))
        #expect(SwapPressureMonitor.emulationOverride(dataRoot: root) == nil)
    }

    @Test("real swap sysctl parses on this host")
    func sysctlParses() {
        let usage = SwapPressureMonitor.readSwapUsage()
        #expect(usage != nil)
        if let usage { #expect(usage.total >= usage.used) }
    }
}
