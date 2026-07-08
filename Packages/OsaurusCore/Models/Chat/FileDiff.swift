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
    /// `isStreaming: false` builds the same card as a settled, never-applied
    /// preview (badge "preview" instead of "…") — used when a write FAILS so
    /// the content the user watched stream doesn't vanish with the error.
    static func streamingPreview(
        toolName: String,
        partialArgs: String,
        isStreaming: Bool = true
    ) -> FileDiff? {
        guard diffProducingToolNames.contains(toolName) else { return nil }
        guard
            let body = partialStringField("content", in: partialArgs)
                ?? partialStringField("new_string", in: partialArgs),
            !body.isEmpty
        else { return nil }

        // Models sometimes emit an alias key for the path (`filename`,
        // `file_path`, …); the executed call is rescued by
        // `SchemaValidator.normalizeKeySpelling`, so the live preview must
        // accept the same spellings or the header shows no name.
        let pathKeys = ["path", "filename", "file_name", "filepath", "file_path"]
        let path = pathKeys.lazy.compactMap { partialStringField($0, in: partialArgs) }
            .first(where: { !$0.isEmpty }) ?? ""
        let lines = body.components(separatedBy: "\n").map { Line(kind: .added, text: $0) }
        return FileDiff(
            path: path,
            language: language(forPath: path),
            lines: lines,
            addedCount: lines.count,
            removedCount: 0,
            isPreview: !isStreaming,
            truncated: false,
            rawDiff: body,
            isStreamingPreview: isStreaming
        )
    }

    /// Best-effort tool name from a partial (still-streaming) tool-call
    /// envelope. Local models stream the raw envelope before any parsed
    /// call exists — the `"name"` field usually completes within the first
    /// few fragments, letting the UI show the pending chip / diff preview
    /// long before the call finishes.
    /// Tool-name extraction across every envelope syntax the runtime streams.
    /// Each strategy anchors on protocol markup so a name is only reported
    /// once it has fully streamed (a half-streamed name would stick as the
    /// pending tool name and never be re-derived).
    static func partialToolName(inArgs args: String) -> String? {
        // JSON: {"name": "tool_name", ...}
        if let name = partialJSONStringValue(forKey: "name", in: args), !name.isEmpty {
            return name
        }
        // XML function (Qwen3-coder / Zyphra / Step): <function=tool_name>
        if let name = delimitedValue(in: args, after: "<function=", terminator: ">") {
            return name
        }
        // MiniMax M2: <invoke name="tool_name">
        if let name = delimitedValue(in: args, after: "<invoke name=\"", terminator: "\"") {
            return name
        }
        // Kimi K2: functions.tool_name:0<|tool_call_argument_begin|>{...}
        if let r = args.range(of: "functions.") {
            let after = args[r.upperBound...]
            let name = after.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
            if !name.isEmpty, after.dropFirst(name.count).first == ":" {
                return String(name)
            }
        }
        // Gemma function envelope: call:tool_name{...
        if let r = args.range(of: "call:") {
            let after = args[r.upperBound...]
            let name = after.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
            if !name.isEmpty, after.dropFirst(name.count).first == "{" {
                return String(name)
            }
        }
        // Hunyuan: <tool_call>tool_name<tool_sep>  /  GLM4: tool_name<arg_key>
        for terminator in ["<tool_sep>", "<arg_key>"] {
            if let r = args.range(of: terminator) {
                let head = args[..<r.lowerBound]
                var start = head.endIndex
                while start > head.startIndex {
                    let prev = head.index(before: start)
                    let c = head[prev]
                    guard c.isLetter || c.isNumber || c == "_" else { break }
                    start = prev
                }
                if start < head.endIndex { return String(head[start...]) }
            }
        }
        // Pythonic (LFM2 / Llama3 native): [tool_name(key="value")] — the
        // identifier must open the buffer (after optional '[' / tag noise)
        // and its '(' must have streamed.
        var head = Substring(args.drop(while: { $0.isWhitespace }))
        if head.first == "[" { head = head.dropFirst() }
        let ident = head.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
        if !ident.isEmpty, head.dropFirst(ident.count).first == "(" {
            return String(ident)
        }
        return nil
    }

    /// Extracts the (possibly still-streaming) string value for `key` from a
    /// partial tool-call payload, across the envelope syntaxes the runtime
    /// streams. Ordered from the most explicitly-marked syntax down, so a
    /// format's own key markup always wins over a looser textual match.
    private static func partialStringField(_ key: String, in text: String) -> String? {
        // JSON: "key": "escaped value"
        if let v = partialJSONStringValue(forKey: key, in: text) { return v }
        // Gemma function envelope: key:<|"|>raw value<|"|>
        if let v = partialDelimitedRawValue(
            in: text, opener: key + ":", valueStart: gemmaStringMarker, closer: gemmaStringMarker
        ) { return v }
        // XML function: <parameter=key>raw value</parameter>
        if let v = partialDelimitedRawValue(
            in: text, opener: "<parameter=\(key)>", valueStart: "", closer: "</parameter>"
        ) { return v }
        // MiniMax: <parameter name="key">raw value</parameter>
        if let v = partialDelimitedRawValue(
            in: text, opener: "<parameter name=\"\(key)\">", valueStart: "", closer: "</parameter>"
        ) { return v }
        // GLM4 / Hunyuan: <arg_key>key</arg_key><arg_value>raw value</arg_value>
        if let v = partialDelimitedRawValue(
            in: text, opener: "<arg_key>\(key)</arg_key>", valueStart: "<arg_value>",
            closer: "</arg_value>"
        ) { return v }
        // Pythonic kwarg: key="python string" or key='python string'
        if let v = partialPythonStringValue(forKey: key, in: text) { return v }
        return nil
    }

    /// Gemma-4 escape marker wrapping string values in its function envelope.
    private static let gemmaStringMarker = "<|\"|>"

    /// Complete (non-partial) value between a marker and a terminator, e.g.
    /// the name in `<function=NAME>`. Returns nil until the terminator has
    /// streamed or when the value isn't a plain identifier-ish token.
    private static func delimitedValue(
        in text: String, after opener: String, terminator: String
    ) -> String? {
        guard let r = text.range(of: opener),
            let end = text.range(of: terminator, range: r.upperBound ..< text.endIndex)
        else { return nil }
        let value = String(text[r.upperBound ..< end.lowerBound])
        guard !value.isEmpty, value.count < 200, !value.contains("\n") else { return nil }
        return value
    }

    /// Raw-text value extraction for marker-delimited syntaxes: finds
    /// `opener`, optionally skips whitespace, requires `valueStart`, then
    /// returns everything up to `closer` — or, mid-stream, everything to the
    /// end of the buffer with any trailing partial `closer` prefix trimmed so
    /// it never flashes in the preview. Values are raw text (real newlines).
    private static func partialDelimitedRawValue(
        in text: String, opener: String, valueStart: String, closer: String
    ) -> String? {
        var searchStart = text.startIndex
        while let openerRange = text.range(of: opener, range: searchStart ..< text.endIndex) {
            searchStart = openerRange.upperBound
            var i = openerRange.upperBound
            while i < text.endIndex, text[i] == " " || text[i] == "\n" {
                i = text.index(after: i)
            }
            let valueBegin: String.Index
            if valueStart.isEmpty {
                valueBegin = i
            } else {
                guard text[i...].hasPrefix(valueStart) else { continue }
                valueBegin = text.index(i, offsetBy: valueStart.count)
            }
            let rest = text[valueBegin...]
            if let end = rest.range(of: closer) {
                return String(rest[..<end.lowerBound])
            }
            var value = String(rest)
            for length in stride(from: closer.count - 1, through: 1, by: -1) {
                if value.hasSuffix(String(closer.prefix(length))) {
                    value.removeLast(length)
                    break
                }
            }
            return value
        }
        return nil
    }

    /// Pythonic kwarg extraction: `key="value"` / `key='value'` with Python
    /// escape decoding, tolerating a truncated value or trailing escape. The
    /// match must sit in kwarg position (preceded by `(` or `,`) so code text
    /// that merely mentions `key=` inside another value doesn't match.
    private static func partialPythonStringValue(forKey key: String, in text: String) -> String? {
        var searchStart = text.startIndex
        while let keyRange = text.range(of: key + "=", range: searchStart ..< text.endIndex) {
            searchStart = keyRange.upperBound
            // kwarg position check: previous non-space char is '(' or ','
            var p = keyRange.lowerBound
            var precededOK = false
            while p > text.startIndex {
                p = text.index(before: p)
                let c = text[p]
                if c == " " || c == "\n" { continue }
                precededOK = c == "(" || c == ","
                break
            }
            guard precededOK else { continue }
            var i = keyRange.upperBound
            while i < text.endIndex, text[i] == " " { i = text.index(after: i) }
            guard i < text.endIndex, text[i] == "\"" || text[i] == "'" else { continue }
            let quote = text[i]
            i = text.index(after: i)
            var out = ""
            while i < text.endIndex {
                let c = text[i]
                if c == quote { return out }
                if c == "\\" {
                    let escIndex = text.index(after: i)
                    guard escIndex < text.endIndex else { return out }
                    switch text[escIndex] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
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
        return nil
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
