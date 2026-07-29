//
//  SpawnRemoteModelIdentity.swift
//  OsaurusCore
//
//  Stable, spawn-only identity for an exact remote provider/model pair.
//  Normal chat model ids intentionally remain the existing human-readable
//  "provider-name/model" form; only persisted subagent targets use this
//  UUID-backed route.
//

import Foundation

enum SpawnRemoteModelIdentity {
    static let prefix = "remote-provider:"

    struct Parsed: Sendable, Equatable {
        let providerId: UUID
        let modelId: String
    }

    static func make(providerId: UUID, modelId: String) -> String? {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(prefix)\(providerId.uuidString.lowercased())/\(trimmed)"
    }

    static func parse(_ value: String?) -> Parsed? {
        guard
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            trimmed.hasPrefix(prefix)
        else {
            return nil
        }
        let remainder = trimmed.dropFirst(prefix.count)
        guard let separator = remainder.firstIndex(of: "/") else { return nil }
        let providerPart = remainder[..<separator]
        let modelStart = remainder.index(after: separator)
        let modelPart = remainder[modelStart...]
        guard
            let providerId = UUID(uuidString: String(providerPart)),
            !modelPart.isEmpty
        else {
            return nil
        }
        return Parsed(providerId: providerId, modelId: String(modelPart))
    }
}
