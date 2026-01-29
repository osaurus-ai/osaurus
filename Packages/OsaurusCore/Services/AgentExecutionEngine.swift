//
//  AgentExecutionEngine.swift
//  osaurus
//
//  Execution engine for Osaurus Agents with bounded context.
//  Handles plan generation, step execution, and automatic decomposition.
//

import Foundation

/// Execution engine for running agent tasks with bounded context
public actor AgentExecutionEngine {
    /// Maximum tool calls allowed per issue execution
    public static let maxToolCallsPerIssue = 10

    /// The chat engine for LLM calls
    private let chatEngine: ChatEngineProtocol

    /// Current execution state
    private var currentPlan: ExecutionPlan?
    private var isExecuting = false

    /// Callback type for streaming updates
    public typealias StreamingCallback = @MainActor @Sendable (String, Int) async -> Void

    /// Callback for streaming updates - called on MainActor
    private var streamingCallback: StreamingCallback?

    init(chatEngine: ChatEngineProtocol? = nil) {
        self.chatEngine = chatEngine ?? ChatEngine(source: .chatUI)
    }

    /// Sets the callback for receiving streaming updates
    public func setStreamingCallback(_ callback: StreamingCallback?) {
        self.streamingCallback = callback
    }

    /// Notifies of streaming delta via callback on main actor
    private func notifyDelta(_ delta: String, forStep stepIndex: Int) async {
        guard let callback = streamingCallback else {
            return
        }
        await callback(delta, stepIndex)
    }

    // MARK: - Plan Generation

    /// Generates an execution plan for an issue
    /// Returns the plan, or decomposes if steps exceed limit
    func generatePlan(
        for issue: Issue,
        systemPrompt: String,
        model: String?,
        tools: [Tool]
    ) async throws -> PlanResult {
        let planPrompt = buildPlanPrompt(for: issue, tools: tools)

        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt + "\n\n" + agentPlanningInstructions),
            ChatMessage(role: "user", content: planPrompt),
        ]

        let request = ChatCompletionRequest(
            model: model ?? "default",
            messages: messages,
            temperature: 0.2,  // Low temperature for consistent planning
            max_tokens: 2048,
            stream: nil,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,  // No tools during planning phase
            tool_choice: nil,
            session_id: nil
        )

        let response = try await chatEngine.completeChat(request: request)

        guard let content = response.choices.first?.message.content else {
            throw AgentExecutionError.failedToGeneratePlan("No response from model")
        }

        // Parse the plan from the response
        let steps = parsePlanSteps(from: content)

        if steps.count > Self.maxToolCallsPerIssue {
            // Plan exceeds limit - return decomposition suggestion
            return .needsDecomposition(steps: steps, suggestedChunks: chunkSteps(steps))
        }

        let plan = ExecutionPlan(
            issueId: issue.id,
            steps: steps,
            maxToolCalls: Self.maxToolCallsPerIssue
        )
        currentPlan = plan

        return .ready(plan)
    }

    /// Builds the prompt for plan generation
    private func buildPlanPrompt(for issue: Issue, tools: [Tool]) -> String {
        var toolList = ""
        for tool in tools {
            let desc = tool.function.description ?? "No description"
            toolList += "\n- `\(tool.function.name)`: \(desc)"
        }

        return """
            I need to complete the following task:

            **Title:** \(issue.title)\(issue.description.map { "\n**Description:** \($0)" } ?? "")

            Available tools:\(toolList)

            Create a step-by-step plan to complete this task.
            Each step should be a single, concrete action.
            Maximum \(Self.maxToolCallsPerIssue) steps allowed.
            If the task requires more steps, list all of them anyway.

            IMPORTANT: Respond with valid JSON only, no markdown or extra text:
            {"steps": [{"description": "what to do", "tool": "tool_name or null"}]}

            Example:
            {"steps": [{"description": "Read the config file", "tool": "read_file"}, {"description": "Update the setting", "tool": "write_file"}]}
            """
    }

    /// JSON structure for plan parsing
    private struct JSONPlan: Codable {
        let steps: [JSONPlanStep]
    }

    private struct JSONPlanStep: Codable {
        let description: String
        let tool: String?
    }

    /// Parses plan steps from LLM response (JSON first, then text fallback)
    private func parsePlanSteps(from content: String) -> [PlanStep] {
        // Try JSON parsing first
        if let steps = parseStepsFromJSON(content) {
            return steps
        }

        // Fallback to text parsing
        return parseStepsFromText(content)
    }

    /// Attempts to parse steps from JSON format
    private func parseStepsFromJSON(_ content: String) -> [PlanStep]? {
        // Try to find JSON in the response (LLM might include extra text)
        let jsonPatterns = [
            content,  // Try raw content first
            extractJSONObject(from: content),  // Extract {...} if wrapped
        ].compactMap { $0 }

        for jsonString in jsonPatterns {
            guard let data = jsonString.data(using: .utf8) else { continue }

            if let plan = try? JSONDecoder().decode(JSONPlan.self, from: data) {
                return plan.steps.enumerated().map { index, step in
                    PlanStep(
                        stepNumber: index + 1,
                        description: step.description,
                        toolName: step.tool
                    )
                }
            }
        }

        return nil
    }

    /// Extracts a JSON object from text that might have surrounding content
    private func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
            let end = text.lastIndex(of: "}"),
            start < end
        else {
            return nil
        }
        return String(text[start ... end])
    }

    /// Fallback text parsing for when JSON fails
    private func parseStepsFromText(_ content: String) -> [PlanStep] {
        var steps: [PlanStep] = []
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }

            // Try to parse "STEP N:" format (case insensitive)
            let upperLine = trimmedLine.uppercased()
            if upperLine.hasPrefix("STEP") {
                if let step = parseStepLine(trimmedLine, fallbackNumber: steps.count + 1) {
                    steps.append(step)
                }
            }
        }

        // If no STEP format found, try numbered list format (1. xxx, 2) xxx, etc.)
        if steps.isEmpty {
            steps = parseNumberedList(lines)
        }

        // Last resort: treat each non-empty line as a step
        if steps.isEmpty {
            steps =
                lines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count > 10 }  // Skip very short lines
                .prefix(Self.maxToolCallsPerIssue + 5)  // Reasonable limit
                .enumerated()
                .map { PlanStep(stepNumber: $0.offset + 1, description: $0.element, toolName: nil) }
        }

        return steps
    }

    /// Parses a single "STEP N: description (tool: name)" line
    private func parseStepLine(_ line: String, fallbackNumber: Int) -> PlanStep? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }

        let beforeColon = line[line.startIndex ..< colonIndex]
        let afterColon = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)

        guard !afterColon.isEmpty else { return nil }

        // Extract step number
        let stepNumStr = beforeColon.filter { $0.isNumber }
        let stepNumber = Int(stepNumStr) ?? fallbackNumber

        var description = String(afterColon)
        var toolName: String? = nil

        // Check for (tool: xxx) at the end
        if let toolStart = description.range(of: "(tool:", options: .caseInsensitive),
            let toolEnd = description.range(of: ")", range: toolStart.upperBound ..< description.endIndex)
        {
            toolName = String(description[toolStart.upperBound ..< toolEnd.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            description = String(description[..<toolStart.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }

        return PlanStep(stepNumber: stepNumber, description: description, toolName: toolName)
    }

    /// Parses numbered list format (1. xxx, 2) xxx, etc.)
    private func parseNumberedList(_ lines: [String]) -> [PlanStep] {
        var steps: [PlanStep] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let firstChar = trimmed.first, firstChar.isNumber else { continue }

            // Find where the number ends
            var numberEndIndex = trimmed.startIndex
            for char in trimmed {
                if char.isNumber {
                    numberEndIndex = trimmed.index(after: numberEndIndex)
                } else {
                    break
                }
            }

            let numberPart = trimmed[..<numberEndIndex]
            let afterNumber = trimmed[numberEndIndex...]

            // Check for separator (., ), :)
            if let firstAfter = afterNumber.first, [".", ")", ":"].contains(String(firstAfter)) {
                let descStart = afterNumber.index(after: afterNumber.startIndex)
                let description = String(afterNumber[descStart...]).trimmingCharacters(in: .whitespaces)

                if let stepNum = Int(numberPart), !description.isEmpty {
                    steps.append(PlanStep(stepNumber: stepNum, description: description, toolName: nil))
                }
            }
        }

        return steps
    }

    /// Chunks steps into groups of maxToolCallsPerIssue for decomposition
    private func chunkSteps(_ steps: [PlanStep]) -> [[PlanStep]] {
        var chunks: [[PlanStep]] = []
        var currentChunk: [PlanStep] = []

        for (index, step) in steps.enumerated() {
            currentChunk.append(step)

            if currentChunk.count >= Self.maxToolCallsPerIssue || index == steps.count - 1 {
                chunks.append(currentChunk)
                currentChunk = []
            }
        }

        return chunks
    }

    // MARK: - Step Execution

    /// Executes a single step in the plan
    func executeStep(
        stepIndex: Int,
        issue: Issue,
        messages: inout [ChatMessage],
        systemPrompt: String,
        model: String?,
        tools: [Tool],
        toolOverrides: [String: Bool]?
    ) async throws -> StepResult {
        guard var plan = currentPlan, plan.issueId == issue.id else {
            throw AgentExecutionError.noPlanForIssue(issue.id)
        }

        guard stepIndex < plan.steps.count else {
            throw AgentExecutionError.stepOutOfBounds(stepIndex, plan.steps.count)
        }

        guard !plan.isAtLimit else {
            throw AgentExecutionError.toolCallLimitReached
        }

        let step = plan.steps[stepIndex]

        // Build the step execution prompt
        let stepPrompt = buildStepPrompt(step: step, stepIndex: stepIndex, totalSteps: plan.steps.count)
        messages.append(ChatMessage(role: "user", content: stepPrompt))

        // Create the request
        let request = ChatCompletionRequest(
            model: model ?? "default",
            messages: [ChatMessage(role: "system", content: systemPrompt)] + messages,
            temperature: 0.3,
            max_tokens: 4096,
            stream: nil,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: tools,
            tool_choice: nil,
            session_id: nil
        )

        // Stream the response
        var responseContent = ""
        var toolCallResult: ToolCallResult?

        do {
            let stream = try await chatEngine.streamChat(request: request)

            for try await delta in stream {
                responseContent += delta
                await notifyDelta(delta, forStep: stepIndex)
            }
        } catch let toolInvocation as ServiceToolInvocation {
            // Tool call detected - handle via StepResult.toolCallResult for UI rendering
            plan.toolCallCount += 1
            currentPlan = plan

            // Execute the tool
            let toolResult = try await executeToolCall(
                toolInvocation,
                overrides: toolOverrides
            )

            toolCallResult = toolResult

            // Log the tool call event with full details
            _ = try? IssueStore.createEvent(
                IssueEvent.withPayload(
                    issueId: issue.id,
                    eventType: .toolCallExecuted,
                    payload: EventPayload.ToolCall(
                        tool: toolInvocation.toolName,
                        step: stepIndex,
                        arguments: toolInvocation.jsonArguments,
                        result: toolResult.result
                    )
                )
            )
        }

        // Mark step as complete
        plan.steps[stepIndex].isComplete = true
        currentPlan = plan

        // Add assistant response to messages
        if !responseContent.isEmpty {
            messages.append(ChatMessage(role: "assistant", content: responseContent))
        }

        // Add tool result to messages if applicable
        if let toolResult = toolCallResult {
            messages.append(
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [toolResult.toolCall],
                    tool_call_id: nil
                )
            )
            messages.append(
                ChatMessage(
                    role: "tool",
                    content: toolResult.result,
                    tool_calls: nil,
                    tool_call_id: toolResult.toolCall.id
                )
            )
        }

        return StepResult(
            stepIndex: stepIndex,
            responseContent: responseContent,
            toolCallResult: toolCallResult,
            isComplete: true,
            remainingToolCalls: plan.maxToolCalls - plan.toolCallCount
        )
    }

    /// Builds the prompt for executing a specific step
    private func buildStepPrompt(step: PlanStep, stepIndex: Int, totalSteps: Int) -> String {
        var prompt = "Execute this step: \(step.description)"

        if let toolName = step.toolName {
            prompt += "\n\nYou should use the `\(toolName)` tool to complete this step."
        }

        // Add tool usage reminder to encourage actual tool invocation
        prompt += """


            IMPORTANT: When you need to perform an action (read files, search, execute commands, etc.), you MUST invoke the appropriate tool. Do not just describe what you would do - actually call the tool to perform the action.

            Provide a concise response after completing the action.
            """

        return prompt
    }

    /// Executes a tool call
    private func executeToolCall(
        _ invocation: ServiceToolInvocation,
        overrides: [String: Bool]?
    ) async throws -> ToolCallResult {
        let callId =
            invocation.toolCallId ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"

        // ToolRegistry.execute is @MainActor async, so call directly
        let result = await executeToolOnMainActor(
            name: invocation.toolName,
            argumentsJSON: invocation.jsonArguments,
            overrides: overrides
        )

        let toolCall = ToolCall(
            id: callId,
            type: "function",
            function: ToolCallFunction(
                name: invocation.toolName,
                arguments: invocation.jsonArguments
            )
        )

        return ToolCallResult(toolCall: toolCall, result: result)
    }

    /// Helper to execute tool on MainActor
    @MainActor
    private func executeToolOnMainActor(
        name: String,
        argumentsJSON: String,
        overrides: [String: Bool]?
    ) async -> String {
        do {
            return try await ToolRegistry.shared.execute(
                name: name,
                argumentsJSON: argumentsJSON,
                overrides: overrides
            )
        } catch {
            print("[AgentExecutionEngine] Tool execution failed: \(error)")
            return "[REJECTED] \(error.localizedDescription)"
        }
    }

    // MARK: - Verification

    /// Verifies if the goal has been achieved
    func verifyGoal(
        issue: Issue,
        messages: [ChatMessage],
        systemPrompt: String,
        model: String?
    ) async throws -> VerificationResult {
        let verifyPrompt = """
            Review the completed work and determine if the goal has been achieved.

            **Original Goal:**
            Title: \(issue.title)
            \(issue.description.map { "Description: \($0)" } ?? "")

            Based on the conversation history, answer:
            1. Was the goal fully achieved? (YES/NO/PARTIAL)
            2. Provide a brief summary of what was accomplished.
            3. If not fully achieved, what remaining work is needed?

            Format your response as:
            STATUS: [YES/NO/PARTIAL]
            SUMMARY: [brief summary]
            REMAINING: [remaining work if any]
            """

        var verifyMessages = messages
        verifyMessages.append(ChatMessage(role: "user", content: verifyPrompt))

        let request = ChatCompletionRequest(
            model: model ?? "default",
            messages: [ChatMessage(role: "system", content: systemPrompt)] + verifyMessages,
            temperature: 0.2,
            max_tokens: 1024,
            stream: nil,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )

        let response = try await chatEngine.completeChat(request: request)

        guard let content = response.choices.first?.message.content else {
            throw AgentExecutionError.verificationFailed("No response from model")
        }

        return parseVerificationResult(from: content)
    }

    /// Parses the verification result from LLM response
    private func parseVerificationResult(from content: String) -> VerificationResult {
        let lines = content.components(separatedBy: .newlines)

        var status: VerificationStatus = .partial
        var summary = ""
        var remaining: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.uppercased().hasPrefix("STATUS:") {
                let value = trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces).uppercased()
                if value.contains("YES") {
                    status = .achieved
                } else if value.contains("NO") {
                    status = .notAchieved
                } else {
                    status = .partial
                }
            } else if trimmed.uppercased().hasPrefix("SUMMARY:") {
                summary = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.uppercased().hasPrefix("REMAINING:") {
                let remainingText = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces)
                if !remainingText.isEmpty && remainingText.lowercased() != "none" {
                    remaining = remainingText
                }
            }
        }

        // If no structured response, use the whole content as summary
        if summary.isEmpty {
            summary = content
        }

        return VerificationResult(
            status: status,
            summary: summary,
            remainingWork: remaining
        )
    }

    // MARK: - State Management

    /// Gets the current plan
    public func getCurrentPlan() -> ExecutionPlan? {
        currentPlan
    }

    /// Clears the current execution state
    public func reset() {
        currentPlan = nil
        isExecuting = false
    }

    // MARK: - Agent Planning Instructions

    private var agentPlanningInstructions: String {
        """
        You are an agent that plans and executes tasks systematically.

        When creating a plan:
        1. Break down the task into concrete, actionable steps
        2. Each step should accomplish one specific thing
        3. Consider dependencies between steps
        4. Use available tools when appropriate
        5. Keep the plan focused and efficient

        When executing steps:
        1. Follow the plan systematically
        2. Use tools to accomplish tasks
        3. Report what was done after each step
        4. Note any discoveries or issues encountered

        Important constraints:
        - Maximum \(Self.maxToolCallsPerIssue) tool calls per task
        - If a task is too large, it will be decomposed into subtasks
        """
    }
}

// MARK: - Supporting Types

/// Result of plan generation
public enum PlanResult: Sendable {
    case ready(ExecutionPlan)
    case needsDecomposition(steps: [PlanStep], suggestedChunks: [[PlanStep]])
}

/// Result of executing a step
public struct StepResult: Sendable {
    public let stepIndex: Int
    public let responseContent: String
    public let toolCallResult: ToolCallResult?
    public let isComplete: Bool
    public let remainingToolCalls: Int
}

/// Result of a tool call
public struct ToolCallResult: Sendable {
    public let toolCall: ToolCall
    public let result: String
}

/// Verification status
public enum VerificationStatus: Sendable {
    case achieved
    case notAchieved
    case partial
}

/// Result of goal verification
public struct VerificationResult: Sendable {
    public let status: VerificationStatus
    public let summary: String
    public let remainingWork: String?
}

// MARK: - Errors

/// Errors that can occur during agent execution
public enum AgentExecutionError: Error, LocalizedError {
    case failedToGeneratePlan(String)
    case noPlanForIssue(String)
    case stepOutOfBounds(Int, Int)
    case toolCallLimitReached
    case verificationFailed(String)
    case executionCancelled
    case networkError(String)
    case rateLimited(retryAfter: TimeInterval?)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .failedToGeneratePlan(let reason):
            return "Failed to generate plan: \(reason)"
        case .noPlanForIssue(let issueId):
            return "No plan exists for issue: \(issueId)"
        case .stepOutOfBounds(let index, let count):
            return "Step index \(index) out of bounds (total: \(count))"
        case .toolCallLimitReached:
            return "Tool call limit reached for this issue"
        case .verificationFailed(let reason):
            return "Goal verification failed: \(reason)"
        case .executionCancelled:
            return "Execution was cancelled"
        case .networkError(let reason):
            return "Network error: \(reason)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry after \(Int(seconds)) seconds"
            }
            return "Rate limited. Please try again later"
        case .unknown(let reason):
            return "Unknown error: \(reason)"
        }
    }

    /// Whether this error is retriable
    public var isRetriable: Bool {
        switch self {
        case .networkError, .rateLimited:
            return true
        case .failedToGeneratePlan:
            // Transient LLM errors might be retriable
            return true
        case .verificationFailed:
            // Could retry with different approach
            return false
        case .executionCancelled, .noPlanForIssue, .stepOutOfBounds, .toolCallLimitReached:
            return false
        case .unknown:
            return true
        }
    }
}
