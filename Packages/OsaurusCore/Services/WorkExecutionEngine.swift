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
    /// The chat engine for LLM calls
    private let chatEngine: ChatEngineProtocol

    init(chatEngine: ChatEngineProtocol? = nil) {
        self.chatEngine = chatEngine ?? ChatEngine(source: .chatUI)
    }

    // MARK: - Tool Execution

    /// Maximum time (in seconds) to wait for a single tool execution before timing out.
    private static let toolExecutionTimeout: UInt64 = 120

    /// Executes a tool call with a timeout to prevent indefinite hangs.
    private func executeToolCall(
        _ invocation: ServiceToolInvocation,
        overrides: [String: Bool]?,
        issueId: String
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
                    overrides: overrides,
                    issueId: issueId
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

    /// Helper to execute tool in background with issue context
    private func executeToolInBackground(
        name: String,
        argumentsJSON: String,
        overrides: [String: Bool]?,
        issueId: String
    ) async -> String {
        do {
            // Wrap with execution context so folder tools can log operations
            return try await WorkExecutionContext.$currentIssueId.withValue(issueId) {
                try await ToolRegistry.shared.execute(
                    name: name,
                    argumentsJSON: argumentsJSON,
                    overrides: overrides
                )
            }
        } catch {
            print("[WorkExecutionEngine] Tool execution failed: \(error)")
            return "[REJECTED] \(error.localizedDescription)"
        }
    }

    // MARK: - Folder Context

    /// Builds the folder context section for prompts when a folder is selected
    private func buildFolderContextSection(from folderContext: WorkFolderContext?) -> String {
        guard let folder = folderContext else {
            return ""
        }

        var section = "\n## Working Directory\n"
        section += "**Path:** \(folder.rootPath.path)\n"
        section += "**Project Type:** \(folder.projectType.displayName)\n"

        section += "\n**File Structure:**\n```\n\(folder.tree)```\n"

        if let manifest = folder.manifest {
            // Truncate manifest if too long for prompt
            let truncatedManifest =
                manifest.count > 2000 ? String(manifest.prefix(2000)) + "\n... (truncated)" : manifest
            section += "\n**Manifest:**\n```\n\(truncatedManifest)\n```\n"
        }

        if let gitStatus = folder.gitStatus, !gitStatus.isEmpty {
            section += "\n**Git Status:**\n```\n\(gitStatus)\n```\n"
        }

        section +=
            "\n**File Tools Available:** Use file_read, file_write, file_edit, file_search, etc. to work with files.\n"
        section += "Always read files before editing. Use relative paths from the working directory.\n"

        return section
    }

    // MARK: - Reasoning Loop

    /// Callback type for iteration-based streaming updates
    public typealias IterationStreamingCallback = @MainActor @Sendable (String, Int) async -> Void

    /// Callback type for tool call completion
    public typealias ToolCallCallback = @MainActor @Sendable (String, String, String) async -> Void

    /// Callback type for status updates
    public typealias StatusCallback = @MainActor @Sendable (String) async -> Void

    /// Callback type for artifact generation
    public typealias ArtifactCallback = @MainActor @Sendable (Artifact) async -> Void

    /// Callback type for iteration start (iteration number)
    public typealias IterationStartCallback = @MainActor @Sendable (Int) async -> Void

    /// Callback type for token consumption (inputTokens, outputTokens)
    public typealias TokenConsumptionCallback = @MainActor @Sendable (Int, Int) async -> Void

    /// Default maximum iterations for the reasoning loop
    public static let defaultMaxIterations = 30

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
    ///   - toolOverrides: Tool permission overrides
    ///   - maxIterations: Maximum loop iterations (not tool calls - iterations)
    ///   - onIterationStart: Callback at the start of each iteration
    ///   - onDelta: Callback for streaming text deltas
    ///   - onToolCall: Callback when a tool is called (toolName, args, result)
    ///   - onStatusUpdate: Callback for status messages
    ///   - onArtifact: Callback when an artifact is generated (via generate_artifact tool)
    ///   - onTokensConsumed: Callback with estimated token consumption per iteration
    /// - Returns: The result of the loop execution
    func executeLoop(
        issue: Issue,
        messages: inout [ChatMessage],
        systemPrompt: String,
        model: String?,
        tools: [Tool],
        toolOverrides: [String: Bool]?,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        topPOverride: Float? = nil,
        maxIterations: Int = defaultMaxIterations,
        onIterationStart: @escaping IterationStartCallback,
        onDelta: @escaping IterationStreamingCallback,
        onToolCall: @escaping ToolCallCallback,
        onStatusUpdate: @escaping StatusCallback,
        onArtifact: @escaping ArtifactCallback,
        onTokensConsumed: @escaping TokenConsumptionCallback
    ) async throws -> LoopResult {
        var iteration = 0
        var totalToolCalls = 0
        var toolsUsed: [String] = []
        var consecutiveTextOnly = 0
        var lastResponseContent = ""

        while iteration < maxIterations {
            iteration += 1
            try Task.checkCancellation()

            await onIterationStart(iteration)

            await onStatusUpdate("Iteration \(iteration)")

            // Build full messages with system prompt
            let fullMessages = [ChatMessage(role: "system", content: systemPrompt)] + messages

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
                tools: tools.isEmpty ? nil : tools,
                tool_choice: nil,
                session_id: nil
            )

            // Stream response
            var responseContent = ""
            var toolInvoked: ServiceToolInvocation?

            do {
                let stream = try await chatEngine.streamChat(request: request)
                for try await delta in stream {
                    responseContent += delta
                    await onDelta(delta, iteration)
                }
            } catch let invocation as ServiceToolInvocation {
                toolInvoked = invocation
            }

            lastResponseContent = responseContent

            // Estimate token consumption for this iteration
            // Rough estimate: ~4 characters per token (varies by model/tokenizer)
            let inputChars = fullMessages.reduce(0) { $0 + ($1.content?.count ?? 0) } + systemPrompt.count
            let outputChars = responseContent.count + (toolInvoked?.jsonArguments.count ?? 0)
            let estimatedInputTokens = max(1, inputChars / 4)
            let estimatedOutputTokens = max(1, outputChars / 4)
            await onTokensConsumed(estimatedInputTokens, estimatedOutputTokens)

            // If pure text response (no tool call) - check if model signals completion
            if toolInvoked == nil {
                messages.append(ChatMessage(role: "assistant", content: responseContent))

                // Check for completion signals in the response
                if isCompletionSignal(responseContent) {
                    let summary = extractCompletionSummary(from: responseContent)
                    return .completed(summary: summary, artifact: nil)
                }

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
                messages.append(ChatMessage(role: "user", content: "Continue with the next action."))
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
                return .needsClarification(clarification)

            default:
                break
            }

            // Execute the tool
            let result = try await executeToolCall(invocation, overrides: toolOverrides, issueId: issue.id)
            await onToolCall(invocation.toolName, invocation.jsonArguments, result.result)

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
                    content: result.result,
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

            case "generate_artifact":
                // Extract artifact from tool result and notify delegate
                if let artifact = parseGeneratedArtifact(from: result.result, taskId: issue.taskId) {
                    await onArtifact(artifact)
                    await onStatusUpdate("Generated artifact: \(artifact.filename)")
                }

            default:
                break
            }
        }

        // Hit iteration limit
        return .iterationLimitReached(
            totalIterations: iteration,
            totalToolCalls: totalToolCalls,
            lastResponseContent: lastResponseContent
        )
    }

    /// Parses generate_artifact tool result to extract the artifact
    private func parseGeneratedArtifact(from result: String, taskId: String) -> Artifact? {
        // Look for the artifact markers
        guard let startRange = result.range(of: "---GENERATED_ARTIFACT_START---\n"),
            let endRange = result.range(of: "\n---GENERATED_ARTIFACT_END---")
        else {
            return nil
        }

        let fullContent = String(result[startRange.upperBound ..< endRange.lowerBound])

        // First line is JSON metadata, rest is content
        let lines = fullContent.components(separatedBy: "\n")
        guard lines.count >= 2, let metadataLine = lines.first else {
            return nil
        }

        // Parse metadata
        guard let metadataData = metadataLine.data(using: .utf8),
            let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: String],
            let filename = metadata["filename"]
        else {
            return nil
        }

        let contentType = metadata["content_type"].flatMap { ArtifactContentType(rawValue: $0) } ?? .text
        let content = lines.dropFirst().joined(separator: "\n")

        guard !content.isEmpty else { return nil }

        return Artifact(
            taskId: taskId,
            filename: filename,
            content: content,
            contentType: contentType,
            isFinalResult: false
        )
    }

    /// Builds the work system prompt for reasoning loop execution
    /// - Parameters:
    ///   - base: Base system prompt (agent instructions, etc.)
    ///   - issue: The issue being executed
    ///   - tools: Available tools
    ///   - folderContext: Optional folder context for file operations
    ///   - skillInstructions: Optional skill-specific instructions
    /// - Returns: Complete system prompt for work mode
    func buildAgentSystemPrompt(
        base: String,
        issue: Issue,
        tools: [Tool],
        folderContext: WorkFolderContext? = nil,
        skillInstructions: String? = nil
    ) -> String {
        var prompt = base

        prompt += """


            # Work Mode

            You are executing a task for the user. Your goal:

            **\(issue.title)**
            \(issue.description ?? "")

            ## How to Work

            - You have tools available. Use them to accomplish the goal.
            - Work step by step. After each tool call, assess what you learned and decide the next action.
            - You do NOT need to plan everything upfront. Explore, read, understand, then act.
            - If you discover additional work needed, use `create_issue` to track it.
            - When the task is complete, use `complete_task` with a summary of what you accomplished.
            - If the task is ambiguous and you cannot make a reasonable assumption, use `request_clarification`.

            ## Important Guidelines

            - Always read/explore before modifying. Don't guess at file contents or project structure.
            - For coding tasks: write code, then verify it works if possible.
            - If something fails, analyze the error and try a different approach. Don't repeat the same action.
            - Keep the user's original request in mind at all times. Every action should serve the goal.
            - When creating follow-up issues, write detailed descriptions with full context about what you learned.

            ## Communication Style

            - Before calling tools, briefly explain what you are about to do and why.
            - After receiving tool results, summarize what you learned before proceeding.
            - Use concise natural language (not code or JSON) when explaining your actions.
            - The user sees your text responses in real time, so keep them informed of progress.

            ## Completion

            When the goal is fully achieved, call `complete_task` with:
            - A summary of what was accomplished
            - Any artifacts produced (optional)

            Do NOT call complete_task until you have actually done the work and verified it.

            """

        // Add folder context if available
        if let folder = folderContext {
            prompt += buildFolderContextSection(from: folder)
        }

        // Add skill instructions if available
        if let skills = skillInstructions, !skills.isEmpty {
            prompt += "\n## Active Skills\n\(skills)\n"
        }

        return prompt
    }

    /// Checks if the response signals task completion (without using complete_task tool)
    private func isCompletionSignal(_ content: String) -> Bool {
        let upperContent = content.uppercased()
        // Look for explicit completion markers
        let completionPhrases = [
            "TASK_COMPLETE",
            "TASK COMPLETE",
            "I HAVE COMPLETED",
            "THE TASK IS COMPLETE",
            "THE TASK HAS BEEN COMPLETED",
            "ALL DONE",
            "FINISHED SUCCESSFULLY",
        ]
        return completionPhrases.contains { upperContent.contains($0) }
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
    private func parseCompleteTaskArgs(_ jsonArgs: String, taskId: String) -> (String, Artifact?) {
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

        var artifact: Artifact? = nil
        if let rawContent = args.artifact, !rawContent.isEmpty {
            // Unescape literal \n and \t sequences that models sometimes send
            let content =
                rawContent
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")

            artifact = Artifact(
                taskId: taskId,
                filename: "result.md",
                content: content,
                contentType: .markdown,
                isFinalResult: true
            )
        }

        return (args.summary, artifact)
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
