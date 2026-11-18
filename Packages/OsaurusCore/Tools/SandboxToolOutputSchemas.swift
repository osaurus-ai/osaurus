//
//  SandboxToolOutputSchemas.swift
//  osaurus
//
//  The `result` shape of each `sandbox_*` tool.
//

import Foundation

enum SandboxToolOutputSchemas {
    private typealias S = ToolOutputSchema

    static let readFile = S.object(
        [
            "kind": S.string("`file`."),
            "path": S.string("Path in the sandbox."),
            "content": S.string("The file's text (the requested lines when paged)."),
            "size": S.integer("Characters in `content`."),
            "start_line": S.integer("First line returned, when paged."),
            "line_count": S.integer("Lines requested, when paged."),
            "tail_lines": S.integer("Lines from the end, when requested."),
            "max_chars": S.integer("Character cap, when requested."),
            "truncated": S.boolean("True when the cap cut `content`."),
        ], required: ["path", "content"])

    static let searchFiles = S.object(
        [
            "pattern": S.string("The pattern searched."),
            "target": S.string("`files` or `content`."),
            "path": S.string("Directory searched."),
            "matches": S.string("Matches, one per line (`path` or `path:line:text`)."),
            "truncated": S.boolean("True when more matches exist."),
        ], required: ["matches"])

    static let writeFile = S.object(
        [
            "path": S.string("Path written."),
            "file_reference": S.object(
                ["kind": S.string("`workspace_file`."), "path": S.string("Path."),
                 "exportable": S.boolean("Can be shared.")], "The written file."),
            "operation_id": S.string("Change set id."),
            "size": S.integer("Bytes written."),
            "mode": S.string("`overwrite` or `append`."),
            "replacements": S.integer("With `old_string`: replacements made."),
            "match_strategy": S.string("With `old_string`: how it matched."),
            "matched_lines": S.array(S.string("Line or line range."), "With `old_string`: where it matched."),
            "summary": S.string("What changed."),
            "diff": S.string("Unified diff."),
            "diff_truncated": S.boolean("True when the diff was cut."),
            "dry_run": S.boolean("True for a preview."),
            "action": S.string("`create` or `update`."),
            "content_sha256": S.string("SHA-256 of the new content."),
            "before_content_sha256": S.string("SHA-256 of the old content."),
            "content_write_complete": S.boolean("True once written."),
            "verification": S.value("How the write was checked."),
        ], required: ["path"])

    static let exec = S.object(
        [
            "stdout": S.string("Standard output."),
            "stderr": S.string("Standard error."),
            "exit_code": S.integer("Exit status."),
            "cwd": S.string("Working directory."),
            "killed_by": S.string("`user` when stopped."),
            "pid": S.integer("With `background`: the process id."),
            "log_file": S.string("With `background`: its log."),
            "background": S.boolean("True for a background start."),
        ])

    static let process = S.object(
        [
            "pid": S.integer("Process id."),
            "alive": S.boolean("`poll`: still running."),
            "exited": S.boolean("`wait`: it exited."),
            "timed_out": S.boolean("`wait`: the wait ran out first."),
            "killed": S.boolean("`kill`: it is gone."),
            "signal": S.string("`kill`: the signal sent."),
            "log_file": S.string("Its log."),
            "log_tail": S.string("The end of its log."),
        ], required: ["pid"])

    static let install = S.object(
        [
            "installed": S.array(S.string("Package."), "Packages installed."),
            "manager": S.string("`apk`, `pip`, or `npm`."),
            "exit_code": S.integer("Installer exit status."),
            "summary": S.string("One line."),
            "retried": S.boolean("True when a retry succeeded."),
        ], required: ["installed"])

    static let secretCheck = S.object(
        ["key": S.string("The secret name."), "exists": S.boolean("True when it is set.")],
        required: ["key", "exists"])

    static let secretSet = S.object(
        ["stored": S.boolean("True when saved."), "key": S.string("The secret name.")], required: ["key"])

    static let pluginRegister = S.object(
        [
            "plugin_id": S.string("Plugin id."),
            "plugin_name": S.string("Plugin name."),
            "installed_dependencies": S.anyObject("System packages installed, by manager."),
            "tools": S.array(
                S.object(["name": S.string("Tool name."), "description": S.string("What it does.")]),
                "Tools it registered."),
        ], required: ["plugin_id"])
}
