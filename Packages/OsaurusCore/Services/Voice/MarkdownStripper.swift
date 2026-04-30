//
//  MarkdownStripper.swift
//  osaurus
//
//  Converts Markdown-formatted text into plain prose suitable for speech synthesis.
//  Drops fenced code blocks entirely (reading code aloud is noise), strips inline
//  markup, and collapses whitespace.
//

import Foundation

public enum MarkdownStripper {

    /// Returns a plain-text rendering of `markdown` with code blocks removed and
    /// formatting markers stripped. Safe to feed directly to a TTS engine.
    public static func plainText(from markdown: String) -> String {
        var text = markdown

        text = replace(pattern: "```[\\s\\S]*?```", in: text, with: " ")
        text = replace(pattern: "~~~[\\s\\S]*?~~~", in: text, with: " ")

        text = replace(pattern: "`([^`\\n]+)`", in: text, with: "$1")

        text = replace(pattern: "!\\[([^\\]]*)\\]\\([^)]*\\)", in: text, with: "$1")
        text = replace(pattern: "\\[([^\\]]+)\\]\\([^)]*\\)", in: text, with: "$1")
        text = replace(pattern: "\\[([^\\]]+)\\]\\[[^\\]]*\\]", in: text, with: "$1")

        text = replace(pattern: "<[^>]+>", in: text, with: " ")

        text = replace(pattern: "(?m)^\\s{0,3}#{1,6}\\s+", in: text, with: "")
        text = replace(pattern: "(?m)^\\s{0,3}>\\s?", in: text, with: "")
        text = replace(pattern: "(?m)^\\s{0,3}[-*+]\\s+", in: text, with: "")
        text = replace(pattern: "(?m)^\\s{0,3}\\d+\\.\\s+", in: text, with: "")
        text = replace(pattern: "(?m)^\\s*[-*_]{3,}\\s*$", in: text, with: "")

        text = replace(pattern: "(\\*\\*|__)(.+?)\\1", in: text, with: "$2")
        text = replace(pattern: "(?<!\\w)([*_])([^*_\\n]+?)\\1(?!\\w)", in: text, with: "$2")
        text = replace(pattern: "~~(.+?)~~", in: text, with: "$1")

        text = replace(pattern: "[ \\t]+", in: text, with: " ")
        text = replace(pattern: "\\n{3,}", in: text, with: "\n\n")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(pattern: String, in text: String, with template: String) -> String {
        guard
            let regex = try? NSRegularExpression(pattern: pattern)
        else {
            return text
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}
