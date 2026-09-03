//
//  InferenceActivityRegistry.swift
//  osaurus
//
//  Request-level live inference state. Batch diagnostics answer how an engine
//  is performing; this registry answers who asked it to run, which lifecycle
//  phase the request is in, and lets the operator stop that exact request.
//

import Foundation

enum InferenceActivityPhase: String, Sendable, CaseIterable {
    case queued
    case loading
    case prefilling
    case generating
    case finishing
    case unloading

    var displayName: String {
        switch self {
        case .queued: return L("Queued")
        case .loading: return L("Loading model")
        case .prefilling: return L("Processing prompt")
        case .generating: return L("Generating")
        case .finishing: return L("Saving cache")
        case .unloading: return L("Unloading model")
        }
    }
}

struct InferenceActivitySnapshot: Identifiable, Sendable, Equatable {
    let id: UUID
    let modelName: String
    let source: RequestSource
    let sessionID: String?
    let phase: InferenceActivityPhase
    let startedAt: Date
    let cancellationRequested: Bool
    let canCancel: Bool
}

actor InferenceActivityRegistry {
    static let shared = InferenceActivityRegistry()

    private struct Entry {
        var snapshot: InferenceActivitySnapshot
        var cancel: (@Sendable () -> Void)?
    }

    private var entries: [UUID: Entry] = [:]

    func begin(
        id: UUID,
        modelName: String,
        source: RequestSource,
        sessionID: String?,
        phase: InferenceActivityPhase
    ) {
        entries[id] = Entry(
            snapshot: InferenceActivitySnapshot(
                id: id,
                modelName: modelName,
                source: source,
                sessionID: sessionID,
                phase: phase,
                startedAt: Date(),
                cancellationRequested: false,
                canCancel: false
            ),
            cancel: nil
        )
    }

    func update(id: UUID, phase: InferenceActivityPhase) {
        guard var entry = entries[id] else { return }
        entry.snapshot = Self.copy(entry.snapshot, phase: phase)
        entries[id] = entry
    }

    func installCancellation(id: UUID, cancel: @escaping @Sendable () -> Void) {
        guard var entry = entries[id] else { return }
        entry.cancel = cancel
        entry.snapshot = Self.copy(entry.snapshot, canCancel: true)
        entries[id] = entry
    }

    func finish(id: UUID) {
        entries.removeValue(forKey: id)
    }

    func snapshot() -> [InferenceActivitySnapshot] {
        entries.values.map(\.snapshot).sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    @discardableResult
    func cancel(id: UUID) -> Bool {
        guard var entry = entries[id], let cancel = entry.cancel else { return false }
        entry.snapshot = Self.copy(entry.snapshot, cancellationRequested: true)
        entries[id] = entry
        cancel()
        return true
    }

    private static func copy(
        _ value: InferenceActivitySnapshot,
        phase: InferenceActivityPhase? = nil,
        cancellationRequested: Bool? = nil,
        canCancel: Bool? = nil
    ) -> InferenceActivitySnapshot {
        InferenceActivitySnapshot(
            id: value.id,
            modelName: value.modelName,
            source: value.source,
            sessionID: value.sessionID,
            phase: phase ?? value.phase,
            startedAt: value.startedAt,
            cancellationRequested: cancellationRequested ?? value.cancellationRequested,
            canCancel: canCancel ?? value.canCancel
        )
    }
}
