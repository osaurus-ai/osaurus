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
    /// Coarse document family, used for model-facing labels and for the
    /// per-family pivot hints in envelopes.
    enum DocumentFamily: String, Sendable, Equatable {
        case pdf
        case word
        case presentation
        case spreadsheet
        case appleIWork
        case openDocument

        var label: String {
            switch self {
            case .pdf: return "PDF document"
            case .word: return "Word document"
            case .presentation: return "presentation"
            case .spreadsheet: return "spreadsheet"
            case .appleIWork: return "Apple iWork document"
            case .openDocument: return "OpenDocument file"
            }
        }

        /// Format the built-in extractor DOES handle for this family, so an
        /// unsupported-variant message can name the concrete conversion target.
        var supportedAlternative: String? {
            switch self {
            case .pdf: return nil
            case .word: return ".docx"
            case .presentation: return ".pptx"
            case .spreadsheet: return ".xlsx"
            case .appleIWork: return ".docx / .xlsx / .pdf (File > Export in Pages, Numbers, Keynote)"
            case .openDocument: return ".docx / .xlsx / .pdf"
            }
        }
    }

    /// What `file_read` can do with a file, decided by extension. Raw UTF-8
    /// decoding still wins at runtime for anything not listed here (an
    /// unknown extension is `.rawText` until the byte sniff says otherwise).
    enum ReadSupport: Equatable, Sendable {
        /// Plain UTF-8 read with `N|` line numbers (source, Markdown, CSV, HTML, RTF, SVG, ...).
        case rawText
        /// A registered document adapter extracts the text layer.
        case extractedText(family: DocumentFamily)
        /// `XLSXAdapter` parses it into a bounded, sheet-aware preview.
        case workbook
        /// Pixel image: shown to vision models, OCR'd for text-only models.
        case image
        /// A recognised document family with no built-in adapter. Never
        /// "text only": the message names the supported sibling format.
        case unsupportedDocument(family: DocumentFamily)

        var isDocument: Bool {
            switch self {
            case .extractedText, .workbook, .unsupportedDocument: return true
            case .rawText, .image: return false
            }
        }

        var family: DocumentFamily? {
            switch self {
            case .extractedText(let family), .unsupportedDocument(let family): return family
            case .workbook: return .spreadsheet
            case .rawText, .image: return nil
            }
        }
    }

    /// Single source of truth for extension → read behaviour. Keep in sync
    /// with the adapters registered in `DocumentAdaptersBootstrap`.
    static let readSupportByExtension: [String: ReadSupport] = [
        // Built-in extraction (PDFAdapter / RichDocumentAdapter / PPTXAdapter).
        "pdf": .extractedText(family: .pdf),
        "docx": .extractedText(family: .word),
        "doc": .extractedText(family: .word),
        "rtfd": .extractedText(family: .word),
        "pptx": .extractedText(family: .presentation),
        "potx": .extractedText(family: .presentation),
        // Workbook preview (XLSXAdapter).
        "xlsx": .workbook,
        // Recognised document families without a built-in adapter.
        "docm": .unsupportedDocument(family: .word),
        "dot": .unsupportedDocument(family: .word),
        "dotx": .unsupportedDocument(family: .word),
        "dotm": .unsupportedDocument(family: .word),
        "xls": .unsupportedDocument(family: .spreadsheet),
        "xlsm": .unsupportedDocument(family: .spreadsheet),
        "xlsb": .unsupportedDocument(family: .spreadsheet),
        "xlt": .unsupportedDocument(family: .spreadsheet),
        "xltx": .unsupportedDocument(family: .spreadsheet),
        "xltm": .unsupportedDocument(family: .spreadsheet),
        "ppt": .unsupportedDocument(family: .presentation),
        "pptm": .unsupportedDocument(family: .presentation),
        "pot": .unsupportedDocument(family: .presentation),
        "potm": .unsupportedDocument(family: .presentation),
        "pps": .unsupportedDocument(family: .presentation),
        "ppsx": .unsupportedDocument(family: .presentation),
        "ppsm": .unsupportedDocument(family: .presentation),
        "pages": .unsupportedDocument(family: .appleIWork),
        "numbers": .unsupportedDocument(family: .appleIWork),
        "key": .unsupportedDocument(family: .appleIWork),
        "odt": .unsupportedDocument(family: .openDocument),
        "ods": .unsupportedDocument(family: .openDocument),
        "odp": .unsupportedDocument(family: .openDocument),
        // Pixel images. SVG is XML source and deliberately absent.
        "png": .image, "jpg": .image, "jpeg": .image, "gif": .image, "bmp": .image,
        "tiff": .image, "tif": .image, "webp": .image, "heic": .image, "heif": .image,
    ]

    static func readSupport(for ext: String) -> ReadSupport {
        readSupportByExtension[ext.lowercased()] ?? .rawText
    }

    /// Extensions that take the document-extraction route (including the
    /// families we recognise but cannot parse, so they get an honest
    /// unsupported-format message instead of a UTF-8 decode failure).
    static let parserPreferredExtensions: Set<String> = Set(
        readSupportByExtension.compactMap { ext, support in
            support.isDocument ? ext : nil
        }
    )

    /// Extensions that read through a working adapter today.
    static let extractableDocumentExtensions: Set<String> = Set(
        readSupportByExtension.compactMap { ext, support in
            switch support {
            case .extractedText, .workbook: return ext
            default: return nil
            }
        }
    )

    /// Model-facing summary of what `file_read` opens. Shared by the tool
    /// description, the compact schema, and every unsupported-format message
    /// so the contract the model learns is identical everywhere.
    static let readableFormatsSummary =
        "text/source (any UTF-8 file), PDF, Word (.docx/.doc/.rtfd), "
        + "PowerPoint (.pptx/.potx), Excel (.xlsx), and images (.png/.jpg/.gif/.webp/.heic/...)"

    /// Model-facing summary of what `file_write` produces.
    static let writableFormatsSummary =
        "UTF-8 text/code (any extension), `.xlsx` from CSV/TSV text or JSON rows, "
        + "and `.docx`/`.pdf` from Markdown or HTML"

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

    /// Document extensions `file_write` cannot generate. `.xlsx`, `.docx`,
    /// and `.pdf` are NOT here — they route through
    /// `FileWriteDocumentRouting`. Every pivot names what the tool does
    /// produce so the model never learns "file_write is text only".
    private static let structuredTargets: [String: StructuredTarget] = {
        let spreadsheetPivot =
            "Write the same data as `.xlsx` (file_write builds a real workbook from CSV/TSV text or JSON rows) or as CSV/TSV text."
        let wordPivot =
            "Write the same content as `.docx` or `.pdf` (file_write renders Markdown/HTML into a real document) or as Markdown text."
        let presentationPivot =
            "Presentation generation is not built in: write the outline as Markdown, `.docx`, or `.pdf` instead, or use the `osaurus.pptx` plugin if it is installed."
        var table: [String: StructuredTarget] = [:]
        for ext in ["xlsm", "xltx", "xltm", "xlsb", "xls", "xlt", "ods", "numbers"] {
            table[ext] = StructuredTarget(label: "spreadsheet format", pivot: spreadsheetPivot)
        }
        for ext in ["docm", "doc", "dot", "dotx", "dotm", "rtfd", "odt", "pages"] {
            table[ext] = StructuredTarget(label: "word-processing format", pivot: wordPivot)
        }
        for ext in ["pptx", "pptm", "potx", "potm", "ppsx", "ppsm", "ppt", "pot", "pps", "odp", "key"] {
            table[ext] = StructuredTarget(label: "presentation format", pivot: presentationPivot)
        }
        return table
    }()

    /// Extensions `file_write` refuses (no generator). Exposed for
    /// descriptions and tests.
    static var unsupportedDocumentWriteExtensions: Set<String> { Set(structuredTargets.keys) }

    static func structuredTextWriteRejection(
        path: String,
        fileExtension ext: String,
        toolName: String
    ) -> String? {
        guard let target = structuredTargets[ext] else { return nil }
        return ToolEnvelope.failure(
            kind: .rejected,
            message:
                "Refused to write '\(path)' with \(toolName): .\(ext) is a \(target.label) that \(toolName) cannot generate. "
                + "\(toolName) writes \(WorkspaceFileFormatPolicy.writableFormatsSummary). \(target.pivot)",
            field: "path",
            expected: "a UTF-8 text path, or `.xlsx` / `.docx` / `.pdf` for a generated document",
            tool: toolName,
            retryable: false,
            metadata: ["extension": ext, "writable_formats": WorkspaceFileFormatPolicy.writableFormatsSummary]
        )
    }

    /// Rejection for `file_edit` / redaction tools, which only operate on
    /// UTF-8 text: any document extension (including the generated
    /// `.xlsx`/`.docx`/`.pdf`) gets the read-then-regenerate pivot.
    static func documentEditRejection(
        path: String,
        fileExtension ext: String,
        toolName: String,
        regenerateHint: String,
        verb: String = "edit"
    ) -> String? {
        let support = WorkspaceFileFormatPolicy.readSupport(for: ext)
        guard support.isDocument else { return nil }
        let label = support.family?.label ?? "document"
        return ToolEnvelope.failure(
            kind: .rejected,
            message:
                "Refused to \(verb) '\(path)' with \(toolName): .\(ext) is a \(label), and \(toolName) \(verb)s UTF-8 text only. "
                + "Read it with `file_read` (documents are extracted to text), apply the change to that text, then \(regenerateHint)",
            field: "path",
            expected: "a UTF-8 text file; for documents, read with file_read and regenerate with file_write",
            tool: toolName,
            retryable: false,
            metadata: ["extension": ext]
        )
    }

    /// Bytes of an existing file (any content), or `nil` when it does not
    /// exist. Used by the document write route so an overwrite of a
    /// binary package is captured for undo instead of refused.
    static func existingBytes(at fileURL: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try? Data(contentsOf: fileURL)
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
        if let contentKind = operation.contentKind {
            entry["content_kind"] = contentKind
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
