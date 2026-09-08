//
//  GroundedFileSideEffectCheck.swift
//  osaurus
//
//  Deterministic grounding for FILE side-effect narration. Observed live
//  (0.24.6, Ornith-1.5-9B): the model wrote "appended to the file" as the
//  visible text of a message whose only tool call was `fetch_html`, and no
//  write tool was even in the schema. Nothing was written, no loop-breaker
//  noticed, and the user was told a file had changed.
//
//  Same contract as `GroundedConfigClaimCheck`: pure text/state predicates
//  over what actually executed. Model output is never edited, stripped, or
//  synthesized. On a trip the loop stages a factual `[System Notice]` on the
//  transient channel and keeps going — this is an ADVISORY nudge, never a
//  stop, never a refusal.
//

import Foundation

enum GroundedFileSideEffectCheck {

    /// Tools whose successful execution grounds a "wrote / appended / saved /
    /// created the file" claim. Deliberately broad: shell/exec tools can
    /// write via redirection, `share_artifact` materialises a file the user
    /// receives, and the knowledge writers produce documents. A claim after
    /// any of these is plausible and must not be second-guessed.
    static let fileWritingToolNames: Set<String> = [
        "file_write", "file_edit", "file_copy", "file_undo", "redact_file",
        "sandbox_write_file", "shell_run", "sandbox_exec",
        "write_knowledge", "edit_knowledge", "share_artifact",
    ]

    /// True when this outcome is a SUCCESSFUL execution of a file-writing
    /// tool. A failed `file_write` grounds nothing — the file is unchanged,
    /// so "I saved it" after that failure is exactly the fabrication this
    /// check exists to catch.
    static func isGroundedFileWriteOutcome(toolName: String, result: String) -> Bool {
        guard fileWritingToolNames.contains(toolName) else { return false }
        return ToolEnvelope.isSuccess(result)
    }

    static let ungroundedFileClaimNotice =
        "[System Notice] Your previous message says a file was written, appended, saved, or "
        + "created, but no file-writing tool (file_write / file_edit / sandbox_write_file) ran "
        + "successfully this turn — nothing has been written. If a file-writing tool is in your "
        + "tool list, call it now with the content. If none is available, tell the user plainly "
        + "that you cannot write files in this chat (they can attach a folder with the Folder "
        + "chip) and give them the content directly instead."

    // MARK: - Claim detection

    /// "appended the file", "wrote the note", "saved this report",
    /// "creating the markdown document", "saving it to the file".
    private static let claimPatterns: [NSRegularExpression] = {
        let sources = [
            "\\b(?:append(?:ed|ing)?|wrote|writing|saved|saving|created|creating)\\s+"
                + "(?:it\\s+|this\\s+|that\\s+|the\\s+|your\\s+|a\\s+|an\\s+)?"
                + "(?:file|note|document|markdown|report)s?\\b",
            "\\bto\\s+(?:the\\s+|your\\s+)?file\\b",
        ]
        return sources.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    /// Honest negations veto the sentence: "nothing was written to the
    /// file", "I couldn't save the report", "the write to the file failed".
    private static let negationPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern:
            "\\b(?:no|not|never|nothing|none|cannot|can't|couldn't|didn't|wasn't|weren't"
            + "|hasn't|haven't|isn't|aren't|won't|unable|without|fail|failed|failing|error)\\b",
        options: [.caseInsensitive]
    )

    /// Stated INTENT is not a claim: "I'll append it to the file once the
    /// page is fetched", "let me save the report", "should I write the note?"
    /// Only past/progressive narration that reads as "this happened / is
    /// happening" counts.
    private static let intentPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern:
            "\\b(?:i(?:'|’)?ll|i\\s+will|will|would|i(?:'|’)?d|let\\s+me|let's|going\\s+to"
            + "|about\\s+to|plan(?:ning)?\\s+to|need\\s+to|want(?:s)?\\s+(?:me\\s+)?to|shall"
            + "|should|could|can|may|might|try(?:ing)?\\s+to|ready\\s+to|able\\s+to|if)\\b",
        options: [.caseInsensitive]
    )

    /// True when any declarative sentence narrates a completed or in-progress
    /// file write. Sentence-scoped so an honest negation or a plan elsewhere
    /// in the message can neither mask nor cause a match.
    static func containsFileSideEffectClaim(_ text: String) -> Bool {
        for sentence in sentences(in: text) {
            guard !sentence.isQuestion else { continue }
            let range = NSRange(sentence.text.startIndex..., in: sentence.text)
            if let negation = negationPattern,
                negation.firstMatch(in: sentence.text, options: [], range: range) != nil
            {
                continue
            }
            if let intent = intentPattern,
                intent.firstMatch(in: sentence.text, options: [], range: range) != nil
            {
                continue
            }
            for pattern in claimPatterns
            where pattern.firstMatch(in: sentence.text, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    private struct Sentence {
        let text: String
        let isQuestion: Bool
    }

    /// Split on sentence terminators and newlines, remembering whether each
    /// unit ended interrogatively. Mirrors `GroundedConfigClaimCheck`.
    private static func sentences(in text: String) -> [Sentence] {
        var result: [Sentence] = []
        var current = ""
        for character in text {
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.append(Sentence(text: trimmed, isQuestion: character == "?"))
                }
                current = ""
            } else {
                current.append(character)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result.append(Sentence(text: trimmed, isQuestion: false))
        }
        return result
    }
}
