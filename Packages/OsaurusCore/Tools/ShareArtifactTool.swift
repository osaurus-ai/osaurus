//
//  ShareArtifactTool.swift
//  osaurus
//
//  Global built-in for surfacing files / inline content to the chat thread.
//  This is the only sanctioned path that creates an artifact card —
//  `file_write` / `sandbox_write_file` writes never appear in chat.
//
//  Result shape: `ToolEnvelope.success` whose `result.text` carries the
//  legacy marker-delimited blob (`---SHARED_ARTIFACT_START` / `END`)
//  that `SharedArtifact.processToolResult` parses downstream. Migrating
//  the payload itself off markers is tracked separately.
//

import Foundation

/// Unified tool for sharing files or inline content with the user.
public struct ShareArtifactTool: OsaurusTool {
    public let name = "share_artifact"
    public let description =
        "Share a deliverable with the user as a clickable artifact card — pass `path` to an EXISTING "
        + "file, or `content` + `filename` for inline text, this is the only path that surfaces "
        + "files in the chat thread. Files written to disk or the sandbox are NOT shown in chat "
        + "without this call, and this tool does NOT create files. Use for generated images, charts, "
        + "websites, reports, and code blobs. If unsure where you wrote a file, find it first "
        + "(`sandbox_search_files` / `file_search` with `target=\"files\"`)."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Path to an EXISTING file or directory: relative to the sandbox agent home "
                        + "(e.g. `output/chart.svg`) or `/workspace/...` absolute in sandbox mode; relative "
                        + "to the working folder in folder mode."
                ),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string(
                    "Inline text/markdown to share without writing a file first. Omit entirely when "
                        + "using `path` — do NOT pass an empty string."
                ),
            ]),
            "filename": .object([
                "type": .string("string"),
                "description": .string(
                    "Filename for the artifact. Required with `content`; optional with `path` (defaults "
                        + "to the basename). Omit when unused — do NOT pass an empty string."
                ),
            ]),
            "description": .object([
                "type": .string("string"),
                "description": .string("Brief human-readable description of what this artifact is."),
            ]),
        ]),
        // The "path OR content(+filename)" contract is enforced in
        // `execute()` rather than via a top-level schema combinator.
        // OpenAI and Anthropic reject `anyOf`/`oneOf`/`allOf`/`enum`/`not`
        // at the root of a tool's parameters (issue #1560), so the schema
        // root stays a plain object and a bare `{}` (or empty path/content)
        // surfaces a clear `invalidArgs` envelope from the body instead.
        "required": .array([]),
    ])

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let json) = argsReq else { return argsReq.failureEnvelope ?? "" }

        // Empty-string filler bug: many models pass `content: ""` and
        // `filename: ""` as placeholders for unused optional fields when
        // they only mean to share a path. Treat empty / whitespace-only
        // strings as absent so the path-mode validator doesn't trip.
        func nonEmpty(_ value: Any?) -> String? {
            guard let s = value as? String else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : s
        }

        let path = nonEmpty(json["path"])
        let providedContent = nonEmpty(json["content"])
        let filename = nonEmpty(json["filename"])
        let description = nonEmpty(json["description"])

        guard path != nil || providedContent != nil else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "At least one of `path` or `content` must be provided (and non-empty). "
                    + "Pass `path` to share an existing file, or `content` + `filename` for inline text.",
                tool: name
            )
        }

        // Path mode wins when both are supplied: models often mirror the file
        // path into `content` alongside a real `path`. Honoring that content
        // would write the literal string as the artifact body and ship a broken
        // file, so drop `content` whenever `path` is present.
        let rawContent = path == nil ? providedContent : nil

        if rawContent != nil {
            guard filename != nil else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`filename` is required when using `content` mode.",
                    field: "filename",
                    expected: "non-empty filename string",
                    tool: name
                )
            }
        }

        // Reject content containing either marker token — there's no
        // escape mechanism, so an embedded marker would silently truncate
        // the artifact at parse time. Match the bare token (no surrounding
        // newline) so adversarial inputs like `---SHARED_ARTIFACT_START---X`
        // are still caught.
        let startToken = "---SHARED_ARTIFACT_START---"
        let endToken = "---SHARED_ARTIFACT_END---"
        if let rawContent,
            rawContent.contains(startToken) || rawContent.contains(endToken)
        {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`content` contains a reserved artifact marker "
                    + "(`\(startToken)` or `\(endToken)`) which would corrupt parsing. "
                    + "Strip the marker or share the content as a file.",
                field: "content",
                expected: "string without artifact marker substrings",
                tool: name
            )
        }

        let content = rawContent?
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")

        let resolvedFilename: String
        if let filename, !filename.isEmpty {
            resolvedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let path {
            resolvedFilename = (path as NSString).lastPathComponent
        } else {
            resolvedFilename = "artifact.txt"
        }

        let mimeType = SharedArtifact.mimeType(from: resolvedFilename)

        var metadataDict: [String: Any] = [
            "filename": resolvedFilename,
            "mime_type": mimeType,
        ]
        if let path { metadataDict["path"] = path }
        if content != nil { metadataDict["has_content"] = true }
        if let description { metadataDict["description"] = description }

        let metadataJSON: String
        if let jsonData = try? JSONSerialization.data(withJSONObject: metadataDict, options: .osaurusCanonical),
            let jsonStr = String(data: jsonData, encoding: .utf8)
        {
            metadataJSON = jsonStr
        } else {
            metadataJSON = "{}"
        }

        var marker = """
            Artifact shared:
            - Filename: \(resolvedFilename)
            - Type: \(mimeType)
            """
        if let description {
            marker += "\n- Description: \(description)"
        }

        marker += "\n\n\(SharedArtifact.startMarker)"
        marker += metadataJSON + "\n"
        if let content {
            marker += content + "\n"
        }
        marker += SharedArtifact.endMarker

        // The marker substring is parsed by `SharedArtifact.processToolResult`
        // post-execute, so we ride it in the envelope's `text` field.
        // `ChatView.processShareArtifactResult` rewrites the result into a
        // failure envelope if path-mode resolve/copy then fails.
        return ToolEnvelope.success(tool: name, text: marker)
    }
}
