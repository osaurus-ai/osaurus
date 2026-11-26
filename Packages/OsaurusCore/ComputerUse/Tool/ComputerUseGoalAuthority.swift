//
//  ComputerUseGoalAuthority.swift
//  OsaurusCore — Computer Use
//
//  Keeps the user's own wording authoritative for exact text replacements.
//  A parent model that paraphrases "change X to Y" before calling
//  `computer_use` has been observed to add unrequested side effects (an
//  invented save) or to turn the old text into a document name. When both the
//  parent goal and the visible user request encode the same exact old/new
//  pair, the user request wins; every other goal passes through unchanged.
//

import Foundation

enum ComputerUseGoalAuthority {
    /// The two exact values of a replacement request.
    struct Replacement: Equatable {
        let oldText: String
        let newText: String

        var values: Set<String> { [oldText, newText] }
    }

    /// Return the user's direct replacement wording when the parent goal
    /// describes the same exact old/new values. Ambiguous, anaphoric, or
    /// non-replacement requests keep the parent goal. An explicit save in the
    /// user wording remains.
    static func authoritativeReplacementTask(
        parentTask: String,
        latestUserTask: String?
    ) -> String {
        guard let latestUserTask else { return parentTask }
        let userTask = latestUserTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userTask.isEmpty,
            let userValues = exactReplacement(from: userTask)
        else { return parentTask }
        let sameExactReplacement: Bool
        if let parentValues = exactReplacement(from: parentTask) {
            sameExactReplacement = parentValues.values == userValues.values
        } else {
            // A parent that rewrote "text in the open document" into
            // "document named <old text>" still repeats both exact values and
            // asks for a mutation. Reconcile only then; a compare/read task, a
            // partial value match, or a different replacement stays untouched.
            let values = [userValues.oldText, userValues.newText]
            let containsEveryValue = values.allSatisfy {
                parentTask.range(of: $0, options: .literal) != nil
            }
            let requestsMutation = parentTask.range(
                of: #"\b(?:replace|change|edit|set|update)\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            let userNamesTextEdit = userTask.range(
                of: #"\bTextEdit\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            let parentNamesTextEdit = parentTask.range(
                of: #"\bTextEdit\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            let parentKeepsExactNewText =
                parentTask.range(of: userValues.newText, options: .literal) != nil
            let parentAddsNoQuotedValue = quotedValues(in: parentTask).map { quoted in
                quoted.allSatisfy { values.contains($0) }
            } ?? false

            // A rewrite that keeps TextEdit, the exact new bytes, and a `set`
            // intent but drops the old text entirely is still the same edit:
            // the visible user request supplies the full from/to contract.
            let safeTextEditNewValueSubset =
                userNamesTextEdit && parentNamesTextEdit
                && parentKeepsExactNewText && parentAddsNoQuotedValue
                && requestsMutation
            sameExactReplacement =
                (containsEveryValue && requestsMutation) || safeTextEditNewValueSubset
        }
        guard sameExactReplacement else { return parentTask }
        debugLog("[ComputerUse] kept matching latest user replacement task authoritative")
        return userTask
    }

    /// Complete straight/curly quoted values, without interpreting them.
    /// `nil` means malformed or unmatched quoting.
    static func quotedValues(in text: String) -> [String]? {
        quotedSpans(in: text)?.map(\.value)
    }

    /// The exact old/new pair of a `replace “old” with “new”`,
    /// `change … from “old” to “new”`, `replace … from “old” to “new”`,
    /// `change occurrences of “old” to “new”`, or
    /// `file containing “old” and replace that text with “new”` request.
    /// Exactly two non-empty quoted values and that narrow grammar are
    /// required; anything else is `nil`.
    static func exactReplacement(from task: String) -> Replacement? {
        guard let quoted = quotedSpans(in: task),
            quoted.count == 2,
            !quoted[0].value.isEmpty,
            !quoted[1].value.isEmpty
        else { return nil }

        let beforeOld = task[..<quoted[0].opening].lowercased()
        let separatorStart = task.index(after: quoted[0].closing)
        let separator = task[separatorStart..<quoted[1].opening].lowercased()
        let trimmedBeforeOld = beforeOld.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSeparator = separator.trimmingCharacters(in: .whitespacesAndNewlines)
        func before(_ pattern: String) -> Bool {
            trimmedBeforeOld.range(of: pattern, options: .regularExpression) != nil
        }
        let replaceForm = trimmedSeparator == "with" && before(#"\breplace\b"#)
        let fromToForm =
            trimmedSeparator == "to"
            && (before(#"\bchange\b"#) || before(#"\breplace\b"#))
            && before(#"\bfrom$"#)
        let changeOccurrenceForm =
            trimmedSeparator == "to"
            && before(#"\bchange\b"#)
            && before(#"\boccurrences?\s+of$"#)
        let containingThenReplaceForm =
            before(#"\b(?:file|document)\s+containing$"#)
            && trimmedSeparator.range(
                of: #"^(?:and\s+)?replace\s+(?:that|the|this)\s+(?:text|content|string|value)\s+with$"#,
                options: .regularExpression
            ) != nil
        guard replaceForm || fromToForm || changeOccurrenceForm || containingThenReplaceForm else {
            return nil
        }
        return Replacement(oldText: quoted[0].value, newText: quoted[1].value)
    }

    private struct QuotedSpan {
        let value: String
        let opening: String.Index
        let closing: String.Index
    }

    private static func quotedSpans(in text: String) -> [QuotedSpan]? {
        var spans: [QuotedSpan] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let closingQuote: Character?
            switch text[cursor] {
            case "\"": closingQuote = "\""
            case "“": closingQuote = "”"
            default: closingQuote = nil
            }
            guard let closingQuote else {
                cursor = text.index(after: cursor)
                continue
            }
            let valueStart = text.index(after: cursor)
            guard let close = text[valueStart...].firstIndex(of: closingQuote) else { return nil }
            spans.append(QuotedSpan(value: String(text[valueStart..<close]), opening: cursor, closing: close))
            cursor = text.index(after: close)
        }
        return spans
    }
}
