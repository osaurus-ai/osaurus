import Foundation
import os

/// Compaction has an admission budget, a generation budget and an owned
/// handoff/restore budget. Waiting for a different local job must not spend
/// the generation budget before the summary model has even started.
enum CompactionDeadline {
    enum Phase: Int, Sendable, Equatable {
        case waiting, preparing, generating, restoring

        var description: String {
            switch self {
            case .waiting: return "waiting for other local work"
            case .preparing: return "preparing the model handoff"
            case .generating: return "running the compaction model"
            case .restoring: return "restoring the chat model"
            }
        }
    }

    struct Expired: Error, Sendable, Equatable {
        let phase: Phase
        let seconds: Double
        let elapsed: Double
    }

    static func run<Value: Sendable>(
        waitingSeconds: Double,
        operation:
            @escaping @Sendable (
                _ enter: @escaping @Sendable (Phase, Double) -> Void
            ) async throws -> Value
    ) async throws -> Value {
        let deadline = Controller<Value>(waitingSeconds: waitingSeconds)
        let work = Task(priority: .high) {
            try await operation { phase, seconds in deadline.enter(phase, seconds: seconds) }
        }
        deadline.attachCancellation { work.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                deadline.install(continuation)
                Task { deadline.finish(await work.result, cancelWork: false) }
            }
        } onCancel: {
            deadline.finish(.failure(CancellationError()), cancelWork: true)
        }
    }

    private final class Controller<Value: Sendable>: @unchecked Sendable {
        typealias Action = (CheckedContinuation<Value, Error>?, Result<Value, Error>, (@Sendable () -> Void)?)
        struct State {
            var phase: Phase = .waiting
            var seconds: Double
            var deadline: DispatchTime
            let started: DispatchTime
            var continuation: CheckedContinuation<Value, Error>?
            var result: Result<Value, Error>?
            var cancel: (@Sendable () -> Void)?
            var cancellationRequested = false
        }

        private let state: OSAllocatedUnfairLock<State>
        private let timer: DispatchSourceTimer

        init(waitingSeconds: Double) {
            let seconds = max(0, waitingSeconds.isFinite ? waitingSeconds : 0)
            let now = DispatchTime.now()
            state = OSAllocatedUnfairLock(
                initialState: State(
                    seconds: seconds,
                    deadline: now + seconds,
                    started: now
                )
            )
            timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.setEventHandler { [weak self] in self?.fired() }
            timer.activate()
        }

        func attachCancellation(_ cancel: @escaping @Sendable () -> Void) {
            let cancelled = state.withLock { s in
                if s.result == nil { s.cancel = cancel }
                return s.cancellationRequested
            }
            if cancelled { cancel() }
        }

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            let result = state.withLock { s -> Result<Value, Error>? in
                if let result = s.result { return result }
                s.continuation = continuation
                timer.schedule(deadline: s.deadline)
                return nil
            }
            if let result { continuation.resume(with: result) }
        }

        func enter(_ phase: Phase, seconds requested: Double) {
            let action = state.withLock { s -> Action? in
                guard s.result == nil, phase.rawValue > s.phase.rawValue else { return nil }
                let now = DispatchTime.now()
                // A late stage notification cannot rescue an already-expired
                // phase just because its timer callback has not run yet.
                if now >= s.deadline {
                    let result: Result<Value, Error> = .failure(expiration(s, now: now))
                    s.result = result
                    s.cancellationRequested = true
                    let action: Action = (s.continuation, result, s.cancel)
                    s.continuation = nil
                    s.cancel = nil
                    timer.cancel()
                    return action
                } else {
                    s.phase = phase
                    s.seconds = max(0, requested.isFinite ? requested : 0)
                    s.deadline = now + s.seconds
                    if s.continuation != nil { timer.schedule(deadline: s.deadline) }
                    return nil
                }
            }
            if let (continuation, result, cancel) = action {
                cancel?()
                continuation?.resume(with: result)
            }
        }

        func finish(_ result: Result<Value, Error>, cancelWork: Bool) {
            let action = state.withLock {
                s -> (CheckedContinuation<Value, Error>?, (@Sendable () -> Void)?, Result<Value, Error>)? in
                guard s.result == nil else { return nil }
                let resolved: Result<Value, Error>
                if case .success = result, DispatchTime.now() >= s.deadline {
                    resolved = .failure(expiration(s, now: .now()))
                } else {
                    resolved = result
                }
                s.result = resolved
                s.cancellationRequested = cancelWork
                let continuation = s.continuation
                s.continuation = nil
                let cancel = cancelWork ? s.cancel : nil
                s.cancel = nil
                timer.cancel()
                return (continuation, cancel, resolved)
            }
            if let (continuation, cancel, resolved) = action {
                cancel?()
                continuation?.resume(with: resolved)
            }
        }

        private func fired() {
            let action = state.withLock { s -> Action? in
                guard s.result == nil else { return nil }
                let now = DispatchTime.now()
                guard now >= s.deadline else {
                    timer.schedule(deadline: s.deadline)
                    return nil
                }
                let result: Result<Value, Error> = .failure(expiration(s, now: now))
                s.result = result
                s.cancellationRequested = true
                let action: Action = (s.continuation, result, s.cancel)
                s.continuation = nil
                s.cancel = nil
                timer.cancel()
                return action
            }
            if let (continuation, result, cancel) = action {
                cancel?()
                continuation?.resume(with: result)
            }
        }

        private func expiration(_ s: State, now: DispatchTime) -> Expired {
            Expired(
                phase: s.phase,
                seconds: s.seconds,
                elapsed: Double(now.uptimeNanoseconds - s.started.uptimeNanoseconds) / 1_000_000_000
            )
        }
    }
}
