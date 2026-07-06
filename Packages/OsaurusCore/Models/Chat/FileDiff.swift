//
//  FileDiff.swift
//  osaurus
//
//  Parsed representation of a file-edit tool result, used to render a
//  GitHub-style diff card in place of the generic tool-call row.
//

import Foundation

/// A parsed, render-ready diff for a single file edit.
///
/// Produced from the envelope returned by the `file_write` / `file_edit`
/// folder tools, whose `result.diff` already carries a unified-diff text
/// (see `WorkspaceWriteSafety.unifiedDiff`). The diff card reads `lines`
/// for per-row tinting and `addedCount` / `removedCount` for the header
/// badge; `rawDiff` backs the copy button.
struct FileDiff: Equatable {
    enum LineKind: Equatable {
        case context
        case added
        case removed
        /// Non-content markers from the diff text (truncation notices,
        /// "no text changes"), shown dimmed without a +/- tint.
        case meta
    }

    struct Line: Equatable {
        let kind: LineKind
        /// Line content with the leading diff marker (+/-/space) stripped.
        let text: String
    }

    /// Path relative to the selected folder (e.g. "src/config.ts").
    let path: String
    /// highlight.js-style language hint inferred from the extension, or nil.
    let language: String?
    let lines: [Line]
    let addedCount: Int
    let removedCount: Int
    /// True when produced by a `dry_run` preview rather than an applied write.
    let isPreview: Bool
    /// True when the underlying tool capped the diff text.
    let truncated: Bool
    /// The raw unified-diff text, used for the card's copy action.
    let rawDiff: String
    /// True for the live card rendered while the tool call's arguments are
    /// still streaming — content is a partial prefix of the file, so the
    /// renderer skips syntax highlighting and shows a "writing" badge.
    var isStreamingPreview: Bool = false

    /// File name component for the card header.
    var fileName: String {
        (path as NSString).lastPathComponent
    }

    // MARK: - Parsing

    /// Tool names whose success envelope carries a renderable diff.
    static let diffProducingToolNames: Set<String> = [
        "file_write", "file_edit", "sandbox_write_file",
    ]

    /// Builds a `FileDiff` from a `file_write` / `file_edit` success envelope.
    /// Returns nil for error envelopes or results without a `diff` field.
    static func from(toolResult result: String) -> FileDiff? {
        guard let payload = ToolEnvelope.successPayload(result) as? [String: Any],
            let diffText = payload["diff"] as? String,
            !diffText.isEmpty
        else { return nil }

        let path = (payload["path"] as? String) ?? ""
        let isPreview = (payload["dry_run"] as? Bool) ?? false
        let truncated = (payload["diff_truncated"] as? Bool) ?? false

        var lines: [Line] = []
        var added = 0
        var removed = 0
        for raw in diffText.components(separatedBy: "\n") {
            // Skip the unified-diff file headers — the card renders the path
            // in its own header row instead.
            if raw.hasPrefix("--- ") || raw.hasPrefix("+++ ") { continue }
            guard let marker = raw.first else {
                lines.append(Line(kind: .context, text: ""))
                continue
            }
            let body = String(raw.dropFirst())
            switch marker {
            case "+":
                added += 1
                lines.append(Line(kind: .added, text: body))
            case "-":
                removed += 1
                lines.append(Line(kind: .removed, text: body))
            case " ":
                lines.append(Line(kind: .context, text: body))
            default:
                // "...", " no text changes", and any other annotation.
                lines.append(Line(kind: .meta, text: raw))
            }
        }

        return FileDiff(
            path: path,
            language: language(forPath: path),
            lines: lines,
            addedCount: added,
            removedCount: removed,
            isPreview: isPreview,
            truncated: truncated,
            rawDiff: diffText
        )
    }

    // MARK: - Streaming preview

    /// Builds a live preview card from a diff-producing tool call whose
    /// arguments are still streaming. Extracts the (possibly truncated)
    /// `content` / `new_string` value from the partial JSON and renders every
    /// line as added, so the card grows smoothly as the model writes instead
    /// of the finished diff landing all at once. Returns nil until the content
    /// field has started streaming.
    static func streamingPreview(toolName: String, partialArgs: String) -> FileDiff? {
        guard diffProducingToolNames.contains(toolName) else { return nil }
        guard
            let body = partialJSONStringValue(forKey: "content", in: partialArgs)
                ?? partialJSONStringValue(forKey: "new_string", in: partialArgs),
            !body.isEmpty
        else { return nil }

        let path = partialJSONStringValue(forKey: "path", in: partialArgs) ?? ""
        let lines = body.components(separatedBy: "\n").map { Line(kind: .added, text: $0) }
        return FileDiff(
            path: path,
            language: language(forPath: path),
            lines: lines,
            addedCount: lines.count,
            removedCount: 0,
            isPreview: false,
            truncated: false,
            rawDiff: body,
            isStreamingPreview: true
        )
    }

    /// Returns the decoded prefix of the JSON string value for `key` inside a
    /// possibly-truncated JSON object text. Tolerates the value (or a trailing
    /// escape sequence) being cut off mid-stream; a truncated escape is dropped
    /// rather than decoded wrong. Returns nil when the key's value hasn't
    /// started streaming or isn't a string.
    private static func partialJSONStringValue(forKey key: String, in text: String) -> String? {
        let needle = "\"\(key)\""
        var searchStart = text.startIndex
        while let keyRange = text.range(of: needle, range: searchStart ..< text.endIndex) {
            searchStart = keyRange.upperBound
            if let value = stringValue(startingAfter: keyRange.upperBound, in: text) {
                return value
            }
        }
        return nil
    }

    /// Decodes a string value expected after `"key"` at `start`: skips
    /// whitespace and the colon, then unescapes until the closing quote or the
    /// end of the (truncated) input. Returns nil if what follows isn't `: "`.
    private static func stringValue(startingAfter start: String.Index, in text: String) -> String? {
        var i = start
        var sawColon = false
        scan: while i < text.endIndex {
            switch text[i] {
            case ":" where !sawColon:
                sawColon = true
            case "\"" where sawColon:
                i = text.index(after: i)
                break scan
            case let c where c.isWhitespace:
                break
            default:
                return nil
            }
            i = text.index(after: i)
        }
        guard sawColon else { return nil }

        var out = ""
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" { break }
            if c == "\\" {
                let escIndex = text.index(after: i)
                guard escIndex < text.endIndex else { break }
                switch text[escIndex] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "u":
                    let hexStart = text.index(after: escIndex)
                    guard let hexEnd = text.index(hexStart, offsetBy: 4, limitedBy: text.endIndex),
                        let value = UInt32(text[hexStart ..< hexEnd], radix: 16),
                        let scalar = Unicode.Scalar(value)
                    else { return out }
                    out.unicodeScalars.append(scalar)
                    i = hexEnd
                    continue
                case let e: out.append(e)
                }
                i = text.index(after: escIndex)
                continue
            }
            out.append(c)
            i = text.index(after: i)
        }
        return out
    }

    /// Maps a file extension to a highlight.js language id. Returns nil when
    /// unknown so callers fall back to plain monospaced rendering.
    static func language(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return extensionToLanguage[ext]
    }

    private static let extensionToLanguage: [String: String] = [
        "swift": "swift",
        "ts": "typescript", "tsx": "typescript",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "py": "python",
        "rb": "ruby",
        "go": "go",
        "rs": "rust",
        "java": "java",
        "kt": "kotlin", "kts": "kotlin",
        "c": "c", "h": "c",
        "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
        "m": "objectivec", "mm": "objectivec",
        "cs": "csharp",
        "php": "php",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "json": "json",
        "yml": "yaml", "yaml": "yaml",
        "toml": "toml",
        "xml": "xml", "html": "xml", "htm": "xml",
        "css": "css", "scss": "scss", "less": "less",
        "sql": "sql",
        "md": "markdown", "markdown": "markdown",
        "dockerfile": "dockerfile",
        "gradle": "gradle",
    ]
}
