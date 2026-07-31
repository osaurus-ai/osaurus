//
//  WorkspaceWriteSafety.swift
//  osaurus
//
//  Shared guardrails for host-folder write tools.
//

import CryptoKit
import Foundation

/// Shared source-vs-document routing for workspace tools.
///
/// UTF-8 text is source, even when the extension also names a renderable
/// format (HTML, RTF, SVG). Binary document packages take the parser path and
/// cannot be fabricated by the UTF-8 text writer.
enum WorkspaceFileFormatPolicy {
    static let parserPreferredExtensions: Set<String> = [
        "pdf",
        "doc", "docx", "docm", "dot", "dotx", "dotm", "rtfd",
        "xls", "xlsx", "xlsm", "xlsb", "xlt", "xltx", "xltm",
        "ppt", "pptx", "pptm", "pot", "potx", "potm", "pps", "ppsx", "ppsm",
        "pages", "numbers", "key",
        "odt", "ods", "odp",
    ]

    /// Files whose successful persistence is not evidence that the delivered
    /// program or interactive artifact actually runs.
    static let runnableArtifactExtensions: Set<String> = [
        "html", "htm",
        "js", "mjs", "cjs", "jsx",
        "ts", "tsx",
        "py", "rb", "php",
        "sh", "bash", "zsh",
        "swift", "c", "cc", "cpp", "cxx", "h", "hpp",
        "java", "kt", "kts", "go", "rs",
    ]

    static func prefersDocumentExtraction(_ ext: String) -> Bool {
        parserPreferredExtensions.contains(ext.lowercased())
    }

    static func isRunnableArtifact(path: String) -> Bool {
        runnableArtifactExtensions.contains(
            URL(fileURLWithPath: path).pathExtension.lowercased()
        )
    }
}

/// Shared preview, diff, and output-safety helpers for host workspace writes.
///
/// The folder write tools stay small and consistent by routing their
/// extension refusals, risk warnings, and preview payloads through this type.
enum WorkspaceWriteSafety {
    struct Preview {
        var payload: [String: Any]
        let warnings: [String]
        let text: String
    }

    enum ExistingTextResult {
        case success(String?)
        case failureEnvelope(String)
    }

    private struct StructuredTarget {
        let label: String
        let pivot: String
    }

    private static let maxDiffLines = 80
    private static let maxDiffCharacters = 12_000
    private static let maxDiffMatrixCells = 200_000
    private static let largeWriteCharacters = 1_000_000

    private static let structuredTargets: [String: StructuredTarget] = [
        "xlsx": StructuredTarget(
            label: "structured workbook package",
            pivot: "Use a spreadsheet/XLSX tool for workbook output, or write CSV/TSV text instead."
        ),
        "xlsm": StructuredTarget(
            label: "structured workbook package",
            pivot: "Use a spreadsheet/XLSX tool for workbook output, or write CSV/TSV text instead."
        ),
        "xltx": StructuredTarget(
            label: "structured workbook package",
            pivot: "Use a spreadsheet/XLSX tool for workbook output, or write CSV/TSV text instead."
        ),
        "xltm": StructuredTarget(
            label: "structured workbook package",
            pivot: "Use a spreadsheet/XLSX tool for workbook output, or write CSV/TSV text instead."
        ),
        "xlsb": StructuredTarget(
            label: "structured workbook package",
            pivot: "Use a spreadsheet/XLSX tool for workbook output, or write CSV/TSV text instead."
        ),
        "xls": StructuredTarget(
            label: "structured workbook package",
            pivot: "Use a spreadsheet/XLSX tool for workbook output, or write CSV/TSV text instead."
        ),
        "xlt": StructuredTarget(
            label: "legacy binary workbook template",
            pivot: "Use a spreadsheet creation path that emits a real workbook template, or write CSV/TSV text instead."
        ),
        "docx": StructuredTarget(
            label: "structured Word document package",
            pivot: "Use a document creation path that emits a real DOCX package, or write Markdown/HTML text instead."
        ),
        "docm": StructuredTarget(
            label: "structured Word document package",
            pivot: "Use a document creation path that emits a real DOCM package, or write Markdown/HTML text instead."
        ),
        "doc": StructuredTarget(
            label: "legacy binary Word document",
            pivot: "Use a document creation path that emits a real Word document, or write Markdown/HTML text instead."
        ),
        "dot": StructuredTarget(
            label: "legacy binary Word template",
            pivot: "Use a document creation path that emits a real Word template, or write Markdown/HTML text instead."
        ),
        "dotx": StructuredTarget(
            label: "structured Word template package",
            pivot: "Use a document creation path that emits a real DOTX package, or write Markdown/HTML text instead."
        ),
        "dotm": StructuredTarget(
            label: "structured Word template package",
            pivot: "Use a document creation path that emits a real DOTM package, or write Markdown/HTML text instead."
        ),
        "rtfd": StructuredTarget(
            label: "rich-text document package",
            pivot: "Use a rich-document creation path that emits a real RTFD package, or write RTF/Markdown/HTML text instead."
        ),
        "pdf": StructuredTarget(
            label: "PDF document",
            pivot: "Use a PDF/document creation path that emits a real PDF package."
        ),
        "pptx": StructuredTarget(
            label: "presentation package",
            pivot: "Use a presentation/PPTX creation path that emits a real OpenXML presentation."
        ),
        "pptm": StructuredTarget(
            label: "presentation package",
            pivot: "Use a presentation/PPTX creation path that emits a real OpenXML presentation."
        ),
        "potx": StructuredTarget(
            label: "presentation template package",
            pivot: "Use a presentation/PPTX creation path that emits a real OpenXML presentation."
        ),
        "potm": StructuredTarget(
            label: "presentation template package",
            pivot: "Use a presentation/PPTX creation path that emits a real OpenXML presentation."
        ),
        "ppsx": StructuredTarget(
            label: "presentation slideshow package",
            pivot: "Use a presentation/PPTX creation path that emits a real OpenXML presentation."
        ),
        "ppsm": StructuredTarget(
            label: "presentation slideshow package",
            pivot: "Use a presentation/PPTX creation path that emits a real OpenXML presentation."
        ),
        "ppt": StructuredTarget(
            label: "presentation document",
            pivot: "Use a presentation/PPTX creation path instead of writing plain text to a presentation extension."
        ),
        "pot": StructuredTarget(
            label: "legacy binary presentation template",
            pivot: "Use a presentation creation path that emits a real template package."
        ),
        "pps": StructuredTarget(
            label: "legacy binary presentation slideshow",
            pivot: "Use a presentation creation path that emits a real slideshow package."
        ),
        "pages": StructuredTarget(
            label: "Apple Pages document package",
            pivot: "Use a document creation path that emits a real Pages package, or write Markdown/HTML text instead."
        ),
        "numbers": StructuredTarget(
            label: "Apple Numbers document package",
            pivot: "Use a spreadsheet creation path that emits a real Numbers package, or write CSV/TSV text instead."
        ),
        "key": StructuredTarget(
            label: "Apple Keynote document package",
            pivot: "Use a presentation creation path that emits a real Keynote package."
        ),
        "odt": StructuredTarget(
            label: "OpenDocument text package",
            pivot: "Use a document creation path that emits a real ODT package, or write Markdown/HTML text instead."
        ),
        "ods": StructuredTarget(
            label: "OpenDocument spreadsheet package",
            pivot: "Use a spreadsheet creation path that emits a real ODS package, or write CSV/TSV text instead."
        ),
        "odp": StructuredTarget(
            label: "OpenDocument presentation package",
            pivot: "Use a presentation creation path that emits a real ODP package."
        ),
    ]

    static func structuredTextWriteRejection(
        path: String,
        fileExtension ext: String,
        toolName: String
    ) -> String? {
        guard let target = structuredTargets[ext] else { return nil }
        return ToolEnvelope.failure(
            kind: .rejected,
            message:
                "Refused to write '\(path)' with \(toolName): .\(ext) is a \(target.label), "
                + "but \(toolName) only writes UTF-8 text. \(target.pivot)",
            field: "path",
            expected: "path for a UTF-8 text file; for .\(ext), use a structured document writer",
            tool: toolName,
            retryable: false,
            metadata: ["extension": ext]
        )
    }

    static func existingText(
        at fileURL: URL,
        relativePath: String,
        toolName: String
    ) -> ExistingTextResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .success(nil)
        }
        do {
            return .success(try String(contentsOf: fileURL, encoding: .utf8))
        } catch {
            return .failureEnvelope(
                ToolEnvelope.failure(
                    kind: .rejected,
                    message:
                        "Refused to modify '\(relativePath)' with \(toolName): the existing file is not valid UTF-8 text, so a text write could destroy binary or structured content.",
                    field: "path",
                    expected: "existing UTF-8 text file, or choose a structured/binary-safe writer",
                    tool: toolName,
                    retryable: false
                )
            )
        }
    }

    static func preview(
        path: String,
        previousContent: String?,
        proposedContent: String,
        operation: String,
        dryRun: Bool,
        overwritesExistingFile: Bool,
        createsParentDirectories: Bool,
        fileURL: URL
    ) -> Preview {
        let existed = previousContent != nil
        let action = existed ? "update" : "create"
        let diff = unifiedDiff(
            old: previousContent ?? "",
            new: proposedContent,
            path: path,
            oldLabel: existed ? "before" : "before (new file)",
            newLabel: dryRun ? "after (preview)" : "after"
        )
        let warnings = riskWarnings(
            path: path,
            fileURL: fileURL,
            existed: existed,
            overwritesExistingFile: overwritesExistingFile,
            createsParentDirectories: createsParentDirectories,
            proposedContent: proposedContent
        )
        let lineCount = proposedContent.components(separatedBy: .newlines).count
        let resultKind = dryRun ? "workspace_write_preview" : "workspace_write_result"
        let riskLevel = warnings.isEmpty ? "low" : "needs_review"
        var payload: [String: Any] = [
            "kind": resultKind,
            "path": path,
            "operation": operation,
            "action": action,
            "dry_run": dryRun,
            "would_write": dryRun,
            "applied": !dryRun,
            "line_count": lineCount,
            "character_count": proposedContent.count,
            "creates_parent_directories": createsParentDirectories,
            "risk_level": riskLevel,
            "diff": diff.text,
            "diff_truncated": diff.truncated,
            "content_sha256": contentSHA256(proposedContent),
        ]
        if let previousContent {
            payload["before_content_sha256"] = contentSHA256(previousContent)
        }
        annotateMutationResult(
            &payload,
            path: path,
            dryRun: dryRun,
            diffTruncated: diff.truncated
        )
        let text =
            dryRun
            ? "Dry run for \(operation) \(path): \(action), \(lineCount) lines, \(proposedContent.count) characters.\n\(diff.text)"
            : "\(action == "create" ? "Created" : "Updated") \(path) (\(lineCount) lines, \(proposedContent.count) characters)"
        payload["text"] = text
        return Preview(payload: payload, warnings: warnings, text: text)
    }

    /// Make the result semantics explicit for small models: a capped review
    /// diff never means the write was partial, and saving runnable code never
    /// proves that it executes correctly.
    static func annotateMutationResult(
        _ payload: inout [String: Any],
        path: String,
        dryRun: Bool,
        diffTruncated: Bool
    ) {
        payload["content_write_complete"] = !dryRun
        if diffTruncated {
            payload["diff_truncation_note"] =
                dryRun
                ? "Only the review diff preview is truncated; the proposed content is complete."
                : "Only the review diff preview is truncated; the full content was applied."
        }
        if !dryRun, WorkspaceFileFormatPolicy.isRunnableArtifact(path: path) {
            payload["verification"] = [
                "status": "not_run",
                "reason": "A successful file mutation proves persistence, not runtime correctness.",
                "next_action":
                    "Run an available syntax, build, test, or behavior check before claiming the artifact works.",
            ]
        }
    }

    static func contentSHA256(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Capped unified-diff text for callers that only need the diff (e.g. the
    /// sandbox write tool, which writes in-container and just wants a reviewable
    /// diff to surface). Same labels / truncation behavior as `preview` so the
    /// chat diff-card parser treats both sources identically.
    static func unifiedDiffText(
        old: String,
        new: String,
        path: String,
        existed: Bool
    ) -> (text: String, truncated: Bool) {
        unifiedDiff(
            old: old,
            new: new,
            path: path,
            oldLabel: existed ? "before" : "before (new file)",
            newLabel: "after"
        )
    }

    static func operationHistoryEntry(_ operation: FileOperation) -> [String: Any] {
        var entry: [String: Any] = [
            "id": operation.id.uuidString,
            "type": operation.type.rawValue,
            "display_name": operation.type.displayName,
            "path": operation.path,
            "timestamp": ISO8601DateFormatter().string(from: operation.timestamp),
            "can_undo": operation.canUndo,
        ]
        if let destinationPath = operation.destinationPath {
            entry["destination_path"] = destinationPath
        }
        if let batchId = operation.batchId {
            entry["batch_id"] = batchId.uuidString
        }
        return entry
    }

    private static func riskWarnings(
        path: String,
        fileURL: URL,
        existed: Bool,
        overwritesExistingFile: Bool,
        createsParentDirectories: Bool,
        proposedContent: String
    ) -> [String] {
        var warnings: [String] = []
        if existed, overwritesExistingFile {
            warnings.append(
                "This will overwrite an existing file; use dry_run first when replacing more than a small edit."
            )
        }
        if createsParentDirectories {
            warnings.append("Parent directories do not exist and will be created.")
        }
        if proposedContent.count > largeWriteCharacters {
            warnings.append("Large text write over 1 MB; confirm this is intentional before applying.")
        }
        if pathComponents(path).contains(where: { $0.hasPrefix(".") }) {
            warnings.append("This targets a hidden or configuration path.")
        }
        if FolderToolHelpers.isSecretPath(fileURL: fileURL) {
            warnings.append(
                "This path looks like secret or credential material; avoid writing real secrets unless the user explicitly requested it."
            )
        }
        return warnings
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private static func unifiedDiff(
        old: String,
        new: String,
        path: String,
        oldLabel: String,
        newLabel: String
    ) -> (text: String, truncated: Bool) {
        // An empty side has zero lines, not one empty line. `"".components(
        // separatedBy:)` returns `[""]`, which would make creating a new file
        // (empty `old`) diff as a phantom removal of one empty line — the card
        // then shows `+1 −1` for a brand-new one-line file instead of `+1 −0`.
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: .newlines)
        let newLines = new.isEmpty ? [] : new.components(separatedBy: .newlines)
        var lines: [String] = [
            "--- \(path) (\(oldLabel))",
            "+++ \(path) (\(newLabel))",
        ]

        if oldLines == newLines {
            lines.append(" no text changes")
            return (lines.joined(separator: "\n"), false)
        }

        let matrixCells = oldLines.count * newLines.count
        if matrixCells > maxDiffMatrixCells {
            return boundedPrefixDiff(
                oldLines: oldLines,
                newLines: newLines,
                path: path,
                oldLabel: oldLabel,
                newLabel: newLabel
            )
        }

        let table = lcsTable(oldLines, newLines)
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count,
                newIndex < newLines.count,
                oldLines[oldIndex] == newLines[newIndex]
            {
                lines.append(" \(oldLines[oldIndex])")
                oldIndex += 1
                newIndex += 1
            } else if newIndex < newLines.count,
                oldIndex == oldLines.count || table[oldIndex][newIndex + 1] >= table[oldIndex + 1][newIndex]
            {
                lines.append("+\(newLines[newIndex])")
                newIndex += 1
            } else if oldIndex < oldLines.count {
                lines.append("-\(oldLines[oldIndex])")
                oldIndex += 1
            }
            if lines.count >= maxDiffLines {
                let joined = lines.joined(separator: "\n")
                return (truncate(joined) + "\n... (diff truncated)", true)
            }
        }

        let joined = lines.joined(separator: "\n")
        let truncated = joined.count > maxDiffCharacters
        return (truncate(joined), truncated)
    }

    private static func boundedPrefixDiff(
        oldLines: [String],
        newLines: [String],
        path: String,
        oldLabel: String,
        newLabel: String
    ) -> (text: String, truncated: Bool) {
        var lines = [
            "--- \(path) (\(oldLabel))",
            "+++ \(path) (\(newLabel))",
            "... large diff preview uses bounded prefixes",
        ]
        for line in oldLines.prefix(maxDiffLines / 2) {
            lines.append("-\(line)")
        }
        for line in newLines.prefix(maxDiffLines / 2) {
            lines.append("+\(line)")
        }
        return (truncate(lines.joined(separator: "\n")) + "\n... (diff truncated)", true)
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maxDiffCharacters else { return text }
        return String(text.prefix(maxDiffCharacters)) + "\n... (diff truncated)"
    }

    private static func lcsTable(_ oldLines: [String], _ newLines: [String]) -> [[Int]] {
        var table = Array(
            repeating: Array(repeating: 0, count: newLines.count + 1),
            count: oldLines.count + 1
        )
        if oldLines.isEmpty || newLines.isEmpty { return table }
        for oldIndex in stride(from: oldLines.count - 1, through: 0, by: -1) {
            for newIndex in stride(from: newLines.count - 1, through: 0, by: -1) {
                if oldLines[oldIndex] == newLines[newIndex] {
                    table[oldIndex][newIndex] = table[oldIndex + 1][newIndex + 1] + 1
                } else {
                    table[oldIndex][newIndex] = max(
                        table[oldIndex + 1][newIndex],
                        table[oldIndex][newIndex + 1]
                    )
                }
            }
        }
        return table
    }
}
