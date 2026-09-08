import Foundation

/// Presentation/advisory policy only. An acknowledgement never overrides
/// runtime admission, Strict mode, delegation reservations, or user settings.
enum MemoryWarningState: Equatable {
    enum Phase: Equatable, Sendable { case unloaded, loading, resident }

    struct Prediction: Equatable {
        let model: String
        let severity: ModelRuntime.RAMFeasibility.LoadPressureSeverity
        let requiredBytes: Int64
        let availableBytes: Int64
        let hardLimitBytes: Int64
        let simulated: Bool

        /// Recheck on Send. Better availability does not nag again; a material
        /// drop, larger estimate, stricter limit, or different identity does.
        func isCovered(by previous: Prediction?) -> Bool {
            guard let previous, previous.model == model,
                previous.simulated == simulated,
                (previous.severity == .block || previous.severity == severity),
                requiredBytes <= previous.requiredBytes,
                hardLimitBytes >= previous.hardLimitBytes
            else { return false }
            return availableBytes >= previous.availableBytes - (512 << 20)
        }
    }

    case none
    case predicted(Prediction)
    case loading(SwapPressureMonitor.State)
    case loaded(SwapPressureMonitor.State)

    static func resolve(
        canonicalModel: String,
        phase: Phase,
        assessment: ModelRuntime.RAMFeasibility?,
        swap: SwapPressureMonitor.State?,
        acknowledged: Prediction?,
        dismissedSwapSeverity: SwapPressureMonitor.Severity?
    ) -> Self {
        if phase == .unloaded {
            let simulated = swap?.emulated == true && swap?.severity != SwapPressureMonitor.Severity.none
            let severity: ModelRuntime.RAMFeasibility.LoadPressureSeverity =
                simulated
                ? (swap?.severity == .critical ? .block : .warn)
                : predictionSeverity(assessment)
            guard severity != .none else { return .none }
            let prediction = Prediction(
                model: canonicalModel,
                severity: severity,
                requiredBytes: assessment?.requiredAvailableBytes ?? 0,
                availableBytes: assessment?.availableMemoryBytes ?? 0,
                hardLimitBytes: assessment?.hardLimitBytes ?? 0,
                simulated: simulated
            )
            return prediction.isCovered(by: acknowledged) ? .none : .predicted(prediction)
        }
        guard let swap, swap.severity != .none,
            swap.emulated || swap.modelName?.caseInsensitiveCompare(canonicalModel) == .orderedSame,
            dismissedSwapSeverity.map({ swap.severity > $0 }) ?? true
        else { return .none }
        // The monitor's aggregate phase can describe ANOTHER concurrent load.
        // Use the selected model's runtime membership, never isStreaming.
        return phase == .loading ? .loading(swap) : .loaded(swap)
    }

    static func predictionSeverity(_ assessment: ModelRuntime.RAMFeasibility?)
        -> ModelRuntime.RAMFeasibility.LoadPressureSeverity
    {
        guard let assessment else { return .none }
        if assessment.loadPressureSeverity != .none { return assessment.loadPressureSeverity }
        // The runtime already accounts for reclaimable memory and slack in
        // its tight verdict. Surface that low-available-only case as an
        // advisory, without changing the shared admission/severity formulas.
        return assessment.verdict == .tight ? .warn : .none
    }
}
