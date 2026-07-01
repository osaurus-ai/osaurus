//
//  ChannelReplayNonceStore.swift
//  osaurus
//
//  Persistent nonce/replay store for scoped channel reply tokens.
//

import Foundation

enum ChannelNonceConsumeResult: Equatable, Sendable {
    case consumed
    case replayed
    case revoked
}

protocol ChannelReplyTokenNonceStore: Sendable {
    func consume(
        scope: String,
        nonce: String,
        expiresAt: Date,
        now: Date
    ) throws -> ChannelNonceConsumeResult

    func revoke(
        scope: String,
        nonce: String,
        expiresAt: Date,
        now: Date
    ) throws

    @discardableResult
    func prune(expiredBefore: Date) throws -> Int
}

final class ChannelReplayNonceStore: ChannelReplyTokenNonceStore, @unchecked Sendable {
    // The file backend is process-local serialized. Future multi-process
    // receive services should move this table behind SQLite or another
    // compare-and-insert store before sharing the same nonce file concurrently.
    static let shared = ChannelReplayNonceStore()

    private struct Envelope: Codable {
        var schemaVersion: Int
        var scopes: [String: [String: Record]]

        init(schemaVersion: Int = 1, scopes: [String: [String: Record]] = [:]) {
            self.schemaVersion = schemaVersion
            self.scopes = scopes
        }
    }

    private struct Record: Codable {
        var expiresAt: Date
        var usedAt: Date?
        var revokedAt: Date?
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "ai.osaurus.channels.replay-nonces")

    init(fileURL: URL? = nil) {
        self.fileURL =
            fileURL
            ?? OsaurusPaths.agentChannels().appendingPathComponent("reply-token-nonces.json")
    }

    func consume(
        scope: String,
        nonce: String,
        expiresAt: Date,
        now: Date = Date()
    ) throws -> ChannelNonceConsumeResult {
        try queue.sync {
            let scope = normalized(scope)
            let nonce = normalized(nonce)
            guard !scope.isEmpty, !nonce.isEmpty else {
                throw ChannelReplayNonceStoreError.invalidScope
            }

            var envelope = try loadUnlocked()
            var records = envelope.scopes[scope] ?? [:]
            if let existing = records[nonce] {
                if existing.revokedAt != nil {
                    return .revoked
                }
                if existing.usedAt != nil {
                    return .replayed
                }
            }

            records[nonce] = Record(
                expiresAt: expiresAt,
                usedAt: now,
                revokedAt: records[nonce]?.revokedAt
            )
            envelope.scopes[scope] = records
            try saveUnlocked(envelope)
            return .consumed
        }
    }

    func revoke(
        scope: String,
        nonce: String,
        expiresAt: Date,
        now: Date = Date()
    ) throws {
        try queue.sync {
            let scope = normalized(scope)
            let nonce = normalized(nonce)
            guard !scope.isEmpty, !nonce.isEmpty else {
                throw ChannelReplayNonceStoreError.invalidScope
            }

            var envelope = try loadUnlocked()
            var records = envelope.scopes[scope] ?? [:]
            let existing = records[nonce]
            records[nonce] = Record(
                expiresAt: existing?.expiresAt ?? expiresAt,
                usedAt: existing?.usedAt,
                revokedAt: now
            )
            envelope.scopes[scope] = records
            try saveUnlocked(envelope)
        }
    }

    @discardableResult
    func prune(expiredBefore: Date) throws -> Int {
        try queue.sync {
            var envelope = try loadUnlocked()
            var removed = 0
            for scope in Array(envelope.scopes.keys) {
                var records = envelope.scopes[scope] ?? [:]
                let before = records.count
                records = records.filter { _, record in
                    record.expiresAt >= expiredBefore
                }
                let after = records.count
                removed += before - after
                if records.isEmpty {
                    envelope.scopes.removeValue(forKey: scope)
                } else {
                    envelope.scopes[scope] = records
                }
            }
            if removed > 0 {
                try saveUnlocked(envelope)
            }
            return removed
        }
    }

    private func loadUnlocked() throws -> Envelope {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Envelope()
        }
        return try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
    }

    private func saveUnlocked(_ envelope: Envelope) throws {
        OsaurusPaths.ensureExistsSilent(fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(envelope).write(to: fileURL, options: [.atomic])
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ChannelReplayNonceStoreError: Error, Equatable {
    case invalidScope
}
