//
//  ToolDisplayName.swift
//  osaurus
//
//  Maps technical tool names (`db_insert`, `sandbox_exec`, …) to friendly
//  labels for the tool chip so non-technical users read natural phrases instead
//  of `db_insert`. Two tenses: present-continuous while the call is running
//  ("Inserting into the database") and past once it has completed ("Inserted
//  into the database"). The raw technical name is still shown when expanded.
//
//  Built-in tools get curated phrasing; anything dynamic (plugin / MCP /
//  folder / sandbox-registered tools that aren't in the table) falls back to a
//  generic snake_case → "Snake case" humanizer (same text for both tenses).
//

import Foundation

enum ToolDisplayName {

    /// Present-continuous + past phrasings for one tool.
    private struct ToolLabel {
        let running: String  // e.g. "Inserting into the database"
        let done: String  // e.g. "Inserted into the database"

        init(_ running: String, _ done: String) {
            self.running = running
            self.done = done
        }

        func text(running isRunning: Bool) -> String {
            isRunning ? running : done
        }
    }

    /// Friendly label for the chip. `running` selects present-continuous
    /// ("Inserting…") vs past ("Inserted…"). Falls back to a humanized form of
    /// `rawName` for tools without a curated entry.
    ///
    /// `arguments` (the raw tool-call JSON) lets search-style tools hoist their
    /// query into the title — "Searching “foo”" / "Searched for “foo”" — so a
    /// column of otherwise identical "Search" rows stays distinguishable.
    static func friendly(for rawName: String, running: Bool, arguments: String? = nil) -> String {
        if isSearchTool(rawName) {
            return searchLabel(rawName, running: running, arguments: arguments)
        }
        if rawName == "image" {
            return imageLabel(running: running, arguments: arguments)
        }
        // Other subagent tools (spawn, computer_use) take their
        // chip label from the capability registry (SSOT) so the chip and the
        // live-feed header always read the same word.
        if let label = SubagentCapabilityRegistry.displayLabel(forToolName: rawName) {
            return label
        }
        if let label = curated[rawName] {
            return label.text(running: running)
        }
        // Uncurated sandbox tools (e.g. dynamically registered plugins) still
        // get the "in sandbox" suffix for context.
        if rawName.hasPrefix("sandbox_") {
            return humanize(String(rawName.dropFirst("sandbox_".count))) + L(" in sandbox")
        }
        return humanize(rawName)
    }

    /// Whether `rawName` is a search tool whose title should embed its query.
    static func isSearchTool(_ rawName: String) -> Bool {
        rawName == "search" || rawName == "web_search"
    }

    /// The single `image` tool both generates and edits; show the right verb by
    /// peeking at whether `source_paths` was provided (edit mode).
    private static func imageLabel(running: Bool, arguments: String?) -> String {
        let isEdit = imageHasSourcePaths(arguments)
        if isEdit {
            return running ? L("Editing the image") : L("Edited the image")
        }
        return running ? L("Generating an image") : L("Generated an image")
    }

    private static func imageHasSourcePaths(_ arguments: String?) -> Bool {
        guard let arguments,
            let data = arguments.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let paths = ArgumentCoercion.stringArray(json["source_paths"])
        else { return false }
        return paths.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func searchLabel(_ rawName: String, running: Bool, arguments: String?) -> String {
        let onWeb = rawName == "web_search"
        guard let query = searchQuery(from: arguments) else {
            // No query parsed yet (e.g. arguments still streaming) — fall back
            // to a clean verb-only form rather than a dangling "Searched for".
            if running { return onWeb ? L("Searching the web") : L("Searching") }
            return onWeb ? L("Searched the web") : L("Searched")
        }
        let verb: String
        if running {
            verb = onWeb ? L("Searching the web for") : L("Searching")
        } else {
            verb = onWeb ? L("Searched the web for") : L("Searched for")
        }
        return "\(verb) “\(query)”"
    }

    /// Extract a non-empty, length-capped `query` string from a tool call's raw
    /// JSON arguments for use in the title. Returns nil when absent/blank.
    private static func searchQuery(from arguments: String?) -> String? {
        guard let arguments,
            let data = arguments.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = json["query"] as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let maxLen = 64
        return trimmed.count > maxLen ? String(trimmed.prefix(maxLen - 1)) + "…" : trimmed
    }

    /// Generic fallback: underscores/dashes → spaces, sentence-cased.
    /// `weather_lookup` → "Weather lookup". Keeps arbitrary plugin/MCP names
    /// readable without a curated entry.
    private static func humanize(_ raw: String) -> String {
        let spaced =
            raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = spaced.first else { return raw }
        return first.uppercased() + spaced.dropFirst()
    }

    /// Curated labels for built-in tools. Agent-loop tools (`todo`, `complete`,
    /// `clarify`) are listed for completeness even though they render as
    /// first-class UI rather than chips.
    private static let curated: [String: ToolLabel] = [
        // Database
        "db_schema": ToolLabel(L("Reading the database schema"), L("Read the database schema")),
        "db_create_table": ToolLabel(L("Creating a database table"), L("Created a database table")),
        "db_alter_table": ToolLabel(L("Updating a table’s structure"), L("Updated a table’s structure")),
        "db_insert": ToolLabel(L("Inserting into the database"), L("Inserted into the database")),
        "db_upsert": ToolLabel(L("Saving to the database"), L("Saved to the database")),
        "db_import": ToolLabel(L("Importing data into the database"), L("Imported data into the database")),
        "db_update": ToolLabel(L("Updating the database"), L("Updated the database")),
        "db_delete": ToolLabel(L("Deleting from the database"), L("Deleted from the database")),
        "db_query": ToolLabel(L("Querying the database"), L("Queried the database")),
        "db_execute": ToolLabel(L("Running a database command"), L("Ran a database command")),
        "db_migrate": ToolLabel(L("Migrating the database"), L("Migrated the database")),
        "db_restore": ToolLabel(L("Restoring the database"), L("Restored the database")),
        "db_define_view": ToolLabel(L("Defining a database view"), L("Defined a database view")),
        "db_drop_view": ToolLabel(L("Removing a database view"), L("Removed a database view")),
        "db_list_views": ToolLabel(L("Listing database views"), L("Listed database views")),
        "db_run_view": ToolLabel(L("Running a database view"), L("Ran a database view")),

        // Sandbox — "in sandbox" suffix makes the execution context explicit.
        "sandbox_exec": ToolLabel(L("Running a command in sandbox"), L("Ran a command in sandbox")),
        "sandbox_read_file": ToolLabel(L("Reading a file in sandbox"), L("Read a file in sandbox")),
        "sandbox_write_file": ToolLabel(L("Writing a file in sandbox"), L("Wrote a file in sandbox")),
        "sandbox_edit_file": ToolLabel(L("Editing a file in sandbox"), L("Edited a file in sandbox")),
        "sandbox_search_files": ToolLabel(L("Searching files in sandbox"), L("Searched files in sandbox")),
        "sandbox_install": ToolLabel(
            L("Installing dependencies in sandbox"),
            L("Installed dependencies in sandbox")
        ),
        "sandbox_process": ToolLabel(L("Managing a process in sandbox"), L("Managed a process in sandbox")),
        "sandbox_plugin_register": ToolLabel(
            L("Registering a plugin in sandbox"),
            L("Registered a plugin in sandbox")
        ),
        "sandbox_secret_check": ToolLabel(L("Checking a secret in sandbox"), L("Checked a secret in sandbox")),
        "sandbox_secret_set": ToolLabel(L("Saving a secret in sandbox"), L("Saved a secret in sandbox")),

        // Folder / file
        "file_read": ToolLabel(L("Reading a file"), L("Read a file")),
        "file_write": ToolLabel(L("Writing a file"), L("Wrote a file")),
        "file_edit": ToolLabel(L("Editing a file"), L("Edited a file")),
        "file_search": ToolLabel(L("Searching files"), L("Searched files")),
        "file_tree": ToolLabel(L("Browsing files"), L("Browsed files")),
        "shell_run": ToolLabel(L("Running a command"), L("Ran a command")),
        "git_status": ToolLabel(L("Checking git status"), L("Checked git status")),
        "git_diff": ToolLabel(L("Viewing changes"), L("Viewed changes")),
        "git_commit": ToolLabel(L("Committing changes"), L("Committed changes")),

        // General built-ins
        "capabilities_discover": ToolLabel(L("Searching capabilities"), L("Searched capabilities")),
        "capabilities_load": ToolLabel(L("Loading capabilities"), L("Loaded capabilities")),
        "search_memory": ToolLabel(L("Searching memory"), L("Searched memory")),
        "render_chart": ToolLabel(L("Rendering a chart"), L("Rendered a chart")),
        // `image` is handled by `imageLabel` (mode-aware: generate vs edit).
        "share_artifact": ToolLabel(L("Sharing a file"), L("Shared a file")),
        "speak": ToolLabel(L("Speaking"), L("Spoke")),
        "notify": ToolLabel(L("Sending a notification"), L("Sent a notification")),
        "schedule_next_run": ToolLabel(L("Scheduling the next run"), L("Scheduled the next run")),
        "cancel_next_run": ToolLabel(L("Canceling the scheduled run"), L("Canceled the scheduled run")),

        // Agent-loop (rendered as first-class UI, listed for completeness)
        "todo": ToolLabel(L("Updating the task list"), L("Updated the task list")),
        "complete": ToolLabel(L("Finishing up"), L("Finished")),
        "clarify": ToolLabel(L("Asking a question"), L("Asked a question")),
    ]
}
