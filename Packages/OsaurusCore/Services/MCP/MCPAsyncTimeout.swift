//
//  MCPAsyncTimeout.swift
//  OsaurusCore
//

import Foundation

enum MCPAsyncTimeout {
    static func run<T: Sendable>(
        seconds: TimeInterval,
        failureSignal: MCPAsyncFailureSignal? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard seconds.isFinite, seconds > 0 else { throw MCPProviderError.timeout }
        let race = MCPTimeoutRace<T>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                failureSignal?.observe { [weak race] error in
                    race?.resolve(.failure(error))
                }
                let operationTask = Task {
                    do {
                        try Task.checkCancellation()
                        race.resolve(.success(try await operation()))
                    } catch {
                        race.resolve(.failure(error))
                    }
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000)
                        )
                        race.resolve(.failure(MCPProviderError.timeout))
                    } catch {
                        // The winning branch cancels this task.
                    }
                }
                race.setTasks(operation: operationTask, timeout: timeoutTask)
            }
        } onCancel: {
            race.resolve(.failure(CancellationError()))
        }
    }
}

final class MCPAsyncFailureSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    private var observer: (@Sendable (Error) -> Void)?

    // One sequential operation observes this sticky signal at a time. A later
    // stage replaces the prior stage's weak observer without losing a failure.
    func observe(_ observer: @escaping @Sendable (Error) -> Void) {
        lock.lock()
        if let failure {
            lock.unlock()
            observer(failure)
        } else {
            self.observer = observer
            lock.unlock()
        }
    }

    func fail(_ error: Error) {
        lock.lock()
        guard failure == nil else {
            lock.unlock()
            return
        }
        failure = error
        let observer = observer
        self.observer = nil
        lock.unlock()
        observer?(error)
    }
}

private final class MCPTimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func setTasks(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        lock.lock()
        if result != nil {
            lock.unlock()
            operation.cancel()
            timeout.cancel()
        } else {
            operationTask = operation
            timeoutTask = timeout
            lock.unlock()
        }
    }

    func resolve(_ candidate: Result<T, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = candidate
        let continuation = continuation
        self.continuation = nil
        let operationTask = operationTask
        let timeoutTask = timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: candidate)
    }
}
