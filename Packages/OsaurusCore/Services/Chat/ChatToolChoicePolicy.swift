//
//  ChatToolChoicePolicy.swift
//

import Foundation

enum ChatToolChoicePolicy {
    static func resolve(
        tools: [Tool],
        userText: String,
        attempt: Int
    ) -> ToolChoiceOption? {
        guard !tools.isEmpty else { return nil }
        guard attempt == 1 else { return .auto }

        return requiresToolCall(tools: tools, userText: userText) ? .required : .auto
    }

    private static func requiresToolCall(tools: [Tool], userText: String) -> Bool {
        let text = userText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard !containsNegatedToolIntent(text) else { return false }

        let names = Set(tools.map { $0.function.name.lowercased() })
        if names.contains(where: { containsCallableName($0, in: text) }) {
            return true
        }

        guard names.contains(where: isFileLikeToolName) else { return false }
        return containsGenericFileToolIntent(text)
    }

    private static func containsCallableName(_ name: String, in text: String) -> Bool {
        guard !name.isEmpty else { return false }
        return text.contains(name)
    }

    private static func containsNegatedToolIntent(_ text: String) -> Bool {
        [
            "do not use",
            "don't use",
            "dont use",
            "without using",
            "no tool",
            "no tools",
            "do not call",
            "don't call",
            "dont call",
        ].contains { text.contains($0) }
    }

    private static func isFileLikeToolName(_ name: String) -> Bool {
        [
            "file_read",
            "file_write",
            "file_edit",
            "file_search",
            "sandbox_read_file",
            "sandbox_write_file",
            "sandbox_search_files",
        ].contains(name)
    }

    private static func containsGenericFileToolIntent(_ text: String) -> Bool {
        let directPhrases = [
            "available file tool",
            "using the available file tool",
            "use the available file tool",
            "call the file tool",
            "use the file tool",
            "invoke the file tool",
            "read the file",
            "read file",
            "open the file",
            "inspect the file",
            "look at the file",
            "look at files",
            "look at the files",
            "list files",
            "list the files",
        ]
        if directPhrases.contains(where: { text.contains($0) }) {
            return true
        }

        let hasFileTarget =
            text.contains(".swift")
            || text.contains(".py")
            || text.contains(".json")
            || text.contains(".md")
            || text.contains(".txt")
            || containsPathLikeTarget(text)

        let hasFileAction =
            text.contains(" read ")
            || text.hasPrefix("read ")
            || text.contains(" open ")
            || text.hasPrefix("open ")
            || text.contains(" inspect ")
            || text.hasPrefix("inspect ")
            || text.contains(" search ")
            || text.hasPrefix("search ")

        return hasFileTarget && hasFileAction
    }

    private static func containsPathLikeTarget(_ text: String) -> Bool {
        text.range(
            of: #"(^|\s)(~?/|\.{1,2}/|/[^\s]+)"#,
            options: .regularExpression
        ) != nil
    }
}
