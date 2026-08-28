//
//  SwapPressureMonitor.swift
//  OsaurusCore
//
//  Watches macOS swap usage while a local model is resident and classifies
//  whether the MODEL'S residency is pushing the machine into swap hard enough
//  to slow decode. Severity keys on GROWTH SINCE THE LOAD BASELINE: a Mac
//  that already sat deep in swap before the load is not blamed on the model —
//  distinguishing "small-memory Mac" from "this load is causing swapping" is
//  the whole point. Advisory only: this never changes model, sampler, or
//  cache behavior; it feeds the chat card's popover banner.
//

import Foundation

public final class SwapPressureMonitor: @unchecked Sendable {
    public static let shared = SwapPressureMonitor()

    public enum Severity: String, Sendable, Equatable, Comparable {
        case none
        case elevated
        case critical

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            func rank(_ s: Severity) -> Int {
                switch s {
                case .none: 0
                case .elevated: 1
                case .critical: 2
                }
            }
            return rank(lhs) < rank(rhs)
        }
    }

    public struct State: Sendable, Equatable {
        public let severity: Severity
        public let swapUsedBytes: UInt64
        public let swapTotalBytes: UInt64
        /// Swap growth attributed to the current residency episode (used now
        /// minus used at load baseline). Negative when swap shrank.
        public let growthSinceLoadBytes: Int64
        /// True when the state came from the team/designer emulation override
        /// rather than a real sample — the banner must say so.
        public let emulated: Bool

        public static let quiet = State(
            severity: .none, swapUsedBytes: 0, swapTotalBytes: 0,
            growthSinceLoadBytes: 0, emulated: false)
    }

    // MARK: - Thresholds (enter fast, exit slow)

    /// Growth since load baseline that flags "this load is swapping".
    static let elevatedEnterGrowthBytes: Int64 = 3 << 29  // 1.5 GiB
    /// Growth that flags "decode slowdown expected".
    static let criticalEnterGrowthBytes: Int64 = 4 << 30  // 4 GiB
    /// Near swap exhaustion counts as critical once the load contributed
    /// at least this much.
    static let criticalNearFullFreeBytes: UInt64 = 256 << 20  // 256 MiB
    static let criticalNearFullMinGrowthBytes: Int64 = 1 << 30  // 1 GiB
    /// Consecutive calm samples required before a severity may drop
    /// (hysteresis so transient pressure doesn't flap the banner).
    static let exitStreakRequired = 3

    private let lock = NSLock()
    private var baselineUsedBytes: UInt64?
    private var lastSeverity: Severity = .none
    private var exitStreak = 0

    // MARK: - Residency episode hooks (called by ModelRuntime)

    /// Capture the swap level at the start of a local model load. Growth is
    /// measured against this point for the whole residency episode.
    public func markLoadBaseline() {
        lock.lock()
        defer { lock.unlock() }
        baselineUsedBytes = Self.readSwapUsage()?.used
        lastSeverity = .none
        exitStreak = 0
    }

    /// End of the residency episode (model unloaded).
    public func clearBaseline() {
        lock.lock()
        defer { lock.unlock() }
        baselineUsedBytes = nil
        lastSeverity = .none
        exitStreak = 0
    }

    // MARK: - Sampling

    /// Current classified state. Cheap (one sysctl); callers ride an existing
    /// periodic tick — the chat card's 2 s memory tick is the intended one.
    public func currentState(dataRoot: URL? = nil) -> State {
        if let override = Self.emulationOverride(dataRoot: dataRoot) {
            let total: UInt64 = 8 << 30
            let growth: Int64 = override == .critical ? (5 << 30) : (2 << 30)
            return State(
                severity: override,
                swapUsedBytes: UInt64(max(0, growth)) + (1 << 30),
                swapTotalBytes: total,
                growthSinceLoadBytes: growth,
                emulated: true)
        }

        guard let usage = Self.readSwapUsage() else { return .quiet }
        lock.lock()
        defer { lock.unlock() }
        guard let baseline = baselineUsedBytes else {
            // No residency episode — nothing to attribute to a model.
            return State(
                severity: .none, swapUsedBytes: usage.used,
                swapTotalBytes: usage.total, growthSinceLoadBytes: 0,
                emulated: false)
        }
        let growth = Int64(bitPattern: usage.used &- baseline)
        let severity = Self.classify(
            growthBytes: growth,
            usedBytes: usage.used,
            totalBytes: usage.total,
            previous: lastSeverity,
            exitStreak: &exitStreak)
        lastSeverity = severity
        return State(
            severity: severity, swapUsedBytes: usage.used,
            swapTotalBytes: usage.total, growthSinceLoadBytes: growth,
            emulated: false)
    }

    // MARK: - Pure classifier (unit-tested)

    /// Enter thresholds apply immediately; dropping a level requires
    /// `exitStreakRequired` consecutive samples below HALF the enter
    /// threshold, so one calm sample never clears a real episode.
    static func classify(
        growthBytes: Int64,
        usedBytes: UInt64,
        totalBytes: UInt64,
        previous: Severity,
        exitStreak: inout Int
    ) -> Severity {
        let freeBytes = totalBytes > usedBytes ? totalBytes - usedBytes : 0
        let entered: Severity
        if growthBytes >= criticalEnterGrowthBytes
            || (totalBytes > 0 && freeBytes <= criticalNearFullFreeBytes
                && growthBytes >= criticalNearFullMinGrowthBytes)
        {
            entered = .critical
        } else if growthBytes >= elevatedEnterGrowthBytes {
            entered = .elevated
        } else {
            entered = .none
        }

        if entered >= previous {
            exitStreak = 0
            return entered
        }
        // Candidate downgrade: require sustained calm below half the
        // PREVIOUS level's enter threshold.
        let halfPrevious =
            previous == .critical
            ? criticalEnterGrowthBytes / 2 : elevatedEnterGrowthBytes / 2
        if growthBytes <= halfPrevious {
            exitStreak += 1
            if exitStreak >= exitStreakRequired {
                exitStreak = 0
                return entered
            }
        } else {
            exitStreak = 0
        }
        return previous
    }

    // MARK: - Real swap sample

    public static func readSwapUsage() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return nil
        }
        return (used: usage.xsu_used, total: usage.xsu_total)
    }

    // MARK: - Team/designer emulation

    /// Deterministic states for the design/QA loop, so the banner can be seen
    /// and iterated without actually thrashing a Mac:
    /// - launch env `OSAURUS_SWAP_EMULATE=elevated|critical`
    /// - OR a live-flippable flag file `debug/swap-emulate` in the data root
    ///   containing `elevated` or `critical` (re-read every sample; write
    ///   `none` or delete the file to end the simulation without relaunch).
    /// Emulated states are tagged so the banner shows "(simulated)".
    static func emulationOverride(dataRoot: URL?) -> Severity? {
        if let raw = ProcessInfo.processInfo.environment["OSAURUS_SWAP_EMULATE"],
            let severity = parseEmulation(raw)
        {
            return severity
        }
        let root = dataRoot ?? OsaurusPaths.root()
        let flag = root.appendingPathComponent("debug/swap-emulate")
        guard let raw = try? String(contentsOf: flag, encoding: .utf8) else {
            return nil
        }
        return parseEmulation(raw)
    }

    static func parseEmulation(_ raw: String) -> Severity? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "elevated", "warn", "warning": .elevated
        case "critical", "block", "severe": .critical
        default: nil
        }
    }
}
