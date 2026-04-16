//
//  StreamingMiddleware.swift
//  osaurus
//
//  Transforms raw streaming deltas before they reach StreamingDeltaProcessor's
//  tag parser. Model-specific streaming behavior lives here, keeping the
//  processor itself model-agnostic.
//

/// Transforms raw streaming deltas before they reach the tag parser.
/// Stateful — create a new instance per streaming session.
@MainActor
protocol StreamingMiddleware: AnyObject {
    func process(_ delta: String) -> String
}

// MARK: - Middleware Implementations

/// Prepends `<think>` to the first non-empty delta for models that only
/// emit `</think>` without the opening tag (e.g. GLM-4.7-flash).
@MainActor
final class PrependThinkTagMiddleware: StreamingMiddleware {
    private var hasFired = false

    func process(_ delta: String) -> String {
        guard !hasFired else { return delta }
        hasFired = true
        return "<think>" + delta
    }
}

// MARK: - Resolver

enum StreamingMiddlewareResolver {
    @MainActor
    static func resolve(
        for modelId: String,
        modelOptions: [String: ModelOptionValue] = [:]
    ) -> StreamingMiddleware? {
        let thinkingDisabled = modelOptions["disableThinking"]?.boolValue == true
        let id = modelId.lowercased()

        let autoInjects = LocalReasoningCapability.capability(forModelId: modelId).templateInjectsThinkTag
        let needsPrependThink =
            !thinkingDisabled
            && (autoInjects
                || (id.contains("glm") && id.contains("flash"))
                || (id.contains("qwen") && id.contains("3.5") && hasParamSize(id, anyOf: "4b", "9b", "27b")))

        return needsPrependThink ? PrependThinkTagMiddleware() : nil
    }

    /// Matches parameter-count tokens like "4b" while ignoring
    /// quantization suffixes like "4bit" that share a prefix.
    private static func hasParamSize(_ id: String, anyOf sizes: String...) -> Bool {
        sizes.contains { id.range(of: "\($0)(?!it)", options: .regularExpression) != nil }
    }
}
