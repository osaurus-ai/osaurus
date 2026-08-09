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

/// Where the byte count behind a catalog memory estimate came from.
///
/// A measured value is the Hub tree sum or the installed bundle's real
/// safetensors size. A metadata fallback is inferred from parameter count and
/// quantization while that measurement is unavailable.
enum ModelSizeEstimateSource: Equatable {
    case measured
    case metadataFallback
}

/// One calculation shared by catalog cards, onboarding, model details, and
/// recommendation/filter policy. Keeping the inputs and thresholds together
/// prevents the UI from comparing one number while explaining another.
struct ModelMemoryAssessment: Equatable {
    let modelSizeBytes: Int64?
    let sizeSource: ModelSizeEstimateSource?
    let estimatedRunningMemoryBytes: UInt64?
    let physicalMemoryGB: Double
    let gpuWorkingSetBudgetGB: Double
    let comfortableModelBudgetGB: Double
    let maximumAdvisoryBudgetGB: Double
    let compatibility: ModelCompatibility

    var estimatedRunningMemoryGB: Double? {
        estimatedRunningMemoryBytes.map { Double($0) / GPUMemoryBudget.bytesPerGB }
    }
}

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

    static let bytesPerGB: Double = 1024 * 1024 * 1024
    private static let chatRuntimeInflation = 1.25
    /// Leaves room inside Metal's recommended working set for longer chats,
    /// transient buffers, and ordinary system activity.
    static let comfortableBudgetRatio: Double = 0.85
    /// Small overshoots remain advisory because Metal's recommendation is not
    /// an allocation cliff. Beyond this ratio paging is the expected outcome.
    static let maximumAdvisoryBudgetRatio: Double = 1.10

    /// Shared picker/load-admission estimate for static weights plus ordinary
    /// chat activations and runtime buffers.
    static func estimatedChatWorkingSetBytes(onDiskBytes: Int64) -> UInt64? {
        guard onDiskBytes > 0 else { return nil }
        let bytes = Double(onDiskBytes) * chatRuntimeInflation
        guard bytes.isFinite, bytes > 0 else { return nil }
        return UInt64(min(Double(UInt64.max), bytes.rounded(.up)))
    }

    /// Build the complete, user-facing fit calculation from one model-size
    /// value. The same result drives labels, sorting, filtering, and default
    /// selection.
    static func assessment(
        modelSizeBytes: Int64?,
        sizeSource: ModelSizeEstimateSource?,
        physicalMemoryGB: Double
    ) -> ModelMemoryAssessment {
        let runningBytes = modelSizeBytes.flatMap(estimatedChatWorkingSetBytes)
        let workingSetBudget = budgetGB(physicalMemoryGB: physicalMemoryGB)
        let comfortableBudget = workingSetBudget * comfortableBudgetRatio
        let maximumAdvisoryBudget = workingSetBudget * maximumAdvisoryBudgetRatio

        let compatibility: ModelCompatibility
        if let runningBytes, workingSetBudget > 0 {
            let requiredGB = Double(runningBytes) / bytesPerGB
            if requiredGB <= comfortableBudget {
                compatibility = .compatible
            } else if requiredGB <= maximumAdvisoryBudget {
                compatibility = .tight
            } else {
                compatibility = .tooLarge
            }
        } else {
            compatibility = .unknown
        }

        return ModelMemoryAssessment(
            modelSizeBytes: modelSizeBytes,
            sizeSource: sizeSource,
            estimatedRunningMemoryBytes: runningBytes,
            physicalMemoryGB: physicalMemoryGB,
            gpuWorkingSetBudgetGB: workingSetBudget,
            comfortableModelBudgetGB: comfortableBudget,
            maximumAdvisoryBudgetGB: maximumAdvisoryBudget,
            compatibility: compatibility
        )
    }

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
