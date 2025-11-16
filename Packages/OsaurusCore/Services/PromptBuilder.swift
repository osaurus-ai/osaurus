//
//  PromptBuilder.swift
//  osaurus
//
//  Created by Terence on 10/14/25.
//

import Foundation

struct OpenAIPromptBuilder {
    /// Build a textual prompt from OpenAI-format chat messages, preserving assistant tool_calls
    /// and subsequent tool results (role=="tool") so models can reason over them.
    static func buildPrompt(from chatMessages: [ChatMessage]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(max(6, chatMessages.count * 2))

        // Map tool_call_id -> function name for labeling tool results
        var toolIdToName: [String: String] = [:]
        for msg in chatMessages where msg.role == "assistant" {
            if let toolCalls = msg.tool_calls {
                for call in toolCalls {
                    toolIdToName[call.id] = call.function.name
                }
            }
        }

        for msg in chatMessages {
            switch msg.role {
            case "system":
                if let content = msg.content, !content.isEmpty {
                    parts.append("System:")
                    parts.append(content)
                }

            case "user":
                if let content = msg.content, !content.isEmpty {
                    parts.append("User:")
                    parts.append(content)
                }

            case "assistant":
                // If assistant provided tool_calls, surface them explicitly
                if let calls = msg.tool_calls, !calls.isEmpty {
                    for call in calls {
                        let name = call.function.name
                        let args = call.function.arguments
                        parts.append("Assistant (tool call):")
                        parts.append("function: \(name)")
                        parts.append("arguments: \(args)")
                    }
                }
                if let content = msg.content, !content.isEmpty {
                    parts.append("Assistant:")
                    parts.append(content)
                }

            case "tool":
                // Include tool output, labeled with function name when available
                let label: String = {
                    if let id = msg.tool_call_id, let name = toolIdToName[id] {
                        return "Tool(\(name)) result:"
                    }
                    return "Tool result:"
                }()
                if let content = msg.content, !content.isEmpty {
                    parts.append(label)
                    parts.append(content)
                }

            default:
                // Treat unknown roles as user content to avoid dropping information
                if let content = msg.content, !content.isEmpty {
                    parts.append("User:")
                    parts.append(content)
                }
            }
        }

        // End with assistant to invite a continuation
        parts.append("Assistant:")
        return parts.joined(separator: "\n")
    }
}
