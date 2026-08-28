//
//  SwapPressureMonitor.swift
//  OsaurusCore
//
//  Watches macOS swap usage across a local-model residency episode and
//  classifies whether that episode COINCIDED with enough system swap growth
//  to slow decode. Attribution is deliberately cautious: swap is a host-wide
//  resource, so the banner reports coincidence ("loading X coincided with
//  N GB of swap growth"), never blame. Severity keys on the episode's
//  MONOTONIC PEAK growth over its baseline — a Mac already deep in swap
//  before the episode contributes nothing to the reading. Advisory only:
//  never changes model, sampler, or cache behavior.
//
//  Episode lifecycle (driven by ModelRuntime):
//  - beginResidencyEpisode(model:) on a COLD load only — a warm cache hit
//    must not reset the baseline. While any episode is active, later cold
//    loads keep the ORIGINAL baseline (multi-model residency accumulates
//    into one episode) and only update the phase/model label.
//  - markLoadCompleted(model:) flips the phase from .loading to .resident.
//  - endEpisodeOnLoadFailure() clears a baseline left by a failed or
//    cancelled load with nothing resident.
//  - endEpisodeIfIdle(residentCount:) on unload clears once nothing is
//    resident.
//

import Darwin
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

    public enum Phase: String, Sendable, Equatable {
        case idle
        case loading
        case resident
    }

    public struct State: Sendable, Equatable {
        public let severity: Severity
        public let phase: Phase
        /// Most recent model the episode attributes to (the one whose cold
        /// load started or extended the episode).
        public let modelName: String?
        public let swapUsedBytes: UInt64
        public let swapTotalBytes: UInt64
        /// Current swap growth over the episode baseline (may dip negative).
        public let growthSinceBaselineBytes: Int64
        /// Monotonic peak growth over the episode baseline — the number the
        /// severity is judged on, so a transient dip cannot clear a real
        /// episode.
        public let peakGrowthBytes: Int64
        /// Seconds since the episode's cold-load baseline.
        public let episodeElapsedSeconds: Double
        /// This process's physical footprint at sample time.
        public let processFootprintBytes: UInt64
        /// Host swap-in rate (pages/s) over the last sample interval —
        /// nonzero sustained swap-ins while generating is the actual
        /// slowdown mechanism.
        public let swapinsPerSecond: Double
        /// Host compressor decompression rate (pages/s) over the last
        /// sample interval.
        public let decompressionsPerSecond: Double
        /// True when the state came from the team/designer emulation
        /// override rather than a real sample — the banner must say so.
        public let emulated: Bool

        public static let quiet = State(
            severity: .none, phase: .idle, modelName: nil,
            swapUsedBytes: 0, swapTotalBytes: 0,
            growthSinceBaselineBytes: 0, peakGrowthBytes: 0,
            episodeElapsedSeconds: 0, processFootprintBytes: 0,
            swapinsPerSecond: 0, decompressionsPerSecond: 0,
            emulated: false)
    }

    // MARK: - Thresholds (enter fast, exit slow)

    /// Peak growth over baseline that flags "this episode coincided with
    /// swapping".
    static let elevatedEnterGrowthBytes: Int64 = 3 << 29  // 1.5 GiB
    /// Peak growth that flags "decode slowdown expected".
    static let criticalEnterGrowthBytes: Int64 = 4 << 30  // 4 GiB
    /// Near swap exhaustion counts as critical once the episode coincided
    /// with at least this much growth.
    static let criticalNearFullFreeBytes: UInt64 = 256 << 20  // 256 MiB
    static let criticalNearFullMinGrowthBytes: Int64 = 1 << 30  // 1 GiB
    /// Consecutive calm samples required before a severity may drop.
    /// Because severity is judged on PEAK growth, exit additionally requires
    /// the CURRENT growth to have receded (macOS reclaimed swap).
    static let exitStreakRequired = 3

    private struct Episode {
        var baselineUsedBytes: UInt64
        var startedAt: Date
        var modelName: String
        var phase: Phase
        var peakGrowthBytes: Int64 = 0
        var lastSeverity: Severity = .none
        var exitStreak = 0
    }

    private let lock = NSLock()
    private var episode: Episode?
    private var lastVMSample: (swapins: UInt64, decompressions: UInt64, at: Date)?
    private var lastRates: (swapins: Double, decompressions: Double) = (0, 0)

    // MARK: - Residency episode hooks (called by ModelRuntime)

    /// Start (or extend) the episode at a COLD load. A no-op when an episode
    /// is already active except for updating the model label and returning
    /// the phase to `.loading`: multi-model residency accumulates into one
    /// episode against the original baseline.
    public func beginResidencyEpisode(model: String) {
        lock.lock()
        defer { lock.unlock() }
        if episode != nil {
            episode?.modelName = model
            episode?.phase = .loading
            return
        }
        guard let usage = Self.readSwapUsage() else { return }
        episode = Episode(
            baselineUsedBytes: usage.used,
            startedAt: Date(),
            modelName: model,
            phase: .loading)
    }

    /// The cold load finished successfully; the episode continues in
    /// `.resident` phase.
    public func markLoadCompleted(model: String) {
        lock.lock()
        defer { lock.unlock() }
        episode?.phase = .resident
    }

    /// A cold load failed or was cancelled. Clears the baseline only when
    /// the caller reports nothing is resident (a failure while another
    /// model remains loaded keeps that model's episode).
    public func endEpisodeOnLoadFailure(residentCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        if residentCount == 0 { episode = nil }
        else { episode?.phase = .resident }
    }

    /// Unload teardown: end the episode once nothing is resident.
    public func endEpisodeIfIdle(residentCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        if residentCount == 0 { episode = nil }
    }

    // MARK: - Sampling

    /// Current classified state. Cheap (two sysctls + one mach call);
    /// callers ride an existing periodic tick — the chat card's 2 s memory
    /// tick is the intended one.
    public func currentState(dataRoot: URL? = nil) -> State {
        if let override = Self.emulationOverride(dataRoot: dataRoot) {
            let growth: Int64 = override == .critical ? (5 << 30) : (2 << 30)
            return State(
                severity: override, phase: .resident,
                modelName: "Simulated Model",
                swapUsedBytes: UInt64(growth) + (1 << 30),
                swapTotalBytes: 8 << 30,
                growthSinceBaselineBytes: growth,
                peakGrowthBytes: growth,
                episodeElapsedSeconds: 42,
                processFootprintBytes: 60 << 30,
                swapinsPerSecond: override == .critical ? 4200 : 600,
                decompressionsPerSecond: override == .critical ? 9000 : 1500,
                emulated: true)
        }

        guard let usage = Self.readSwapUsage() else { return .quiet }
        let footprint = Self.processFootprintBytes()
        let rates = sampleVMRates()

        lock.lock()
        defer { lock.unlock() }
        guard var current = episode else {
            return State(
                severity: .none, phase: .idle, modelName: nil,
                swapUsedBytes: usage.used, swapTotalBytes: usage.total,
                growthSinceBaselineBytes: 0, peakGrowthBytes: 0,
                episodeElapsedSeconds: 0,
                processFootprintBytes: footprint,
                swapinsPerSecond: rates.swapins,
                decompressionsPerSecond: rates.decompressions,
                emulated: false)
        }
        let growth = Int64(bitPattern: usage.used &- current.baselineUsedBytes)
        current.peakGrowthBytes = max(current.peakGrowthBytes, growth)
        let severity = Self.classify(
            currentGrowthBytes: growth,
            peakGrowthBytes: current.peakGrowthBytes,
            usedBytes: usage.used,
            totalBytes: usage.total,
            previous: current.lastSeverity,
            exitStreak: &current.exitStreak)
        if severity < current.lastSeverity {
            // Recovered: re-baseline the peak to the present growth so a
            // stale historic spike cannot instantly re-enter — only NEW
            // growth re-triggers.
            current.peakGrowthBytes = max(0, growth)
        }
        current.lastSeverity = severity
        episode = current
        return State(
            severity: severity,
            phase: current.phase,
            modelName: current.modelName,
            swapUsedBytes: usage.used,
            swapTotalBytes: usage.total,
            growthSinceBaselineBytes: growth,
            peakGrowthBytes: current.peakGrowthBytes,
            episodeElapsedSeconds: Date().timeIntervalSince(current.startedAt),
            processFootprintBytes: footprint,
            swapinsPerSecond: rates.swapins,
            decompressionsPerSecond: rates.decompressions,
            emulated: false)
    }

    // MARK: - Pure classifier (unit-tested)

    /// Severity ENTERS on peak growth immediately. Dropping a level
    /// requires the CURRENT growth to sit below half the previous level's
    /// enter threshold for `exitStreakRequired` consecutive samples — the
    /// peak is monotonic, so recovery is judged on what macOS actually
    /// reclaimed, and one calm sample never clears a real episode.
    static func classify(
        currentGrowthBytes: Int64,
        peakGrowthBytes: Int64,
        usedBytes: UInt64,
        totalBytes: UInt64,
        previous: Severity,
        exitStreak: inout Int
    ) -> Severity {
        let freeBytes = totalBytes > usedBytes ? totalBytes - usedBytes : 0
        func level(for growth: Int64) -> Severity {
            if growth >= criticalEnterGrowthBytes
                || (totalBytes > 0 && freeBytes <= criticalNearFullFreeBytes
                    && growth >= criticalNearFullMinGrowthBytes)
            {
                return .critical
            }
            if growth >= elevatedEnterGrowthBytes { return .elevated }
            return .none
        }

        // Upgrades enter immediately, judged on the episode's PEAK so a
        // transient dip cannot mask a real spike between samples.
        let peakLevel = level(for: peakGrowthBytes)
        if peakLevel > previous {
            exitStreak = 0
            return peakLevel
        }
        guard previous != .none else { return .none }

        // Downgrades are judged on the CURRENT growth receding: macOS must
        // actually have reclaimed swap, sustained for the full streak. The
        // caller re-baselines the peak when the severity drops so a stale
        // peak cannot instantly re-enter.
        let halfPrevious =
            previous == .critical
            ? criticalEnterGrowthBytes / 2 : elevatedEnterGrowthBytes / 2
        if currentGrowthBytes <= halfPrevious {
            exitStreak += 1
            if exitStreak >= exitStreakRequired {
                exitStreak = 0
                return level(for: currentGrowthBytes)
            }
        } else {
            exitStreak = 0
        }
        return previous
    }

    // MARK: - Host samples

    public static func readSwapUsage() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return nil
        }
        return (used: usage.xsu_used, total: usage.xsu_total)
    }

    /// This process's physical footprint (the same metric Activity Monitor
    /// reports as Memory).
    static func processFootprintBytes() -> UInt64 {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }

    /// Host swap-in and decompression rates over the interval since the
    /// previous call (pages/s). First call primes the counters and reports
    /// zero.
    private func sampleVMRates() -> (swapins: Double, decompressions: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return lastRates }
        let now = Date()
        let swapins = stats.swapins
        let decompressions = stats.decompressions
        lock.lock()
        defer { lock.unlock() }
        defer { lastVMSample = (swapins, decompressions, now) }
        guard let previous = lastVMSample else { return (0, 0) }
        let dt = now.timeIntervalSince(previous.at)
        guard dt > 0.2 else { return lastRates }
        let rates = (
            swapins: Double(swapins &- previous.swapins) / dt,
            decompressions: Double(decompressions &- previous.decompressions) / dt
        )
        lastRates = rates
        return rates
    }

    // MARK: - Team/designer emulation

    /// Deterministic states for the design/QA loop, so the banner can be
    /// seen and iterated without actually thrashing a Mac:
    /// - launch env `OSAURUS_SWAP_EMULATE=elevated|critical`
    /// - OR a live-flippable flag file `debug/swap-emulate` in the data root
    ///   containing `elevated` or `critical` (re-read every sample; delete
    ///   the file or write `none` to end the simulation without relaunch).
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
