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
    static func resolve(for modelId: String) -> StreamingMiddleware? {
        let lower = modelId.lowercased()

        if lower.contains("glm") && lower.contains("flash") {
            return PrependThinkTagMiddleware()
        }

        return nil
    }
}
