import OsaurusCore

/// Headless DefaultAgent runs have no ChatSession carrying the selected model.
/// Bind the same model for newly created workers that inherit the Orchestrator
/// configuration, and restore the complete configuration after the case.
/// This changes neither generation settings nor production model resolution.
@MainActor
enum EvalDefaultAgentModelBinding {
    static func run<T: Sendable>(
        model: String?,
        operation: @MainActor () async throws -> T
    ) async rethrows -> T {
        guard let model else { return try await operation() }
        let previous = DefaultAgentConfigurationStore.load()
        var bound = previous
        bound.defaultModel = model
        DefaultAgentConfigurationStore.save(bound)
        defer { DefaultAgentConfigurationStore.save(previous) }
        return try await operation()
    }
}
