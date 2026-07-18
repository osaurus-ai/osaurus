//
//  Skill.swift
//  osaurus
//
//  Defines a Skill - markdown instructions that guide AI behavior.
//  Skills are stored as directories with SKILL.md files following the Agent Skills spec.
//  See: https://agentskills.io/specification
//

import Foundation

/// Represents a file within a skill's references or assets directory
public struct SkillFile: Codable, Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let relativePath: String
    public let size: Int64

    public init(name: String, relativePath: String, size: Int64 = 0) {
        self.name = name
        self.relativePath = relativePath
        self.size = size
    }
}

/// A skill containing instructions/guidance for the AI
/// Follows the Agent Skills specification: https://agentskills.io/specification
public struct Skill: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var description: String
    public var version: String
    public var author: String?
    public var category: String?
    public var keywords: [String]
    public var instructions: String
    public let isBuiltIn: Bool
    public let createdAt: Date
    public var updatedAt: Date

    // MARK: - Plugin Association

    /// The plugin ID if this skill was installed as part of a plugin
    public var pluginId: String?

    /// Whether this skill was installed from a plugin
    public var isFromPlugin: Bool { pluginId != nil }

    // MARK: - Directory Structure

    /// Files in the references/ directory (loaded into context)
    public var references: [SkillFile]
    /// Files in the assets/ directory (supporting files)
    public var assets: [SkillFile]
    /// The directory name (Agent Skills format: lowercase-with-hyphens)
    public var directoryName: String?

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        version: String = "1.0.0",
        author: String? = nil,
        category: String? = nil,
        keywords: [String] = [],
        instructions: String = "",
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        references: [SkillFile] = [],
        assets: [SkillFile] = [],
        directoryName: String? = nil,
        pluginId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.category = category
        self.keywords = keywords
        self.instructions = instructions
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.references = references
        self.assets = assets
        self.directoryName = directoryName
        self.pluginId = pluginId
    }

    /// Total count of associated files
    public var totalFileCount: Int {
        references.count + assets.count
    }

    /// Whether this skill has any associated files
    public var hasAssociatedFiles: Bool {
        totalFileCount > 0
    }

    // MARK: - Built-in Skills

    /// All built-in skills
    ///
    /// Every preset is grounded in real Osaurus tools (like `render_chart`,
    /// `web_search`, `applescript`) rather than generic persona advice, so
    /// enabling a skill teaches the agent a concrete workflow it could not
    /// otherwise know.
    public static var builtInSkills: [Skill] {
        [
            // Web Researcher
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-000000000008")!,
                name: L("Web Researcher"),
                description: L("Live web research with source retrieval, cross-checking, and cited reports"),
                version: "1.0.0",
                author: "Osaurus",
                category: L("research"),
                keywords: [
                    "research", "web", "search", "sources", "fact-check", "citations",
                    "investigate", "news", "compare", "verify", "report",
                ],
                instructions: """
                    When researching a topic that needs live web data:

                    ## Workflow
                    1. Use `web_search` with focused queries to find candidate sources
                    2. Pick the most authoritative results and call `search_and_extract` with each result's direct `url` to retrieve the actual page content — never pass a known URL back into `web_search` as another query
                    3. Cross-reference key facts across at least two independent sources
                    4. Note publication dates; prefer recent sources for fast-moving topics

                    ## Query strategy
                    - Start specific; broaden only if results are thin
                    - Run separate searches per sub-question instead of one broad query
                    - Re-search with alternate terms when sources disagree or look stale

                    ## Synthesis
                    - Distinguish facts from opinion and speculation
                    - Attribute every non-obvious claim to its source (title + URL)
                    - Call out disagreements between sources instead of averaging them away
                    - State plainly what could not be verified

                    ## Delivering results
                    - Short findings: answer inline with a source list at the end
                    - Long reports: write the full report to a file and surface it with `share_artifact` so it appears in chat
                    - Lead any long report with an executive summary
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),

            // Content Summarizer
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-000000000005")!,
                name: L("Content Summarizer"),
                description: L("Extract key points and create structured summaries"),
                version: "1.1.0",
                author: "Osaurus",
                category: L("productivity"),
                keywords: [
                    "summarize", "summary", "tldr", "key-points", "digest", "condense",
                    "gist", "overview", "recap", "synopsis", "brief", "abstract",
                    "main-points", "takeaways", "highlights", "skim", "the-gist",
                ],
                instructions: """
                    When asked to summarize content:

                    ## Get the content first
                    - URL mentioned: call `search_and_extract` with the direct `url` to retrieve the page text — never summarize from the title or from memory
                    - File in the working folder: read it with `file_read`
                    - Attached or pasted content: use it as-is
                    - If the content cannot be retrieved, say so; never fabricate a summary

                    ## Summary types
                    - TL;DR: 1-2 sentence essence
                    - Executive Summary: key points for decision makers
                    - Detailed Summary: comprehensive overview
                    - Bullet Points: scannable key takeaways

                    ## Structure
                    - Lead with the most important information
                    - Group related points; use section headers for long summaries
                    - Capture key facts, figures, names, dates, and action items
                    - End with conclusions or next steps

                    ## Quality guidelines
                    - Maintain accuracy — do not add interpretation
                    - Keep the original tone and intent
                    - Match length to the requested format
                    - Note any gaps or missing information
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),

            // Mac Automator
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-000000000009")!,
                name: L("Mac Automator"),
                description: L("Control and query Mac apps with AppleScript automation"),
                version: "1.0.0",
                author: "Osaurus",
                category: L("automation"),
                keywords: [
                    "mac", "automate", "applescript", "automation", "app", "safari",
                    "finder", "notes", "control", "script", "macos",
                ],
                instructions: """
                    When asked to control or query Mac applications:

                    ## Choosing the right tool
                    - **Read-only lookups** (current Safari tab, what's playing, unread counts, file listings): use `mac_query` — it cannot change anything
                    - **Actions** (create a note, send an email, move files, change settings): use `applescript` with a clear natural-language goal

                    ## Well-supported apps
                    Safari, Notes, Mail, Finder, Calendar, Reminders, Music, Shortcuts, Terminal, and System Events have curated automation recipes — prefer these when the user has a choice of app.

                    ## Safety
                    - Confirm with the user before destructive or irreversible actions (deleting files, sending emails or messages, emptying trash)
                    - Prefer the narrowest action that satisfies the request
                    - Report exactly what was done, including anything skipped or failed

                    ## When automation fails
                    - Check whether the target app is running and whether Osaurus has Automation permission (System Settings → Privacy & Security → Automation)
                    - Retry once with a simpler, more explicit goal before giving up
                    - Fall back to step-by-step instructions the user can follow manually
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),

            // Personal Organizer
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-00000000000A")!,
                name: L("Personal Organizer"),
                description: L("Manage calendar events, reminders, email, and messages"),
                version: "1.0.0",
                author: "Osaurus",
                category: L("productivity"),
                keywords: [
                    "calendar", "events", "reminders", "schedule", "email", "mail",
                    "messages", "appointments", "meetings", "organize", "todo",
                ],
                instructions: """
                    When helping manage calendar, reminders, email, or messages:

                    ## Available tools (from plugins)
                    - **Calendar**: `get_events`, `search_events`, `create_event`, `open_event`
                    - **Reminders**: `get_reminders`, `search_reminders`, `create_reminder`, `get_lists`
                    - **Mail**: `list_messages`, `read_message`, `search_messages`, `compose_message`, `reply_to_message`
                    - **Messages**: `send_message`, `read_messages`, `get_unread_messages`

                    These come from installable plugins. If a tool is missing, use `capabilities_discover` to check what is available, and tell the user which plugin to install from Management → Plugins (osaurus.calendar, osaurus.reminders, osaurus.mail, osaurus.messages).

                    ## Working with dates
                    - Call `get_current_time` before computing any relative date ("tomorrow", "next Tuesday") — never guess today's date
                    - Confirm ambiguous times ("Friday" — this week or next?) before creating events

                    ## Good defaults
                    - Read before you write: check for conflicts before creating events, and for existing entries before creating reminders
                    - Confirm before sending email or messages on the user's behalf
                    - After creating something, report back the exact title, date, and time so mistakes are easy to spot
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),

            // Document Builder
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-00000000000B")!,
                name: L("Document Builder"),
                description: L("Create spreadsheets and presentations, delivered as downloadable files"),
                version: "1.0.0",
                author: "Osaurus",
                category: L("productivity"),
                keywords: [
                    "spreadsheet", "excel", "xlsx", "csv", "presentation", "powerpoint",
                    "pptx", "slides", "document", "export", "deck",
                ],
                instructions: """
                    When asked to produce a spreadsheet or presentation:

                    ## Spreadsheets (osaurus.xlsx plugin)
                    - `create_xlsx` to start a workbook, `write_cells` to fill in data
                    - `csv_to_xlsx` when the data already exists as CSV
                    - `read_xlsx` to inspect an existing workbook before modifying it
                    - Put headers in the first row; keep one dataset per sheet

                    ## Presentations (osaurus.pptx plugin)
                    - `create_presentation`, then `add_slide` / `add_text` per slide, then `save_presentation`
                    - One idea per slide; start with a title slide; keep bullets short

                    ## Missing tools
                    These tools come from plugins. If they are unavailable, use `capabilities_discover` to check, and tell the user to install osaurus.xlsx or osaurus.pptx from Management → Plugins.

                    ## Delivering files
                    Always surface the finished file with `share_artifact` — it is the only way a file appears in chat as a downloadable card. A file written to disk without `share_artifact` is invisible to the user.

                    ## Quality
                    - Confirm the desired structure (columns, slide outline) before building anything large
                    - After delivery, summarize what the file contains
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),

            // Workspace Assistant
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-00000000000C")!,
                name: L("Workspace Assistant"),
                description: L("Work on files in the mounted folder: read, edit, search, run commands, commit"),
                version: "1.0.0",
                author: "Osaurus",
                category: L("development"),
                keywords: [
                    "files", "folder", "workspace", "code", "edit", "shell",
                    "git", "commit", "search", "project", "refactor",
                ],
                instructions: """
                    When a working folder is mounted, use the folder tools:

                    ## Orientation first
                    - `file_tree` to see the project layout before anything else
                    - `file_search` to locate relevant files by name or content
                    - `file_read` before editing — never edit a file you have not read

                    ## Editing
                    - Prefer `file_edit` (targeted replacements) over `file_write` whole-file rewrites; rewrites risk destroying content you did not read
                    - Make the smallest change that satisfies the request
                    - `file_undo` and `file_operation_history` can recover from mistakes

                    ## Commands
                    - `shell_run` executes in the folder context — use it for builds, tests, and scripts
                    - Show the user relevant command output, especially failures

                    ## Git
                    - `git_status` and `git_diff` to review state before and after changes
                    - `git_commit` only when the user asks for a commit
                    - Never write commit messages that overstate what changed

                    ## Boundaries
                    - Only use the tools above that are actually in your tool list. In sandbox mode the folder may be read-only and shell/git run in the sandbox instead — the `## Files` rules in your system prompt win over this skill
                    - If none of these tools are present, ask the user to attach a working folder
                    - Stay inside the mounted folder; do not attempt paths outside it
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),

            // Data Keeper
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-00000000000D")!,
                name: L("Data Keeper"),
                description: L("Keep structured records across chats in the agent's private database"),
                version: "1.0.0",
                author: "Osaurus",
                category: L("productivity"),
                keywords: [
                    "track", "log", "record", "database", "expenses", "habits",
                    "inventory", "history", "persist", "table", "sqlite",
                ],
                instructions: """
                    When the user wants to track structured information over time (expenses, habits, workouts, inventories, reading lists):

                    ## The agent database
                    Each agent has a private SQLite database that persists across chats. Use it — not chat memory — for anything the user will ask about later. These tools are gated by the agent's database setting; if `db_query` is missing, ask the user to enable the database for this agent.

                    ## Workflow
                    1. `db_schema` first — check what tables already exist before creating or writing
                    2. `db_create_table` with explicit column types when a new table is needed
                    3. `db_upsert` for records with a natural key (idempotent); `db_insert` for append-only logs
                    4. `db_query` to answer questions; aggregate in SQL (SUM, COUNT, GROUP BY) rather than in prose

                    ## Schema tips
                    - Include a date or timestamp column on anything tracked over time
                    - Store amounts as numbers, not formatted strings
                    - Keep one concept per table; add columns via `db_alter_table` rather than overloading text fields

                    ## Reporting
                    - Totals and summaries: answer inline from `db_query` results
                    - Trends: pass query results to `render_chart` for a visual
                    - Exports: `db_export`, then surface the file with `share_artifact`

                    ## Care with data
                    - Confirm before `db_delete` or destructive `db_execute`; `db_restore` exists but do not rely on it
                    - Echo back inserted values so entry errors are caught early
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),

            // Autonomous Scheduler
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-00000000000E")!,
                name: L("Autonomous Scheduler"),
                description: L("Set up recurring or delayed self-running tasks with notifications"),
                version: "1.0.0",
                author: "Osaurus",
                category: L("automation"),
                keywords: [
                    "schedule", "recurring", "automate", "later", "daily", "weekly",
                    "notify", "notification", "routine", "briefing", "remind",
                ],
                instructions: """
                    When the user wants something done later or on a recurring basis (daily briefing, weekly report, periodic check):

                    ## Scheduling tools
                    - `get_current_time` first — compute the target time from the real current time, never a guessed one
                    - `schedule_next_run` with the computed time and a precise instruction describing exactly what the future run should do
                    - `cancel_next_run` when the user wants to stop a scheduled task
                    - `notify` to post a local notification when a run produces something the user should see

                    ## Writing the future-run instruction
                    The scheduled run starts fresh — it will not remember this conversation. Include everything it needs: what to do, which tools to use, what to deliver, and that it should call `schedule_next_run` again if the task recurs.

                    ## Confirming
                    - Repeat back the exact scheduled time and what will happen, so the user can catch mistakes
                    - For recurring tasks, state the cadence explicitly ("every weekday at 8:00")

                    ## Boundaries
                    - One next run is scheduled at a time; a recurring task keeps itself alive by rescheduling at the end of each run
                    - Do not schedule actions the user has not explicitly approved (sending messages, spending money)
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),

            // Data Visualization
            Skill(
                id: UUID(uuidString: "00000001-0000-0000-0000-000000000007")!,
                name: L("Data Visualizer"),
                description: L("Render charts and graphs from attached, retrieved, or computed data"),
                version: "1.0.0",
                author: "Osaurus",
                category: L("productivity"),
                keywords: ["chart", "graph", "plot", "visualize", "bar", "line", "pie", "data", "table", "csv"],
                instructions: """
                    When the user's message contains data suitable for visualization:

                    ## Choosing the right path

                    **If raw tabular data is available from an attachment, web extraction,
                    sandbox/file read, download, or computation:** call the `render_chart` tool.
                    Retrieve or compute the data first, then pass its full raw content in the
                    `data` field without removing or rewriting its header row, and use
                    `xColumn` / `series` to specify which columns to plot.
                    When `search_and_extract` returns a `data_ref` and an exact
                    `next_action`, call `render_chart` with those arguments instead of
                    copying the raw payload through your context.
                    The tool does not fetch URLs itself; it handles parsing and downsampling once
                    data is available. After `web_search` selects a source, call
                    `search_and_extract` with that result's direct `url` to retrieve its actual
                    contents; never pass a known URL back as another search query, and do not keep
                    rephrasing discovery searches when retrieval is the required next step. Example:
                    ```
                    render_chart(
                      data: "<full raw CSV/TSV/JSON content>",
                      format: "csv",
                      chartType: "line",
                      xColumn: "Month",
                      series: ["Revenue", "Expenses"],
                      title: "Monthly Financials"
                    )
                    ```

                    **If the data is small and inline** (pasted table, computed values, fewer
                    than ~50 data points): emit a ```chart fenced block with the full spec:
                    ```chart
                    {
                      "chartType": "line",
                      "title": "...",
                      "categories": [...],
                      "series": [{ "name": "...", "data": [...] }]
                    }
                    ```

                    ## Chart type selection
                    - **column / bar**: comparisons between categories
                    - **line / spline**: trends over time or ordered sequences
                    - **area / areaspline**: trends where cumulative volume matters
                    - **pie**: proportions (use only with ≤8 slices)
                    - **scatter**: correlations between two numeric variables
                    - **bubble**: correlations with a third size dimension
                    - **gauge**: single KPI value with a target range
                    - **waterfall**: cumulative effect of sequential values

                    ## Quality guidelines
                    - Always set a meaningful `title`
                    - Set `tooltipSuffix` when data has units (USD, %, ms, kg, etc.)
                    - Use `stacking: "percent"` for part-to-whole comparisons across categories
                    - Keep series count ≤ 8 for readability
                    - For time series, put dates/times as `categories` on the x-axis
                    """,
                isBuiltIn: true,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast
            ),
        ]
    }
}

// MARK: - YAML Frontmatter Parsing

extension Skill {
    /// Parse a skill from markdown content with YAML frontmatter
    public static func parse(from markdown: String) throws -> Skill {
        let (frontmatter, body) = try extractFrontmatter(from: markdown)

        guard let name = frontmatter["name"] as? String, !name.isEmpty else {
            throw SkillParseError.missingRequiredField("name")
        }

        let id: UUID
        if let idString = frontmatter["id"] as? String, let parsedId = UUID(uuidString: idString) {
            id = parsedId
        } else {
            id = UUID()
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let createdAt: Date
        if let dateString = frontmatter["createdAt"] as? String,
            let parsed = dateFormatter.date(from: dateString)
        {
            createdAt = parsed
        } else {
            createdAt = Date()
        }

        let updatedAt: Date
        if let dateString = frontmatter["updatedAt"] as? String,
            let parsed = dateFormatter.date(from: dateString)
        {
            updatedAt = parsed
        } else {
            updatedAt = Date()
        }

        let keywords: [String]
        if let raw = frontmatter["keywords"] as? String, !raw.isEmpty {
            keywords = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            keywords = []
        }

        return Skill(
            id: id,
            name: name,
            description: frontmatter["description"] as? String ?? "",
            version: frontmatter["version"] as? String ?? "1.0.0",
            author: frontmatter["author"] as? String,
            category: frontmatter["category"] as? String,
            keywords: keywords,
            instructions: body.trimmingCharacters(in: .whitespacesAndNewlines),
            isBuiltIn: false,
            createdAt: createdAt,
            updatedAt: updatedAt,
            pluginId: frontmatter["pluginId"] as? String
        )
    }

    /// Convert skill to markdown with YAML frontmatter
    public func toMarkdown() -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var yaml = "---\n"
        yaml += "id: \"\(id.uuidString)\"\n"
        yaml += "name: \"\(escapeYamlString(name))\"\n"
        yaml += "description: \"\(escapeYamlString(description))\"\n"
        yaml += "version: \"\(version)\"\n"
        if let author = author {
            yaml += "author: \"\(escapeYamlString(author))\"\n"
        }
        if let category = category {
            yaml += "category: \"\(escapeYamlString(category))\"\n"
        }
        if !keywords.isEmpty {
            yaml += "keywords: \"\(keywords.joined(separator: ", "))\"\n"
        }
        if let pluginId = pluginId {
            yaml += "pluginId: \"\(escapeYamlString(pluginId))\"\n"
        }
        yaml += "createdAt: \"\(dateFormatter.string(from: createdAt))\"\n"
        yaml += "updatedAt: \"\(dateFormatter.string(from: updatedAt))\"\n"
        yaml += "---\n\n"
        yaml += instructions

        return yaml
    }

    /// Extract YAML frontmatter and body from markdown
    private static func extractFrontmatter(from markdown: String) throws -> ([String: Any], String) {
        guard let split = Self.splitFrontmatter(markdown) else {
            // Distinguish "no frontmatter at all" from "opened but never closed"
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.hasPrefix("---") {
                throw SkillParseError.noFrontmatter
            }
            throw SkillParseError.malformedFrontmatter
        }
        let frontmatter = parseYaml(split.frontmatterLines)
        return (frontmatter, split.body)
    }

    /// Splits a markdown document into its YAML frontmatter lines and body.
    /// Returns nil when no closing `---` is found. Returns an empty
    /// frontmatter when the document does not start with `---`.
    ///
    /// Exposed to other parsers in the module (e.g. the Claude plugin
    /// installer) so frontmatter parsing stays consistent across SKILL.md,
    /// agent and command markdown.
    static func splitFrontmatter(_ markdown: String) -> (frontmatterLines: [String], body: String)? {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else {
            return ([], normalized)
        }
        let lines = trimmed.components(separatedBy: "\n")
        var endIndex: Int?
        for (index, line) in lines.enumerated() where index > 0 {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                endIndex = index
                break
            }
        }
        guard let end = endIndex else { return nil }
        let frontmatterLines = Array(lines[1 ..< end])
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (frontmatterLines, body)
    }

    /// Run `parseYaml` against an arbitrary YAML block. Public-in-module so
    /// other parsers can reuse the same folded/literal scalar handling.
    static func parseYamlBlock(_ lines: [String]) -> [String: Any] {
        parseYaml(lines)
    }

    /// Simple YAML parser for frontmatter. Handles:
    /// - flat `key: value` pairs
    /// - nested objects (indented children)
    /// - folded (`>`) and literal (`|`) block scalars
    private static func parseYaml(_ lines: [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        var currentNestedKey: String?
        var nestedObject: [String: Any] = [:]

        var i = 0
        while i < lines.count {
            let rawLine = lines[i]
            let stripped = rawLine.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped.hasPrefix("#") {
                i += 1
                continue
            }

            let leadingSpaces = rawLine.prefix(while: { $0 == " " }).count

            guard let colonIndex = stripped.firstIndex(of: ":") else {
                i += 1
                continue
            }

            let key = String(stripped[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(stripped[stripped.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

            // Block scalar introducer (`>` or `|`) — consume continuation lines
            // that are indented strictly more than the parent key.
            if value == ">" || value == "|" {
                let folded = (value == ">")
                let baseIndent = leadingSpaces
                var collected: [String] = []
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    let nextTrim = next.trimmingCharacters(in: .whitespaces)
                    if nextTrim.isEmpty {
                        // Preserve paragraph breaks for `|`; for `>` empty
                        // lines also separate paragraphs (insert empty marker).
                        collected.append("")
                        i += 1
                        continue
                    }
                    let nextIndent = next.prefix(while: { $0 == " " }).count
                    if nextIndent <= baseIndent {
                        break
                    }
                    collected.append(nextTrim)
                    i += 1
                }
                let joined: String
                if folded {
                    // Folded: paragraphs separated by single newlines; lines
                    // inside a paragraph joined by spaces.
                    var paragraphs: [String] = []
                    var current: [String] = []
                    for piece in collected {
                        if piece.isEmpty {
                            if !current.isEmpty {
                                paragraphs.append(current.joined(separator: " "))
                                current = []
                            }
                        } else {
                            current.append(piece)
                        }
                    }
                    if !current.isEmpty {
                        paragraphs.append(current.joined(separator: " "))
                    }
                    joined = paragraphs.joined(separator: "\n")
                } else {
                    // Literal: preserve newlines verbatim, trim trailing blanks.
                    var trimmedTail = collected
                    while let last = trimmedTail.last, last.isEmpty {
                        trimmedTail.removeLast()
                    }
                    joined = trimmedTail.joined(separator: "\n")
                }

                if leadingSpaces >= 2 && currentNestedKey != nil {
                    nestedObject[key] = joined
                } else {
                    if let nestedKey = currentNestedKey, !nestedObject.isEmpty {
                        result[nestedKey] = nestedObject
                        nestedObject = [:]
                    }
                    currentNestedKey = nil
                    result[key] = joined
                }
                continue
            }

            // Check if this is a nested key (indented)
            if leadingSpaces >= 2 && currentNestedKey != nil {
                let parsedValue = parseYamlValue(value)
                nestedObject[key] = parsedValue
            } else {
                if let nestedKey = currentNestedKey, !nestedObject.isEmpty {
                    result[nestedKey] = nestedObject
                    nestedObject = [:]
                }

                if value.isEmpty {
                    currentNestedKey = key
                } else {
                    currentNestedKey = nil
                    result[key] = parseYamlValue(value)
                }
            }
            i += 1
        }

        if let nestedKey = currentNestedKey, !nestedObject.isEmpty {
            result[nestedKey] = nestedObject
        }

        return result
    }

    /// Parse a single YAML value
    private static func parseYamlValue(_ value: String) -> Any {
        var v = value

        // Remove quotes if present
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
            // Unescape quotes
            v = v.replacingOccurrences(of: "\\\"", with: "\"")
            v = v.replacingOccurrences(of: "\\'", with: "'")
        }

        // Parse booleans
        if v.lowercased() == "true" {
            return true
        } else if v.lowercased() == "false" {
            return false
        }

        return v
    }

    /// Escape special characters for YAML string
    private func escapeYamlString(_ string: String) -> String {
        return
            string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Errors

public enum SkillParseError: Error, LocalizedError {
    case noFrontmatter
    case malformedFrontmatter
    case missingRequiredField(String)

    public var errorDescription: String? {
        switch self {
        case .noFrontmatter:
            return "Skill file must start with YAML frontmatter (---)"
        case .malformedFrontmatter:
            return "Could not parse YAML frontmatter"
        case .missingRequiredField(let field):
            return "Missing required field: \(field)"
        }
    }
}

// MARK: - Export/Import Support

extension Skill {
    /// Export format for sharing skills
    public struct ExportData: Codable {
        public let version: Int
        public let skill: Skill

        public init(skill: Skill) {
            self.version = 1
            // Create a copy without built-in flag for export
            self.skill = Skill(
                id: UUID(),  // Generate new ID on export
                name: skill.name,
                description: skill.description,
                version: skill.version,
                author: skill.author,
                category: skill.category,
                keywords: skill.keywords,
                instructions: skill.instructions,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            )
        }
    }

    /// Export this skill to JSON data
    public func exportToJSON() throws -> Data {
        let exportData = ExportData(skill: self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(exportData)
    }

    /// Import a skill from JSON data
    public static func importFromJSON(_ data: Data) throws -> Skill {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exportData = try decoder.decode(ExportData.self, from: data)
        return exportData.skill
    }
}

// MARK: - Agent Skills Format Compatibility
// Compatible with https://agentskills.io/specification

extension Skill {
    /// Convert name to Agent Skills format (lowercase, hyphens)
    public var xplaceholder_agentSkillsNamex: String {
        let sanitized = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .joined()
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "skill-\(id.uuidString.prefix(8).lowercased())" : sanitized
    }

    /// Export to Agent Skills SKILL.md format
    /// Compatible with: https://agentskills.io/specification
    public func toAgentSkillsFormat() -> String {
        toAgentSkillsFormatInternal(includeId: false)
    }

    /// Export to Agent Skills format with internal ID for local storage
    public func toAgentSkillsFormatWithId() -> String {
        toAgentSkillsFormatInternal(includeId: true)
    }

    private func toAgentSkillsFormatInternal(includeId: Bool) -> String {
        var yaml = "---\n"
        yaml += "name: \(xplaceholder_agentSkillsNamex)\n"

        // Description is required, truncate to 1024 chars per spec
        let truncatedDesc = String(description.prefix(1024))
        yaml += "description: \(escapeAgentSkillsYaml(truncatedDesc))\n"

        // Metadata section
        yaml += "metadata:\n"
        if includeId {
            yaml += "  osaurus-id: \"\(id.uuidString)\"\n"
        }
        if let pluginId = pluginId {
            yaml += "  osaurus-plugin-id: \"\(pluginId)\"\n"
        }
        if let author = author {
            yaml += "  author: \(escapeAgentSkillsYaml(author))\n"
        }
        yaml += "  version: \"\(version)\"\n"
        if let category = category {
            yaml += "  category: \(escapeAgentSkillsYaml(category))\n"
        }
        if !keywords.isEmpty {
            yaml += "  keywords: \"\(keywords.joined(separator: ", "))\"\n"
        }

        yaml += "---\n\n"
        yaml += instructions

        return yaml
    }

    /// Parse from Agent Skills SKILL.md format
    /// Compatible with: https://agentskills.io/specification
    public static func parseAgentSkillsFormat(from markdown: String) throws -> Skill {
        let (frontmatter, body) = try extractFrontmatter(from: markdown)

        // Agent Skills format requires 'name' field
        guard let name = frontmatter["name"] as? String, !name.isEmpty else {
            throw SkillParseError.missingRequiredField("name")
        }

        // Description is required in Agent Skills format
        let description = frontmatter["description"] as? String ?? ""

        // Extract metadata if present
        var author: String?
        var version = "1.0.0"
        var category: String?
        var keywords: [String] = []
        var osaurusId: UUID?
        var pluginId: String?

        if let metadata = frontmatter["metadata"] as? [String: Any] {
            author = metadata["author"] as? String
            version = metadata["version"] as? String ?? "1.0.0"
            category = metadata["category"] as? String
            if let raw = metadata["keywords"] as? String, !raw.isEmpty {
                keywords = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }

            // Osaurus-specific metadata
            if let idString = metadata["osaurus-id"] as? String {
                osaurusId = UUID(uuidString: idString)
            }
            // Legacy `osaurus-enabled` metadata is intentionally ignored:
            // installed skills are always available.
            pluginId = metadata["osaurus-plugin-id"] as? String
        }

        // Convert Agent Skills name (lowercase-hyphen) to display name (Title Case)
        let displayName =
            name
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")

        return Skill(
            id: osaurusId ?? UUID(),
            name: displayName,
            description: description,
            version: version,
            author: author,
            category: category,
            keywords: keywords,
            instructions: body.trimmingCharacters(in: .whitespacesAndNewlines),
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date(),
            pluginId: pluginId
        )
    }

    /// Check if markdown content is in Agent Skills format
    public static func isAgentSkillsFormat(_ markdown: String) -> Bool {
        guard let (frontmatter, _) = try? extractFrontmatter(from: markdown) else {
            return false
        }
        // Agent Skills format has 'name' but no 'id' field
        let hasName = frontmatter["name"] != nil
        let hasId = frontmatter["id"] != nil
        return hasName && !hasId
    }

    /// Parse from either Osaurus or Agent Skills format (auto-detect)
    public static func parseAnyFormat(from markdown: String) throws -> Skill {
        if isAgentSkillsFormat(markdown) {
            return try parseAgentSkillsFormat(from: markdown)
        } else {
            return try parse(from: markdown)
        }
    }

    /// Escape string for Agent Skills YAML format
    private func escapeAgentSkillsYaml(_ string: String) -> String {
        // If string contains special chars, wrap in quotes
        let needsQuotes =
            string.contains(":") || string.contains("#") || string.contains("\"") || string.contains("'")
            || string.contains("\n") || string.hasPrefix(" ") || string.hasSuffix(" ")

        if needsQuotes {
            let escaped =
                string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        }
        return string
    }
}
