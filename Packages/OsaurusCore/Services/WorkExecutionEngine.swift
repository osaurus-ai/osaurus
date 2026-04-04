//
//  WorkExecutionEngine.swift
//  osaurus
//
//  Execution engine for Osaurus Agents - reasoning loop based.
//  Handles iterative task execution where model decides actions.
//

import Foundation

/// Execution engine for running work tasks via reasoning loop
public actor WorkExecutionEngine {
    /// The chat engine for LLM calls (lazily resolved to snapshot remote services)
    private var _chatEngine: ChatEngineProtocol?

    init(chatEngine: ChatEngineProtocol? = nil) {
        self._chatEngine = chatEngine
    }

    private func resolvedChatEngine() async -> ChatEngineProtocol {
        if let engine = _chatEngine { return engine }
        let engine = ChatEngine(source: .chatUI)
        _chatEngine = engine
        return engine
    }

    // MARK: - Prompt Constants

    static let truncationOmissionMarker = "characters omitted"
    static let sandboxSectionHeading = "## Linux Sandbox Environment"
    static let sandboxScaffoldGuidance = "Prefer one `sandbox_run_script` to scaffold or bulk-edit multiple files"
    static let sandboxVerifyGuidance = "Run tests or verification commands with `sandbox_exec`"
    static let sandboxReadFileHint = "`sandbox_read_file` with `start_line`/`line_count`/`tail_lines`"
    static let budgetWarningThreshold = 5

    static func budgetRemainingStatus(remaining: Int, total: Int) -> String {
        "Budget: \(remaining) of \(total) iterations remaining"
    }

    static func budgetWarningStatus(remaining: Int) -> String {
        "Warning: \(remaining) iterations remaining"
    }

    // MARK: - Tool Execution

    /// Hard safety-net timeout for a single tool execution. The real timeout
    /// for sandbox commands is inactivity-based (at the container exec layer),
    /// so this only fires if something is genuinely stuck.
    private static let toolExecutionTimeout: UInt64 = 300

    /// Executes a tool call with a timeout to prevent indefinite hangs.
    private func executeToolCall(
        _ invocation: ServiceToolInvocation,
        issueId: String,
        agentId: UUID? = nil
    ) async throws -> ToolCallResult {
        let callId =
            invocation.toolCallId
            ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"

        let timeout = Self.toolExecutionTimeout
        let toolName = invocation.toolName

        let result: String = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await self.executeToolInBackground(
                    name: invocation.toolName,
                    argumentsJSON: invocation.jsonArguments,
                    issueId: issueId,
                    agentId: agentId
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                return nil
            }

            let first = await group.next()!
            group.cancelAll()

            if let result = first {
                return result
            }

            print("[WorkExecutionEngine] Tool '\(toolName)' timed out after \(timeout)s")
            return "[TIMEOUT] Tool '\(toolName)' did not complete within \(timeout) seconds."
        }

        let toolCall = ToolCall(
            id: callId,
            type: "function",
            function: ToolCallFunction(
                name: invocation.toolName,
                arguments: invocation.jsonArguments
            ),
            geminiThoughtSignature: invocation.geminiThoughtSignature
        )

        return ToolCallResult(toolCall: toolCall, result: result)
    }

    /// Helper to execute tool in background with issue and agent context
    private func executeToolInBackground(
        name: String,
        argumentsJSON: String,
        issueId: String,
        agentId: UUID? = nil
    ) async -> String {
        do {
            return try await WorkExecutionContext.$currentIssueId.withValue(issueId) {
                try await WorkExecutionContext.$currentAgentId.withValue(agentId) {
                    try await ToolRegistry.shared.execute(
                        name: name,
                        argumentsJSON: argumentsJSON
                    )
                }
            }
        } catch {
            print("[WorkExecutionEngine] Tool execution failed: \(error)")
            return "[REJECTED] \(error.localizedDescription)"
        }
    }

    // MARK: - Tool Result Truncation

    /// Maximum characters for a single tool result in the conversation.
    static let maxToolResultLength = 8000

    /// Truncates a tool result, keeping head and tail with an omission marker.
    /// Internal visibility for testability via `@testable import`.
    func truncateToolResult(_ result: String) -> String {
        guard result.count > Self.maxToolResultLength else { return result }
        if let structured = truncateStructuredToolResult(result) {
            return structured
        }
        return truncatePlainTextToolResult(result)
    }

    private func truncateStructuredToolResult(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
            var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let preferredKeys = ["stdout", "stderr", "output", "content", "entries", "matches", "processes"]
        let presentKeys = preferredKeys.filter { (payload[$0] as? String)?.isEmpty == false }
        guard !presentKeys.isEmpty else { return nil }

        let perFieldLimit = max(600, (Self.maxToolResultLength - 1200) / max(presentKeys.count, 1))
        var truncatedAny = false
        for key in presentKeys {
            guard let value = payload[key] as? String, value.count > perFieldLimit else { continue }
            payload[key] = truncatePlainTextToolResult(value, limit: perFieldLimit)
            payload["\(key)_truncated"] = true
            payload["\(key)_original_length"] = value.count
            truncatedAny = true
        }

        guard truncatedAny,
            let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let text = String(data: encoded, encoding: .utf8),
            text.count <= Self.maxToolResultLength
        else { return nil }

        return text
    }

    private func truncatePlainTextToolResult(_ result: String, limit: Int = maxToolResultLength) -> String {
        guard result.count > limit else { return result }
        let headSize = limit * 3 / 4
        let tailSize = limit / 4
        let head = String(result.prefix(headSize))
        let tail = String(result.suffix(tailSize))
        let omitted = result.count - headSize - tailSize
        return
            "\(head)\n\n[... \(omitted) \(Self.truncationOmissionMarker) — use `sandbox_read_file` (with start_line, line_count, or tail_lines) or `file_read` to inspect the full output ...]\n\n\(tail)"
    }

    // MARK: - Folder Context

    /// Builds the folder context section for prompts when a folder is selected.
    /// Uses a compact representation — the agent can explore via tools on demand.
    static func buildFolderContextSection(from folderContext: WorkFolderContext?) -> String {
        guard let folder = folderContext else {
            return ""
        }

        var section = "\n## Working Directory\n"
        section += "**Path:** \(folder.rootPath.path)\n"
        section += "**Project Type:** \(folder.projectType.displayName)\n"

        let topLevel = buildTopLevelSummary(from: folder.tree)
        section += "**Root contents:** \(topLevel)\n"

        if let gitStatus = folder.gitStatus, !gitStatus.isEmpty {
            let shortStatus = String(gitStatus.prefix(300))
            section += "\n**Git status (uncommitted changes):**\n```\n\(shortStatus)\n```\n"
        }

        section +=
            "\nUse `file_read`, `file_search`, and `file_list` to explore the project structure. Always read files before editing.\n"

        return section
    }

    /// Extracts top-level directory entries from the tree string for a compact summary.
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

    // MARK: - Sandbox Prompt Blocks

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
        - Use `sandbox_read_file` before editing — never modify code you have not inspected.
        - Use `sandbox_edit_file` for targeted changes (old_string → new_string). Prefer this over rewriting entire files with `sandbox_write_file`.
        - Use `sandbox_write_file` only for new files or complete rewrites.
        - Use `sandbox_find_files` to locate files by name pattern (e.g. `*.py`).
        - Use `sandbox_search_files` to search file contents with regex (ripgrep). Use `sandbox_find_files` for name-based lookup.
        - Use `sandbox_list_directory` with `recursive: true` for project structure overview.
        - Prefer `sandbox_run_script` for multi-line logic (python, bash, node). Use `sandbox_exec` for single shell commands. Use `sandbox_exec_background` for servers, watchers, and long-running processes.
        - Set `timeout` for long operations (default 60 s scripts, 30 s exec, max 300 s).
        - Use dedicated tools instead of shell equivalents: `sandbox_read_file` not `cat`, `sandbox_edit_file` not `sed`, `sandbox_find_files` not `find`.
        - When multiple tool calls have no dependency on each other, issue them in parallel.
        """

    private static let sandboxToolGuideCompact = """
        Tools: `sandbox_read_file` before editing. `sandbox_edit_file` for targeted edits (old_string/new_string) — prefer over full rewrites. \
        `sandbox_find_files` for name patterns, `sandbox_search_files` for content search. \
        `sandbox_run_script` for multi-line scripts; `sandbox_exec` for single commands.
        """

    private static let sandboxCodeStyle = """
        Code style:
        - Limit changes to what was requested — a bug fix does not warrant adjacent refactoring or style cleanup.
        - Do not add defensive error handling for conditions that cannot arise in the current code path.
        - Do not extract helpers or utilities for logic that appears only once.
        - Only add comments when reasoning is genuinely non-obvious — never narrate what the code does.
        - Do not add docstrings or type annotations to code you did not modify.
        """

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

    /// Chat-mode sandbox guidance (no `complete_task` workflow).
    static func chatSandboxPromptSection(compact: Bool = false, secretNames: [String] = []) -> String {
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

    /// Work-mode sandbox guidance with build/verify pattern.
    static func sandboxPromptSection(compact: Bool = false, secretNames: [String] = []) -> String {
        let env = compact ? sandboxEnvironmentBlockCompact : sandboxEnvironmentBlock
        let tools = compact ? sandboxToolGuideCompact : sandboxToolGuide
        let hints = compact ? sandboxRuntimeHintsCompact : sandboxRuntimeHints

        var section = """

            \(sandboxSectionHeading)

            \(env)
            Files persist across tasks.

            \(tools)

            """

        if !compact {
            section += """
                For build/test tasks, follow this pattern:
                1. Inspect the workspace and choose a stack.
                2. \(sandboxScaffoldGuidance).
                3. Install project-specific dependencies with `sandbox_pip_install` or `sandbox_npm_install`.
                4. \(sandboxVerifyGuidance).
                5. If verification fails, read the error carefully, fix the cause, and rerun.

                \(sandboxCodeStyle)

                \(sandboxRiskGuidance)

                """
        }

        section += """
            \(hints)

            """
        section += secretsPromptBlock(secretNames)
        return section
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

    // MARK: - Context Compaction

    /// Clears old tool results in-place to free context budget.
    /// Returns the number of results cleared this pass.
    private func clearStaleToolResults(
        messages: inout [ChatMessage],
        currentIteration: Int,
        staleness: Int = 8
    ) -> Int {
        guard currentIteration > staleness else { return 0 }

        var iterationBoundary = 0
        var cleared = 0

        // Walk backwards counting iteration boundaries (each assistant message = ~1 iteration)
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let msg = messages[i]
            if msg.role == "assistant" {
                iterationBoundary += 1
            }
            if msg.role == "tool", iterationBoundary >= staleness,
                let content = msg.content,
                !content.hasPrefix("[Result cleared")
            {
                let toolName = resolveToolName(
                    forToolCallId: msg.tool_call_id,
                    in: messages,
                    before: i
                )
                let label = toolName ?? "unknown tool"
                let byteCount = content.utf8.count
                messages[i] = ChatMessage(
                    role: "tool",
                    content:
                        "[Result cleared — \(label) returned \(byteCount) bytes. Re-run the tool or use `sandbox_read_file` to inspect.]",
                    tool_calls: nil,
                    tool_call_id: msg.tool_call_id
                )
                cleared += 1
            }
        }
        return cleared
    }

    /// Finds the tool name for a given `tool_call_id` by scanning preceding assistant messages.
    private func resolveToolName(
        forToolCallId callId: String?,
        in messages: [ChatMessage],
        before index: Int
    ) -> String? {
        guard let callId else { return nil }
        for i in stride(from: index - 1, through: 0, by: -1) {
            if let toolCalls = messages[i].tool_calls {
                for tc in toolCalls where tc.id == callId {
                    return tc.function.name
                }
            }
        }
        return nil
    }

    /// Prompt used to summarize the middle chunk of conversation during compaction.
    private static let compactionSummarizationPrompt = """
        You are summarizing an agent's work-in-progress for context continuity.

        Given the following conversation excerpt from an ongoing task, produce a concise summary covering:
        - Key decisions made and why
        - Files created, modified, or read (with paths)
        - Current state of the task (what's done, what remains)
        - Any errors encountered and how they were resolved
        - Important values, configurations, or findings

        Be specific — include file paths, function names, error messages, and concrete details.
        Do NOT include tool call arguments or raw file contents.
        Keep it under 800 tokens.
        """

    /// Compacts middle messages into a summary using an LLM call.
    /// Protects the head (initial context) and tail (recent work), summarizing everything between.
    private func compactMiddleMessages(
        messages: [ChatMessage],
        model: String?,
        protectHead: Int = 2,
        protectTail: Int = 6
    ) async throws -> [ChatMessage] {
        let head = min(protectHead, messages.count)
        let tail = min(protectTail, messages.count - head)

        guard messages.count > head + tail else { return messages }

        let headSlice = Array(messages[..<head])
        let tailSlice = Array(messages[(messages.count - tail)...])
        let middle = Array(messages[head ..< (messages.count - tail)])

        // Serialize the middle chunk for summarization
        var transcript = ""
        for msg in middle {
            let role = msg.role.uppercased()
            if let content = msg.content, !content.isEmpty {
                let truncated = content.count > 500 ? String(content.prefix(500)) + "..." : content
                transcript += "[\(role)] \(truncated)\n"
            } else if let toolCalls = msg.tool_calls {
                let names = toolCalls.map { $0.function.name }.joined(separator: ", ")
                transcript += "[ASSISTANT] Called: \(names)\n"
            }
        }

        guard !transcript.isEmpty else { return messages }

        let request = ChatCompletionRequest(
            model: model ?? "default",
            messages: [
                ChatMessage(role: "system", content: Self.compactionSummarizationPrompt),
                ChatMessage(role: "user", content: transcript),
            ],
            temperature: 0.1,
            max_tokens: 1024,
            stream: nil,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil
        )

        let response = try await resolvedChatEngine().completeChat(request: request)
        guard let summary = response.choices.first?.message.content, !summary.isEmpty else {
            throw WorkExecutionError.unknown("Empty compaction summary")
        }

        let summaryMessage = ChatMessage(
            role: "user",
            content: """
                [System — Context Summary]
                The following summarizes work completed in earlier iterations that has been compacted:

                \(summary)

                Continue from where this summary leaves off.
                """
        )

        return stripOrphanedToolResults(headSlice + [summaryMessage] + tailSlice)
    }

    /// Removes tool-result messages that have no matching tool_call in a preceding assistant message.
    private func stripOrphanedToolResults(_ messages: [ChatMessage]) -> [ChatMessage] {
        var knownCallIds = Set<String>()
        var cleaned: [ChatMessage] = []
        for msg in messages {
            if let toolCalls = msg.tool_calls {
                for tc in toolCalls { knownCallIds.insert(tc.id) }
            }
            if msg.role == "tool" {
                guard let callId = msg.tool_call_id, knownCallIds.contains(callId) else { continue }
            }
            cleaned.append(msg)
        }
        return cleaned
    }

    // MARK: - Reasoning Loop

    /// Callback type for iteration-based streaming updates
    public typealias IterationStreamingCallback = @MainActor @Sendable (String, Int) async -> Void

    /// Callback type for tool call completion
    public typealias ToolCallCallback = @MainActor @Sendable (String, String, String) async -> Void

    /// Callback type for status updates
    public typealias StatusCallback = @MainActor @Sendable (String) async -> Void

    /// Callback type for artifact generation
    public typealias ArtifactCallback = @MainActor @Sendable (SharedArtifact) async -> Void

    /// Callback type for iteration start (iteration number)
    public typealias IterationStartCallback = @MainActor @Sendable (Int) async -> Void

    /// Callback type for tool hint (pending tool name detected during streaming)
    public typealias ToolHintCallback = @MainActor @Sendable (String) async -> Void

    /// Callback type for tool argument fragment (partial args detected during streaming)
    public typealias ToolArgHintCallback = @MainActor @Sendable (String) async -> Void

    /// Callback type for token consumption (inputTokens, outputTokens)
    public typealias TokenConsumptionCallback = @MainActor @Sendable (Int, Int) async -> Void
    public typealias InterruptCheckCallback = @Sendable () async -> Bool

    /// Callback for secret prompt — shows a secure input overlay and returns the value (nil if cancelled)
    public typealias SecretPromptCallback = @MainActor @Sendable (SecretPromptParser.Prompt) async -> String?

    /// Default maximum iterations for the reasoning loop
    public static let defaultMaxIterations = 50

    /// Maximum consecutive text-only responses (no tool call) before aborting.
    /// Models that don't support tool calling will describe actions in plain text
    /// instead of invoking tools, causing an infinite loop of "Continue" prompts.
    private static let maxConsecutiveTextOnlyResponses = 3

    /// The main reasoning loop. Model decides what to do on each iteration.
    /// - Parameters:
    ///   - issue: The issue being executed
    ///   - messages: Conversation messages (mutated with new messages)
    ///   - systemPrompt: The full system prompt including work instructions
    ///   - model: Model to use
    ///   - tools: All available tools (model picks which to use)
    ///   - contextLength: Model context window size in tokens (used for budget management)
    ///   - toolTokenEstimate: Estimated tokens consumed by tool definitions
    ///   - maxIterations: Maximum loop iterations (not tool calls - iterations)
    ///   - onIterationStart: Callback at the start of each iteration
    ///   - onDelta: Callback for streaming text deltas
    ///   - onToolCall: Callback when a tool is called (toolName, args, result)
    ///   - onStatusUpdate: Callback for status messages
    ///   - onArtifact: Callback when an artifact is shared (via share_artifact tool)
    ///   - onTokensConsumed: Callback with estimated token consumption per iteration
    /// - Returns: The result of the loop execution
    func executeLoop(
        issue: Issue,
        messages: inout [ChatMessage],
        systemPrompt: String,
        model: String?,
        tools: [Tool],
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        topPOverride: Float? = nil,
        contextLength: Int? = nil,
        toolTokenEstimate: Int = 0,
        maxIterations: Int = defaultMaxIterations,
        executionMode: WorkExecutionMode = .none,
        sandboxAgentName: String? = nil,
        agentId: UUID? = nil,
        shouldInterrupt: @escaping InterruptCheckCallback = { false },
        onIterationStart: @escaping IterationStartCallback,
        onDelta: @escaping IterationStreamingCallback,
        onToolHint: @escaping ToolHintCallback,
        onToolArgHint: @escaping ToolArgHintCallback,
        onToolCall: @escaping ToolCallCallback,
        onStatusUpdate: @escaping StatusCallback,
        onArtifact: @escaping ArtifactCallback,
        onTokensConsumed: @escaping TokenConsumptionCallback,
        onSecretPrompt: SecretPromptCallback? = nil
    ) async throws -> LoopResult {
        var activeTools = tools
        var iteration = 0
        var totalToolCalls = 0
        var toolsUsed: [String] = []
        var consecutiveTextOnly = 0
        var lastResponseContent = ""
        var preSaveAttempted = false

        // Set up context budget manager if context length is known
        var budgetManager: ContextBudgetManager? = nil
        if let ctxLen = contextLength {
            var manager = ContextBudgetManager(contextLength: ctxLen)
            manager.reserveByCharCount(.systemPrompt, characters: systemPrompt.count)
            manager.reserve(.tools, tokens: toolTokenEstimate)
            manager.reserve(.memory, tokens: 0)
            manager.reserve(.response, tokens: maxTokens ?? 4096)
            budgetManager = manager
        }

        while iteration < maxIterations {
            iteration += 1
            if Task.isCancelled {
                return .interrupted(
                    messages: messages,
                    iteration: iteration - 1,
                    totalToolCalls: totalToolCalls
                )
            }
            if await shouldInterrupt() {
                return .interrupted(
                    messages: messages,
                    iteration: iteration - 1,
                    totalToolCalls: totalToolCalls
                )
            }

            await onIterationStart(iteration)
            await onStatusUpdate("Iteration \(iteration)")

            if iteration > 1 && iteration % 10 == 0 {
                let remaining = maxIterations - iteration
                await onStatusUpdate(Self.budgetRemainingStatus(remaining: remaining, total: maxIterations))
                messages.append(
                    ChatMessage(
                        role: "user",
                        content:
                            "[System Notice] Budget: \(remaining)/\(maxIterations) iterations remaining. Prioritize completing the core task. Use `create_issue` for non-essential follow-up work."
                    )
                )
            }

            if iteration == maxIterations - Self.budgetWarningThreshold {
                await onStatusUpdate(Self.budgetWarningStatus(remaining: Self.budgetWarningThreshold))
                messages.append(
                    ChatMessage(
                        role: "user",
                        content:
                            "[System Notice] \(Self.budgetWarningThreshold) iterations remaining. Finish current work and call `complete_task` with a summary. Create issues for anything unfinished."
                    )
                )
            }

            // Tier 1: Clear stale tool results in-place (cheap, no LLM call)
            let cleared = clearStaleToolResults(messages: &messages, currentIteration: iteration)
            if cleared > 0 {
                await onStatusUpdate("Optimizing memory...")
            }

            // Context compaction: tier 2 LLM summarization if still over budget
            let effectiveMessages: [ChatMessage]
            if let manager = budgetManager, !manager.fitsInBudget(messages) {
                if !preSaveAttempted {
                    await onStatusUpdate("Saving progress notes...")
                    messages.append(
                        ChatMessage(
                            role: "user",
                            content: "[System] Context is getting large and will be compacted soon. "
                                + "Use `save_notes` now to record any important findings, decisions, "
                                + "or state you want to preserve. Then continue with your task."
                        )
                    )
                    preSaveAttempted = true
                    continue
                }
                await onStatusUpdate("Summarizing earlier work...")
                do {
                    effectiveMessages = try await compactMiddleMessages(
                        messages: messages,
                        model: model
                    )
                    await onStatusUpdate("Resuming with summary")
                } catch {
                    effectiveMessages = manager.trimMessages(messages)
                    await onStatusUpdate("Resuming...")
                }
            } else {
                effectiveMessages = messages
            }

            await onStatusUpdate("Thinking...")

            // Build full messages with system prompt
            let fullMessages = [ChatMessage(role: "system", content: systemPrompt)] + effectiveMessages

            // Create request with all available tools - model picks which to use
            let request = ChatCompletionRequest(
                model: model ?? "default",
                messages: fullMessages,
                temperature: temperature ?? 0.3,
                max_tokens: maxTokens ?? 4096,
                stream: nil,
                top_p: topPOverride,
                frequency_penalty: nil,
                presence_penalty: nil,
                stop: nil,
                n: nil,
                tools: activeTools.isEmpty ? nil : activeTools,
                tool_choice: nil,
                session_id: issue.id
            )

            // Stream response
            var responseContent = ""
            var toolInvoked: ServiceToolInvocation?

            do {
                let stream = try await resolvedChatEngine().streamChat(request: request)
                for try await delta in stream {
                    if await shouldInterrupt() {
                        return .interrupted(
                            messages: messages,
                            iteration: iteration,
                            totalToolCalls: totalToolCalls
                        )
                    }
                    if let toolName = StreamingToolHint.decode(delta) {
                        await onToolHint(toolName)
                        continue
                    }
                    if let argFragment = StreamingToolHint.decodeArgs(delta) {
                        await onToolArgHint(argFragment)
                        continue
                    }
                    responseContent += delta
                    await onDelta(delta, iteration)
                }
            } catch let invocation as ServiceToolInvocation {
                toolInvoked = invocation
            } catch is CancellationError {
                return .interrupted(
                    messages: messages,
                    iteration: iteration,
                    totalToolCalls: totalToolCalls
                )
            }

            lastResponseContent = responseContent

            // Estimate token consumption for this iteration
            // Rough estimate: ~4 characters per token (varies by model/tokenizer)
            let inputChars = fullMessages.reduce(0) { $0 + ($1.content?.count ?? 0) } + systemPrompt.count
            let outputChars = responseContent.count + (toolInvoked?.jsonArguments.count ?? 0)
            let estimatedInputTokens = max(1, inputChars / 4)
            let estimatedOutputTokens = max(1, outputChars / 4)
            await onTokensConsumed(estimatedInputTokens, estimatedOutputTokens)

            // If pure text response (no tool call), keep nudging tool-capable progress.
            if toolInvoked == nil {
                messages.append(ChatMessage(role: "assistant", content: responseContent))

                // Track consecutive text-only responses to detect models that can't use tools
                consecutiveTextOnly += 1
                if consecutiveTextOnly >= Self.maxConsecutiveTextOnlyResponses {
                    print(
                        "[WorkExecutionEngine] \(consecutiveTextOnly) consecutive text-only responses"
                            + " — aborting to prevent infinite loop"
                    )
                    let summary = extractCompletionSummary(from: responseContent)
                    let fallback =
                        summary.isEmpty
                        ? String(responseContent.prefix(500))
                        : summary
                    return .completed(summary: fallback, artifact: nil)
                }

                // Model is reasoning but hasn't called a tool yet - prompt to continue
                // This helps models that reason out loud before acting
                messages.append(
                    ChatMessage(
                        role: "user",
                        content:
                            "Continue with the next action. Use the available tools to do the work, verify the result, and call `complete_task` only after verification."
                    )
                )
                continue
            }

            // Model successfully called a tool - reset consecutive text-only counter
            consecutiveTextOnly = 0

            // Tool call - execute it
            let invocation = toolInvoked!
            totalToolCalls += 1
            if !toolsUsed.contains(invocation.toolName) {
                toolsUsed.append(invocation.toolName)
            }

            // Check for meta-tool signals before execution
            switch invocation.toolName {
            case "complete_task":
                // Parse the complete_task arguments to get summary and artifact
                let (summary, artifact) = parseCompleteTaskArgs(invocation.jsonArguments, taskId: issue.taskId)
                return .completed(summary: summary, artifact: artifact)

            case "request_clarification":
                // Parse clarification request
                let clarification = parseClarificationArgs(invocation.jsonArguments)
                return .needsClarification(
                    clarification,
                    messages: messages,
                    iteration: iteration,
                    totalToolCalls: totalToolCalls
                )

            default:
                break
            }

            // Execute the tool
            let result = try await executeToolCall(invocation, issueId: issue.id, agentId: agentId)

            // Hot-load tools injected by capabilities_load or sandbox_plugin_register.
            // Skipped in manual mode — the user's explicit tool set is fixed.
            let isManualMode: Bool = await {
                guard let id = agentId else { return false }
                return await MainActor.run { AgentManager.shared.effectiveToolSelectionMode(for: id) == .manual }
            }()
            if !isManualMode,
                invocation.toolName == "capabilities_load"
                    || invocation.toolName == "sandbox_plugin_register"
            {
                let newTools = await CapabilityLoadBuffer.shared.drain()
                for tool in newTools where !activeTools.contains(where: { $0.function.name == tool.function.name }) {
                    activeTools.append(tool)
                }
            }

            // Process share_artifact before storing the result so the enriched
            // metadata (host_path, file_size, etc.) flows into the transcript.
            var toolResultForDisplay = result.result
            var sharedArtifact: SharedArtifact?
            if invocation.toolName == "share_artifact" {
                if let processed = SharedArtifact.processToolResult(
                    result.result,
                    contextId: issue.taskId,
                    contextType: .work,
                    executionMode: executionMode,
                    sandboxAgentName: sandboxAgentName
                ) {
                    toolResultForDisplay = processed.enrichedToolResult
                    sharedArtifact = processed.artifact
                }
            }

            let truncatedResult = truncateToolResult(toolResultForDisplay)
            await onToolCall(invocation.toolName, invocation.jsonArguments, toolResultForDisplay)

            // Clean response content - strip any leaked function-call JSON patterns
            let cleanedContent = StringCleaning.stripFunctionCallLeakage(responseContent, toolName: invocation.toolName)

            // Append tool call + result to conversation
            if cleanedContent.isEmpty {
                messages.append(
                    ChatMessage(role: "assistant", content: nil, tool_calls: [result.toolCall], tool_call_id: nil)
                )
            } else {
                messages.append(
                    ChatMessage(
                        role: "assistant",
                        content: cleanedContent,
                        tool_calls: [result.toolCall],
                        tool_call_id: nil
                    )
                )
            }
            messages.append(
                ChatMessage(
                    role: "tool",
                    content: truncatedResult,
                    tool_calls: nil,
                    tool_call_id: result.toolCall.id
                )
            )

            // Log the tool call event
            _ = try? IssueStore.createEvent(
                IssueEvent.withPayload(
                    issueId: issue.id,
                    eventType: .toolCallCompleted,
                    payload: EventPayload.ToolCallCompleted(
                        toolName: invocation.toolName,
                        iteration: iteration,
                        arguments: invocation.jsonArguments,
                        result: result.result,
                        success: !result.result.hasPrefix("[REJECTED]")
                    )
                )
            )

            // Handle semi-meta-tools (execute but also process results)
            switch invocation.toolName {
            case "create_issue":
                await onStatusUpdate("Created follow-up issue")

            case "share_artifact":
                if let artifact = sharedArtifact {
                    await onArtifact(artifact)
                    await onStatusUpdate("Shared artifact: \(artifact.filename)")
                    await PluginManager.shared.notifyArtifactHandlers(artifact: artifact)
                }

            case "sandbox_secret_set":
                if let prompt = SecretPromptParser.parse(result.result),
                    let handler = onSecretPrompt
                {
                    let secretValue = await handler(prompt)
                    let replacement =
                        secretValue != nil
                        ? SecretToolResult.stored(key: prompt.key)
                        : SecretToolResult.cancelled(key: prompt.key)
                    if let lastIdx = messages.indices.last, messages[lastIdx].role == "tool" {
                        messages[lastIdx] = ChatMessage(
                            role: "tool",
                            content: replacement,
                            tool_calls: nil,
                            tool_call_id: messages[lastIdx].tool_call_id
                        )
                    }
                }

            default:
                break
            }
        }

        // Hit iteration limit
        return .iterationLimitReached(
            messages: messages,
            totalIterations: iteration,
            totalToolCalls: totalToolCalls,
            lastResponseContent: lastResponseContent
        )
    }

    // MARK: - Work System Prompt

    /// Builds the complete work-mode system prompt for reasoning loop execution.
    static func buildAgentSystemPrompt(
        base: String,
        executionMode: WorkExecutionMode,
        compact: Bool = false,
        secretNames: [String] = []
    ) -> String {
        var prompt = base

        prompt +=
            compact
            ? workModeCompact()
            : workModeFull()

        switch executionMode {
        case .hostFolder: break
        case .sandbox: prompt += sandboxPromptSection(compact: compact, secretNames: secretNames)
        case .none: break
        }

        return prompt
    }

    private static func workModeCompact() -> String {
        """


        # Work Mode

        You are executing a task for the user. The goal and context will be provided in the user's first message.

        ## Instructions

        - ALWAYS attempt the task using your tools. Never refuse or list limitations.
        - Read/explore before modifying. Never edit code you have not examined.
        - Use `create_issue` for additional work; `request_clarification` if ambiguous.
        - If something fails: read the error, verify assumptions, apply a targeted fix. Do not retry blindly.
        - Limit changes to what was requested. No speculative error handling, no premature abstractions, no narrating comments.
        - Start with the answer — no filler, no echoing the user. Be concise.
        - You MUST call `share_artifact` for every output file BEFORE calling `complete_task`. The user sees nothing unless you share it.
        - Only after sharing all outputs, call `complete_task` with `{"summary": "...", "success": true}`.
        - NEVER call `complete_task` without first calling `share_artifact`.

        ## Notes

        Use `save_notes` to record important findings, decisions, file paths, and current state as you work. Your context may be compacted during long tasks — saved notes persist and will be available if you resume. Use `read_notes` to recall earlier findings.

        """
    }

    private static func workModeFull() -> String {
        """


        # Work Mode

        You are executing a task for the user. The goal and context will be provided in the user's first message.

        ## How to Work

        - ALWAYS attempt the task using your tools. Never refuse, never list limitations, never say you cannot do something without trying first. You have powerful tools — use them.
        - Work step by step. After each tool call, assess what you learned and decide the next action.
        - You do not need to plan everything upfront. Explore, read, understand, then act.
        - If you discover additional work needed, use `create_issue` to track it.
        - Use `complete_task` as the normal way to finish work once the task is actually verified.
        - If the task is ambiguous and you cannot make a reasonable assumption, use `request_clarification`.

        ## Task Execution

        - Always read/explore before modifying. Never propose changes to code you have not examined.
        - For coding tasks: install missing dependencies, write code efficiently, then verify it works.
        - Keep the user's original request in mind at all times. Every action should serve the goal.
        - When creating follow-up issues, write detailed descriptions with full context about what you learned.

        ## Failure Recovery

        When something fails, follow this protocol:
        1. Read and understand the actual error output.
        2. Verify the assumptions that led to the failed action.
        3. Apply a targeted correction based on the diagnosis.
        4. Do not re-execute the same action without changing anything.
        5. Do not discard a fundamentally sound strategy because of a single failure.
        6. Only escalate to the user when you have exhausted actionable diagnostic steps.

        ## Code Style

        - Limit changes to what was explicitly requested. A bug fix does not warrant adjacent refactoring, style cleanup, or feature additions.
        - Do not insert defensive error handling, fallback logic, or input validation for conditions that cannot arise in the current code path.
        - Do not extract helpers or utility functions for logic that appears only once.
        - Only add code comments when the reasoning behind a decision is genuinely non-obvious. Never comment to narrate what the code does.
        - Do not add docstrings, comments, or type annotations to code you did not modify.

        ## Tool Discipline

        - Use dedicated tools instead of shell equivalents when available. Purpose-built tools give better visibility into what you are doing.
        - When multiple tool calls have no dependency on each other's results, issue them in parallel.

        ## Communication

        - Start with the answer or action — no context-setting preamble.
        - Eliminate filler phrases, hedging language, and unnecessary transitions.
        - Do not echo or paraphrase what the user said.
        - Focus on: decisions needing input, progress at meaningful checkpoints, and errors requiring attention.
        - If a single sentence suffices, do not expand it into a paragraph.
        - The user sees your text responses in real time, so keep them informed of progress.

        ## Completion

        When the goal is fully achieved:
        1. You MUST call `share_artifact` BEFORE `complete_task`. The user cannot see any files you created unless you explicitly share them. Call `share_artifact` for every output file or directory (images, charts, code, websites, reports, HTML, videos, etc.).
        2. Only AFTER sharing all outputs, call `complete_task` with `{"summary": "what was accomplished", "success": true}`.

        NEVER call `complete_task` without first calling `share_artifact` for every file the user should see. If you skip `share_artifact`, the user gets nothing.

        ## Notes

        Use `save_notes` to record important findings, decisions, file paths, and current state as you work. Your context may be compacted during long tasks — saved notes persist and will be available if you resume. Use `read_notes` to recall earlier findings.

        """
    }

    /// Extracts a completion summary from a text response
    private func extractCompletionSummary(from content: String) -> String {
        // Try to find a summary section
        let lines = content.components(separatedBy: .newlines)
        var summaryLines: [String] = []
        var inSummary = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().contains("SUMMARY") || trimmed.uppercased().contains("COMPLETED") {
                inSummary = true
            }
            if inSummary && !trimmed.isEmpty {
                summaryLines.append(trimmed)
            }
        }

        if summaryLines.isEmpty {
            // Just use the whole content, truncated
            return String(content.prefix(500))
        }
        return summaryLines.joined(separator: "\n")
    }

    /// Parses complete_task tool arguments
    private func parseCompleteTaskArgs(_ jsonArgs: String, taskId: String) -> (String, SharedArtifact?) {
        struct CompleteTaskArgs: Decodable {
            let summary: String
            let success: Bool?
            let artifact: String?
            let remaining_work: String?
        }

        guard let data = jsonArgs.data(using: .utf8),
            let args = try? JSONDecoder().decode(CompleteTaskArgs.self, from: data)
        else {
            return ("Task completed", nil)
        }

        var artifact: SharedArtifact? = nil
        if let rawContent = args.artifact, !rawContent.isEmpty {
            let content =
                rawContent
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")

            let contextDir = OsaurusPaths.contextArtifactsDir(contextId: taskId)
            OsaurusPaths.ensureExistsSilent(contextDir)
            let destPath = contextDir.appendingPathComponent("result.md")
            try? content.write(to: destPath, atomically: true, encoding: .utf8)

            artifact = SharedArtifact(
                contextId: taskId,
                contextType: .work,
                filename: "result.md",
                mimeType: "text/markdown",
                fileSize: content.utf8.count,
                hostPath: destPath.path,
                content: content,
                isFinalResult: true
            )
            if let artifact { _ = try? IssueStore.createSharedArtifact(artifact) }
        }

        var summary = args.summary
        if args.success == false, let remaining = args.remaining_work, !remaining.isEmpty {
            summary += "\nRemaining work: \(remaining)"
        }

        return (summary, artifact)
    }

    /// Parses request_clarification tool arguments
    private func parseClarificationArgs(_ jsonArgs: String) -> ClarificationRequest {
        struct ClarificationArgs: Decodable {
            let question: String
            let options: [String]?
            let context: String?
        }

        guard let data = jsonArgs.data(using: .utf8),
            let args = try? JSONDecoder().decode(ClarificationArgs.self, from: data)
        else {
            return ClarificationRequest(question: "Could you please clarify your request?")
        }

        return ClarificationRequest(
            question: args.question,
            options: args.options,
            context: args.context
        )
    }

}

// MARK: - Secret Prompt Parsing

public enum SecretPromptParser {
    public struct Prompt: Sendable {
        public let key: String
        public let description: String
        public let instructions: String
        public let agentId: String
    }

    public static func parse(_ toolResult: String) -> Prompt? {
        guard let data = toolResult.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let action = dict["action"] as? String,
            action == SecretPromptAction.actionKey,
            let key = dict["key"] as? String,
            let desc = dict["description"] as? String,
            let instructions = dict["instructions"] as? String,
            let agentId = dict["agent_id"] as? String
        else { return nil }
        return Prompt(key: key, description: desc, instructions: instructions, agentId: agentId)
    }

}

// MARK: - Supporting Types

/// Result of a tool call
public struct ToolCallResult: Sendable {
    public let toolCall: ToolCall
    public let result: String
}

// MARK: - Errors

/// Errors that can occur during work execution
public enum WorkExecutionError: Error, LocalizedError {
    case executionCancelled
    case iterationLimitReached(Int)
    case networkError(String)
    case rateLimited(retryAfter: TimeInterval?)
    case toolExecutionFailed(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .executionCancelled:
            return "Execution was cancelled"
        case .iterationLimitReached(let count):
            return "Iteration limit reached after \(count) iterations"
        case .networkError(let reason):
            return "Network error: \(reason)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry after \(Int(seconds)) seconds"
            }
            return "Rate limited. Please try again later"
        case .toolExecutionFailed(let reason):
            return "Tool execution failed: \(reason)"
        case .unknown(let reason):
            return "Unknown error: \(reason)"
        }
    }

    /// Whether this error is retriable
    public var isRetriable: Bool {
        switch self {
        case .networkError, .rateLimited:
            return true
        case .toolExecutionFailed:
            return true
        case .executionCancelled, .iterationLimitReached:
            return false
        case .unknown:
            return true
        }
    }
}
