//
//  TaskBus.swift
//  osaurus
//
//  In-process fan-out of task changes, journal events and reservation
//  changes. Observers run synchronously on the main actor in registration
//  order; `stream()` is for async consumers.
//

import Foundation

public enum TaskBusEvent: Sendable {
    case taskChanged(OsaurusTask)
    case journal(TaskEvent)
    case reservationsChanged([ForegroundReservation])
}

@MainActor
public final class TaskBus {
    public static let shared = TaskBus()

    public struct Token: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private var observers: [(id: UUID, handler: @MainActor (TaskBusEvent) -> Void)] = []
    private var continuations: [UUID: AsyncStream<TaskBusEvent>.Continuation] = [:]

    public init() {}

    @discardableResult
    public func observe(_ handler: @escaping @MainActor (TaskBusEvent) -> Void) -> Token {
        let id = UUID()
        observers.append((id, handler))
        return Token(id: id)
    }

    public func remove(_ token: Token) {
        observers.removeAll { $0.id == token.id }
        continuations.removeValue(forKey: token.id)?.finish()
    }

    public func stream() -> AsyncStream<TaskBusEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    public func publish(_ event: TaskBusEvent) {
        for observer in observers { observer.handler(event) }
        for continuation in continuations.values { continuation.yield(event) }
    }
}
