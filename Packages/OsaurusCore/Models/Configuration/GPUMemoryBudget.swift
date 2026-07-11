//
//  GPUMemoryBudget.swift
//  OsaurusCore
//
//  The unified-memory ceiling a model's working set has to respect.
//

import Foundation

#if canImport(Metal)
    import Metal
#endif

/// How much unified memory a model may actually occupy before macOS starts
/// paging it.
///
/// MLX holds weights in Metal buffers, and its allocator only refuses a
/// request once it passes `min(1.5 × recommendedMaxWorkingSetSize, 0.95 × RAM)`.
/// Everything between the recommended working set and that hard limit
/// *allocates successfully* and is then paged in and out by the OS on every
/// decode step. So a model sized against raw RAM can pass the check, load
/// without a single error, and then emit roughly one character every ten
/// seconds. Fit has to be judged against the GPU working set, not against
/// `physicalMemory`.
enum GPUMemoryBudget {

    private static let bytesPerGB: Double = 1024 * 1024 * 1024

    /// Apple's default split between the GPU working set and everything else.
    /// Machines at or below 36 GB hold back proportionally more for the OS.
    ///
    /// This is deliberately the long-standing documented split rather than the
    /// (larger) figure recent macOS releases advertise — an M5 Max on macOS 26
    /// reports 84% of RAM. Pinning the catalog verdict to the conservative
    /// number keeps it stable across OS releases and never optimistic, and the
    /// `.tight` band below absorbs the difference.
    static func defaultBudgetGB(physicalMemoryGB: Double) -> Double {
        guard physicalMemoryGB > 0 else { return 0 }
        return physicalMemoryGB * (physicalMemoryGB <= 36.5 ? (2.0 / 3.0) : 0.75)
    }

    /// Physical memory of the machine we're running on, in GB.
    static let hostPhysicalMemoryGB: Double =
        Double(ProcessInfo.processInfo.physicalMemory) / bytesPerGB

    /// What Metal advertises as this machine's working-set budget, when that
    /// is usable. `nil` on a paravirtual device, when the value exceeds
    /// installed RAM, or where Metal is unavailable.
    static let hostAdvertisedBudgetGB: Double? = {
        #if canImport(Metal)
            guard let device = MTLCreateSystemDefaultDevice() else { return nil }
            let advertised = Double(device.recommendedMaxWorkingSetSize) / bytesPerGB
            guard advertised > 0, advertised <= hostPhysicalMemoryGB else { return nil }
            return advertised
        #else
            return nil
        #endif
    }()

    /// Working-set budget for a Mac with `physicalMemoryGB` of unified memory.
    ///
    /// Metal is consulted only for the machine we're actually running on, and
    /// only ever to *lower* the budget — a user who has pinned
    /// `iogpu.wired_limit_mb` below the default split gets the tighter number,
    /// but nobody gets a more optimistic one than `defaultBudgetGB`. Callers
    /// passing a hypothetical RAM size (the catalog reasoning about another
    /// machine, or a test) always land on the pure default, so the verdict
    /// never depends on the host it was computed on.
    static func budgetGB(physicalMemoryGB: Double) -> Double {
        let base = defaultBudgetGB(physicalMemoryGB: physicalMemoryGB)
        guard
            base > 0,
            abs(physicalMemoryGB - hostPhysicalMemoryGB) < 1.0,
            let advertised = hostAdvertisedBudgetGB
        else { return base }
        return min(base, advertised)
    }
}
