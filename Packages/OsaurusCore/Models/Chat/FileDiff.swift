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
