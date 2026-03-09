//
//  SandboxLogBuffer.swift
//  osaurus
//
//  Observable ring buffer for real-time sandbox container logs.
//  Captures exec stdout/stderr streams, plugin log calls, and provisioning events.
//

import Foundation

@MainActor
public final class SandboxLogBuffer: ObservableObject {
    public static let shared = SandboxLogBuffer()

    public struct Entry: Identifiable, Sendable {
        public let id: UUID
        public let timestamp: Date
        public let level: Level
        public let message: String
        public let source: String

        public enum Level: String, Sendable, CaseIterable, Hashable {
            case debug, info, warn, error, stdout

            public init(raw: String) {
                self = Level(rawValue: raw.lowercased()) ?? .info
            }
        }
    }

    public private(set) var entries: [Entry] = []

    private static let maxEntries = 2000
    private static let trimBatchSize = 500
    private var pendingFlush: Task<Void, Never>?

    public func append(level: String, message: String, source: String) {
        append(level: Entry.Level(raw: level), message: message, source: source)
    }

    public func append(level: Entry.Level, message: String, source: String) {
        entries.append(
            Entry(
                id: UUID(),
                timestamp: Date(),
                level: level,
                message: message,
                source: source
            )
        )
        trimIfNeeded()
        scheduleFlush()
    }

    public func appendBatch(_ batch: [(level: Entry.Level, message: String, source: String)]) {
        guard !batch.isEmpty else { return }
        let now = Date()
        entries.reserveCapacity(entries.count + batch.count)
        for item in batch {
            entries.append(
                Entry(
                    id: UUID(),
                    timestamp: now,
                    level: item.level,
                    message: item.message,
                    source: item.source
                )
            )
        }
        trimIfNeeded()
        scheduleFlush()
    }

    public func clear() {
        entries.removeAll(keepingCapacity: true)
        pendingFlush?.cancel()
        pendingFlush = nil
        objectWillChange.send()
    }

    private func trimIfNeeded() {
        if entries.count > Self.maxEntries + Self.trimBatchSize {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    private func scheduleFlush() {
        guard pendingFlush == nil else { return }
        pendingFlush = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self.objectWillChange.send()
            self.pendingFlush = nil
        }
    }
}
