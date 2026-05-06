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

        Your current tool list is the relevant subset for this task. If you \
        need a capability that is not listed, grow the list in two steps:

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

    // MARK: - Sandbox

    /// Renders the sandbox section. Code style + risk-aware actions are
    /// NOT included here — they live as top-level sections gated on
    /// file-mutation tools being in the schema, so folder-mode agents
    /// doing real edits get the same discipline.
    public static func sandbox(secretNames: [String] = []) -> String {
        var section = """

            \(sandboxSectionHeading)

            \(sandboxEnvironmentBlock)
            Files persist across messages.

            \(sandboxToolGuide)

            \(sandboxRuntimeHints)

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

    private static let sandboxEnvironmentBlock = """
        You have access to an isolated Linux sandbox (Alpine Linux, ARM64). \
        Your workspace is your home directory inside the sandbox.

        You have full internet access in the sandbox. Use `curl`, `wget`, \
        Python `requests`, or Node `fetch` for live data; prefer fetched \
        data over generated placeholders.

        Pre-installed: bash, python3, node, git, curl, wget, jq, ripgrep (rg), \
        sqlite3, build-base (gcc/make), cmake, vim, tree, and standard POSIX utilities.
        """

    private static let sandboxToolGuide = """
        Tool dispatch (each tool's description has full detail and the \
        shell pattern it replaces):
        - File IO: `sandbox_read_file` to read, `sandbox_write_file` to create or rewrite, `sandbox_edit_file` for targeted in-place edits.
        - Search: `sandbox_search_files` (`target="content"` for ripgrep, `target="files"` for filename glob).
        - Shell: `sandbox_exec` for builds, installs, git, processes, network calls. Pass `background:true` for servers; track with `sandbox_process`.
        - Python orchestration: `sandbox_execute_code` for 3+ calls with logic between them. Helpers: `from osaurus_tools import read_file, write_file, edit_file, search_files, terminal`.
        - Issue independent calls in parallel; chain dependent shell steps with `&&` inside one `sandbox_exec`.
        """

    private static let sandboxRuntimeHints = """
        Runtime hints:
        - Python deps: `sandbox_pip_install` — e.g. `{"packages": ["numpy"]}`.
        - Node deps: `sandbox_npm_install` — e.g. `{"packages": ["express"]}`.
        - System packages: `sandbox_install` — e.g. `{"packages": ["ffmpeg"]}`.
        - Use \(sandboxReadFileHint) to inspect large logs.
        - The sandbox is disposable — experiment freely.
        """

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
        - Layout: `file_tree` to list directory structure.
        - Search: `file_search` for content (case-insensitive substring match).
        - Read: `file_read` to inspect a file (optional line range).
        - Edit: `file_edit` for targeted in-place edits, `file_write` for new files or full rewrites.
        - Shell: `shell_run` for `mv` / `cp` / `rm` / `mkdir` (write/exec ops are logged and undoable).
        """

    /// Folder-mode-specific reminder: filesystem changes ARE visible to
    /// the user (unlike sandbox), but only `share_artifact` surfaces an
    /// artifact card in the chat thread.
    static let folderArtifactReminder = """
        **Files land in the working folder, not in chat.** When you create or edit a file with `file_write` / `file_edit`, the user can see it on disk and in the operations log. If the user needs the deliverable to appear in the chat thread (an image, chart, generated text, report, code blob), additionally call `share_artifact` — it's the only thing that surfaces an artifact card.
        """

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
