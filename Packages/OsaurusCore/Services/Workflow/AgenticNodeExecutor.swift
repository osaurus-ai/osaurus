//
//  AgenticNodeExecutor.swift
//  osaurus
//
//  Agentic inference nodes: a bounded tool loop over the node's listed MCP
//  and plugin tools, then one call for the output (plain text for a single
//  string field, schema-enforced otherwise; see `InferenceNodeExecutor`). Only the
//  listed tools are exposed and only they can execute. The loop ends when
//  the model stops calling tools or the step budget runs out; either way the
//  final call answers from what the tools returned. A `share_artifact`
//  call adds the file to the run's files.
//

import Foundation

enum AgenticNodeExecutor {
    /// Tool calls a node may make, whatever its `maxSteps` says.
    static let stepCeiling = 12
    /// Characters of one tool result carried into the model's history.
    static let resultCharacterLimit = 8_000

    /// One model turn in the loop: either tool calls or a final reply.
    struct Turn: Sendable {
        var text: String?
        var calls: [ToolCall]
        var inputTokens: Int?
        var outputTokens: Int?
    }

    /// The pieces the loop talks to, injectable for tests.
    struct Runtime: Sendable {
        var step: @Sendable (_ model: String, _ messages: [ChatMessage], _ tools: [Tool]) async throws -> Turn
        var execute: @Sendable (_ name: String, _ arguments: String, _ scope: ToolExecutionScope) async -> String
        var finish:
            @Sendable (_ model: String, _ prompt: String, _ system: String, _ schema: JSONValue, _ timeout: TimeInterval)
                async throws -> String
        var specs: @Sendable (_ names: [String]) async -> [Tool]

        static let live = Runtime(
            step: { model, messages, tools in
                // A local model loads under the run's owner, like a generate
                // step's; never `.httpAPI`, which gates Router spend.
                let owner = InferenceNodeExecutor.residencyRequestSource(model: model)
                let engine = ChatEngine(
                    source: owner == .httpAPI ? .agent : owner, activitySource: .agent, privacyReviewMode: .autoScrub)
                var request = ChatCompletionRequest(
                    model: model, messages: messages, temperature: nil, max_tokens: nil, stream: false,
                    top_p: nil, frequency_penalty: nil, presence_penalty: nil, stop: nil, n: nil,
                    tools: tools, tool_choice: nil, session_id: nil)
                request.samplingParametersAreImplicit = true
                request.isAgentRequest = true
                let response = try await engine.completeChat(request: request)
                let message = response.choices.first?.message
                return Turn(
                    text: message?.content, calls: message?.tool_calls ?? [],
                    inputTokens: response.usage.prompt_tokens, outputTokens: response.usage.completion_tokens)
            },
            execute: { name, arguments, scope in
                do {
                    return try await ToolNodeExecutor.executeInScope(name: name, arguments: arguments, scope: scope)
                } catch {
                    return ToolEnvelope.failure(
                        kind: .executionError, message: WorkflowFailure.message(error), tool: name)
                }
            },
            finish: { model, prompt, system, schema, timeout in
                let owner = InferenceNodeExecutor.residencyRequestSource(model: model)
                if StructuredOutputSchema.singleTextField(schema) != nil {
                    return try await CoreModelService.shared.generateNodeText(
                        model: model, prompt: prompt, systemPrompt: system, timeout: timeout,
                        purpose: "workflow_node", requestSource: owner)
                }
                return try await CoreModelService.shared.generateStructured(
                    model: model, prompt: prompt, systemPrompt: system, schema: schema, timeout: timeout,
                    purpose: "workflow_node", requestSource: owner)
            },
            specs: { names in
                await MainActor.run {
                    WorkflowToolCatalog.ensureRegistered()
                    return ToolRegistry.shared.specs(forTools: names)
                }
            }
        )
    }

    static func run(
        spec: InferenceSpec, tools: [ToolRef], maxSteps: Int, context: WorkflowNodeContext
    ) async throws -> WorkflowNodeOutcome {
        try await run(spec: spec, tools: tools, maxSteps: maxSteps, context: context, runtime: .live)
    }

    static func run(
        spec: InferenceSpec, tools: [ToolRef], maxSteps: Int, context: WorkflowNodeContext, runtime: Runtime
    ) async throws -> WorkflowNodeOutcome {
        guard let model = context.model else { throw WorkflowNodeError.noModel(slot: spec.modelSlot) }
        let names = Array(Set(tools.map(\.name))).sorted()
        if let excluded = names.first(where: WorkflowValidator.isExcludedFromWorkflows) {
            throw WorkflowNodeError.unsupported(L("\(excluded) cannot run as a workflow step."))
        }
        let specs = await runtime.specs(names)
        let available = Set(specs.map(\.function.name))
        if let missing = names.first(where: { !available.contains($0) }) {
            throw WorkflowNodeError.unsupported(L("The tool \(missing) is not available on this Mac."))
        }
        let scope = ToolExecutionScope(exposed: specs)
        let started = Date()
        let budget = max(0, min(maxSteps, stepCeiling))

        let split = InferenceNodeExecutor.splitInstructions(spec: spec, context: context)
        let system = split.text
        let userPrompt = InferenceNodeExecutor.userPrompt(context: context, untrusted: split.untrusted)
        var messages = [
            ChatMessage(role: "system", content: system + "\n\n" + loopInstructions(budget: budget)),
            ChatMessage(role: "user", content: userPrompt),
        ]
        var record: [(name: String, arguments: String, result: String)] = []
        var records: [WorkflowToolCallRecord] = []
        var artifacts: [WorkflowArtifact] = []
        let artifactsDir = OsaurusPaths.workflowRunArtifacts(workflowID: context.workflowID, runID: context.runID)
        var notes: String?
        var inputTokens = 0
        var outputTokens = 0

        while record.count < budget {
            try Task.checkCancellation()
            let turn = try await runtime.step(model, messages, specs)
            inputTokens += turn.inputTokens ?? 0
            outputTokens += turn.outputTokens ?? 0
            guard !turn.calls.isEmpty else {
                notes = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            let calls = Array(turn.calls.prefix(budget - record.count))
            messages.append(ChatMessage(role: "assistant", content: turn.text, tool_calls: calls, tool_call_id: nil))
            for call in calls {
                try Task.checkCancellation()
                let callStarted = Date()
                var result = await runtime.execute(call.function.name, call.function.arguments, scope)
                if call.function.name == WorkflowArtifactCollector.shareToolName, !ToolEnvelope.isError(result) {
                    let shared = WorkflowArtifactCollector.share(
                        result, nodeID: context.node.id, scope: WorkflowFileScope(context: context), into: artifactsDir)
                    result = shared.modelResult
                    if let artifact = shared.artifact { artifacts.append(artifact) }
                }
                records.append(
                    WorkflowToolCallRecord(
                        name: call.function.name, arguments: call.function.arguments, result: result,
                        durationMs: Int(Date().timeIntervalSince(callStarted) * 1000),
                        isError: ToolEnvelope.isError(result)))
                let carried = String(result.prefix(resultCharacterLimit))
                record.append((call.function.name, call.function.arguments, carried))
                messages.append(ChatMessage(role: "tool", content: carried, tool_calls: nil, tool_call_id: call.id))
            }
        }

        let remaining = max(5, context.timeout - Date().timeIntervalSince(started))
        let schema = context.node.effectiveOutputSchema
        let textField = StructuredOutputSchema.singleTextField(schema)
        let finalSystem =
            system + "\n\n" + Self.finalInstructions
            + (textField.map { InferenceNodeExecutor.textContract(field: $0, schema: schema) }
                ?? InferenceNodeExecutor.outputContract(schema))
        let output: JSONValue
        do {
            let text = try await runtime.finish(
                model, finalPrompt(userPrompt: userPrompt, record: record, notes: notes), finalSystem, schema,
                remaining)
            output =
                try textField.map { try StructuredOutputSchema.decodeText(text, field: $0, schema: schema) }
                ?? StructuredOutputSchema.decode(text, schema: schema)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw records.isEmpty ? error : RecordedNodeFailure(underlying: error, toolCallRecords: records)
        }
        return WorkflowNodeOutcome(
            output: output, model: model, toolCalls: record.map(\.name), toolCallRecords: records,
            inputTokens: inputTokens > 0 ? inputTokens : nil, outputTokens: outputTokens > 0 ? outputTokens : nil,
            artifacts: artifacts)
    }

    static func loopInstructions(budget: Int) -> String {
        "Use the tools to gather what this step needs (at most \(budget) tool calls). "
            + "When you have enough, stop calling tools and reply with a short note of what you found."
    }

    static let finalInstructions =
        "Produce this step's output from the input and the tool results below. Use only what they contain."

    static func finalPrompt(
        userPrompt: String, record: [(name: String, arguments: String, result: String)], notes: String?
    ) -> String {
        var parts = ["Input:\n" + userPrompt]
        if record.isEmpty {
            parts.append("No tools were called.")
        } else {
            for (index, call) in record.enumerated() {
                parts.append("Tool call \(index + 1): \(call.name) \(call.arguments)\nResult:\n\(call.result)")
            }
        }
        if let notes, !notes.isEmpty { parts.append("Notes:\n" + notes) }
        return parts.joined(separator: "\n\n")
    }
}
