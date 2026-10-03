//
//  ChipProfileCalibration.swift
//  osaurus
//
//  Measured memory bandwidth for the host machine, plus the decode-throughput
//  estimate derived from it.
//
//  Decode speed for a memory-bound LLM is (bandwidth / bytes-of-weights-read
//  -per-token), so a single machine-wide bandwidth number turns "how fast will
//  this model run?" from a guess into arithmetic. Spec-sheet bandwidth is a
//  ceiling, not what a real process achieves; the probe below measures what
//  this machine actually sustains.
//
//  The probe NEVER runs automatically: it allocates ~2 GiB and hammers the
//  memory subsystem for ~2.4 s, which is only acceptable when a user asks for
//  it explicitly. The only entry point is `osaurus bench --calibrate`, which
//  runs a standalone copy of the same arithmetic in the CLI process (see
//  Packages/OsaurusCLI/Sources/OsaurusCLICore/Services/
//  MemoryBandwidthCalibration.swift — cross-referenced there) and writes the
//  record this store reads. Bandwidth is a machine property, not a server
//  property, so measuring it in the CLI process is equivalent.
//
//  File: ~/.osaurus/config/chip-profile.json — written by the CLI (a separate
//  process), so reads are mtime-checked instead of cached forever, exactly
//  like `ModelPrefillTuningStore`.
//

import Foundation
import os.log

private let calibrationLog = Logger(
    subsystem: "com.dinoki.osaurus", category: "ChipProfileCalibration")

enum ChipProfileCalibration {
    /// One record for the whole machine (unlike prefill tuning, which is
    /// per-model): bandwidth belongs to the hardware, not to any model.
    struct CalibrationRecord: Codable, Sendable, Equatable {
        /// STREAM-copy bandwidth in GB/s (decimal, 1e9 bytes/s), max of trials.
        let measuredBandwidthGBps: Double
        /// Brand string of the chip the measurement was taken on. Required —
        /// it is the invalidation key: a record restored onto different
        /// hardware by Migration Assistant must not be trusted.
        let chip: String
        /// Provenance for humans reading the file; not used for invalidation.
        let measuredAt: String?
        let osVersion: String?
        /// Copy-thread count the aggregate probe ran with, so a record's
        /// provenance is auditable (a 1-thread number is not comparable to
        /// an 8-thread one). Required: records from the retired
        /// single-threaded probe lack it, fail decode, and are re-measured.
        let probeThreads: Int
    }

    // MARK: - Persistence (exact `ModelPrefillTuningStore` file pattern)

    /// Test-only injection point, scoped per task tree (same pattern as
    /// `ModelPrefillTuningStore.fileURLOverrideForTests`) so parallel tests
    /// don't race.
    @TaskLocal
    static var fileURLOverrideForTests: URL?

    static var fileURL: URL {
        fileURLOverrideForTests
            ?? OsaurusPaths.config().appendingPathComponent("chip-profile.json")
    }

    private struct CacheBox: @unchecked Sendable {
        var record: CalibrationRecord?
        var mtime: Date?
        var checkedURL: URL?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache = CacheBox()

    /// Measured bandwidth for the machine, or nil when no valid record exists.
    ///
    /// Invalidation rule: a stored record is ignored when its `chip` differs
    /// from the live brand string — Migration Assistant moves the file to new
    /// hardware where the old measurement would be silently wrong.
    static func measuredBandwidthGBps(forChip brandString: String) -> Double? {
        guard let record = storedRecord(), record.chip == brandString else { return nil }
        return record.measuredBandwidthGBps
    }

    /// Raw stored record, mtime-cached: one stat(2) per call, a re-decode only
    /// when the CLI (a separate process) has rewritten the file.
    static func storedRecord() -> CalibrationRecord? {
        let url = fileURL
        let mtime =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate])
            as? Date

        lock.lock()
        defer { lock.unlock() }
        if cache.checkedURL == url, cache.mtime == mtime {
            return cache.record
        }
        var record: CalibrationRecord?
        if mtime != nil,
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(CalibrationRecord.self, from: data),
            decoded.measuredBandwidthGBps > 0,
            decoded.measuredBandwidthGBps.isFinite,
            decoded.probeThreads > 0,
            !decoded.chip.isEmpty {
            record = decoded
            calibrationLog.info(
                "loaded calibration record: \(decoded.measuredBandwidthGBps, privacy: .public) GB/s on \(decoded.chip, privacy: .public)"
            )
        }
        cache = CacheBox(record: record, mtime: mtime, checkedURL: url)
        return record
    }

    /// Atomic whole-file write (single record, no merge needed — there is
    /// exactly one machine). Used by tests; the CLI writes the same JSON
    /// contract from its own process without linking OsaurusCore.
    static func save(record: CalibrationRecord) throws {
        let url = fileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    // MARK: - Spec bandwidth table

    /// Spec-sheet unified-memory bandwidth (GB/s) by exact brand string.
    ///
    /// Display-only estimates, superseded by measurement: use these only when
    /// no calibration record exists. Where Apple shipped binned variants
    /// (e.g. M3 Max 300/400) the table carries the full-fat number.
    ///
    /// Shared-by-convention with the CLI copy in
    /// Packages/OsaurusCLI/Sources/OsaurusCLICore/Services/
    /// MemoryBandwidthCalibration.swift — keep both tables identical
    /// (parity is asserted by tests on both sides).
    static func specBandwidthGBps(brandString: String) -> Double? {
        let table: [String: Double] = [
            "Apple M1": 68, "Apple M1 Pro": 200, "Apple M1 Max": 400, "Apple M1 Ultra": 800,
            "Apple M2": 100, "Apple M2 Pro": 200, "Apple M2 Max": 400, "Apple M2 Ultra": 800,
            "Apple M3": 100, "Apple M3 Pro": 150, "Apple M3 Max": 400, "Apple M3 Ultra": 819,
            "Apple M4": 120, "Apple M4 Pro": 273, "Apple M4 Max": 546,
            "Apple M5": 153, "Apple M5 Pro": 307, "Apple M5 Max": 614,
        ]
        return table[brandString.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    // MARK: - Decode-throughput estimator (pure)

    /// Conservative utilization margin applied to either measured STREAM
    /// bandwidth or a spec-sheet fallback. It accounts for kernel overhead,
    /// non-weight traffic, and non-ideal access; it is not a conversion from
    /// theoretical bandwidth to measured memcpy bandwidth.
    static let decodeEfficiency = 0.7

    /// tok/s ≈ bandwidth × efficiency ÷ bytes read per token. For a dense
    /// model every weight byte is read once per token, so bytes-per-token is
    /// approximated by on-disk weights size. Callers must suppress or label
    /// architectures such as MoE and multimodal models where that assumption
    /// does not represent active decode bytes.
    static func estimatedDecodeTps(weightsBytes: Int64, bandwidthGBps: Double) -> Double {
        guard weightsBytes > 0, bandwidthGBps > 0, bandwidthGBps.isFinite else { return 0 }
        return bandwidthGBps * 1e9 * decodeEfficiency / Double(weightsBytes)
    }

    /// Profile-based variant: prefers the measured number (ground truth for
    /// this machine) over the spec table, nil when neither is available.
    static func estimatedDecodeTps(weightsBytes: Int64, profile: ChipProfile) -> Double? {
        let bandwidth =
            profile.measuredBandwidthGBps
            ?? specBandwidthGBps(brandString: profile.brandString)
        guard let bandwidth else { return nil }
        return estimatedDecodeTps(weightsBytes: weightsBytes, bandwidthGBps: bandwidth)
    }

    // MARK: - Bandwidth probe (explicit CLI verb only — never automatic)

    /// Buffer size for one of the two probe buffers: ~1 GiB, large enough
    /// that the system-level cache (SLC) cannot hide DRAM behind the copy.
    /// On machines with ≤ 16 GiB of RAM the transient ~2 GiB allocation
    /// risks memory pressure, so fall back to 256 MiB — still far beyond
    /// any SLC size, so the number stays a DRAM measurement.
    static func defaultProbeBufferBytes(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        physicalMemoryBytes <= (16 << 30) ? (256 << 20) : (1 << 30)
    }

    /// Probe parallelism: one copy thread cannot saturate the memory fabric
    /// on Pro/Max/Ultra tiers (a single-core memcpy tops out around
    /// 100–120 GB/s while an M-series Max carries 400–600+), so the probe
    /// aggregates over threads. Capped at 8: memcpy saturates the fabric
    /// well before core count on every M-series tier, more threads past ~8
    /// only add scheduler noise, and P/E-core asymmetry makes exact core
    /// targeting not worth the complexity.
    static func defaultProbeThreadCount(
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Int {
        max(1, min(8, activeProcessorCount))
    }

    /// Parallel aggregate STREAM-copy bandwidth probe.
    ///
    /// Convention (documented so the number is comparable to published STREAM
    /// results): the buffer pair is split into `threads` disjoint contiguous
    /// slices; each thread repeats `memcpy(dstSlice, srcSlice, n)` on its own
    /// slice against a shared absolute deadline ~`secondsPerTrial` away.
    /// Aggregate bandwidth = (Σ bytesCopied over threads × 2) / trial wall
    /// time — each copied byte is read once and written once, and STREAM
    /// counts both directions.
    ///
    /// Threads run via `DispatchQueue.concurrentPerform`: it is synchronous
    /// (usable from this non-async path, deterministic completion) and it
    /// schedules all iterations across cores up front, so with `threads` ≤
    /// core count every slice runs concurrently. Full overlap comes from the
    /// shared absolute deadline rather than an explicit start barrier: all
    /// threads stop at the same instant, so microsecond-scale start skew
    /// only trims a sliver off one end of a 0.8 s window, and every byte
    /// count is divided by the same wall interval.
    ///
    /// The result is the MAX over `trials`, not the mean: transient system
    /// activity (other processes touching memory) only ever *lowers* a trial,
    /// so the best trial is the closest to the machine's true capability.
    ///
    /// Buffers are freed deterministically via `defer` before returning.
    /// Never called automatically — a ~2 GiB allocation plus sustained memory
    /// hammering must be user-initiated (`osaurus bench --calibrate`).
    static func measureMemoryBandwidthGBps(
        bufferBytes: Int = defaultProbeBufferBytes(),
        secondsPerTrial: Double = 0.8,
        trials: Int = 3,
        threads: Int = defaultProbeThreadCount()
    ) -> Double {
        precondition(
            threads > 0 && bufferBytes >= threads && trials > 0 && secondsPerTrial > 0)
        // Page-aligned so no trial pays for straddled cache lines at the ends.
        let alignment = 16_384
        let src = UnsafeMutableRawPointer.allocate(byteCount: bufferBytes, alignment: alignment)
        let dst = UnsafeMutableRawPointer.allocate(byteCount: bufferBytes, alignment: alignment)
        defer {
            src.deallocate()
            dst.deallocate()
        }

        // Touch every page (memset) so first-fault costs are paid up front,
        // then one warm copy pass so trial 1 starts from steady state.
        memset(src, 0xA5, bufferBytes)
        memset(dst, 0x5A, bufferBytes)
        memcpy(dst, src, bufferBytes)

        // Disjoint contiguous slices. Integer division strands at most
        // `threads - 1` trailing bytes; the byte accounting below uses the
        // actual slice size, so the arithmetic stays exact regardless.
        let sliceBytes = bufferBytes / threads
        // One counter slot per thread index — disjoint writes, no locks.
        // `concurrentPerform` executes every index exactly once, so each
        // slot is written before the aggregation reads it.
        let perThreadBytes = UnsafeMutablePointer<UInt64>.allocate(capacity: threads)
        perThreadBytes.initialize(repeating: 0, count: threads)
        defer { perThreadBytes.deallocate() }

        // Raw pointers are not Sendable, so they cannot be captured by the
        // `@Sendable` concurrentPerform closure directly. The unchecked
        // wrapper is sound here: thread `index` only ever touches its own
        // disjoint slice and its own counter slot, and `concurrentPerform`
        // returns only after all iterations finish (no escape).
        struct Workspace: @unchecked Sendable {
            let src: UnsafeMutableRawPointer
            let dst: UnsafeMutableRawPointer
            let counters: UnsafeMutablePointer<UInt64>
        }
        let workspace = Workspace(src: src, dst: dst, counters: perThreadBytes)

        var best = 0.0
        for _ in 0..<trials {
            let start = DispatchTime.now().uptimeNanoseconds
            let deadline = start &+ UInt64(secondsPerTrial * 1e9)
            DispatchQueue.concurrentPerform(iterations: threads) { index in
                let offset = index * sliceBytes
                var copied: UInt64 = 0
                repeat {
                    memcpy(workspace.dst + offset, workspace.src + offset, sliceBytes)
                    copied &+= UInt64(sliceBytes)
                } while DispatchTime.now().uptimeNanoseconds < deadline
                workspace.counters[index] = copied
            }
            let elapsedSeconds =
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            var totalBytes: UInt64 = 0
            for index in 0..<threads {
                totalBytes &+= perThreadBytes[index]
            }
            let gbps = Double(totalBytes) * 2 / elapsedSeconds / 1e9
            best = max(best, gbps)
        }
        return best
    }
}
