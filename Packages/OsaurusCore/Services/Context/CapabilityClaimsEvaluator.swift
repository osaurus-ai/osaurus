//
//  CapabilityClaimsEvaluator.swift
//  osaurus
//
//  Public facade that drives a real, multi-turn agent loop for the
//  OsaurusEvals `capability_claims` domain. It runs the whole chat path —
//  compose prompt → model call → tool dispatch → drain
//  `CapabilityLoadBuffer` → re-compose → continue — so eval cases can
//  assert on what the model SAYS and DOES when asked "do you have X".
//
//  The internal `ChatCompletionRequest` / `ChatMessage` / `Tool` types
//  stay encapsulated; the public surface is a decode-friendly transcript
//  (ordered tool calls + final assistant text) plus an LLM-judge verdict
//  so the runner can combine deterministic transcript checks with a
//  rubric grade.
//

import Foundation

// MARK: - Public transcript

/// Decode-friendly record of one capability-claims agent run. Carries
/// the ordered tool calls and final assistant text the runner scores,
/// plus forensics (first-turn system prompt, mid-session loads) so a
/// failing row is debuggable from the JSON report alone.
public struct CapabilityClaimsTranscript: Sendable, Codable {
    /// One tool invocation the model emitted, in call order. Arguments
    /// are the raw JSON string the model produced (post-parse), so a
    /// case can assert both the tool name and its argument shape.
    public struct ToolInvocation: Sendable, Codable {
        public let name: String
        public let arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    /// Every tool call across every iteration, flattened in order. The
    /// deterministic transcript checks (did it discover/load before
    /// answering; did it load `Osaurus Browser` before browser tools)
    /// read this list.
    public let toolCalls: [ToolInvocation]
    /// The model's last assistant message text — what the LLM judge
    /// grades against the rubric.
    public let finalText: String
    /// How many model round-trips the loop took before it stopped
    /// emitting tool calls (or hit the cap).
    public let iterations: Int
    /// True when the loop stopped because it reached `maxIterations`
    /// rather than because the model produced a tool-call-free answer.
    /// A capped run is suspect — the model may have been looping.
    public let hitIterationCap: Bool
    /// First-turn system prompt (post-compose). Lets a report show
    /// "what the model saw" — including the enabled-capabilities
    /// manifest — without re-deriving it.
    public let systemPrompt: String
    /// Tool names brought into the schema mid-session via
    /// `capabilities_load`, in load order.
    public let loadedToolNames: [String]
    /// Non-nil when the loop aborted (model not routable, engine threw).
    /// `finalText` is empty in that case.
    public let error: String?

    public init(
        toolCalls: [ToolInvocation],
        finalText: String,
        iterations: Int,
        hitIterationCap: Bool,
        systemPrompt: String,
        loadedToolNames: [String],
        error: String?
    ) {
        self.toolCalls = toolCalls
        self.finalText = finalText
        self.iterations = iterations
        self.hitIterationCap = hitIterationCap
        self.systemPrompt = systemPrompt
        self.loadedToolNames = loadedToolNames
        self.error = error
    }
}

/// One LLM-judge verdict for one rubric condition. `pass` is the grade;
/// `reason` is the judge's one-line justification, surfaced in the
/// report so a contributor can see WHY a condition failed.
public struct CapabilityClaimsJudgement: Sendable, Codable {
    public let pass: Bool
    public let reason: String

    public init(pass: Bool, reason: String) {
        self.pass = pass
        self.reason = reason
    }
}

// MARK: - Evaluator

/// Public entry point for the capability-claims behaviour evals. Lives
/// on the main actor because the prompt composer, tool registry, and
/// agent lookups it drives are all main-actor-isolated.
@MainActor
public enum CapabilityClaimsEvaluator {

    /// Run the multi-turn agent loop for `query` against the live
    /// registry/agent state and return the transcript. The loop mirrors
    /// the production chat path: it composes the real system prompt
    /// (manifest included), calls the routed model with the resolved
    /// tool schema, dispatches every tool call through
    /// `ToolRegistry.execute`, drains tools loaded via
    /// `capabilities_load` back into the schema, and continues until the
    /// model answers without calling a tool (or `maxIterations` is hit).
    ///
    /// `agentId` defaults to the active agent. `model` defaults to
    /// whatever `ChatConfigurationStore` currently routes to (set by the
    /// eval runner's `ModelOverride`).
    public static func run(
        query: String,
        agentId: UUID? = nil,
        maxIterations: Int = 6,
        model: String? = nil
    ) async -> CapabilityClaimsTranscript {
        let resolvedAgentId = agentId ?? AgentManager.shared.activeAgent.id
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"
        let engine = ChatEngine()

        var history: [ChatMessage] = [ChatMessage(role: "user", content: query)]
        var toolCalls: [CapabilityClaimsTranscript.ToolInvocation] = []
        var loadedToolNames: [String] = []
        var additionalToolNames: LoadedTools = []
        var firstTurnPrompt = ""
        var finalText = ""
        var iterations = 0
        var hitCap = false

        // Bind the agent for the whole loop so capability-tool scoping,
        // `capabilities_load` agent grants, and agent-scoped tools see
        // the same agent the prompt was composed for.
        let result:
            (
                text: String, calls: [CapabilityClaimsTranscript.ToolInvocation], loaded: [String], iters: Int,
                cap: Bool, prompt: String, err: String?
            )
        do {
            result = try await ChatExecutionContext.$currentAgentId.withValue(resolvedAgentId) {
                while iterations < maxIterations {
                    let composed = await SystemPromptComposer.composeChatContext(
                        agentId: resolvedAgentId,
                        executionMode: .none,
                        model: resolvedModel,
                        query: query,
                        messages: history,
                        additionalToolNames: additionalToolNames
                    )
                    if iterations == 0 { firstTurnPrompt = composed.prompt }

                    var requestMessages: [ChatMessage] = [
                        ChatMessage(role: "system", content: composed.prompt)
                    ]
                    requestMessages.append(contentsOf: history)

                    let request = ChatCompletionRequest(
                        model: resolvedModel,
                        messages: requestMessages,
                        temperature: 0.0,
                        max_tokens: 2048,
                        stream: false,
                        top_p: nil,
                        frequency_penalty: nil,
                        presence_penalty: nil,
                        stop: nil,
                        n: nil,
                        tools: composed.tools,
                        tool_choice: .auto,
                        session_id: nil
                    )

                    let response = try await engine.completeChat(request: request)
                    guard let choice = response.choices.first else {
                        finalText = ""
                        break
                    }
                    let message = choice.message
                    if let content = message.content, !content.isEmpty {
                        finalText = content
                    }

                    guard let calls = message.tool_calls, !calls.isEmpty else {
                        // Tool-call-free answer → the loop is done.
                        break
                    }

                    iterations += 1

                    // Echo the assistant tool-call turn back into history
                    // so the model sees its own request alongside results.
                    history.append(
                        ChatMessage(
                            role: "assistant",
                            content: message.content,
                            tool_calls: calls,
                            tool_call_id: nil
                        )
                    )

                    for call in calls {
                        toolCalls.append(
                            .init(name: call.function.name, arguments: call.function.arguments)
                        )
                        let toolResult: String
                        do {
                            toolResult = try await ToolRegistry.shared.execute(
                                name: call.function.name,
                                argumentsJSON: call.function.arguments
                            )
                        } catch {
                            toolResult = ToolEnvelope.failure(
                                kind: .unavailable,
                                message: "Tool execution failed: \(error.localizedDescription)",
                                tool: call.function.name
                            )
                        }
                        history.append(
                            ChatMessage(
                                role: "tool",
                                content: toolResult,
                                tool_calls: nil,
                                tool_call_id: call.id
                            )
                        )
                    }

                    // Pull tools loaded via capabilities_load into the
                    // schema for the next compose, exactly like the chat
                    // loop does.
                    let drained = await CapabilityLoadBuffer.shared.drain()
                    for spec in drained {
                        let name = spec.function.name
                        if !additionalToolNames.contains(name) {
                            additionalToolNames.insert(name)
                            loadedToolNames.append(name)
                        }
                    }
                }
                if iterations >= maxIterations { hitCap = true }
                return (finalText, toolCalls, loadedToolNames, iterations, hitCap, firstTurnPrompt, nil)
            }
        } catch {
            return CapabilityClaimsTranscript(
                toolCalls: toolCalls,
                finalText: "",
                iterations: iterations,
                hitIterationCap: false,
                systemPrompt: firstTurnPrompt,
                loadedToolNames: loadedToolNames,
                error: error.localizedDescription
            )
        }

        return CapabilityClaimsTranscript(
            toolCalls: result.calls,
            finalText: result.text,
            iterations: result.iters,
            hitIterationCap: result.cap,
            systemPrompt: result.prompt,
            loadedToolNames: result.loaded,
            error: result.err
        )
    }

    /// Grade `finalText` against each rubric `condition` with a single
    /// LLM-judge call. Returns one verdict per condition (same order).
    /// Falls back to a `pass: false` verdict carrying the error when the
    /// judge model can't be reached or returns unparseable output — a
    /// case should never silently pass because the judge broke.
    ///
    /// `model` defaults to the run model; pass a stronger judge model
    /// (the runner threads `JUDGE_MODEL`) when grading small-model output.
    public static func judge(
        finalText: String,
        conditions: [String],
        model: String? = nil
    ) async -> [CapabilityClaimsJudgement] {
        guard !conditions.isEmpty else { return [] }
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"
        let engine = ChatEngine()

        let numbered = conditions.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let judgeSystem = """
            You are a strict evaluator. You are given an assistant's final \
            reply and a numbered list of conditions. For each condition, \
            decide whether the reply satisfies it. Judge ONLY the reply text \
            against each condition; do not invent requirements.

            Respond with ONLY a JSON object of this exact shape, no prose:
            {"verdicts": [{"pass": true, "reason": "<short>"}, ...]}
            One verdict per condition, in order.
            """
        let judgeUser = """
            Assistant reply:
            \"\"\"
            \(finalText)
            \"\"\"

            Conditions:
            \(numbered)
            """

        let request = ChatCompletionRequest(
            model: resolvedModel,
            messages: [
                ChatMessage(role: "system", content: judgeSystem),
                ChatMessage(role: "user", content: judgeUser),
            ],
            temperature: 0.0,
            max_tokens: 1024,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )

        do {
            let response = try await engine.completeChat(request: request)
            let raw = response.choices.first?.message.content ?? ""
            if let parsed = parseVerdicts(raw, expected: conditions.count) {
                return parsed
            }
            return conditions.map {
                CapabilityClaimsJudgement(
                    pass: false,
                    reason: "judge output not parseable for condition: \($0)"
                )
            }
        } catch {
            return conditions.map { _ in
                CapabilityClaimsJudgement(
                    pass: false,
                    reason: "judge call failed: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Extract `{"verdicts":[{"pass":...,"reason":...}]}` from possibly
    /// chatty judge output. Scans for the first balanced JSON object so
    /// a model that wraps the answer in prose or a code fence still
    /// parses. Returns nil when the count doesn't match the conditions.
    private static func parseVerdicts(
        _ raw: String,
        expected: Int
    ) -> [CapabilityClaimsJudgement]? {
        guard let objectString = firstJSONObject(in: raw),
            let data = objectString.data(using: .utf8)
        else { return nil }

        struct Envelope: Decodable {
            struct Verdict: Decodable {
                let pass: Bool
                let reason: String?
            }
            let verdicts: [Verdict]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
            envelope.verdicts.count == expected
        else { return nil }

        return envelope.verdicts.map {
            CapabilityClaimsJudgement(pass: $0.pass, reason: $0.reason ?? "")
        }
    }

    /// Return the substring of the first balanced `{...}` JSON object in
    /// `text`, or nil if there isn't one. Brace-counts so nested objects
    /// (the verdict array) are kept intact.
    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start ... index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
