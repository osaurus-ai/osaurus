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
    /// The 128 GB-and-up tier follows the 84% working-set ceiling Metal
    /// advertises on current high-memory Apple silicon, leaving roughly 20 GB
    /// for macOS and app/runtime overhead while still allowing explicit
    /// 105–109 GB-class loads. Mid-memory machines retain the conservative 75%
    /// split that prevents the proven 48 GB paging regression.
    ///
    /// The tier boundary is deliberate: current 128 GB hardware advertises an
    /// 84% Metal working set, while the smaller-machine paging regression was
    /// reproduced under the older 75% split. Host calculations are still
    /// capped by Metal's live advertised value below.
    static func defaultBudgetGB(physicalMemoryGB: Double) -> Double {
        guard physicalMemoryGB > 0 else { return 0 }
        if physicalMemoryGB <= 36.5 { return physicalMemoryGB * (2.0 / 3.0) }
        if physicalMemoryGB >= 127.5 { return physicalMemoryGB * 0.84 }
        return physicalMemoryGB * 0.75
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

/// User-facing wording for the exact budget that powers model compatibility
/// and automatic routing. Keeping this beside `GPUMemoryBudget` prevents UI
/// copy from drifting back to raw physical RAM while the policy uses the
/// smaller GPU working-set ceiling.
enum ModelHardwareGuidance {
    /// Native image jobs use a separate MLX graph with denoise/VAE buffers.
    /// Keep their catalog estimate identical to the existing execution-time
    /// RAM preflight (`ChatResidencyHandoff.memoryPreflight`) so Automatic and
    /// the visible fit label never approve a graph the final gate estimates
    /// differently.
    private static let delegatedModelRuntimeInflation = 1.3
    private static let delegatedModelRuntimeHeadroomGB = 3.0

    /// The same fit bands used by chat-model cards, image-model defaults, and
    /// Automatic routing. Explicit tight-fit choices remain selectable; only
    /// `.compatible` is eligible for an unattended automatic route.
    static func compatibility(
        estimatedMemoryGB: Double?,
        physicalMemoryGB: Double
    ) -> ModelCompatibility {
        guard let required = estimatedMemoryGB, required > 0, physicalMemoryGB > 0 else {
            return .unknown
        }
        let budget = GPUMemoryBudget.budgetGB(physicalMemoryGB: physicalMemoryGB)
        guard budget > 0 else { return .unknown }
        let ratio = required / budget
        if ratio <= 0.85 { return .compatible }
        if ratio <= 1.10 { return .tight }
        return .tooLarge
    }

    static func formattedGB(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0 GB" }
        if abs(value.rounded() - value) < 0.05 {
            return String(format: "%.0f GB", value)
        }
        return String(format: "%.1f GB", value)
    }

    static func estimatedImageWorkingSetGB(onDiskBytes: UInt64) -> Double? {
        guard onDiskBytes > 0 else { return nil }
        let onDiskGB = Double(onDiskBytes) / (1024 * 1024 * 1024)
        return onDiskGB * delegatedModelRuntimeInflation
            + delegatedModelRuntimeHeadroomGB
    }

    static func delegatedModelPreflightRequiredBytes(onDiskBytes: Int64) -> Int64 {
        guard onDiskBytes > 0 else { return 0 }
        let headroomBytes = Int64(
            delegatedModelRuntimeHeadroomGB * 1024 * 1024 * 1024
        )
        return Int64(Double(onDiskBytes) * delegatedModelRuntimeInflation)
            + headroomBytes
    }

    static func budgetSummary(physicalMemoryGB: Double) -> String? {
        guard physicalMemoryGB > 0 else { return nil }
        let budget = GPUMemoryBudget.budgetGB(physicalMemoryGB: physicalMemoryGB)
        guard budget > 0 else { return nil }
        return "\(formattedGB(physicalMemoryGB)) unified memory · \(formattedGB(budget)) recommended local-model budget"
    }

    static func fitSummary(
        estimatedMemoryGB: Double?,
        compatibility: ModelCompatibility?,
        physicalMemoryGB: Double
    ) -> String? {
        guard let compatibility else { return nil }
        let verdict: String
        switch compatibility {
        case .compatible: verdict = "Comfortable fit"
        case .tight: verdict = "Tight fit"
        case .tooLarge: verdict = "Too large"
        case .unknown: verdict = "Fit unknown"
        }

        guard
            let workingSet = workingSetSummary(
                estimatedMemoryGB: estimatedMemoryGB,
                physicalMemoryGB: physicalMemoryGB
            )
        else { return verdict }
        return "\(verdict) · \(workingSet)"
    }

    static func workingSetSummary(
        estimatedMemoryGB: Double?,
        physicalMemoryGB: Double
    ) -> String? {
        guard let estimatedMemoryGB, estimatedMemoryGB > 0 else { return nil }
        let budget = GPUMemoryBudget.budgetGB(physicalMemoryGB: physicalMemoryGB)
        guard budget > 0 else {
            return "~\(formattedGB(estimatedMemoryGB)) working set"
        }
        return "~\(formattedGB(estimatedMemoryGB)) working set · \(formattedGB(budget)) budget"
    }
}
