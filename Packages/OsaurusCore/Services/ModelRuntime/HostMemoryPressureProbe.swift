//
//  HostMemoryPressureProbe.swift
//  osaurus
//
//  HOST-WIDE memory state, as opposed to `ProcessMemoryProbe`, which reports
//  only this process's footprint.
//
//  The distinction is the whole point. A user on a 64 GB M3 Max reported
//  9.3 tok/s and a 215 s TTFT on a 35B-A3B bundle. Our own process footprint
//  looked unremarkable; the machine did not. Captured while the model ran:
//
//      free RAM      64 MB median (14 MB low)
//      swap          33.9 GB of 34.8 GB — 97.4% full
//      decompressions ~308k per 2s, peaking 577k
//
//  308k pages of 16 KiB per 2 s is ~2.5 GB/s spent unpacking compressed pages
//  purely to read memory that was already "resident". An idle Mac sits at ~10.
//  Osaurus was not even in the top 15 by RSS: the weights had been evicted into
//  the compressor, and every token was faulting them back.
//
//  A Mixture-of-Experts bundle is punished worst by this. A dense model rereads
//  the same weights each token, so they stay hot; an A3B gathers a DIFFERENT
//  scattered subset of experts every token, so a large share of those gathers
//  become decompressions. The runtime is healthy and the numbers still collapse,
//  which is precisely the case a user cannot diagnose alone.
//
//  This probe exists so the app can SAY that. It advises; it never refuses.
//  Nothing here gates a load, caps a size, or blocks generation — a wrong guess
//  about memory must never become a wall between a user and their model.
//

import Darwin
import Foundation

/// A point-in-time reading of host-wide memory state.
public struct HostMemorySample: Equatable, Sendable {
    /// Free physical bytes. On a healthy machine this is gigabytes; under the
    /// pressure that matters it collapses to tens of megabytes.
    public let freeBytes: UInt64

    /// Bytes currently held by the compressor (its compressed size, not the
    /// logical size of what it holds).
    public let compressedBytes: UInt64

    /// Backing-store bytes in use, and the total the OS has provisioned.
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64

    /// Monotonic since-boot counters. Meaningless as absolutes; the RATE
    /// between two samples is the signal.
    public let decompressions: UInt64
    public let swapins: UInt64

    /// Instant this sample was taken, so two samples yield a rate.
    public let at: Date

    public init(
        freeBytes: UInt64,
        compressedBytes: UInt64,
        swapUsedBytes: UInt64,
        swapTotalBytes: UInt64,
        decompressions: UInt64,
        swapins: UInt64,
        at: Date
    ) {
        self.freeBytes = freeBytes
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.decompressions = decompressions
        self.swapins = swapins
        self.at = at
    }

    /// Share of provisioned swap in use, 0 when the OS reports no swap.
    public var swapUsedFraction: Double {
        guard swapTotalBytes > 0 else { return 0 }
        return Double(swapUsedBytes) / Double(swapTotalBytes)
    }

    /// Pages-per-second decompression rate between two samples, using the
    /// elapsed time actually observed rather than an assumed interval.
    ///
    /// Returns nil when the counter went backwards or no time passed — a
    /// reboot or a same-instant re-read must not manufacture a rate.
    public func decompressionRate(since earlier: HostMemorySample) -> Double? {
        let seconds = at.timeIntervalSince(earlier.at)
        guard seconds > 0, decompressions >= earlier.decompressions else { return nil }
        return Double(decompressions - earlier.decompressions) / seconds
    }

    public func swapinRate(since earlier: HostMemorySample) -> Double? {
        let seconds = at.timeIntervalSince(earlier.at)
        guard seconds > 0, swapins >= earlier.swapins else { return nil }
        return Double(swapins - earlier.swapins) / seconds
    }
}

/// Reads host-wide memory statistics. Every failure path returns nil rather
/// than a fabricated value, so a failed probe is "no sample" and can never be
/// mistaken for a healthy reading — or become a restriction.
public enum HostMemoryPressureProbe {

    /// Page size in bytes.
    ///
    /// Read via `sysconf` rather than the `vm_kernel_page_size` global: that
    /// global is a `var`, so touching it is a data race under strict
    /// concurrency. Verified equal on Apple Silicon — `vm_kernel_page_size`,
    /// `sysconf(_SC_PAGESIZE)` and `host_page_size()` all report 16384 — so
    /// this is the same number by a thread-safe route, not an approximation.
    public static let pageSize = UInt64(sysconf(_SC_PAGESIZE))

    public static func sample(now: Date = Date()) -> HostMemorySample? {
        guard let vm = virtualMemoryStatistics() else { return nil }
        let pageSize = Self.pageSize
        let swap = swapUsage()

        return HostMemorySample(
            freeBytes: UInt64(vm.free_count) * pageSize,
            compressedBytes: UInt64(vm.compressor_page_count) * pageSize,
            swapUsedBytes: swap?.used ?? 0,
            swapTotalBytes: swap?.total ?? 0,
            decompressions: UInt64(vm.decompressions),
            swapins: UInt64(vm.swapins),
            at: now
        )
    }

    private static func virtualMemoryStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return stats
    }

    private static func swapUsage() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (used: usage.xsu_used, total: usage.xsu_total)
    }
}
