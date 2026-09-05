//
//  MemoryBandwidthCalibration.swift
//  osaurus
//
//  Standalone CLI copy of the memory-bandwidth calibration probe and the
//  decode-throughput arithmetic.
//
//  Why a copy: the canonical implementation lives in OsaurusCore
//  (Packages/OsaurusCore/Services/ChipProfileCalibration.swift — cross-
//  referenced there), which the CLI does not link. This mirrors how
//  Bench.swift writes the prefill-tuning JSON contract without linking
//  `ModelPrefillTuningStore`. Bandwidth is a machine property, not a server
//  property, so running the probe IN the CLI process measures exactly the
//  same thing the server would see; the JSON record below is byte-compatible
//  with the Core `CalibrationRecord` Codable (asserted by tests on both
//  sides via a shared fixture string).
//
//  Keep the probe convention, the efficiency constant, and the spec table
//  identical to the Core copy.
//

import Foundation

enum MemoryBandwidthCalibration {
    /// Mirrors `ChipProfileCalibration.CalibrationRecord` (OsaurusCore) —
    /// same keys, same optionality. Do not rename fields without updating
    /// the Core struct and both shape tests.
    struct Record: Codable {
        let measuredBandwidthGBps: Double
        let chip: String
        let measuredAt: String?
        let osVersion: String?
        /// Copy-thread count the aggregate probe ran with — auditable
        /// provenance (a 1-thread number is not comparable to an 8-thread
        /// one). Required, matching the Core Codable.
        let probeThreads: Int
    }

    /// `~/.osaurus/config/chip-profile.json` — the Core-side reader is
    /// `ChipProfileCalibration` (OsaurusCore), while the CLI reads it fresh
    /// each time `osaurus show` runs.
    static func fileURL() -> URL {
        Configuration.root()
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("chip-profile.json")
    }

    // MARK: - Machine identity

    /// Live chip brand string (`machdep.cpu.brand_string`), the calibration
    /// record's invalidation key: a record written on other hardware
    /// (Migration Assistant restore) must not be trusted.
    static func chipBrandString() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        // Truncate at the null terminator; sysctl strings are NUL-terminated.
        return String(bytes: buffer.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "unknown"
    }

    // MARK: - Record I/O

    /// Stored record, or nil when absent, undecodable, or measured on a
    /// different chip (same invalidation rule as the Core reader).
    static func readValidRecord(
        at url: URL = fileURL(),
        forChip liveChip: String = chipBrandString()
    ) -> Record? {
        guard let data = try? Data(contentsOf: url),
            let record = try? JSONDecoder().decode(Record.self, from: data),
            record.chip == liveChip,
            record.measuredBandwidthGBps > 0,
            record.measuredBandwidthGBps.isFinite,
            record.probeThreads > 0
        else { return nil }
        return record
    }

    /// Atomic whole-file write; single machine-wide record, no merge needed.
    static func save(_ record: Record) throws {
        let url = fileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    // MARK: - Spec bandwidth table

    /// Spec-sheet unified-memory bandwidth (GB/s) by exact brand string.
    /// Display-only estimates, superseded by measurement. Keep identical to
    /// `ChipProfileCalibration.specBandwidthGBps` (OsaurusCore); parity is
    /// asserted by tests on both sides. Unknown chip → nil.
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

    // MARK: - Decode-throughput estimator

    /// Conservative utilization margin applied to either a measured STREAM
    /// bandwidth or a spec-sheet fallback. It accounts for kernel overhead,
    /// non-weight traffic, and non-ideal access; it is not a conversion from
    /// theoretical bandwidth to measured memcpy bandwidth. Keep in sync with
    /// `ChipProfileCalibration.decodeEfficiency`.
    static let decodeEfficiency = 0.7

    /// tok/s ≈ bandwidth × efficiency ÷ weights bytes read per token.
    static func estimatedDecodeTps(weightsBytes: Int64, bandwidthGBps: Double) -> Double {
        guard weightsBytes > 0, bandwidthGBps > 0, bandwidthGBps.isFinite else { return 0 }
        return bandwidthGBps * 1e9 * decodeEfficiency / Double(weightsBytes)
    }

    // MARK: - Bandwidth probe (STREAM copy)

    /// ~1 GiB per buffer so the system-level cache cannot hide DRAM behind
    /// the copy; 256 MiB when physical RAM ≤ 16 GiB, where a transient
    /// ~2 GiB allocation risks memory pressure (256 MiB still far exceeds
    /// any SLC, so it remains a DRAM measurement).
    static func defaultBufferBytes(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        physicalMemoryBytes <= (16 << 30) ? (256 << 20) : (1 << 30)
    }

    /// One copy thread cannot saturate the fabric on Pro/Max/Ultra tiers, so
    /// the probe aggregates over threads, capped at 8 — memcpy saturates the
    /// fabric well before core count on every M-series tier, more threads
    /// past ~8 only add scheduler noise, and P/E-core asymmetry makes exact
    /// core targeting not worth the complexity. Same rationale as the Core
    /// copy (`ChipProfileCalibration.defaultProbeThreadCount`).
    static func defaultThreadCount(
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Int {
        max(1, min(8, activeProcessorCount))
    }

    /// Parallel aggregate STREAM copy: the buffer pair is split into
    /// `threads` disjoint contiguous slices; each thread repeats
    /// `memcpy(dstSlice, srcSlice, n)` on its own slice against a shared
    /// absolute deadline ~`secondsPerTrial` away. Aggregate bandwidth =
    /// (Σ bytesCopied × 2) / trial wall time (each byte read once and
    /// written once — STREAM counts both). `DispatchQueue.concurrentPerform`
    /// is used because it is synchronous and schedules all iterations across
    /// cores up front; the shared deadline (not a start barrier) provides
    /// full overlap — all threads stop at the same instant, so start skew
    /// only trims a sliver off a 0.8 s window. Result is the MAX over
    /// `trials` — transient system activity only ever lowers a trial, so the
    /// best trial is closest to the machine's true capability. Buffers are
    /// freed deterministically.
    ///
    /// Keep byte-for-byte in sync with
    /// `ChipProfileCalibration.measureMemoryBandwidthGBps` (OsaurusCore).
    static func measureBandwidthGBps(
        bufferBytes: Int = defaultBufferBytes(),
        secondsPerTrial: Double = 0.8,
        trials: Int = 3,
        threads: Int = defaultThreadCount()
    ) -> Double {
        precondition(
            threads > 0 && bufferBytes >= threads && trials > 0 && secondsPerTrial > 0)
        let alignment = 16_384  // page-aligned
        let src = UnsafeMutableRawPointer.allocate(byteCount: bufferBytes, alignment: alignment)
        let dst = UnsafeMutableRawPointer.allocate(byteCount: bufferBytes, alignment: alignment)
        defer {
            src.deallocate()
            dst.deallocate()
        }

        // Fault every page up front, then one warm pass.
        memset(src, 0xA5, bufferBytes)
        memset(dst, 0x5A, bufferBytes)
        memcpy(dst, src, bufferBytes)

        // Disjoint contiguous slices; integer division strands at most
        // `threads - 1` trailing bytes, and the accounting uses the actual
        // slice size, so the arithmetic stays exact. One counter slot per
        // thread index — disjoint writes, no locks; `concurrentPerform`
        // executes every index exactly once before returning.
        let sliceBytes = bufferBytes / threads
        let perThreadBytes = UnsafeMutablePointer<UInt64>.allocate(capacity: threads)
        perThreadBytes.initialize(repeating: 0, count: threads)
        defer { perThreadBytes.deallocate() }

        // Raw pointers are not Sendable, so they cannot be captured by the
        // `@Sendable` concurrentPerform closure directly. Sound here: thread
        // `index` only touches its own disjoint slice and counter slot, and
        // `concurrentPerform` returns only after all iterations finish.
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
