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
    /// - Parameters:
    ///   - issue: The issue to generate a plan for
    ///   - systemPrompt: Base system prompt
    ///   - model: Model to use for generation
    ///   - tools: Available tool specifications
    ///   - skillCatalog: Available skills (names and descriptions only)
    ///   - folderContext: Optional folder context for file operations
    func generatePlan(
        for issue: Issue,
        systemPrompt: String,
        model: String?,
        tools: [Tool],
        skillCatalog: [CapabilityEntry] = [],
        folderContext: AgentFolderContext? = nil
    ) async throws -> PlanResult {
        // Check if this issue has pre-selected capabilities from parent (decomposed task)
        let inheritedCapabilities = SelectedCapabilitiesContext.parse(from: issue.context)
        let planPrompt = buildPlanPrompt(
            for: issue,
            tools: tools,
            skillCatalog: skillCatalog,
            inheritedCapabilities: inheritedCapabilities,
            folderContext: folderContext
        )

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

        // Extract token usage from response
        let inputTokens = response.usage.prompt_tokens
        let outputTokens = response.usage.completion_tokens

        guard let content = response.choices.first?.message.content else {
            throw AgentExecutionError.failedToGeneratePlan("No response from model")
        }

        // Try to parse as the new format with clarification support
        if let clarificationResult = parsePlanResponseWithClarification(
            from: content,
            issueId: issue.id,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        ) {
            return clarificationResult
        }

        // Fallback: Parse the plan from the response (legacy format - no capability selection)
        let steps = parsePlanSteps(from: content)

        if steps.count > Self.maxToolCallsPerIssue {
            // Plan exceeds limit - return decomposition suggestion
            // Legacy format doesn't have capability selection, so pass empty arrays
            return .needsDecomposition(
                steps: steps,
                suggestedChunks: chunkSteps(steps),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                selectedTools: [],
                selectedSkills: []
            )
        }

        // Legacy format doesn't have capability selection
        let plan = ExecutionPlan(
            issueId: issue.id,
            steps: steps,
            maxToolCalls: Self.maxToolCallsPerIssue,
            selectedTools: [],
            selectedSkills: []
        )
        currentPlan = plan

        return .ready(plan, inputTokens: inputTokens, outputTokens: outputTokens)
    }

    /// Parses plan response that may include clarification request
    private func parsePlanResponseWithClarification(
        from content: String,
        issueId: String,
        inputTokens: Int,
        outputTokens: Int
    ) -> PlanResult? {
        // Try to extract JSON from content
        guard let jsonString = extractJSONObject(from: content),
            let data = jsonString.data(using: .utf8)
        else {
            return nil
        }

        // Try to parse as the new format
        guard let response = try? JSONDecoder().decode(JSONPlanResponse.self, from: data) else {
            return nil
        }

        // Check if clarification is needed
        if response.needs_clarification == true, let clarification = response.clarification {
            return .needsClarification(
                ClarificationRequest(
                    question: clarification.question,
                    options: clarification.options,
                    context: clarification.context
                ),
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
        }

        // Parse steps if provided
        guard let jsonSteps = response.steps, !jsonSteps.isEmpty else {
            return nil
        }

        let steps = jsonSteps.enumerated().map { index, step in
            PlanStep(
                stepNumber: index + 1,
                description: step.description,
                toolName: step.tool
            )
        }

        // Extract selected capabilities from the response
        let selectedTools = response.selected_tools ?? []
        let selectedSkills = response.selected_skills ?? []

        if steps.count > Self.maxToolCallsPerIssue {
            return .needsDecomposition(
                steps: steps,
                suggestedChunks: chunkSteps(steps),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                selectedTools: selectedTools,
                selectedSkills: selectedSkills
            )
        }

        let plan = ExecutionPlan(
            issueId: issueId,
            steps: steps,
            maxToolCalls: Self.maxToolCallsPerIssue,
            selectedTools: selectedTools,
            selectedSkills: selectedSkills
        )
        currentPlan = plan

        return .ready(plan, inputTokens: inputTokens, outputTokens: outputTokens)
    }

    /// Builds the prompt for plan generation with capability selection
    private func buildPlanPrompt(
        for issue: Issue,
        tools: [Tool],
        skillCatalog: [CapabilityEntry],
        inheritedCapabilities: SelectedCapabilitiesContext?,
        folderContext: AgentFolderContext? = nil
    ) -> String {
        // If this issue inherited capabilities from parent, skip capability selection
        if let inherited = inheritedCapabilities {
            return buildPlanPromptWithInheritedCapabilities(
                for: issue,
                tools: tools,
                inherited: inherited,
                folderContext: folderContext
            )
        }

        // Build tool catalog
        var toolCatalog = ""
        for tool in tools {
            let desc = tool.function.description ?? "No description"
            toolCatalog += "\n- `\(tool.function.name)`: \(desc)"
        }

        // Build skill catalog
        var skillList = ""
        for skill in skillCatalog {
            skillList += "\n- `\(skill.name)`: \(skill.description)"
        }

        // Include prior context if available (but not capability context which is JSON)
        let contextSection: String
        if let context = issue.context,
            SelectedCapabilitiesContext.parse(from: context) == nil
        {
            contextSection = "\n**Prior Context:**\n\(context)\n"
        } else {
            contextSection = ""
        }

        // Capability selection section
        let capabilitySection: String
        if !tools.isEmpty || !skillCatalog.isEmpty {
            var section = "\n## Available Capabilities\n"
            section += "Select which capabilities you need for this task.\n"
            if !tools.isEmpty {
                section += "\n**Tools** (callable functions):\(toolCatalog)"
            }
            if !skillCatalog.isEmpty {
                section += "\n\n**Skills** (specialized knowledge/guidance):\(skillList)"
            }
            capabilitySection = section
        } else {
            capabilitySection = ""
        }

        // Build folder context section if active
        let folderSection = buildFolderContextSection(from: folderContext)

        return """
            I need to complete the following task:

            **Title:** \(issue.title)\(issue.description.map { "\n**Description:** \($0)" } ?? "")\(contextSection)\(folderSection)\(capabilitySection)

            IMPORTANT: Before creating a plan, analyze if this task has critical ambiguities that would significantly affect the approach. Consider:
            - Are there multiple valid interpretations that lead to very different outcomes?
            - Is essential information missing that is required to proceed correctly?
            - Are there implicit assumptions that need confirmation before proceeding?

            Only request clarification for CRITICAL ambiguities that would lead to wrong results if assumed incorrectly. Do NOT ask for clarification on minor details or preferences.

            Respond with valid JSON only, no markdown or extra text:

            If clarification is needed:
            {"needs_clarification": true, "clarification": {"question": "Clear, specific question", "options": ["Option 1", "Option 2"] or null, "context": "Brief explanation of why this is ambiguous"}}

            If no clarification is needed, create a plan with capability selection:
            {"needs_clarification": false, "steps": [{"description": "what to do", "tool": "tool_name or null"}], "selected_tools": ["tool_names_you_need"], "selected_skills": ["skill_names_you_need"]}

            Important:
            - Only include tools/skills in your selection that you actually need for this task
            - If you don't need any capabilities, use empty arrays: "selected_tools": [], "selected_skills": []
            - Your selection persists for the entire task including any subtasks
            - Maximum \(Self.maxToolCallsPerIssue) steps allowed
            """
    }

    /// Builds the folder context section for prompts when a folder is selected
    private func buildFolderContextSection(from folderContext: AgentFolderContext?) -> String {
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

    /// Builds prompt for issues with inherited capabilities (from decomposed parent)
    private func buildPlanPromptWithInheritedCapabilities(
        for issue: Issue,
        tools: [Tool],
        inherited: SelectedCapabilitiesContext,
        folderContext: AgentFolderContext? = nil
    ) -> String {
        // Filter tools to only inherited ones
        let filteredTools = tools.filter { inherited.selectedTools.contains($0.function.name) }
        var toolList = ""
        for tool in filteredTools {
            let desc = tool.function.description ?? "No description"
            toolList += "\n- `\(tool.function.name)`: \(desc)"
        }

        // Include prior context if available (but not capability context)
        let contextSection: String
        if let context = issue.context,
            SelectedCapabilitiesContext.parse(from: context) == nil
        {
            contextSection = "\n**Prior Context:**\n\(context)\n"
        } else {
            contextSection = ""
        }

        // Build folder context section if active
        let folderSection = buildFolderContextSection(from: folderContext)

        let toolSection = toolList.isEmpty ? "" : "\nAvailable tools:\(toolList)"
        let skillSection =
            inherited.selectedSkills.isEmpty
            ? "" : "\nActive skills: \(inherited.selectedSkills.joined(separator: ", "))"

        return """
            I need to complete the following task:

            **Title:** \(issue.title)\(issue.description.map { "\n**Description:** \($0)" } ?? "")\(contextSection)\(folderSection)\(toolSection)\(skillSection)

            Note: This is a subtask with pre-selected capabilities from the parent task.

            IMPORTANT: Before creating a plan, analyze if this task has critical ambiguities that would significantly affect the approach. Consider:
            - Are there multiple valid interpretations that lead to very different outcomes?
            - Is essential information missing that is required to proceed correctly?
            - Are there implicit assumptions that need confirmation before proceeding?

            Only request clarification for CRITICAL ambiguities that would lead to wrong results if assumed incorrectly. Do NOT ask for clarification on minor details or preferences.

            Respond with valid JSON only, no markdown or extra text:

            If clarification is needed:
            {"needs_clarification": true, "clarification": {"question": "Clear, specific question", "options": ["Option 1", "Option 2"] or null, "context": "Brief explanation of why this is ambiguous"}}

            If no clarification is needed, create a plan:
            {"needs_clarification": false, "steps": [{"description": "what to do", "tool": "tool_name or null"}], "selected_tools": \(toJSONArray(inherited.selectedTools)), "selected_skills": \(toJSONArray(inherited.selectedSkills))}

            Maximum \(Self.maxToolCallsPerIssue) steps allowed.
            """
    }

    private func toJSONArray(_ items: [String]) -> String {
        let json = items.map { "\"\($0)\"" }.joined(separator: ", ")
        return "[\(json)]"
    }

    /// JSON structure for plan parsing (with optional clarification and capability selection)
    private struct JSONPlanResponse: Codable {
        let needs_clarification: Bool?
        let clarification: JSONClarification?
        let steps: [JSONPlanStep]?
        let selected_tools: [String]?
        let selected_skills: [String]?
    }

    private struct JSONClarification: Codable {
        let question: String
        let options: [String]?
        let context: String?
    }

    /// Legacy JSON structure for backward compatibility
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

        // Add step prompt to messages
        let stepPrompt = buildStepPrompt(step: step, stepIndex: stepIndex, totalSteps: plan.steps.count)
        messages.append(ChatMessage(role: "user", content: stepPrompt))

        // Track totals across multiple tool calls
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var allResponseContent = ""
        var lastToolCallResult: ToolCallResult?

        // Execute step - may involve multiple tool calls until expected tool is called
        let maxToolCallsPerStep = 5
        var toolCallsInStep = 0

        while toolCallsInStep < maxToolCallsPerStep && !plan.isAtLimit {
            // Build request with current messages
            let currentMessages = [ChatMessage(role: "system", content: systemPrompt)] + messages
            totalInputTokens += estimateInputTokens(currentMessages)

            let request = ChatCompletionRequest(
                model: model ?? "default",
                messages: currentMessages,
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

            // Stream response
            var responseContent = ""
            var toolInvoked: ServiceToolInvocation?

            do {
                let stream = try await chatEngine.streamChat(request: request)
                for try await delta in stream {
                    responseContent += delta
                    await notifyDelta(delta, forStep: stepIndex)
                }
            } catch let invocation as ServiceToolInvocation {
                toolInvoked = invocation
            }

            allResponseContent += responseContent
            totalOutputTokens += estimateOutputTokens(responseContent)

            // Add text response to conversation
            if !responseContent.isEmpty {
                messages.append(ChatMessage(role: "assistant", content: responseContent))
            }

            // No tool called = step complete
            guard let invocation = toolInvoked else { break }

            // Execute the tool
            plan.toolCallCount += 1
            toolCallsInStep += 1
            currentPlan = plan

            let toolResult = try await executeToolCall(invocation, overrides: toolOverrides, issueId: issue.id)
            lastToolCallResult = toolResult

            // Log and add to conversation
            _ = try? IssueStore.createEvent(
                IssueEvent.withPayload(
                    issueId: issue.id,
                    eventType: .toolCallExecuted,
                    payload: EventPayload.ToolCall(
                        tool: invocation.toolName,
                        step: stepIndex,
                        arguments: invocation.jsonArguments,
                        result: toolResult.result
                    )
                )
            )

            messages.append(
                ChatMessage(role: "assistant", content: nil, tool_calls: [toolResult.toolCall], tool_call_id: nil)
            )
            messages.append(
                ChatMessage(
                    role: "tool",
                    content: toolResult.result,
                    tool_calls: nil,
                    tool_call_id: toolResult.toolCall.id
                )
            )

            // Step complete if expected tool was called (or no specific tool expected)
            if step.toolName == nil || invocation.toolName == step.toolName {
                break
            }
        }

        plan.steps[stepIndex].isComplete = true
        currentPlan = plan

        return StepResult(
            stepIndex: stepIndex,
            responseContent: allResponseContent,
            toolCallResult: lastToolCallResult,
            isComplete: true,
            remainingToolCalls: plan.maxToolCalls - plan.toolCallCount,
            inputTokens: totalInputTokens,
            outputTokens: totalOutputTokens
        )
    }

    /// Builds the prompt for executing a specific step
    private func buildStepPrompt(step: PlanStep, stepIndex: Int, totalSteps: Int) -> String {
        var prompt = "Execute step \(stepIndex + 1)/\(totalSteps): \(step.description)"

        if let toolName = step.toolName {
            prompt += "\n\nUse the `\(toolName)` tool to complete this step."

            if toolName == "batch" {
                prompt += " Format: {\"operations\": [{\"tool\": \"...\", \"args\": {...}}, ...]}"
            }
        }

        prompt += "\n\nCall the tool now."

        return prompt
    }

    /// Executes a tool call
    private func executeToolCall(
        _ invocation: ServiceToolInvocation,
        overrides: [String: Bool]?,
        issueId: String
    ) async throws -> ToolCallResult {
        let callId =
            invocation.toolCallId ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"

        // Execute tool with issue context for file operation logging
        let result = await executeToolOnMainActor(
            name: invocation.toolName,
            argumentsJSON: invocation.jsonArguments,
            overrides: overrides,
            issueId: issueId
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

    /// Helper to execute tool on MainActor with issue context
    @MainActor
    private func executeToolOnMainActor(
        name: String,
        argumentsJSON: String,
        overrides: [String: Bool]?,
        issueId: String
    ) async -> String {
        do {
            // Wrap with execution context so folder tools can log operations
            return try await AgentExecutionContext.$currentIssueId.withValue(issueId) {
                try await ToolRegistry.shared.execute(
                    name: name,
                    argumentsJSON: argumentsJSON,
                    overrides: overrides
                )
            }
        } catch {
            print("[AgentExecutionEngine] Tool execution failed: \(error)")
            return "[REJECTED] \(error.localizedDescription)"
        }
    }

    // MARK: - Token Estimation

    /// Estimate input tokens from messages (rough heuristic: ~4 chars per token)
    private func estimateInputTokens(_ messages: [ChatMessage]) -> Int {
        let totalChars = messages.reduce(0) { sum, msg in
            sum + (msg.content?.count ?? 0)
        }
        return max(1, totalChars / 4)
    }

    /// Estimate output tokens from response content (rough heuristic: ~4 chars per token)
    private func estimateOutputTokens(_ content: String) -> Int {
        return max(1, content.count / 4)
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

        // Extract token usage from response
        let inputTokens = response.usage.prompt_tokens
        let outputTokens = response.usage.completion_tokens

        guard let content = response.choices.first?.message.content else {
            throw AgentExecutionError.verificationFailed("No response from model")
        }

        return parseVerificationResult(from: content, inputTokens: inputTokens, outputTokens: outputTokens)
    }

    /// Parses the verification result from LLM response
    private func parseVerificationResult(
        from content: String,
        inputTokens: Int,
        outputTokens: Int
    ) -> VerificationResult {
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
            remainingWork: remaining,
            inputTokens: inputTokens,
            outputTokens: outputTokens
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

        ## Capability Selection

        You have access to tools (callable functions) and skills (specialized knowledge/guidance).
        When creating your plan, select which capabilities you need:

        - Review the available capabilities catalog carefully
        - Select only the tools and skills that are relevant to this specific task
        - Include your selections in the JSON response as `selected_tools` and `selected_skills`
        - If you don't need any capabilities, use empty arrays
        - Your selection persists for the entire task, including any subtasks
        - Only selected capabilities will be available during execution

        ## Planning Guidelines

        When creating a plan:
        1. Break down the task into concrete, actionable steps
        2. Each step should accomplish one specific thing
        3. Consider dependencies between steps
        4. Use selected tools when appropriate
        5. Keep the plan focused and efficient

        ## Execution Guidelines

        When executing steps:
        1. Follow the plan systematically
        2. Use tools to accomplish tasks
        3. Report what was done after each step
        4. Note any discoveries or issues encountered

        ## Asking for Clarification

        Request clarification when:
        - The task has multiple valid interpretations with significantly different outcomes
        - Critical information is missing (e.g., file paths, configuration values)
        - The scope is unclear (e.g., "update the tests" - which tests?)

        Do NOT ask for clarification when:
        - You can make a reasonable assumption and note it in the plan
        - The ambiguity is minor and won't affect the outcome
        - The information can be discovered during execution (e.g., by reading files)

        ## Constraints

        - Maximum \(Self.maxToolCallsPerIssue) tool calls per task
        - If a task is too large, it will be decomposed into subtasks
        - Subtasks inherit the same capability selection from the parent
        """
    }
}

// MARK: - Supporting Types

/// Result of plan generation
public enum PlanResult: Sendable {
    case ready(ExecutionPlan, inputTokens: Int, outputTokens: Int)
    case needsDecomposition(
        steps: [PlanStep],
        suggestedChunks: [[PlanStep]],
        inputTokens: Int,
        outputTokens: Int,
        selectedTools: [String],
        selectedSkills: [String]
    )
    case needsClarification(ClarificationRequest, inputTokens: Int, outputTokens: Int)
}

/// Result of executing a step
public struct StepResult: Sendable {
    public let stepIndex: Int
    public let responseContent: String
    public let toolCallResult: ToolCallResult?
    public let isComplete: Bool
    public let remainingToolCalls: Int
    /// Estimated input tokens consumed by this step
    public let inputTokens: Int
    /// Estimated output tokens consumed by this step
    public let outputTokens: Int
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
    /// Estimated input tokens consumed by verification
    public let inputTokens: Int
    /// Estimated output tokens consumed by verification
    public let outputTokens: Int
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
