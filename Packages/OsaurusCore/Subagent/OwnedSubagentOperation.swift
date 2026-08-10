//
//  OwnedSubagentOperation.swift
//  OsaurusCore
//
//  Explicit ownership for asynchronous work started on behalf of a spawned
//  run. Cancellation is a two-step contract: request abort, then wait for the
//  operation to terminate. Callers never race a timeout and abandon the losing
//  task.
//

import Foundation

struct OwnedSubagentOperation<Value: Sendable>: Sendable {
    private let task: Task<Value, Error>

    init(_ operation: @escaping @Sendable () async throws -> Value) {
        task = Task {
            try await operation()
        }
    }

    /// Await the operation while polling a run-owned interrupt/deadline signal.
    /// Parent task cancellation requests abort immediately. Every path drains
    /// both the operation and the monitor before returning or throwing.
    func value(
        cancellationRequested: @escaping @Sendable () -> Bool = { false },
        pollInterval: Duration = .milliseconds(20)
    ) async throws -> Value {
        let monitor = Task {
            while !Task.isCancelled {
                if cancellationRequested() {
                    task.cancel()
                    return
                }
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return
                }
            }
        }

        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }

        monitor.cancel()
        _ = await monitor.result

        if cancellationRequested() || Task.isCancelled {
            task.cancel()
            _ = await task.result
            throw CancellationError()
        }
        return try result.get()
    }

    func requestAbort() {
        task.cancel()
    }

    func abortAndWait() async {
        task.cancel()
        _ = await task.result
    }
}
