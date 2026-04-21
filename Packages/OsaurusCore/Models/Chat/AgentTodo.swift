//
//  AgentTodo.swift
//  osaurus
//
//  Lightweight todo model used by the unified Chat agent loop. The model
//  writes a markdown checklist via the `todo` tool; we parse it into
//  `AgentTodoItem`s for inline UI rendering. State is per chat session
//  (keyed by session id).
//
//  Design notes:
//    - Markdown is the canonical representation. `- [ ] ...` (pending)
//      and `- [x] ...` / `- [X] ...` (done). Anything else in the body
//      is preserved as raw markdown but not parsed into items.
//    - The store replaces wholesale on every `todo` call. We do NOT try
//      to merge old + new lines; partial merges hide model intent.
//    - There are no IDs, no acceptance criteria, no step statuses beyond
//      done/pending. Bigger structures are how the previous round drowned
//      small local models. Keep it simple; works for both tiers.
//

import Foundation

/// One row parsed out of the agent's todo markdown.
public struct AgentTodoItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let isDone: Bool

    public init(id: String, text: String, isDone: Bool) {
        self.id = id
        self.text = text
        self.isDone = isDone
    }
}

/// Snapshot of the agent's current todo for a session, including the raw
/// markdown (echoed back to the model on the next turn) and the parsed
/// items (used by the UI).
public struct AgentTodo: Sendable, Equatable {
    public let markdown: String
    public let items: [AgentTodoItem]
    public let updatedAt: Date

    public init(markdown: String, items: [AgentTodoItem], updatedAt: Date = Date()) {
        self.markdown = markdown
        self.items = items
        self.updatedAt = updatedAt
    }

    /// Convenience: parse + wrap.
    public static func parse(_ markdown: String, updatedAt: Date = Date()) -> AgentTodo {
        AgentTodo(markdown: markdown, items: parseItems(from: markdown), updatedAt: updatedAt)
    }

    public var doneCount: Int { items.filter(\.isDone).count }
    public var totalCount: Int { items.count }

    // MARK: - Parsing

    /// Extract `- [ ]` / `- [x]` rows from a markdown blob. Lines that
    /// don't match the checklist syntax are ignored — the model is free
    /// to include prose between groups, headings, etc., we only render
    /// the checklist part. Indentation up to 6 spaces is permitted so
    /// nested checklists still parse.
    static func parseItems(from markdown: String) -> [AgentTodoItem] {
        // Two leading delimiters supported: `-` and `*`. Followed by space,
        // a `[ ]` / `[x]` / `[X]` checkbox, another space, then the text.
        // Captures: 1 = checkbox char, 2 = item text (trailing whitespace
        // trimmed below). We use `[ \t]+` (not `\s+`) for the inter-token
        // separators so a single line cannot bridge across a `\n` and pull
        // the next line's text into a previous item — e.g. an empty
        // `- [ ]` line followed by `- []wrong` would otherwise end up with
        // `"- []wrong"` as the text capture.
        let pattern = #"^[ ]{0,6}[-*][ \t]+\[(?<box>[ xX])\][ \t]+(?<text>.+?)[ \t]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        else { return [] }

        let range = NSRange(markdown.startIndex ..< markdown.endIndex, in: markdown)
        let matches = regex.matches(in: markdown, options: [], range: range)

        var items: [AgentTodoItem] = []
        items.reserveCapacity(matches.count)
        for (offset, m) in matches.enumerated() {
            guard let boxRange = Range(m.range(withName: "box"), in: markdown),
                let textRange = Range(m.range(withName: "text"), in: markdown)
            else { continue }
            let box = String(markdown[boxRange])
            let text = String(markdown[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // Stable ID: index + a short hash of the trimmed text. Index
            // disambiguates duplicates ("- [ ] commit" twice in a list);
            // the hash makes diffs across `todo` calls more meaningful
            // when steps are reordered.
            let id = "\(offset)-\(text.hashValue & 0xFFFFFF)"
            items.append(AgentTodoItem(id: id, text: text, isDone: box.lowercased() == "x"))
        }
        return items
    }
}
