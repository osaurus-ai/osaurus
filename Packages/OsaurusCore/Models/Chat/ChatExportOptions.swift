//
//  ChatExportOptions.swift
//  osaurus
//
//  User-selectable flags for chat export. Persisted via UserDefaults
//  so the export chooser remembers the user's last selection.
//

import Foundation

public struct ChatExportOptions: Codable, Equatable, Sendable {
    public var includeTimestamps: Bool
    public var includeDeltas: Bool
    public var includeTokenUsage: Bool

    public init(
        includeTimestamps: Bool = false,
        includeDeltas: Bool = false,
        includeTokenUsage: Bool = false
    ) {
        self.includeTimestamps = includeTimestamps
        self.includeDeltas = includeDeltas
        self.includeTokenUsage = includeTokenUsage
    }

    /// True if anything timing-related should appear in the export header.
    public var hasAnyFlag: Bool {
        includeTimestamps || includeDeltas || includeTokenUsage
    }

    private static let defaultsKey = "chat.export.options.lastChoice"

    public static func loadLast() -> ChatExportOptions {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let value = try? JSONDecoder().decode(ChatExportOptions.self, from: data)
        else { return ChatExportOptions() }
        return value
    }

    public func saveAsLast() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

extension ChatSessionData {
    /// True if at least one turn carries any timing data. Used by the
    /// chooser to enable / disable the page-2 toggles.
    public var hasAnyTimingData: Bool {
        turns.contains { turn in
            turn.createdAt != nil
                || turn.completedAt != nil
                || turn.generationTokenCount != nil
                || turn.timeToFirstToken != nil
        }
    }
}
