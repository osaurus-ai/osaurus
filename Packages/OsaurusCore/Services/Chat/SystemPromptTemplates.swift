//
//  SystemPromptTemplates.swift
//  osaurus
//
//  Centralized repository of all system prompt text. Every instruction
//  string sent to the model should be defined here so the full prompt
//  surface can be viewed, compared, and tuned in a single file.
//

import Foundation

public enum SystemPromptTemplates {

    // MARK: - Identity

    /// Platform framing — emitted unconditionally as a stable, non-customizable
    /// section ahead of the user's persona. Tells the model where it's
    /// running so a custom persona doesn't accidentally erase that context.
    /// Names no tools (see `defaultPersona` for why).
    public static let platformIdentity =
        "You are an Osaurus chat agent running locally on the user's Mac."

    /// Default persona used when the user has not configured a custom one.
    /// Frames the agent as tool-driven so models don't reflexively say
    /// "I cannot do that" when they actually can. Behavior-only — platform
    /// framing lives separately in `platformIdentity`.
    ///
    /// **Tool names are deliberately NOT mentioned here.** Naming `todo` /
    /// `complete` / `share_artifact` / `clarify` / `capabilities_search`
    /// in the unconditional persona caused MiniMax M2.7 Small JANGTQ
    /// (and other low-bit MoE models) to fall into a recitation loop on
    /// any chat where those tools weren't actually in the request's
    /// `tools[]` array — the model saw the names in the system prompt,
    /// expected the schema to back them, found a mismatch, and degenerated
    /// into emitting tool-spec text from its training distribution
    /// (live-confirmed 2026-04-25).
    ///
    /// Each chat-layer-intercepted tool's how-to lives in the gated
    /// `agentLoopGuidance` / `capabilityDiscoveryNudge` blocks below,
    /// which fire ONLY when the corresponding tool is actually resolved
    /// into the schema. Sandbox-/folder-tool hints are similarly gated
    /// at their composer call-sites.
    public static let defaultPersona = """
        Use the tools available in this conversation when they raise \
        correctness or ground a claim in real data; do not narrate intent \
        before acting. If no tools are listed, answer directly from your \
        own knowledge.
        """

    /// Returns the effective persona, falling back to `defaultPersona`
    /// when the user has not configured one.
    public static func effectivePersona(_ basePrompt: String) -> String {
        let trimmed = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultPersona : trimmed
    }

    // MARK: - Agent Loop

    /// Cheat-sheet for the four chat-layer-intercepted tools (`todo`,
    /// `complete`, `clarify`, `share_artifact`). Injected when any of
    /// those names is in the resolved schema. Tool descriptions carry
    /// the detail; this is the one-line "when to call which" reminder.
    public static let agentLoopGuidance = """
        ## Agent loop

        - `todo(markdown)` — write or replace the user-visible task list. Use it when the request has 3+ obvious steps; skip for trivial work. Each call replaces the whole list, so to mark items done re-send the full list with the new boxes.
        - `complete(summary)` — call once at the very end (never alongside other tools) with WHAT you did + HOW you verified it. Vague placeholders ("done", "looks good") are rejected; partial work should be reported honestly.
        - `clarify(question)` — pause and ask exactly one concrete question only when guessing wrong would change the result. For minor preferences pick a sensible default and proceed.
        - `share_artifact(...)` — the only way the user sees a generated image, chart, report, code blob, or any file. **The file MUST exist before this call.** Sandbox: save under your home dir (default cwd) — files in `/tmp` won't be findable. If unsure where you wrote it, verify with `sandbox_search_files(target="files", pattern="<name>")` first. For inline text/markdown, use `content`+`filename` mode and skip the file write entirely. **When using `sandbox_execute_code`, call `share_artifact` from the model layer AFTER the script returns — the helper module does not expose it because in-script calls would silently fail to render the artifact card.**
        """

    // MARK: - Capability Discovery Nudge

    /// Static guidance appended to the system prompt when `capabilities_search`
    /// / `capabilities_load` are in the active tool set (auto-selection mode).
    /// Tells the model how to recover when its current tool kit is missing
    /// something instead of inventing tool names — works hand-in-hand with
    /// the `toolNotFound` self-heal envelope returned by `ToolRegistry`.
    public static let capabilityDiscoveryNudge = """
        ## Discovering more tools

        Your current tool list was pre-selected for this session from your \
        request and the contents of your working directory. It is a starting \
        set, not an exhaustive one. If you need a capability that is not \
        listed, grow the list in two steps:

        1. `capabilities_search({"query": "<what you need>"})` — returns \
        IDs like `tool/sandbox_exec` or `skill/plot-data`.
        2. `capabilities_load({"ids": ["tool/sandbox_exec"]})` — adds \
        those tools to your schema for the rest of this session.

        Do not invent tool names — the search step is the source of truth.
        """

    // MARK: - Cross-cutting Engineering Discipline

    /// General code-style discipline. Injected into the system prompt
    /// whenever any file-mutation tool (sandbox or folder) is in the
    /// resolved schema. Not sandbox-specific — folder-mode agents doing
    /// real edits get the same guardrails.
    public static let codeStyleGuidance = """
        ## Code style

        - Limit changes to what was requested — a bug fix does not warrant adjacent refactoring or style cleanup.
        - Do not add defensive error handling, fallback logic, or input validation for conditions that cannot arise in the current code path.
        - Do not extract helpers or utilities for logic that appears only once.
        - Only add comments when reasoning is genuinely non-obvious — never narrate what the code does.
        - Do not add docstrings, comments, or type annotations to code you did not modify.
        """

    /// Risk-aware action discipline. Same gate as `codeStyleGuidance` —
    /// fires whenever the schema includes a tool that can mutate the
    /// user's filesystem or run arbitrary code (sandbox or folder).
    public static let riskAwareGuidance = """
        ## Risk-aware actions

        - Local, reversible actions (editing a file, running a test) — proceed without hesitation.
        - Destructive or hard-to-undo actions (deleting files, `rm -rf`, dropping data) — confirm with the user first.
        - When encountering unexpected state (unfamiliar files, unknown processes), investigate before removing anything.
        """

    // MARK: - Soul

    /// Renders the SOUL section — agent-authored, sandbox-only identity
    /// layer that complements the user-authored persona slot. Frames the
    /// content as the agent's own notes and explicitly tells the model
    /// that earlier sections (i.e. persona) take precedence on conflict.
    ///
    /// Returns `""` when `content` trims to empty so the composer's
    /// existing `PromptSection.isEmpty` filter drops the section without
    /// the caller having to second-guess the gate.
    ///
    /// Size policy (truncate at 8 KB on a line boundary) lives at the
    /// read site in `SystemPromptComposer.resolveSoul` — keeping the
    /// renderer pure means PR2's bootstrap seed and PR3's advert can
    /// reuse `soulSection` without dragging in I/O.
    public static func soulSection(_ content: String) -> String {
        let trimmed = stripLeadingSoulHeading(content.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return "" }
        return """
            ## SOUL

            The agent has recorded the following stable preferences and patterns \
            across prior sessions. These are the agent's own notes; the user's \
            instructions in earlier sections take precedence. Any plugin or tool \
            named in these notes is NOT automatically callable — bring it into \
            your schema with `capabilities_search` / `capabilities_load` before \
            invoking it.

            \(trimmed)
            """
    }

    /// The seeded `~/SOUL.md` (and many hand-edited ones) begin with their own
    /// `# SOUL` title. Since `soulSection` already emits a `## SOUL` heading,
    /// keeping the file's title would render the heading twice. Strip a single
    /// leading markdown heading whose text is exactly "SOUL" (any `#` depth).
    private static func stripLeadingSoulHeading(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix("#") else { return content }
        let headingText = first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        guard headingText.caseInsensitiveCompare("SOUL") == .orderedSame else { return content }
        lines.removeFirst()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sandbox

    /// Renders the sandbox section. Code style + risk-aware actions are
    /// NOT included here — they live as top-level sections gated on
    /// file-mutation tools being in the schema, so folder-mode agents
    /// doing real edits get the same discipline.
    public static func sandbox(secretNames: [String] = [], hostReadCombined: Bool = false) -> String {
        var section = """

            \(sandboxSectionHeading)

            \(sandboxEnvironmentBlock)
            Files persist across messages.

            \(hostReadCombined ? sandboxToolGuideCombined : sandboxToolGuide)

            \(sandboxRuntimeHints(hostReadCombined: hostReadCombined))

            """
        // The runtime hints block ends with a single `\n`; the secrets
        // block is its own logical subsection, so prepend a blank-line
        // separator instead of having it run on as a sixth bullet.
        let secrets = secretsPromptBlock(secretNames)
        if !secrets.isEmpty {
            section += "\n" + secrets
        }
        return section
    }

    // MARK: - Sandbox Building Blocks

    static let sandboxSectionHeading = "## Linux Sandbox Environment"
    static let sandboxReadFileHint =
        "`sandbox_read_file` with `start_line`/`line_count`/`tail_lines`"

    /// Combined-mode log-read hint: `sandbox_read_file` is hidden in
    /// combined mode (the unified `file_read` reaches `/workspace/...`),
    /// so point the model at `file_read` with `tail_lines` instead of a
    /// tool it can't call.
    static let sandboxReadFileHintCombined =
        "`file_read` with `tail_lines` (works on `/workspace/...` sandbox paths too)"

    private static let sandboxEnvironmentBlock = """
        You have an isolated Alpine Linux ARM64 sandbox. Your home directory \
        (`~`) is your sandbox home; files persist across messages.

        Internet access is available. Use `curl`, `wget`, Python `requests`, \
        or Node `fetch` for live data; prefer fetched data over placeholders.

        Installed: bash, python3, node, git, curl, wget, jq, rg, sqlite3, \
        build-base, cmake, vim, tree, and standard POSIX utilities.
        """

    private static let sandboxToolGuide = """
        Tool dispatch:
        - Files: `sandbox_read_file` (read/list); `sandbox_write_file` (`content` whole-file, or `old_string`+`new_string` to edit).
        - Search: `sandbox_search_files` with `target="content"` or `target="files"`.
        - Shell: `sandbox_exec` for single-line shell; use `background:true` for servers and `sandbox_process` to inspect them.
        - Python: `sandbox_execute_code` (runs Python directly) with `osaurus_tools` helpers (`read_file`, `write_file`, `edit_file`, `search_files`, `terminal`) — the default for ANY Python.
        - NEVER embed multi-line code in `python3 -c` / `node -e`: the JSON→shell→code escaping breaks. Use `sandbox_execute_code`, or `sandbox_write_file` the script then run the file.
        - Run independent calls in parallel; chain dependent shell steps with `&&`.
        """

    /// Combined-mode (`.sandbox(hostRead:)`) variant: the host `file_*`
    /// tools are the single, path-routed read family, so reads/lists/searches
    /// are NOT done with `sandbox_read_file` / `sandbox_search_files` (hidden
    /// in this mode). The `## Files` block spells out the path routing.
    private static let sandboxToolGuideCombined = """
        Tool dispatch:
        - Read files / list dirs / search: `file_read` (reads a file or lists a directory — the path decides), `file_search` (they reach both your workspace and `/workspace/...` sandbox paths — see `## Files`).
        - Sandbox writes: `sandbox_write_file` (pass `content` to write the whole file, or `old_string`+`new_string` to edit one match — your workspace is read-only).
        - Shell: `sandbox_exec` for single-line shell; use `background:true` for servers and `sandbox_process` to inspect them.
        - Python: `sandbox_execute_code` (runs Python directly) with `osaurus_tools` helpers (`read_file`, `write_file`, `edit_file`, `search_files`, `terminal`) — the default for ANY Python.
        - NEVER embed multi-line code in `python3 -c` / `node -e`: the JSON→shell→code escaping breaks. Use `sandbox_execute_code`, or `sandbox_write_file` the script then run the file.
        - Run independent calls in parallel; chain dependent shell steps with `&&`.
        """

    /// Runtime hints block. In combined mode the log-read hint points at
    /// `file_read` (the unified read tool) rather than the hidden
    /// `sandbox_read_file`, so the model is never steered toward a tool
    /// it can't see in this mode.
    private static func sandboxRuntimeHints(hostReadCombined: Bool) -> String {
        let logReadHint = hostReadCombined ? sandboxReadFileHintCombined : sandboxReadFileHint
        return """
            Runtime hints:
            - Install Python, Node, or system deps with `sandbox_pip_install`, `sandbox_npm_install`, or `sandbox_install`.
            - Use \(logReadHint) to inspect large logs.
            - The sandbox is disposable; experiment freely.
            - Your `SOUL.md` at `~/SOUL.md` records stable preferences across sessions. Edit it with `sandbox_write_file` when you observe a durable pattern; edits apply on the next session.
            """
    }

    private static func secretsPromptBlock(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        let list = names.sorted().map { "- `\($0)`" }.joined(separator: "\n")
        return """
            Configured secrets (available as environment variables):
            \(list)
            Access via `$NAME` in shell, `os.environ["NAME"]` in Python, or `process.env.NAME` in Node.

            """
    }

    // MARK: - Folder Context

    /// Working-directory framing appended to the system prompt when chat
    /// is mounted on a host folder (`ExecutionMode.hostFolder`). Mirrors
    /// the sandbox section's structure: heading + environment metadata +
    /// path rule + tool dispatch + mode-specific framing + optional
    /// project context. Returns `""` when no folder is mounted so the
    /// composer can append unconditionally.
    public static func folderContext(from folderContext: FolderContext?) -> String {
        guard let folder = folderContext else { return "" }

        var lines: [String] = ["## Working Directory"]
        lines.append("**Path:** \(folder.rootPath.path)")
        if folder.projectType != .unknown {
            lines.append("**Project Type:** \(folder.projectType.displayName)")
        }
        let topLevel = buildTopLevelSummary(from: folder.tree)
        if !topLevel.isEmpty {
            lines.append("**Root contents:** \(topLevel)")
        }
        var section = "\n" + lines.joined(separator: "\n") + "\n"

        if let status = folder.gitStatus {
            let trimmed = String(status.prefix(300))
            if !trimmed.isEmpty {
                section += "\n**Git status (uncommitted changes):**\n```\n\(trimmed)\n```\n"
            }
        }

        section += """

            \(folderPathRule)

            \(folderToolGuide)

            \(folderArtifactReminder)

            """

        // Project-level guidance file (first-found-wins across AGENTS.md,
        // CLAUDE.md, .hermes.md, .cursorrules). Loaded once at folder-mount
        // time and stamped onto the FolderContext so it lives in the static
        // prefix and doesn't break KV-cache reuse across turns. Capped at
        // 20K chars with head+tail truncation by FolderContextService.
        if let contextFiles = folder.contextFiles, !contextFiles.isEmpty {
            section += """

                ## Project Context

                The following project context file has been loaded and should be followed:

                \(contextFiles)

                """
        }

        return section
    }

    // MARK: - Folder Building Blocks

    /// One-line restatement of the path-arg rule. Each `file_*` tool's
    /// description carries the per-arg detail; this lives in the prompt
    /// so the rule is anchored once at the top of the section instead of
    /// repeated in every dispatch bullet.
    static let folderPathRule =
        "Tool paths are relative to the working directory; absolute paths are rejected."

    /// Positive dispatch table for the folder-mode tools. Mirror of
    /// `sandboxToolGuide` — discipline ("instead of cat / sed / awk")
    /// lives in each tool's description.
    static let folderToolGuide = """
        Tool dispatch (each tool's description has full detail and the \
        shell pattern it replaces):
        - Read / list: `file_read` to read a file or list a directory — the path decides (optional line range, or `max_depth` for a directory).
        - Search: `file_search` for content (case-insensitive substring match).
        - Edit: `file_edit` for targeted in-place edits, `file_write` for new files or full rewrites.
        - Shell: `shell_run` for `mv` / `cp` / `rm` / `mkdir` (write/exec ops are logged and undoable).
        """

    /// Folder-mode-specific reminder: filesystem changes ARE visible to
    /// the user (unlike sandbox), but only `share_artifact` surfaces an
    /// artifact card in the chat thread.
    static let folderArtifactReminder = """
        **Files land in the working folder, not in chat.** When you create or edit a file with `file_write` / `file_edit`, the user can see it on disk and in the operations log. If the user needs the deliverable to appear in the chat thread (an image, chart, generated text, report, code blob), additionally call `share_artifact` — it's the only thing that surfaces an artifact card.
        """

    // MARK: - Combined Sandbox + Host-Read

    /// Read-only host-workspace framing for combined mode
    /// (`ExecutionMode.sandbox(hostRead: ctx)`). Rendered AFTER the
    /// sandbox section so the agent reads the sandbox framing first,
    /// then learns the host workspace is a separate, read-only
    /// filesystem. Unlike `folderContext` this marks the workspace
    /// read-only, lists only the read tools, and appends the
    /// two-filesystem block. Returns "" when no host-read folder is
    /// attached so the composer can append unconditionally.
    public static func combinedHostRead(
        from folderContext: FolderContext?,
        allowSecretReads: Bool = false
    ) -> String {
        guard let folder = folderContext else { return "" }

        var lines: [String] = ["## Host Workspace (read-only)"]
        lines.append("**Path:** \(folder.rootPath.path)")
        if folder.projectType != .unknown {
            lines.append("**Project Type:** \(folder.projectType.displayName)")
        }
        let topLevel = buildTopLevelSummary(from: folder.tree)
        if !topLevel.isEmpty {
            lines.append("**Root contents:** \(topLevel)")
        }
        var section = "\n" + lines.joined(separator: "\n") + "\n"

        if let status = folder.gitStatus {
            let trimmed = String(status.prefix(300))
            if !trimmed.isEmpty {
                section += "\n**Git status (uncommitted changes):**\n```\n\(trimmed)\n```\n"
            }
        }

        section += """

            \(unifiedFilesBlock(allowSecretReads: allowSecretReads))

            """

        // Same project-context file the folder section surfaces, loaded
        // once at folder-mount time so it lives in the static prefix.
        if let contextFiles = folder.contextFiles, !contextFiles.isEmpty {
            section += """

                ## Project Context

                The following project context file has been loaded and should be followed:

                \(contextFiles)

                """
        }

        return section
    }

    /// The load-bearing mental model for combined mode under the unified,
    /// path-routed file tools: ONE reader (`file_read`, which also lists
    /// directories) and ONE search tool (`file_search`) reach two storage
    /// areas by path — the read-only workspace (default) and the
    /// `/workspace/...` sandbox scratch area; one writer
    /// (`sandbox_write_file`, which also edits) targets the sandbox. This
    /// replaces the older `## Two filesystems` framing that asked the model
    /// to pick between `file_*` and `sandbox_*` read families (the
    /// disambiguation weak models kept getting wrong). The final sentence
    /// reflects the per-agent secret-read setting.
    static func unifiedFilesBlock(allowSecretReads: Bool) -> String {
        let secretLine =
            allowSecretReads
            ? "Workspace secret files (`.env`, keys, credentials) are readable because you enabled secret reads — handle them carefully and never copy them into the sandbox or off-host."
            : "Workspace secret files (`.env`, keys, credentials) are refused."
        return """
            ## Files

            One reader and one search tool reach two storage areas by path:
            - **Workspace** (your read-only host folder) — the default. For "what's in my workspace / on my Desktop", use `file_read` (it reads a file or lists a directory) and `file_search`. Relative paths and `/Users/...` paths are the workspace.
            - **Sandbox** scratch area — pass a `/workspace/...` path to the SAME `file_read` / `file_search`.

            The workspace is read-only: create or change files with `sandbox_write_file` (pass `content` to write the whole file, or `old_string`+`new_string` to edit one match — it writes the sandbox), and run commands with `sandbox_exec` / `sandbox_execute_code` (they run in the sandbox, which has no copy of the workspace — `file_read` a workspace file and pass its content in if a command needs it). Surface results with `share_artifact`. \(secretLine)
            """
    }

    private static func buildTopLevelSummary(from tree: String) -> String {
        let lines = tree.components(separatedBy: .newlines)
        let topLevel = lines.compactMap { line -> String? in
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return nil }
            let treeChars = CharacterSet(charactersIn: "│├└─ \u{00A0}")
            let indentPrefix = line.prefix(while: { char in
                char.unicodeScalars.allSatisfy { treeChars.contains($0) }
            })
            guard indentPrefix.count <= 4 else { return nil }
            return stripped.trimmingCharacters(in: treeChars)
        }
        .filter { !$0.isEmpty }

        if topLevel.count <= 8 {
            return topLevel.joined(separator: ", ")
        }
        let shown = topLevel.prefix(6)
        return shown.joined(separator: ", ") + ", and \(topLevel.count - 6) other items"
    }

}
