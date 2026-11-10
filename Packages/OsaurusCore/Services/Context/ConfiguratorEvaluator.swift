//
//  ConfiguratorEvaluator.swift
//  osaurus
//
//  Drives one real Configurator handoff for the OsaurusEvals `configurator`
//  domain: the same seed (the user's words, the matching catalog rows and
//  guide sections), persona, tool surface, and step budget a
//  `configurator_handoff` from the Orchestrator gets, on the same
//  `HiddenAgentHandoffKind`. Every tool call the Configurator makes is
//  recorded so a case can score selection and arguments.
//
//  Headless: there is no approval card, so tool prompts auto-approve, as in
//  the `default_agent` lane before the split. Cases score what the model
//  chose, not the human tap.
//

import Foundation

@MainActor
public enum ConfiguratorEvaluator {
    /// Same bound as the `default_agent` lane: a hung live-service call
    /// becomes a typed timeout instead of wedging the suite.
    public static let toolExecutionTimeout: TimeInterval = 25
    /// Tools that own their budget in the app (`osaurus_import` fetches and
    /// runs a local reader with its own wall clock) get the longer bound,
    /// so the lane measures the tool rather than the cap.
    public static let ownBudgetToolExecutionTimeout: TimeInterval = 300

    public static func run(query: String, model: String? = nil) async -> CapabilityClaimsTranscript {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let resolvedModel = model ?? ChatConfigurationStore.load().coreModelIdentifier ?? "foundation"
        let sessionId = "eval-configurator-\(UUID().uuidString)"
        let log = HandoffToolLog()
        let dispatch: @Sendable (ServiceToolInvocation) async -> String = { invocation in
            let ownsBudget = await MainActor.run { ToolRegistry.shared.bypassesTimeout(invocation.toolName) }
            let result = await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
                await CapabilityClaimsEvaluator.executeTool(
                    name: invocation.toolName,
                    argumentsJSON: invocation.jsonArguments,
                    timeout: ownsBudget ? ownBudgetToolExecutionTimeout : toolExecutionTimeout)
            }
            log.append(
                HandoffToolCall(name: invocation.toolName, argumentsJSON: invocation.jsonArguments, result: result))
            return result
        }

        let kind = await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                await ChatExecutionContext.$currentUserRequest.withValue(query) {
                    await ConfiguratorHandoffTool(evalModel: resolvedModel, dispatchOverride: dispatch)
                        .makeKind(argumentsJSON: #"{"brief":""}"#)
                }
            }
        }
        guard let kind else {
            return Self.transcript(log: log, finalText: "", steps: 0, prompt: "", usage: nil, error: "empty query")
        }

        let scope = SubagentScope(sessionId: sessionId, toolCallId: "eval-handoff", agentId: Agent.defaultId)
        let feed = SubagentFeed(
            toolCallId: "eval-handoff", kindId: kind.capability.id, title: kind.feedTitle,
            agentId: Agent.defaultId, parentSessionId: sessionId)
        do {
            let resolved = try await kind.resolveModel(scope)
            let prompt = kind.seedMessages.compactMap(\.content).joined(separator: "\n\n")
            let result = try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                try await kind.run(scope, resolved, feed: feed, interrupt: InterruptToken())
            }
            return Self.transcript(
                log: log, finalText: result.summary ?? "", steps: result.payload["steps"] as? Int ?? 0,
                prompt: prompt, usage: result.payload["usage"] as? [String: Any], error: nil)
        } catch {
            let prompt = kind.seedMessages.compactMap(\.content).joined(separator: "\n\n")
            return Self.transcript(
                log: log, finalText: "", steps: 0, prompt: prompt, usage: nil, error: "\(error)")
        }
    }

    private static func transcript(
        log: HandoffToolLog,
        finalText: String,
        steps: Int,
        prompt: String,
        usage: [String: Any]?,
        error: String?
    ) -> CapabilityClaimsTranscript {
        CapabilityClaimsTranscript(
            toolCalls: log.all.map {
                .init(name: $0.name, arguments: $0.argumentsJSON, resultPreview: String($0.result.prefix(2000)))
            },
            finalText: finalText,
            iterations: steps,
            hitIterationCap: steps >= ConfiguratorHandoffTool.maxSteps,
            systemPrompt: prompt,
            loadedToolNames: [],
            error: error,
            decodeTokensPerSecond: usage?["tokens_per_second"] as? Double,
            completionTokens: usage?["completion_tokens"] as? Int,
            promptTokensTotal: usage?["prompt_tokens"] as? Int,
            modelSteps: steps
        )
    }
}
