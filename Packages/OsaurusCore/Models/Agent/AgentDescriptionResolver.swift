import Foundation

/// Shared fallback contract. Callers own request identity and persistence;
/// this helper never mutates an agent or weakens description validation.
enum AgentDescriptionResolver {
    static func canResolve(description: String, systemPrompt: String) -> Bool {
        if !AgentDescriptionPolicy.normalized(description).isEmpty {
            return AgentDescriptionPolicy.violation(in: description) == nil
        }
        return !AgentDescriptionPolicy.normalized(systemPrompt).isEmpty
    }

    static func resolve(
        description: String,
        systemPrompt: String,
        generate: @Sendable (String) async throws -> String
    ) async throws -> String {
        try Task.checkCancellation()
        if !AgentDescriptionPolicy.normalized(description).isEmpty {
            return try AgentDescriptionPolicy.validated(description)
        }
        let prompt = AgentDescriptionPolicy.normalized(systemPrompt)
        guard !prompt.isEmpty else { throw AgentDescriptionPolicy.Violation.required }
        let result = try await generate(prompt)
        try Task.checkCancellation()
        return try AgentDescriptionPolicy.validated(result)
    }
}
