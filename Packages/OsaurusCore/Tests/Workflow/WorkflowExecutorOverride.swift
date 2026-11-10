//
//  WorkflowExecutorOverride.swift
//  osaurusTests
//

@testable import OsaurusCore

/// Every workflow run `body` starts uses `makeExecutor`; runs other tests
/// start in parallel keep their own.
@MainActor
enum WorkflowExecutorOverride {
    static func with<T>(
        _ makeExecutor: @escaping @Sendable () -> WorkflowNodeExecuting,
        _ body: @MainActor () async throws -> T
    ) async rethrows -> T {
        try await WorkflowExecutorSeam.$override.withValue(makeExecutor) { try await body() }
    }
}
