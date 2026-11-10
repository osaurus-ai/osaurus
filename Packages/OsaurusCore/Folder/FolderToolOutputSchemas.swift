//
//  FolderToolOutputSchemas.swift
//  osaurus
//
//  What each folder tool's success `result` holds, published as its
//  `outputSchema` so a workflow tool step binds the real fields.
//

import Foundation

enum FolderToolOutputSchemas {
    private typealias S = ToolOutputSchema

    /// One `{name, path, type}` row of a listing or filename search.
    static let entry = S.object(
        [
            "name": S.string("File or folder name."),
            "path": S.string(
                "Path to pass to the next file tool: relative to the working folder, or absolute when the file is outside it."
            ),
            "type": S.string("`file` or `directory`."),
            "modified": S.string("ISO 8601 modification time, with `sort: recent`."),
        ], required: ["name", "path"])

    private static let fileReference = S.object(
        [
            "kind": S.string("`workspace_file` or `sandbox_file`."),
            "path": S.string("Path of the file written."),
            "exportable": S.boolean("Whether `share_artifact` can surface it."),
        ], "The file this call wrote.")

    static let fileSearch = S.object(
        [
            "kind": S.string("`search` for `target: \"files\"`; absent for a content search."),
            "query": S.string("`target: \"files\"`: the name pattern actually matched."),
            "entries": S.array(
                entry,
                "`target: \"files\"`: the matching files, `{name, path, type}`. Each `path` is ready for `file_read`."),
            "match_count": S.integer("`target: \"files\"`: entries on this page."),
            "total": S.integer("`target: \"files\"`: matches in the whole folder."),
            "offset": S.integer("`target: \"files\"`: this page's start."),
            "next_offset": S.integer("`target: \"files\"`: pass as `offset` for the next page; absent on the last page."),
            "truncated": S.boolean("`target: \"files\"`: the walk stopped early, so results may be incomplete."),
            "text": S.string(
                "`target: \"content\"` (default): matching lines as `path:line: text`, or a no-matches note."),
        ],
        "`target: \"files\"` returns `entries`; `target: \"content\"` returns `text`.")

    static let fileRead = S.object(
        [
            "kind": S.string(
                "`file` (text or extracted document), `image`, `workbook` (.xlsx preview), `listing` (a directory), or `files` (a `paths` batch)."
            ),
            "text": S.string(
                "The content. Each line is `<line number>|<content>`; a PDF's pages are split by `--- Page N of M ---`. An empty file reads `(empty file)`."
            ),
            "path": S.string("The path read."),
            "format": S.string("File type opened, e.g. `text`, `pdf`, `docx`, `pptx`, `xlsx`, `png`."),
            "source": S.string("`raw_text`, `extracted_text`, `ocr_text`, `workbook_preview`, or `image`."),
            "line_format": S.string("How to read the `N|` gutter in `text`."),
            "start_line": S.integer("First line returned."),
            "end_line": S.integer("Last complete line returned."),
            "total_lines": S.integer("Lines in the file (or extracted text)."),
            "total_lines_exact": S.boolean("False when a byte cap stopped the read before the end."),
            "truncated": S.boolean("The read stopped before the end of the requested range."),
            "next_start_line": S.integer("Pass as `start_line` to continue a truncated read."),
            "next_end_line": S.integer("Pass as `end_line` to continue a truncated read."),
            "pages": S.integer("PDF page count."),
            "slides": S.integer("PowerPoint slide count."),
            "note": S.string("Provenance note, e.g. an OCR caveat."),
            "entries": S.array(entry, "`kind: listing`: the directory's entries."),
            "entry_count": S.integer("`kind: listing`: number of entries."),
            "sheets": S.integer("`kind: workbook`: sheet count."),
            "sheet_names": S.array(S.string("Sheet name."), "`kind: workbook`: the sheet names."),
            "sheet_name": S.string("`kind: workbook`: the sheet previewed."),
            "width": S.integer("`kind: image`: pixel width."),
            "height": S.integer("`kind: image`: pixel height."),
            "files": S.array(
                S.object(
                    [
                        "ok": S.boolean("Whether this file was read."),
                        "path": S.string("The path requested."),
                        "text": S.string("The content, as for a single read."),
                        "message": S.string("Why the file was not read, when `ok` is false."),
                    ], required: ["ok", "path"]),
                "`kind: files`: one result per path in request order, each with the single-read fields."),
            "file_count": S.integer("`kind: files`: number of results."),
            "failed_count": S.integer("`kind: files`: results with `ok: false`."),
        ],
        "A file read returns `text`; a directory returns `entries`; a `paths` batch returns `files`.")

    /// Shared by `file_write`, `file_edit`, and `redact_file`.
    private static let writeFields: [String: JSONValue] = [
        "kind": S.string(
            "`workspace_write_result`, `workspace_write_preview` (dry run), `document_write_result`, or `document_write_preview`."
        ),
        "path": S.string("The path written."),
        "action": S.string("`create`, `update`, or `overwrite`."),
        "applied": S.boolean("Whether the file on disk changed (false for a dry run)."),
        "dry_run": S.boolean("Whether this was a preview only."),
        "text": S.string("One-line summary of what was written."),
        "diff": S.string("Unified diff of the change (capped)."),
        "diff_truncated": S.boolean("The diff excerpt was cut; the write itself is complete."),
        "line_count": S.integer("Lines in the new content."),
        "character_count": S.integer("Characters in the new content."),
        "content_sha256": S.string("SHA-256 of the new content."),
        "before_content_sha256": S.string("SHA-256 of the previous content, when the file existed."),
        "format": S.string("Generated document type (`docx`, `pdf`, `xlsx`, `pptx`)."),
        "bytes_written": S.integer("Bytes of a generated document."),
        "operation_id": S.string("Change-set id for `file_undo`."),
        "file_reference": fileReference,
        "mode": S.string("`overwrite` or `append`."),
        "verification": S.value("What still needs checking after the write."),
    ]

    static let fileWrite = S.object(writeFields, "The written (or previewed) file.")

    static let fileEdit = S.object(
        writeFields.merging([
            "replacements": S.integer("Occurrences replaced."),
            "match_strategy": S.string("How `old_string` was matched (`exact`, or a tolerated drift)."),
            "matched_lines": S.array(S.string("Line or line range."), "Where the matches were."),
            "edits_applied": S.array(S.integer("Replacements made by this edit."), "With `edits`: per-edit counts."),
            "operations_applied": S.value("On a .docx/.xlsx/.pptx/.pdf: what each operation changed."),
        ]) { _, new in new },
        "The edited (or previewed) file.")

    static let fileCopy = S.object(
        [
            "kind": S.string("`file_copy_result`."),
            "source": S.string("The path copied from."),
            "destination": S.string("The path copied to."),
            "source_area": S.string("Where the source lives (`workspace` or `sandbox`)."),
            "destination_area": S.string("Where the copy lives (`workspace` or `sandbox`)."),
            "bytes": S.integer("Bytes copied."),
            "overwrote": S.boolean("Whether an existing file was replaced."),
            "file_reference": fileReference,
            "operation_id": S.string("Change-set id for `file_undo`."),
        ], required: ["source", "destination"])

    static let fileTree = S.object(
        [
            "text": S.string("The directory tree, one entry per line."),
            "entries": S.array(entry, "In the sandbox: the listing's entries."),
        ], "The folder's tree as `text` (or `entries` for a sandbox path).")

    static let fileOperationHistory = S.object(
        [
            "kind": S.string("`file_operation_history`."),
            "entries": S.array(
                S.object([
                    "id": S.string("Change-set id; pass to `file_undo`."),
                    "tool": S.string("The tool that made the change."),
                    "status": S.string("Whether it is applied or reverted."),
                    "timestamp": S.string("ISO 8601 time of the change."),
                    "can_undo": S.boolean("Whether `file_undo` can revert it."),
                    "files": S.array(
                        S.object([
                            "path": S.string("File changed."),
                            "change": S.string("Kind of change."),
                            "state": S.string("Current state of the file."),
                        ]), "Files the change touched."),
                ]), "Recent changes, newest first."),
            "operation_count": S.integer("Changes matching the filter."),
            "returned_count": S.integer("Changes in `entries`."),
            "limit": S.integer("The most `entries` returned."),
            "path": S.string("The path filter, when given."),
        ])

    static let fileUndo = S.object(
        [
            "kind": S.string("`file_undo`."),
            "undone_count": S.integer("Files restored."),
            "undone": S.array(S.object(["path": S.string("File restored.")]), "The files restored."),
            "undone_operation_id": S.string("The change that was reverted."),
            "undone_tool": S.string("The tool that made that change."),
            "revert_operation_id": S.string("Change-set id of the revert itself."),
        ], required: ["undone_count"])

    static let shellRun = S.object(
        [
            "stdout": S.string("Standard output (trimmed; long output keeps head and tail)."),
            "stderr": S.string("Standard error (trimmed)."),
            "exit_code": S.integer("The command's exit status; 0 is success."),
            "working_directory": S.string("Where the command ran on this Mac."),
            "cwd": S.string("Where the command ran in the sandbox."),
            "killed_by": S.string("`user` or `idle_timeout` when the command was stopped."),
            "idle_timeout_seconds": S.integer("The idle ceiling that stopped it."),
            "operation_id": S.string("Change-set id for `file_undo`."),
            "pid": S.integer("`background: true`: the job's pid for `sandbox_process`."),
            "log_file": S.string("`background: true`: where the job logs."),
            "background": S.boolean("`background: true`: the job was started."),
        ], "A finished command's `stdout`, `stderr`, and `exit_code`.")

    static let gitStatus = S.text("`git status` output, or `No changes`.")
    static let gitDiff = S.text("The unified diff, or a note that there are no changes.")
    static let gitLog = S.text("Recent commits, one per line.")
    static let gitCommit = S.text("The commit summary, or `Nothing to commit`.")

    static let detectPII = S.object(
        [
            "backend": S.string("The detector that ran."),
            "total_detections": S.integer("Sensitive items found."),
            "categories": S.anyObject(
                "Per category (`name`, `email`, `phone`, …): `{count, samples: [{text, line, occurrences}]}`."),
            "path": S.string("The file scanned, when a path was given."),
            "rejected_rules": S.array(
                S.object(["name": S.string("Rule name."), "reason": S.string("Why it was rejected.")]),
                "Custom rules that were not applied."),
        ], required: ["total_detections"])

    static let redactFile = S.object(
        writeFields.merging([
            "backend": S.string("The detector that ran."),
            "replacements": S.integer("Items redacted."),
            "replacements_by_category": S.anyObject("Category → items redacted."),
            "custom_rule_matches": S.anyObject("Custom rule name → items redacted."),
            "written": S.boolean("Whether the redacted file was saved."),
        ]) { _, new in new },
        "The redacted (or previewed) file and what was replaced.")
}

extension FileReadTool { var outputSchema: JSONValue? { FolderToolOutputSchemas.fileRead } }
extension FileWriteTool { var outputSchema: JSONValue? { FolderToolOutputSchemas.fileWrite } }
extension FileEditTool { var outputSchema: JSONValue? { FolderToolOutputSchemas.fileEdit } }
extension FileSearchTool { var outputSchema: JSONValue? { FolderToolOutputSchemas.fileSearch } }
extension FileTreeTool { var outputSchema: JSONValue? { FolderToolOutputSchemas.fileTree } }
extension FileCopyTool { var outputSchema: JSONValue? { FolderToolOutputSchemas.fileCopy } }
extension FileOperationHistoryTool { var outputSchema: JSONValue? { FolderToolOutputSchemas.fileOperationHistory } }
extension FileUndoTool { var outputSchema: JSONValue? { FolderToolOutputSchemas.fileUndo } }
extension ShellRunTool { var outputSchema: JSONValue? { FolderToolOutputSchemas.shellRun } }
extension GitStatusTool { var outputSchema: JSONValue? { FolderToolOutputSchemas.gitStatus } }
extension GitDiffTool { var outputSchema: JSONValue? { FolderToolOutputSchemas.gitDiff } }
extension GitLogTool { var outputSchema: JSONValue? { FolderToolOutputSchemas.gitLog } }
extension GitCommitTool { var outputSchema: JSONValue? { FolderToolOutputSchemas.gitCommit } }
extension DetectPIITool { var outputSchema: JSONValue? { FolderToolOutputSchemas.detectPII } }
extension RedactFileTool { var outputSchema: JSONValue? { FolderToolOutputSchemas.redactFile } }
