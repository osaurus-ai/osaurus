//
//  AgentContentBlockBuilder.swift
//  osaurus
//
//  Converts historical agent execution events (IssueEvents) into ChatTurns
//  for rendering via ContentBlock.generateBlocks() in MessageThreadView.
//

import Foundation

// MARK: - Agent Content Block Builder

/// Converts historical IssueEvent records into ChatTurn arrays.
/// The resulting turns can be passed to ContentBlock.generateBlocks() for
/// consistent rendering with ChatView.
///
/// Note: Live execution is now handled directly in AgentSession by populating
/// executionTurns and using ContentBlock.generateBlocks().
enum AgentContentBlockBuilder {

    // MARK: - Historical Event Loading

    /// Builds ChatTurn array from historical IssueEvent records
    /// - Parameters:
    ///   - events: The historical events to process
    ///   - issue: The issue these events belong to
    ///   - personaName: Display name for assistant messages (unused, kept for API compatibility)
    /// - Returns: Array of ChatTurn representing the execution history
    @MainActor
    static func buildTurnsFromHistory(
        events: [IssueEvent],
        issue: Issue,
        personaName: String = "Agent"
    ) -> [ChatTurn] {
        var turns: [ChatTurn] = []

        // 1. Create user turn with issue context (matches live execution flow)
        // Use description if available (it's the full text), otherwise use title
        let displayContent: String
        if let description = issue.description, !description.isEmpty {
            displayContent = description
        } else {
            displayContent = issue.title
        }
        let userTurn = ChatTurn(role: .user, content: displayContent)
        turns.append(userTurn)

        // 2. Create assistant turn for responses
        let assistantTurn = ChatTurn(role: .assistant, content: "")
        turns.append(assistantTurn)

        // Collect data from events
        var planSteps: [PlanStep] = []
        var toolCalls: [ToolCallPayload] = []

        // First pass: collect plan and tool info
        for event in events {
            switch event.eventType {
            case .planCreated:
                if let payload = event.payload,
                    let data = payload.data(using: .utf8)
                {
                    // Try new format first (with full step data)
                    if let decoded = try? JSONDecoder().decode(PlanCreatedPayload.self, from: data) {
                        planSteps = decoded.steps.map { stepData in
                            PlanStep(
                                stepNumber: stepData.stepNumber,
                                description: stepData.description,
                                toolName: stepData.toolName,
                                isComplete: true  // Historical steps are complete
                            )
                        }
                    }
                    // Fallback to legacy format (step count only)
                    else if let decoded = try? JSONDecoder().decode(StepCountPayload.self, from: data) {
                        // Create placeholder steps for legacy data
                        for index in 0 ..< decoded.stepCount {
                            planSteps.append(
                                PlanStep(
                                    stepNumber: index + 1,
                                    description: "Step \(index + 1)",
                                    toolName: nil,
                                    isComplete: true
                                )
                            )
                        }
                    }
                }

            case .toolCallExecuted:
                if let payload = event.payload,
                    let data = payload.data(using: .utf8),
                    let decoded = try? JSONDecoder().decode(ToolCallPayload.self, from: data)
                {
                    toolCalls.append(decoded)
                }

            default:
                break
            }
        }

        // Build plan if we have steps
        if !planSteps.isEmpty {
            let plan = ExecutionPlan(
                issueId: issue.id,
                steps: planSteps,
                maxToolCalls: planSteps.count,
                toolCallCount: toolCalls.count
            )
            assistantTurn.plan = plan
            assistantTurn.currentPlanStep = planSteps.count  // All steps complete
        }

        // Second pass: process events for display
        for event in events {
            switch event.eventType {
            case .toolCallExecuted:
                if let payload = event.payload,
                    let data = payload.data(using: .utf8),
                    let decoded = try? JSONDecoder().decode(ToolCallPayload.self, from: data)
                {
                    // Create tool call with full arguments
                    let toolCall = ToolCall(
                        id: event.id,
                        type: "function",
                        function: ToolCallFunction(
                            name: decoded.tool,
                            arguments: decoded.arguments ?? "{}"
                        )
                    )

                    // Add to assistant turn's tool calls
                    if assistantTurn.toolCalls == nil {
                        assistantTurn.toolCalls = []
                    }
                    assistantTurn.toolCalls?.append(toolCall)

                    // Store result if available
                    if let result = decoded.result {
                        assistantTurn.toolResults[toolCall.id] = result
                    } else {
                        assistantTurn.toolResults[toolCall.id] = "[Completed]"
                    }
                }

            case .executionCompleted:
                if let payload = event.payload,
                    let data = payload.data(using: .utf8),
                    let decoded = try? JSONDecoder().decode(ExecutionCompletedPayload.self, from: data)
                {
                    // Use summary if available, otherwise generate status
                    if let summary = decoded.summary, !summary.isEmpty {
                        assistantTurn.appendContent(summary)
                    } else {
                        let status = decoded.success ? "Completed successfully" : "Failed"
                        var text = status
                        if decoded.discoveries > 0 {
                            text += " (discovered \(decoded.discoveries) new issues)"
                        }
                        assistantTurn.appendContent(text)
                    }
                }

            case .decomposed:
                if let payload = event.payload,
                    let data = payload.data(using: .utf8),
                    let decoded = try? JSONDecoder().decode(ChildCountPayload.self, from: data)
                {
                    assistantTurn.appendContent("Decomposed into \(decoded.childCount) sub-issues")
                }

            default:
                // Other events handled elsewhere or not displayed
                break
            }
        }

        // Add result if issue is closed
        if issue.status == .closed, let result = issue.result {
            if !assistantTurn.contentIsEmpty {
                assistantTurn.appendContent("\n\n")
            }
            assistantTurn.appendContent(result)
        }

        // Consolidate all content
        for turn in turns {
            turn.consolidateContent()
        }

        return turns
    }
}

// MARK: - Payload Decoding Types

/// Enhanced tool call payload with arguments and result
private struct ToolCallPayload: Decodable {
    let tool: String
    let step: Int
    let arguments: String?
    let result: String?
}

/// Enhanced plan payload with full step details
private struct PlanCreatedPayload: Decodable {
    let steps: [PlanStepData]

    struct PlanStepData: Decodable {
        let stepNumber: Int
        let description: String
        let toolName: String?
    }
}

/// Execution completed payload with optional summary
private struct ExecutionCompletedPayload: Decodable {
    let success: Bool
    let discoveries: Int
    let summary: String?
}

private struct ChildCountPayload: Decodable {
    let childCount: Int
}

/// Legacy step count payload (for backward compatibility)
private struct StepCountPayload: Decodable {
    let stepCount: Int
}
