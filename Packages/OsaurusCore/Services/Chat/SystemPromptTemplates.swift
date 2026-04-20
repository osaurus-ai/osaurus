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

    /// Default identity used when the user has not configured a base prompt.
    /// Frames the agent as tool-driven so models don't reflexively say
    /// "I cannot do that" when they actually can.
    public static let defaultIdentity = """
        You are an Osaurus chat agent running locally on the user's Mac.

        You have a tool registry. Call tools when they raise correctness or \
        ground a claim in real data; do not narrate intent before acting. \
        When the task involves more than two obvious steps, write a `todo` \
        checklist; when you finish, call `complete` with a one-paragraph \
        summary of what you did and how you verified it.
        """

    /// Returns the effective base prompt, falling back to `defaultIdentity`
    /// when the user has not configured one.
    public static func effectiveBasePrompt(_ basePrompt: String) -> String {
        let trimmed = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultIdentity : trimmed
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
        - `share_artifact(...)` — the only way the user sees a generated image, chart, report, code blob, or any file. Writing to disk or returning content in the chat does not surface an artifact card.
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

    /// Code-style discipline injected into the sandbox section.
    public static let codeStyleGuidance = """
        Code style:
        - Limit changes to what was requested — a bug fix does not warrant adjacent refactoring or style cleanup.
        - Do not add defensive error handling, fallback logic, or input validation for conditions that cannot arise in the current code path.
        - Do not extract helpers or utilities for logic that appears only once.
        - Only add comments when reasoning is genuinely non-obvious — never narrate what the code does.
        - Do not add docstrings, comments, or type annotations to code you did not modify.
        """

    // MARK: - Sandbox

    public static func sandbox(compact: Bool, secretNames: [String] = []) -> String {
        chatSandboxSection(compact: compact, secretNames: secretNames)
    }

    // MARK: Chat sandbox

    private static func chatSandboxSection(compact: Bool, secretNames: [String]) -> String {
        let env = compact ? sandboxEnvironmentBlockCompact : sandboxEnvironmentBlock
        let tools = compact ? sandboxToolGuideCompact : sandboxToolGuide
        let hints = compact ? sandboxRuntimeHintsCompact : sandboxRuntimeHints
        var section = """

            \(sandboxSectionHeading)

            \(env)
            Files persist across messages.

            \(tools)

            \(hints)

            """
        if !compact {
            section += """
                \(sandboxCodeStyle)

                \(sandboxRiskGuidance)

                """
        }
        section += secretsPromptBlock(secretNames)
        return section
    }

    // MARK: - Sandbox Building Blocks

    static let sandboxSectionHeading = "## Linux Sandbox Environment"
    static let sandboxReadFileHint =
        "`sandbox_read_file` with `start_line`/`line_count`/`tail_lines`"

    private static let sandboxEnvironmentBlock = """
        You have access to an isolated Linux sandbox (Alpine Linux, ARM64). \
        Your workspace is your home directory inside the sandbox.

        **IMPORTANT — You have full internet access in this sandbox.** You can \
        use `curl`, `wget`, Python `requests`/`urllib`, Node `fetch`, or any \
        HTTP client to call external APIs, download files, and fetch live data. \
        Do NOT say you lack internet access or cannot reach external services — \
        you can. Always prefer fetching real data over generating fake/placeholder data.

        Pre-installed: bash, python3, node, git, curl, wget, jq, ripgrep (rg), \
        sqlite3, build-base (gcc/make), cmake, vim, tree, and standard POSIX utilities.
        """

    private static let sandboxEnvironmentBlockCompact = """
        Isolated Linux sandbox (Alpine, ARM64). Home dir is your workspace. \
        **You have full internet access.** Use `curl`, Python `requests`, or \
        Node `fetch` to call APIs and download data. Do NOT claim you lack \
        internet — always fetch real data. \
        Pre-installed: bash, python3, node, git, curl, jq, rg, sqlite3, gcc/make, cmake.
        """

    private static let sandboxToolGuide = """
        Tool usage:
        - Read before edit: `sandbox_read_file` first; never modify code you have not inspected.
        - Edit with `sandbox_edit_file` (old_string -> new_string); prefer it over rewriting whole files.
        - `sandbox_write_file` is for new files or complete rewrites only.
        - Find files by name pattern with `sandbox_find_files` (e.g. `*.py`); search file contents with `sandbox_search_files` (ripgrep regex).
        - `sandbox_list_directory` with `recursive: true` for a project-structure overview.
        - For commands: `sandbox_run_script` for multi-line python/bash/node, `sandbox_exec` for single shell commands, `sandbox_exec_background` for servers and watchers.
        - Set `timeout` for long operations (default 60s scripts, 30s exec, max 300s).
        - Always use the dedicated tools instead of shell equivalents: `sandbox_read_file` not `cat`, `sandbox_edit_file` not `sed`, `sandbox_find_files` not `find`.
        - Issue independent tool calls in parallel.
        - Anything you generate inside the sandbox stays in the sandbox unless you also call `share_artifact` — that's the only path to the chat thread.
        """

    private static let sandboxToolGuideCompact = """
        Tools: `sandbox_read_file` before editing. `sandbox_edit_file` for targeted edits (old_string/new_string) — prefer over full rewrites. `sandbox_write_file` for new files. \
        `sandbox_find_files` for name patterns, `sandbox_search_files` for content. `sandbox_list_directory` for layout. \
        `sandbox_run_script` for multi-line scripts; `sandbox_exec` for single commands; `sandbox_exec_background` for servers. \
        Use `share_artifact` to surface anything to the user (the chat does not show sandbox files directly).
        """

    /// Sandbox section reuses the canonical code-style block exposed at
    /// the top of this file so updates propagate to both surfaces.
    private static let sandboxCodeStyle = codeStyleGuidance

    private static let sandboxRiskGuidance = """
        Risk-aware actions:
        - Local, reversible actions (editing a file, running a test) — proceed without hesitation.
        - Destructive or hard-to-undo actions (deleting files, `rm -rf`, dropping data) — confirm with the user first.
        - When encountering unexpected state (unfamiliar files, unknown processes), investigate before removing anything.
        """

    private static let sandboxRuntimeHints = """
        Runtime hints:
        - Python deps: `sandbox_pip_install` — e.g. `{"packages": ["numpy"]}`.
        - Node deps: `sandbox_npm_install` — e.g. `{"packages": ["express"]}`.
        - System packages: `sandbox_install` — e.g. `{"packages": ["ffmpeg"]}`.
        - Use \(sandboxReadFileHint) to inspect large logs.
        - The sandbox is disposable — experiment freely.
        """

    private static let sandboxRuntimeHintsCompact = """
        `sandbox_pip_install` for Python, `sandbox_npm_install` for Node, `sandbox_install` for system packages.
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
    /// is mounted on a host folder (`ExecutionMode.hostFolder`). Carries
    /// the path, project type, top-level layout, optional git status,
    /// usage guidance, and any project-level context file
    /// (AGENTS.md / CLAUDE.md / .hermes.md / .cursorrules) loaded at
    /// folder-mount time. Returns `""` when no folder is mounted so the
    /// composer can append unconditionally.
    public static func folderContext(from folderContext: FolderContext?) -> String {
        guard let folder = folderContext else { return "" }

        let topLevel = buildTopLevelSummary(from: folder.tree)
        let gitBlock =
            folder.gitStatus.flatMap { status -> String? in
                let trimmed = String(status.prefix(300))
                guard !trimmed.isEmpty else { return nil }
                return "\n**Git status (uncommitted changes):**\n```\n\(trimmed)\n```\n"
            } ?? ""

        var section = """

            ## Working Directory
            **Path:** \(folder.rootPath.path)
            **Project Type:** \(folder.projectType.displayName)
            **Root contents:** \(topLevel)
            \(gitBlock)
            **Path arguments are relative to the Working Directory** — pass `README.md`, `src/app.py`, `docs/intro.md`. Absolute paths are rejected as a security boundary, even ones that point inside the directory. The path above is for orientation when you describe the project to the user, not for tool calls.

            Tool recipe:
            - Layout: `file_tree` for the directory structure (skips hidden + truncates at 300 entries).
            - Discovery: `file_search` for content (ripgrep), or read individual files with `file_read`.
            - Edits: `file_edit` for targeted (old_string -> new_string) changes; `file_write` for new files or full rewrites; always read a file before editing it.
            - Mutations: `file_move` / `file_copy` / `file_delete` / `dir_create` for filesystem changes. All write/exec operations are logged and undoable.
            - Multi-step work: take the next concrete action each turn — read, write, run. Don't narrate intent; just do the thing.

            **Files land in the working folder, not in chat.** When you create or edit a file with `file_write` / `file_edit`, the user can see it on disk and in the operations log. If the user needs the deliverable to appear in the chat thread (an image, chart, generated text, report, code blob), additionally call `share_artifact` — it's the only thing that surfaces an artifact card.

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

    // MARK: - Model Classification

    /// Returns true when the model identifier refers to a local model
    /// (Foundation or MLX) that benefits from shorter/compact prompts.
    public static func isLocalModel(_ modelId: String?) -> Bool {
        let trimmed = (modelId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "default" || trimmed == "foundation" {
            return true
        }
        if trimmed.contains("/") {
            return false
        }
        return ModelManager.findInstalledModel(named: trimmed) != nil
    }
}
