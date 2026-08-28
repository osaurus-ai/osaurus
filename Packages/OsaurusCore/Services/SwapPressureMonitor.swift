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
//  Episode lifecycle (driven by ModelRuntime): every COLD load appends its
//  own record (own baseline, own attribution window) — warm cache hits never
//  touch the episode. markLoadCompleted / noteFirstOutput / failure hooks
//  match records BY MODEL, so concurrent loads cannot corrupt each other,
//  and a load's attribution window closes at its first output (issue #2501)
//  — the frozen window keeps the warning honest without attributing the
//  machine's later behavior to the model indefinitely. The episode ends when
//  nothing is resident and no load is in flight.
//

import Darwin
import Foundation
import os

private let swapLog = Logger(subsystem: "ai.osaurus", category: "swap-pressure")

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
        /// Swap used at the episode's first cold-load baseline.
        public let baselineUsedBytes: UInt64
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
            baselineUsedBytes: 0,
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

    /// One cold load inside the episode. Each keeps its OWN baseline so
    /// growth is attributed to the load whose window it happened in — a
    /// shared label would falsely pin earlier growth on the newest model.
    /// The attribution window closes at the load's first output (issue
    /// #2501): the frozen window growth keeps the warning honest afterwards
    /// without attributing the machine's later behavior to the model
    /// indefinitely.
    private struct LoadRecord {
        let id = UUID()
        let model: String
        let baselineUsedBytes: UInt64
        let startedAt: Date
        var phase: Phase
        var windowClosed = false
        var frozenWindowGrowthBytes: Int64 = 0

        func windowGrowthBytes(currentUsed: UInt64) -> Int64 {
            windowClosed
                ? frozenWindowGrowthBytes
                : Int64(bitPattern: currentUsed &- baselineUsedBytes)
        }
    }

    private struct Episode {
        var loads: [LoadRecord]
        var peakGrowthBytes: Int64 = 0
        var lastSeverity: Severity = .none
        var exitStreak = 0

        var baselineUsedBytes: UInt64 { loads.first?.baselineUsedBytes ?? 0 }
        var startedAt: Date { loads.first?.startedAt ?? Date() }
        /// Attribution keeps advancing only while some load's window is open.
        var attributionOpen: Bool { loads.contains { !$0.windowClosed } }
        var anyLoading: Bool { loads.contains { $0.phase == .loading } }
    }

    private let lock = NSLock()
    private var episode: Episode?
    private var lastVMSample: (swapins: UInt64, decompressions: UInt64, at: Date)?
    private var lastRates: (swapins: Double, decompressions: Double) = (0, 0)

    /// Swap-usage source. The default reads the host sysctl; tests inject a
    /// deterministic sequence so the attribution-window contract (growth
    /// during load/prefill/TTFT counts, growth after first output does not)
    /// is provable without actually thrashing the machine.
    var swapSampler: () -> (used: UInt64, total: UInt64)? = SwapPressureMonitor.readSwapUsage

    // MARK: - Residency episode hooks (called by ModelRuntime)

    /// Start (or extend) the episode at a COLD load. Each cold load gets its
    /// own record with its own baseline captured at ITS start, so growth is
    /// attributed to the correct load's window under multi-model residency
    /// and concurrent loads.
    public func beginResidencyEpisode(model: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let usage = swapSampler() else { return }
        let record = LoadRecord(
            model: model,
            baselineUsedBytes: usage.used,
            startedAt: Date(),
            phase: .loading)
        if episode == nil {
            episode = Episode(loads: [record])
        } else {
            episode?.loads.append(record)
        }
    }

    /// The named model's cold load finished; only ITS record flips to
    /// `.resident` — concurrent completions cannot touch each other.
    public func markLoadCompleted(model: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var current = episode,
            let index = current.loads.lastIndex(where: {
                $0.model == model && $0.phase == .loading
            })
        else { return }
        current.loads[index].phase = .resident
        episode = current
    }

    /// The named model produced its first output: close ITS attribution
    /// window, freezing the growth that coincided with its load-through-
    /// first-output span (issue #2501's measurement bound).
    public func noteFirstOutput(model: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var current = episode,
            let index = current.loads.lastIndex(where: {
                $0.model == model && !$0.windowClosed
            }),
            let usage = swapSampler()
        else { return }
        current.loads[index].frozenWindowGrowthBytes =
            current.loads[index].windowGrowthBytes(currentUsed: usage.used)
        current.loads[index].windowClosed = true
        episode = current
    }

    /// The named model's cold load failed or was cancelled: remove ITS
    /// record only. The episode ends when no records remain and nothing is
    /// resident — a failure can never erase another in-flight load's
    /// baseline.
    public func endEpisodeOnLoadFailure(model: String, residentCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard var current = episode else { return }
        if let index = current.loads.lastIndex(where: {
            $0.model == model && $0.phase == .loading
        }) {
            current.loads.remove(at: index)
        }
        episode = current.loads.isEmpty && residentCount == 0 ? nil : current
    }

    /// Unload teardown: end the episode once nothing is resident and no
    /// load remains in flight.
    public func endEpisodeIfIdle(residentCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = episode else { return }
        if residentCount == 0 && !current.anyLoading { episode = nil }
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
                baselineUsedBytes: 1 << 30,
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

        guard let usage = swapSampler() else { return .quiet }
        let footprint = Self.processFootprintBytes()
        let rates = sampleVMRates()

        lock.lock()
        defer { lock.unlock() }
        guard var current = episode, !current.loads.isEmpty else {
            return State(
                severity: .none, phase: .idle, modelName: nil,
                baselineUsedBytes: 0,
                swapUsedBytes: usage.used, swapTotalBytes: usage.total,
                growthSinceBaselineBytes: 0, peakGrowthBytes: 0,
                episodeElapsedSeconds: 0,
                processFootprintBytes: footprint,
                swapinsPerSecond: rates.swapins,
                decompressionsPerSecond: rates.decompressions,
                emulated: false)
        }
        let growth = Int64(bitPattern: usage.used &- current.baselineUsedBytes)
        // Attribution stops accumulating once every load's window closed at
        // its first output (issue #2501): the peak persists so the warning
        // remains honest, but later machine behavior is no longer attributed
        // to the models.
        if current.attributionOpen {
            current.peakGrowthBytes = max(current.peakGrowthBytes, growth)
        }
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
        // Attribute to the load whose own window saw the most growth, not
        // merely the newest one.
        let dominant = current.loads.max {
            $0.windowGrowthBytes(currentUsed: usage.used)
                < $1.windowGrowthBytes(currentUsed: usage.used)
        }
        let phase: Phase = current.anyLoading ? .loading : .resident
        if severity != current.lastSeverity {
            swapLog.info(
                "swap-pressure \(current.lastSeverity.rawValue, privacy: .public) -> \(severity.rawValue, privacy: .public) model=\(dominant?.model ?? "?", privacy: .public) phase=\(phase.rawValue, privacy: .public) baselineMB=\(current.baselineUsedBytes >> 20) usedMB=\(usage.used >> 20) growthMB=\(growth >> 20) peakMB=\(current.peakGrowthBytes >> 20) footprintMB=\(footprint >> 20) swapins_s=\(Int(rates.swapins)) decomp_s=\(Int(rates.decompressions))"
            )
        }
        current.lastSeverity = severity
        episode = current
        return State(
            severity: severity,
            phase: phase,
            modelName: dominant?.model,
            baselineUsedBytes: current.baselineUsedBytes,
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
        // Counter regression (host_statistics64 reset, e.g. across a sleep
        // cycle) would wrap `&-` into an astronomically large rate. Re-prime
        // and keep the previous reading instead.
        guard swapins >= previous.swapins, decompressions >= previous.decompressions else {
            return lastRates
        }
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
