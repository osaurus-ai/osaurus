//
//  HiddenAgentHandoffRunner.swift
//  osaurus
//
//  Runs a hidden built-in agent (the Configurator; the Architect inline in
//  step 3) inside the Orchestrator's turn, on the shared subagent host
//  (`SubagentSession`): recursion guard, admission, residency handoff, the
//  live feed under the handoff's tool call, and Stop.
//
//  What it skips, and only that: the spawn pool membership check and the
//  spawn permission prompt. The user never added these built-ins to a pool,
//  so asking "allow Osaurus to use the Configurator?" would be noise. Every
//  tool the hidden agent calls still runs through `ToolRegistry.execute`
//  with its own ask/allow/deny policy, and every approval card still shows
//  (the `osaurus_config` plan card, `browser_use` confirms, workflow test
//  runs). The runner never binds `autoApproveToolPrompts`.
//
//  Each run starts from a fresh context: the target's persona, then one user
//  message carrying the handoff. Nothing from earlier handoffs carries over.
//

import Foundation

/// One tool call a hidden agent made, kept so the target can classify its
/// outcome (applied, declined, ...) from what actually happened rather than
/// from its prose.
struct HandoffToolCall: Sendable {
    let name: String
    let argumentsJSON: String
    let result: String
}

/// Thread-safe log of a run's tool calls.
final class HandoffToolLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [HandoffToolCall] = []

    func append(_ call: HandoffToolCall) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    var all: [HandoffToolCall] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// A hidden target: who runs, with what, and how its run becomes a
/// `HandoffResult`.
struct HiddenAgentTarget: Sendable {
    let agentId: UUID
    let capability: SubagentCapability
    /// Neutral feed header. Never the agent's internal name.
    let feedTitle: String
    let maxSteps: Int
    let wallClockSeconds: TimeInterval
    /// The persona, resolved on the main actor at run time (so a settings
    /// edit applies on the next handoff).
    let systemPrompt: @MainActor @Sendable () -> String
    /// The tool names the target may call.
    let toolNames: @MainActor @Sendable () -> [String]
    /// The target's own model, or nil to use the invoking chat's model.
    let configuredModel: @MainActor @Sendable () -> String?
    let temperature: @MainActor @Sendable () -> Float?
    let classify:
        @Sendable (_ calls: [HandoffToolCall], _ digest: String, _ exposedToolNames: Set<String>) -> HandoffResult
    /// A call after which the target has nothing left to do: the run ends
    /// there instead of waiting for the model's closing reply.
    var endsRun: (@Sendable (HandoffToolCall) -> Bool)? = nil
    /// The feed's step while the model works.
    var workingPhase: String = "working"
}

final class HiddenAgentHandoffKind: SubagentKind, SubagentPostAdmissionResidencyPlanning, SubagentContextAdmission,
    @unchecked Sendable
{
    let target: HiddenAgentTarget
    let seedUserContent: String
    /// The session id the target's tool calls see, in place of the chat's.
    /// The inline Architect drafts into a draft of its own this way.
    let toolSessionId: String?

    /// Test seams: force the model and replace child dispatch.
    private let evalModel: String?
    private let dispatchOverride: (@Sendable (ServiceToolInvocation) async -> String)?
    private let streamProvider: AgentSubagentRunner.ResponsesStreamProvider?

    private var residencyPlan: ResidencyPlan = .none
    private var invokingParentModelName: String?
    private var resolvedPrompt = ""
    private var resolvedSpecs: [Tool] = []
    private var resolvedTemperature: Float?
    /// The run's position ceiling, derived like a delegated agent's from the
    /// delegation budgets, the target's steps, its prompt, tools, and seed,
    /// within the model's context window. The runner trims history to it and
    /// the runtime refuses a request past it, so admission prices exactly it.
    /// Nil (before resolution, or on overflow) prices the whole window.
    private(set) var runContract: DelegatedRunContract?
    /// One round: the prompt, tools, seed, and a single step's output and
    /// tool result. Admission never fits the window below it.
    private(set) var minimumAdmissionContextPositions: Int?
    private(set) var admissionContextWasMemoryFitted = false

    private static let residencyIdleWaitSeconds = 120

    static let cappedAppliedText =
        "The change was applied, but the run used all its steps before writing a reply."

    /// What a run that hit its step cap still reports: only a change that
    /// landed, and never as a blank reply the caller would retry.
    static func cappedOutcome(_ outcome: HandoffResult) -> HandoffResult? {
        guard case .applied(let text) = outcome else { return nil }
        return text.isEmpty ? .applied(cappedAppliedText) : outcome
    }

    static let deadlineAppliedText =
        "The change was applied, but the run ran out of time before writing a reply."

    /// What a run that ran out of time still reports: any change that
    /// landed, even when a later call was cut off, so the caller does not
    /// retry and apply it twice.
    static func landedOutcome(
        _ calls: [HandoffToolCall], target: HiddenAgentTarget, exposed: Set<String>
    ) -> HandoffResult? {
        for call in calls.reversed() {
            switch target.classify([call], "", exposed) {
            case .applied(let text): return .applied(text.isEmpty ? deadlineAppliedText : text)
            case .needsSetup(let text): return .needsSetup(text.isEmpty ? deadlineAppliedText : text)
            default: continue
            }
        }
        return nil
    }

    init(
        target: HiddenAgentTarget,
        seedUserContent: String,
        toolSessionId: String? = nil,
        evalModel: String? = nil,
        dispatchOverride: (@Sendable (ServiceToolInvocation) async -> String)? = nil,
        streamProvider: AgentSubagentRunner.ResponsesStreamProvider? = nil
    ) {
        self.target = target
        self.seedUserContent = seedUserContent
        self.toolSessionId = toolSessionId
        self.evalModel = evalModel
        self.dispatchOverride = dispatchOverride
        self.streamProvider = streamProvider
    }

    var capability: SubagentCapability { target.capability }
    var feedTitle: String { target.feedTitle }

    /// The messages the run starts from. Exposed for tests: a fresh context
    /// is exactly these two messages.
    var seedMessages: [ChatMessage] {
        var messages: [ChatMessage] = []
        let prompt = resolvedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { messages.append(ChatMessage(role: "system", content: prompt)) }
        messages.append(ChatMessage(role: "user", content: seedUserContent))
        return messages
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        invokingParentModelName = scope.parentModelName
        let target = self.target
        let snapshot = await MainActor.run {
            () -> (prompt: String, specs: [Tool], model: String?, temperature: Float?) in
            (
                target.systemPrompt(),
                ToolRegistry.shared.specs(forTools: target.toolNames()),
                target.configuredModel(),
                target.temperature()
            )
        }
        resolvedPrompt = snapshot.prompt
        resolvedSpecs = snapshot.specs
        resolvedTemperature = snapshot.temperature
        let configured = snapshot.model
        let resolved = try await SubagentModelResolution.resolve(
            capabilityId: target.capability.id,
            agentId: target.agentId,
            evalModel: evalModel,
            invokingParentModelName: scope.parentModelName,
            idleWaitSeconds: Self.residencyIdleWaitSeconds,
            deniedMessage:
                "Answering this needs a different local model, and swapping local models is off "
                + "(Settings → Agents → Delegation).",
            unavailableMessage: "No model is selected, so Osaurus can't answer this. Pick a model first.",
            honorConfiguredOverride: false,
            defaultModel: {
                configured ?? scope.parentModelName ?? AgentManager.shared.effectiveModel(for: Agent.defaultId)
            }
        )
        residencyPlan = resolved.decision.plan
        await deriveRunContract(model: resolved.model, scope: scope)
        return ResolvedModel(
            name: resolved.model,
            id: resolved.installedModelID,
            isLocal: resolved.decision.isLocal
        )
    }

    private func deriveRunContract(model: String, scope: SubagentScope) async {
        let window = await AgentLoopBudget.resolveContextWindow(modelId: model)
        let specs = resolvedSpecs
        let (budgets, toolTokens) = await MainActor.run {
            (SpawnFanOutPolicy.effectiveBudgets(scope: scope), ToolRegistry.shared.totalEstimatedTokens(for: specs))
        }
        func contract(turns: Int) -> DelegatedRunContract? {
            var stepBudgets = budgets
            stepBudgets.maxDelegateTurns = turns
            return DelegatedRunContract.derive(
                seedCharacters: seedUserContent.count, systemPromptCharacters: resolvedPrompt.count,
                toolSchemaTokens: toolTokens, budgets: stepBudgets, toolEnabled: !specs.isEmpty,
                resolvedContextWindow: window)
        }
        runContract = contract(turns: max(1, target.maxSteps))
        minimumAdmissionContextPositions = contract(turns: 1)?.contextPositions
        admissionContextWasMemoryFitted = false
    }

    func admissionRequestEstimate() -> SubagentChildRequestEstimate? {
        runContract.map {
            SubagentChildRequestEstimate(
                seedCharacters: nil, maxOutputTokens: nil, enforcedPositionCeiling: $0.contextPositions)
        }
    }

    func tightenAdmissionContextPositions(to limit: Int) -> Bool {
        guard let contract = runContract, let minimum = minimumAdmissionContextPositions,
            limit >= minimum, limit < contract.contextPositions
        else { return false }
        runContract = DelegatedRunContract(
            responseTokens: contract.responseTokens, assistantTurns: contract.assistantTurns,
            contextPositions: limit)
        admissionContextWasMemoryFitted = true
        return true
    }

    func refreshedResidencyPlanAfterAdmission(for resolved: ResolvedModel) async throws -> ResidencyPlan {
        residencyPlan = try await SubagentResidency.refreshedPlan(
            for: resolved,
            invokingParentModelName: invokingParentModelName,
            idleWaitSeconds: Self.residencyIdleWaitSeconds,
            deniedMessage: "Osaurus could not safely swap to the model this needs."
        )
        return residencyPlan
    }

    func makeHandoff() -> SubagentHandoff {
        SubagentResidency.handoff(for: residencyPlan)
    }

    func admissionClass(_ resolved: ResolvedModel) -> SubagentAdmissionClass {
        SubagentResidency.admissionClass(isLocal: resolved.isLocal, plan: residencyPlan)
    }

    /// The spawn-pool permission is the one check skipped; tool-level
    /// policies and cards apply inside `run`.
    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        .allow
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        let log = HandoffToolLog()
        let execute: @Sendable (ServiceToolInvocation) async -> String =
            dispatchOverride
            ?? { invocation in
                do {
                    // Owned like the default subagent path when the tool cooperates with
                    // cancellation. A hidden agent's fixed set also holds tools nobody has
                    // audited for that (`osaurus_config`, `sandbox_exec`, `browser_use`,
                    // `clarify`), which the registry refuses under ownership; those keep its
                    // race, which cancels the body on Stop and waits out the grace window.
                    let owns = await ToolRegistry.shared.supportsSpawnedOwnership(
                        name: invocation.toolName, argumentsJSON: invocation.jsonArguments)
                    return try await ToolRegistry.shared.execute(
                        name: invocation.toolName,
                        argumentsJSON: invocation.jsonArguments,
                        ownsExecutionUntilTermination: owns
                    )
                } catch {
                    return ToolEnvelope.fromError(error, tool: invocation.toolName)
                }
            }
        let toolSessionId = self.toolSessionId
        let dispatch: @Sendable (ServiceToolInvocation) async -> String = { invocation in
            let result: String
            if let toolSessionId {
                result = await ChatExecutionContext.$currentSessionId.withValue(toolSessionId) {
                    await execute(invocation)
                }
            } else {
                result = await execute(invocation)
            }
            log.append(
                HandoffToolCall(name: invocation.toolName, argumentsJSON: invocation.jsonArguments, result: result))
            return result
        }
        let toolset = await TextSubagentKind.makeToolset(
            feed: feed,
            agentSpecs: resolvedSpecs,
            executionAgentId: target.agentId,
            dispatch: dispatch
        )

        var endsRun: (@Sendable (ServiceToolInvocation, String) -> Bool)?
        if let predicate = target.endsRun {
            endsRun = { invocation, result in
                predicate(
                    HandoffToolCall(name: invocation.toolName, argumentsJSON: invocation.jsonArguments, result: result))
            }
        }

        feed.emitPhase(target.workingPhase, detail: nil)
        let result = try await AgentSubagentRunner.run(
            modelName: resolved.name,
            seedMessages: seedMessages,
            maxTokens: nil,
            admissionPositionLimit: runContract?.contextPositions,
            maxIterations: target.maxSteps,
            deadline: Date().addingTimeInterval(target.wallClockSeconds),
            sessionId: "handoff-\(target.capability.id)-\(UUID().uuidString)",
            temperature: resolvedTemperature,
            enableThinking: scope.enableThinking(forDelegatedModel: resolved.name),
            reasoningEffort: scope.reasoningEffort(forDelegatedModel: resolved.name),
            isInterrupted: { interrupt.isInterrupted },
            toolset: toolset,
            endsRun: endsRun,
            onProgress: { [feed] tokens, tokensPerSecond in
                var detail = "\(tokens) tokens"
                if let tokensPerSecond { detail += String(format: " · %.1f tok/s", tokensPerSecond) }
                feed.emitProgress("generating", step: tokens, detail: detail)
            },
            responsesStreamProvider: streamProvider
        )

        var usage: [String: Any] = [
            "prompt_tokens": result.usage.promptTokens,
            "completion_tokens": result.usage.completionTokens,
            "total_tokens": result.usage.promptTokens + result.usage.completionTokens,
        ]
        if let tps = result.usage.tokensPerSecond {
            usage["tokens_per_second"] = (tps * 10).rounded() / 10
            ModelThroughputLedger.record(
                model: resolved.name, tokensPerSecond: tps, tokens: result.usage.completionTokens)
        }
        switch result.exit {
        case .finalResponse, .endedBySurface:
            let digest = (result.digest ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let exposed = Set(resolvedSpecs.map { $0.function.name })
            let outcome = target.classify(log.all, digest, exposed)
            guard !outcome.text.isEmpty else {
                throw SubagentError.executionFailed(message: "Finished without a reply.", retryable: true)
            }
            var payload = outcome.payload
            payload["steps"] = result.iterations
            payload["usage"] = usage
            return SubagentResult(payload: payload, summary: outcome.text)
        case .cancelled:
            switch result.cancelCause {
            case .userInterrupt:
                throw SubagentError.userDenied("Stopped by the user.")
            case .parentTask, .upstream:
                throw SubagentError.executionFailed(message: "Cancelled with the turn.", retryable: false)
            case .deadline, .none:
                if let landed = Self.landedOutcome(log.all, target: target, exposed: Set(resolvedSpecs.map { $0.function.name })) {
                    var payload = landed.payload
                    payload["steps"] = result.iterations
                    payload["usage"] = usage
                    return SubagentResult(payload: payload, summary: landed.text)
                }
                throw SubagentError.timedOut("Took longer than \(Int(target.wallClockSeconds)) seconds.")
            }
        case .iterationCapReached:
            let outcome = target.classify(
                log.all, (result.digest ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                Set(resolvedSpecs.map { $0.function.name }))
            if let outcome = Self.cappedOutcome(outcome) {
                var payload = outcome.payload
                payload["steps"] = result.iterations
                payload["usage"] = usage
                return SubagentResult(payload: payload, summary: outcome.text)
            }
            throw SubagentError.iterationCap("Used all \(target.maxSteps) steps without finishing.")
        case .toolRejected:
            throw SubagentError.toolRejected("Tried a tool it does not have.")
        case .overBudget:
            throw SubagentError.overBudget("The request did not fit in the model's context.")
        case .emptyResponseExhausted:
            throw SubagentError.emptyExhausted("Returned an empty reply.")
        case .lengthExhausted, .truncatedToolCallExhausted:
            throw SubagentError.executionFailed(message: "Ran out of output tokens.", retryable: false)
        case .repetitionLoopExhausted:
            throw SubagentError.executionFailed(message: "Got stuck repeating itself.", retryable: false)
        case .incompleteReasoningExhausted:
            throw SubagentError.executionFailed(
                message: "Ended in reasoning without a visible reply.", retryable: false)
        }
    }
}

enum HiddenAgentHandoffRunner {
    /// Run `kind` under the handoff tool's call and return its envelope.
    static func run(_ kind: HiddenAgentHandoffKind, tool: String) async -> String {
        await SubagentSession.run(kind, tool: tool)
    }
}
