import Foundation

enum ChatErrorMessages {
    static func assistantMessage(for error: Error) -> String {
        let description = error.localizedDescription
        if OsaurusRouter.isInsufficientFundsError(description) {
            return "Error: You're out of credits. Add credits to continue."
        }
        if isSystemResourceExhaustion(description) {
            return
                "Error: Ran out of system resources while running this model. Free memory, unload other models, or choose a smaller/more-quantized model, then try again."
        }
        return "Error: \(description)"
    }

    static func isSystemResourceExhaustion(_ message: String) -> Bool {
        let normalized = message.lowercased()
        if normalized.contains("not enough memory")
            || normalized.contains("out of memory")
            || normalized.contains("ran out of memory")
            || normalized.contains("failed to allocate memory")
        {
            return true
        }

        if normalized.contains("metal"),
            normalized.contains("memory") || normalized.contains("allocation")
                || normalized.contains("resource")
        {
            return true
        }

        if normalized.contains("mlx"),
            normalized.contains("memory") || normalized.contains("allocation")
                || normalized.contains("resource")
        {
            return true
        }

        return false
    }
}
