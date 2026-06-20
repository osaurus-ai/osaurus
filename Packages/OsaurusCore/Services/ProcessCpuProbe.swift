//
//  ProcessCpuProbe.swift
//  OsaurusCore
//
//  Public, dependency-free reader for the calling process's cumulative CPU
//  time (user + system, summed across every thread). Companion to
//  `ProcessMemoryProbe`: the eval harness resource sampler diffs two reads
//  over wall-clock to derive CPU utilization for a case, the same way
//  `top`/Activity Monitor compute a %CPU column.
//
//  NOTE: on Apple silicon MLX decode is GPU-bound, so this number reflects
//  HOST CPU work (tokenizer, sampler, JSON, stream plumbing, harness
//  orchestration) — not the model's matmuls. That is exactly what makes a
//  high value actionable: it flags host-side overhead, not GPU compute.
//

import Darwin
import Foundation

/// Reads `getrusage(RUSAGE_SELF)` user + system CPU time for the calling
/// process. `RUSAGE_SELF` aggregates all of the process's threads, so this is
/// the whole-process CPU consumption (live + reaped threads), monotonic
/// non-decreasing.
public enum ProcessCpuProbe {
    /// Cumulative CPU seconds (user + system) consumed by this process so
    /// far, or `nil` when the kernel query fails (callers treat a failed
    /// probe as "no sample" rather than a hard error in a measurement loop).
    public static func cumulativeCpuSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user =
            Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000.0
        let system =
            Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000.0
        return user + system
    }
}
