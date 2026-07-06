//
//  ChatInputHistoryNavigator.swift
//  osaurus
//

import Foundation

struct ChatInputHistoryNavigator: Equatable, Sendable {
    private(set) var entries: [String] = []
    private var cursor: Int?
    private var draft: String = ""
    private let limit: Int

    init(limit: Int = 100) {
        self.limit = max(1, limit)
    }

    var isNavigating: Bool {
        cursor != nil
    }

    mutating func record(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { resetNavigation() }
        guard !normalized.isEmpty else { return }
        if entries.last == normalized { return }
        entries.append(normalized)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    mutating func previous(currentText: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if cursor == nil {
            draft = currentText
            cursor = entries.count - 1
        } else if let current = cursor, current > 0 {
            cursor = current - 1
        }
        guard let cursor else { return nil }
        return entries[cursor]
    }

    mutating func next() -> String? {
        guard let current = cursor else { return nil }
        if current < entries.count - 1 {
            cursor = current + 1
            return entries[current + 1]
        }
        let restored = draft
        resetNavigation()
        return restored
    }

    mutating func resetNavigation() {
        cursor = nil
        draft = ""
    }

    mutating func reset() {
        entries.removeAll()
        resetNavigation()
    }
}
