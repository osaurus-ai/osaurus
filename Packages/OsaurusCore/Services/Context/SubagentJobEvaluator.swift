//
//  SubagentJobEvaluator.swift
//  osaurus
//
//  Public facade that drives the shared `SubagentSession` host for the
//  OsaurusEvals `subagent` domain — the spawn/image analogue of
//  `AgentLoopEvaluator` (agent_loop) and the Computer-Use loop runner
//  (computer_use_loop). Three lanes share ONE transcript shape:
//
//    - scripted: a model-free `ScriptedSubagentKind` exercises the host's
//      full control flow (resolve → permission → handoff → run → normalize
//      → cleanup) plus the unified recursion guard and feed lifecycle, with
//      no tokens. This is the CI-safe lane the eval-kit unit tests run.
//    - spawn: invokes the real `SpawnTool` through the host (live text
//      sub-agent on a user-configured spawnable persona).
//    - image: invokes the real `ImageTool` through the host (live native
//      image generation or, with `sourcePaths`, edit).
//
//  Every lane binds the chat execution context (`currentSessionId` /
//  `currentToolCallId` / `currentAgentId`, plus headless auto-approval) so
//  the run addresses a known feed and never blocks on an approval card no
//  one can click, then reads back the compact `ToolEnvelope` result and the
//  `SubagentFeed` events the host emitted. The result is a decode-friendly
//  `SubagentJobTranscript` the eval runner scores against `expect.subagent`.
//

import Foundation

// MARK: - Public transcript

/// Decode-friendly record of one `subagent` eval run, across all three
/// lanes. Every field is lane-tolerant: scripted runs carry
/// `handoffWrapped` / `nestedRefused`, the image lane carries `mode` /
/// `imageCount`, and the spawn lane carries the persona digest in `summary`.
public struct SubagentJobTranscript: Sendable, Codable {
    /// Tool name the host ran under (`scripted` kind id, `spawn`, or `image`).
    public let tool: String
    /// The `SubagentKind.capability.id` that drove the run.
    public let kindId: String
    /// True when the host returned a success envelope.
    public let succeeded: Bool
    /// `"success"` on success; otherwise the failure envelope's `kind`
    /// discriminator (`rejected` / `user_denied` / `unavailable` /
    /// `invalid_args` / `timeout` / `execution_error`).
    public let envelopeKind: String
    /// Result payload discriminator on success (`spawn_result` /
    /// `native_image_generation_job` / the scripted kind's `resultKind`).
    /// `nil` on failure.
    public let resultKind: String?
    /// Image lane only: `"generate"` or `"edit"` from the result payload.
    public let mode: String?
    /// Resolved model name from the result payload, when present.
    public let model: String?
    /// Terminal feed summary (or the payload `summary`/`digest`) — the prose
    /// digest a parent agent would read.
    public let summary: String
    /// Image lane only: number of images in the result payload.
    public let imageCount: Int?
    /// Feed event kinds in emit order — the live-progress proof (a text
    /// spawn used to render a "frozen turn"; the unified feed fixes that).
    public let feedEventKinds: [String]
    /// Feed phase titles in emit order.
    public let feedPhases: [String]
    /// Scripted lane: whether the optional residency handoff wrapped the run
    /// (asserts `needsHandoff` kinds go through the middleware). `nil` on the
    /// live lanes (the real handoff is internal to the kind).
    public let handoffWrapped: Bool?
    /// Scripted lane: whether a nested sub-agent call was refused by the
    /// unified recursion guard (the BUG-class regression guard). `nil` unless
    /// the scripted spec asked to recurse.
    public let nestedRefused: Bool?
    /// Failure message when `!succeeded`.
    public let error: String?
    /// Wall-clock milliseconds for the host run.
    public let latencyMs: Double

    public init(
        tool: String,
        kindId: String,
        succeeded: Bool,
        envelopeKind: String,
        resultKind: String? = nil,
        mode: String? = nil,
        model: String? = nil,
        summary: String,
        imageCount: Int? = nil,
        feedEventKinds: [String],
        feedPhases: [String],
        handoffWrapped: Bool? = nil,
        nestedRefused: Bool? = nil,
        error: String? = nil,
        latencyMs: Double
    ) {
        self.tool = tool
        self.kindId = kindId
        self.succeeded = succeeded
        self.envelopeKind = envelopeKind
        self.resultKind = resultKind
        self.mode = mode
        self.model = model
        self.summary = summary
        self.imageCount = imageCount
        self.feedEventKinds = feedEventKinds
        self.feedPhases = feedPhases
        self.handoffWrapped = handoffWrapped
        self.nestedRefused = nestedRefused
        self.error = error
        self.latencyMs = latencyMs
    }
}

// MARK: - Scripted lane spec

/// Knobs for the model-free scripted lane. A `ScriptedSubagentKind` built
/// from this exercises the host's whole lifecycle deterministically: pick
/// the permission verdict, throw a typed `SubagentError` at resolve or run
/// time, opt into the handoff middleware, and (optionally) attempt a nested
/// sub-agent so the unified recursion guard can refuse it.
public struct ScriptedSubagentSpec: Sendable {
    /// Permission verdict the scripted kind returns.
    public enum Decision: String, Sendable {
        case allow
        case deny
        case userDeny
    }

    /// Typed failure a scripted kind can throw (maps 1:1 onto
    /// `SubagentError`, so the host's envelope mapping is exercised).
    public enum Failure: String, Sendable {
        case denied
        case userDenied
        case unavailable
        case invalidArgs
        case timedOut
        case iterationCap
        case toolRejected
        case overBudget
        case emptyExhausted
        case executionFailed

        func error(context: String) -> SubagentError {
            switch self {
            case .denied: return .denied("scripted denial (\(context))")
            case .userDenied: return .userDenied("scripted user refusal (\(context))")
            case .unavailable: return .unavailable("scripted unavailable (\(context))")
            case .invalidArgs:
                return .invalidArgs(message: "scripted invalid args (\(context))", field: "scripted")
            case .timedOut: return .timedOut("scripted timeout (\(context))")
            case .iterationCap: return .iterationCap("scripted iteration cap (\(context))")
            case .toolRejected: return .toolRejected("scripted tool rejected (\(context))")
            case .overBudget: return .overBudget("scripted over budget (\(context))")
            case .emptyExhausted: return .emptyExhausted("scripted empty (\(context))")
            case .executionFailed:
                return .executionFailed(message: "scripted execution failure (\(context))")
            }
        }
    }

    /// Kind id (also the tool name the host runs under).
    public var kindId: String
    /// Opt into the residency-handoff middleware (asserts `needsHandoff`).
    public var needsHandoff: Bool
    /// Permission verdict.
    public var decision: Decision
    /// Throw at resolve time (reject-before-evict). `nil` = resolve cleanly.
    public var resolveFailure: Failure?
    /// Throw inside `run`. `nil` = succeed.
    public var runFailure: Failure?
    /// Attempt a nested sub-agent inside `run` (the recursion-guard probe).
    public var recurse: Bool
    /// Lifecycle phases the scripted kind emits onto the feed.
    public var phases: [String]
    /// Prose digest the scripted run returns (also the terminal feed status).
    public var summary: String
    /// Result payload discriminator the scripted kind returns.
    public var resultKind: String
    /// Resolved model name the scripted kind returns.
    public var modelName: String

    public init(
        kindId: String = "scripted",
        needsHandoff: Bool = false,
        decision: Decision = .allow,
        resolveFailure: Failure? = nil,
        runFailure: Failure? = nil,
        recurse: Bool = false,
        phases: [String] = ["running"],
        summary: String = "scripted digest",
        resultKind: String = "scripted_result",
        modelName: String = "scripted-model"
    ) {
        self.kindId = kindId
        self.needsHandoff = needsHandoff
        self.decision = decision
        self.resolveFailure = resolveFailure
        self.runFailure = runFailure
        self.recurse = recurse
        self.phases = phases
        self.summary = summary
        self.resultKind = resultKind
        self.modelName = modelName
    }
}

// MARK: - Facade

public enum SubagentJobEvaluator {

    /// Run the model-free scripted lane: build a `ScriptedSubagentKind` from
    /// `spec`, drive it through the real `SubagentSession` host, and read back
    /// the envelope + feed + handoff/recursion observations. No tokens, no
    /// model, CI-safe — this is the deterministic seam the whole sub-agent
    /// family rides on.
    public static func runScripted(_ spec: ScriptedSubagentSpec) async -> SubagentJobTranscript {
        let kind = ScriptedSubagentKind(spec: spec)
        let toolCallId = freshToolCallId()
        let started = Date()
        let envelope = await withEvalScope(toolCallId: toolCallId) {
            await SubagentSession.run(kind, tool: spec.kindId)
        }
        let latency = Date().timeIntervalSince(started) * 1000
        return transcript(
            fromEnvelope: envelope,
            tool: spec.kindId,
            kindId: spec.kindId,
            toolCallId: toolCallId,
            latencyMs: latency,
            handoffWrapped: spec.needsHandoff ? kind.handoffWrapped : nil,
            nestedRefused: spec.recurse ? kind.nestedRefused : nil
        )
    }

    /// Run the live spawn lane through the host + `TextSubagentKind` (the same
    /// path `SpawnTool` drives). The caller is responsible for skipping when
    /// the persona/model is unavailable — the transcript's `envelopeKind`
    /// surfaces a `rejected`/`unavailable` envelope so the runner can decide
    /// skip vs. fail.
    ///
    /// When `modelId` is provided, the spawned persona runs on THAT model
    /// instead of its own configured one, so `spawn` becomes a real
    /// cross-model column in the matrix (the production kind otherwise pins to
    /// the persona's model, which wouldn't vary with the eval `--model`). The
    /// persona must still exist and be spawnable; only the effective model is
    /// overridden.
    public static func runSpawn(
        agent: String,
        input: String,
        modelId: String? = nil
    ) async -> SubagentJobTranscript {
        let toolCallId = freshToolCallId()
        let kind = TextSubagentKind(agentName: agent, input: input, modelOverride: modelId)
        let started = Date()
        let envelope = await withEvalScope(toolCallId: toolCallId) {
            await SubagentSession.run(kind, tool: "spawn")
        }
        let latency = Date().timeIntervalSince(started) * 1000
        return transcript(
            fromEnvelope: envelope,
            tool: "spawn",
            kindId: "spawn",
            toolCallId: toolCallId,
            latencyMs: latency
        )
    }

    /// Run the live image lane through the real `ImageTool` (host +
    /// `ImageSubagentKind`). `sourcePaths` non-empty selects edit mode. The
    /// run auto-approves the `.ask` permission prompt (headless), so a
    /// host with image delegation enabled + a ready model produces the image
    /// without UI; otherwise the envelope is `rejected`/`unavailable` and the
    /// runner skips.
    public static func runImage(
        prompt: String,
        sourcePaths: [String] = [],
        model: String? = nil
    ) async -> SubagentJobTranscript {
        let toolCallId = freshToolCallId()
        var args: [String: Any] = ["prompt": prompt]
        if !sourcePaths.isEmpty { args["source_paths"] = sourcePaths }
        if let model, !model.isEmpty { args["model"] = model }
        let argsJSON = jsonString(args)
        let started = Date()
        let envelope = await withEvalScope(toolCallId: toolCallId) {
            (try? await ImageTool().execute(argumentsJSON: argsJSON))
                ?? ToolEnvelope.failure(
                    kind: .executionError,
                    message: "image tool threw",
                    tool: "image"
                )
        }
        let latency = Date().timeIntervalSince(started) * 1000
        return transcript(
            fromEnvelope: envelope,
            tool: "image",
            kindId: "image",
            toolCallId: toolCallId,
            latencyMs: latency
        )
    }

    /// Run the live `computer_use` lane through the host + `ComputerUseKind`
    /// against an injected, in-memory `driver` (e.g. `ScriptedCUDriver`) +
    /// permissive `gate`. The desktop is never touched, so this is safe and
    /// deterministic in CI.
    ///
    /// - `scriptedActions` non-nil drives the loop with NO model call (the
    ///   CI-safe lane that proves the host wrapper + envelope mapping).
    /// - `scriptedActions` nil drives the loop with the live `modelId` (the
    ///   local-vs-frontier planning lane). Callers should pre-skip
    ///   tiny-context models (which can't use tools) before calling.
    ///
    /// The injected `driver` is the caller's, so after this returns the caller
    /// reads back the world state (final values, clicked ids, verb trace) for
    /// the substantive "did it work" check; this facade returns only the
    /// host-parity transcript (envelope/feed/summary).
    public static func runComputerUse(
        goal: String,
        modelId: String,
        driver: MacDriver,
        gate: ComputerUseGating,
        vision: VisionContext = .none,
        scriptedActions: [String]? = nil,
        maxSteps: Int = 16
    ) async -> SubagentJobTranscript {
        let toolCallId = freshToolCallId()
        let harness = ComputerUseEvalHarness(
            modelId: modelId,
            driver: driver,
            gate: gate,
            vision: vision,
            scriptedActions: scriptedActions
        )
        let kind = ComputerUseKind(
            goal: goal,
            limits: RunLimits(maxSteps: max(1, maxSteps), wallClockSeconds: 240),
            evalHarness: harness
        )
        let started = Date()
        let envelope = await withEvalScope(toolCallId: toolCallId) {
            await SubagentSession.run(kind, tool: "computer_use")
        }
        let latency = Date().timeIntervalSince(started) * 1000
        return transcript(
            fromEnvelope: envelope,
            tool: "computer_use",
            kindId: "computer_use",
            toolCallId: toolCallId,
            latencyMs: latency
        )
    }

    /// Run the live `sandbox_reduce` lane through the host + `SandboxReduceKind`
    /// on the active run `modelId`. Pre-flights the sandbox child toolset: when
    /// it isn't registered (no container on this host) the lane is genuinely
    /// unavailable, so this returns an `unavailable` transcript that the runner
    /// SKIPS — never a false failure, and never touching production error
    /// classification in `SandboxReduceKind`.
    public static func runSandboxReduce(
        task: String,
        modelId: String,
        paths: [String] = [],
        maxIterations: Int? = nil
    ) async -> SubagentJobTranscript {
        let toolsReady = await MainActor.run {
            !ToolRegistry.shared.specs(forTools: SandboxReduceTool.childToolAllowlist).isEmpty
        }
        guard toolsReady else {
            return SubagentJobTranscript(
                tool: "sandbox_reduce",
                kindId: "sandbox_reduce",
                succeeded: false,
                envelopeKind: "unavailable",
                summary: "",
                feedEventKinds: [],
                feedPhases: [],
                error: "sandbox child tools are not registered on this host (no container).",
                latencyMs: 0
            )
        }
        let toolCallId = freshToolCallId()
        let iterations = min(
            max(maxIterations ?? SandboxReduceTool.defaultIterations, 1),
            SandboxReduceTool.maxIterations
        )
        let kind = SandboxReduceKind(
            agentId: Agent.defaultId.uuidString,
            task: task,
            paths: paths,
            iterations: iterations,
            modelOverride: modelId
        )
        let started = Date()
        let envelope = await withEvalScope(toolCallId: toolCallId) {
            await SubagentSession.run(kind, tool: "sandbox_reduce")
        }
        let latency = Date().timeIntervalSince(started) * 1000
        return transcript(
            fromEnvelope: envelope,
            tool: "sandbox_reduce",
            kindId: "sandbox_reduce",
            toolCallId: toolCallId,
            latencyMs: latency
        )
    }

    // MARK: - Eval persona seeding

    /// Seed a spawnable persona named `name` for the duration of `body`, then
    /// restore. Creates an `Agent` with that name (when absent, with a concise
    /// persona prompt) and adds it to the Default agent's GLOBAL spawnable pool
    /// (`SubagentConfiguration.spawnableAgentNames`, which the Default/main-chat
    /// agent the eval scope uses consults), so the `spawn` lane RUNS across
    /// models on any host instead of skipping for lack of a configured persona.
    /// Also forces `localTextDelegationEnabled` (the "Local Orchestrator
    /// Handoff" switch) ON for the run so a LOCAL run model can actually hand
    /// off to the local text subagent (unload/reload) instead of skipping —
    /// this is the real documented capability switch (the RAM-safety preflight
    /// still guards it), so `spawn` becomes a true cross-model column including
    /// local MLX, not just `foundation`/remote. The whole prior
    /// `SubagentConfiguration` is snapshotted and restored, and the seeded
    /// agent removed, leaving a developer's real config untouched. The
    /// persona's own model is irrelevant — the eval passes the run model as a
    /// `TextSubagentKind` override. Seed/restore run on the main actor
    /// (`AgentStore`/`AgentManager` are main-actor state);
    /// `SubagentConfigurationStore` is nonisolated.
    public static func withSpawnablePersona<T: Sendable>(
        name: String,
        _ body: @Sendable () async -> T
    ) async -> T {
        let state: (createdAgentId: UUID?, priorConfig: SubagentConfiguration, configChanged: Bool) =
            await MainActor.run {
                let priorConfig = SubagentConfigurationStore.snapshot()
                var createdAgentId: UUID? = nil
                let exists = AgentManager.shared.agents.contains {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                }
                if !exists {
                    let agent = Agent(
                        id: UUID(),
                        name: name,
                        description: "Seeded by OsaurusEvals for the spawn lane; safe to delete.",
                        systemPrompt:
                            "You are a concise sub-agent. Answer the task directly and follow any "
                            + "formatting instructions exactly. Do not add preamble or commentary."
                    )
                    AgentStore.save(agent)
                    createdAgentId = agent.id
                }
                var updated = priorConfig
                if !priorConfig.isAgentSpawnable(name) {
                    updated.spawnableAgentNames = priorConfig.spawnableAgentNames + [name]
                }
                // Enable the local handoff switch so a LOCAL run model can
                // spawn the local persona (the chat model unloads to make
                // room). Default is on; this only flips a host that disabled
                // it, and is restored afterward.
                updated.localTextDelegationEnabled = true
                let configChanged = updated != priorConfig
                if configChanged { SubagentConfigurationStore.save(updated) }
                if createdAgentId != nil { AgentManager.shared.refresh() }
                return (createdAgentId, priorConfig, configChanged)
            }
        let result = await body()
        await MainActor.run {
            if let id = state.createdAgentId {
                AgentStore.delete(id: id)
                AgentManager.shared.refresh()
            }
            if state.configChanged {
                SubagentConfigurationStore.save(state.priorConfig)
            }
        }
        return result
    }

    // MARK: - Shared plumbing

    /// Bind the chat execution context the host resolves its scope from, plus
    /// headless auto-approval so `.ask`-gated kinds (image) don't block on a
    /// permission card. `autoApproveToolPrompts` is module-internal — binding
    /// it here is exactly why this facade lives in OsaurusCore rather than the
    /// eval kit.
    private static func withEvalScope<T: Sendable>(
        toolCallId: String,
        _ body: @Sendable () async -> T
    ) async -> T {
        await ChatExecutionContext.$currentSessionId.withValue("subagent-eval-\(UUID().uuidString)") {
            await ChatExecutionContext.$currentToolCallId.withValue(toolCallId) {
                await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
                    await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
                        await body()
                    }
                }
            }
        }
    }

    /// Build the transcript from the returned envelope + the feed the host
    /// registered for `toolCallId`. The host's `defer` schedules the feed for
    /// drop after a grace window, so it is still resolvable synchronously here
    /// immediately after the run returns.
    private static func transcript(
        fromEnvelope envelope: String,
        tool: String,
        kindId: String,
        toolCallId: String,
        latencyMs: Double,
        handoffWrapped: Bool? = nil,
        nestedRefused: Bool? = nil
    ) -> SubagentJobTranscript {
        let succeeded = ToolEnvelope.isSuccess(envelope)
        let payload = (ToolEnvelope.successPayload(envelope) as? [String: Any]) ?? [:]

        let feed = SubagentFeedRegistry.shared.feed(for: toolCallId)
        let events = feed?.currentEvents() ?? []
        let eventKinds = events.map { $0.kind.rawValue }
        let phases = events.filter { $0.kind == .phase }.map(\.title)

        let summary: String
        if case .finished(_, let s)? = feed?.currentStatus(), !s.isEmpty {
            summary = s
        } else {
            summary =
                (payload["summary"] as? String) ?? (payload["digest"] as? String) ?? ""
        }

        let imageCount = (payload["images"] as? [[String: Any]])?.count
        let envelopeKind = succeeded ? "success" : (failureKind(envelope) ?? "execution_error")
        let error = succeeded ? nil : ToolEnvelope.failureMessage(envelope)

        return SubagentJobTranscript(
            tool: tool,
            kindId: kindId,
            succeeded: succeeded,
            envelopeKind: envelopeKind,
            resultKind: payload["kind"] as? String,
            mode: payload["mode"] as? String,
            model: payload["model"] as? String,
            summary: summary,
            imageCount: imageCount,
            feedEventKinds: eventKinds,
            feedPhases: phases,
            handoffWrapped: handoffWrapped,
            nestedRefused: nestedRefused,
            error: error,
            latencyMs: latencyMs
        )
    }

    /// The failure envelope's `kind` discriminator, or `nil` if `envelope`
    /// isn't a failure / doesn't parse.
    static func failureKind(_ envelope: String) -> String? {
        guard ToolEnvelope.isError(envelope),
            let data = envelope.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict["kind"] as? String
    }

    private static func freshToolCallId() -> String { "subagent-eval-\(UUID().uuidString)" }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
            let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}

// MARK: - Scripted kind

/// A fully scripted `SubagentKind` so the host's control flow runs without a
/// model. Mirrors the `ScriptedKind` test double, but lives in the non-test
/// surface so the eval facade (and thus the eval kit + its CI unit tests) can
/// drive the exact same host lifecycle the live kinds use.
final class ScriptedSubagentKind: SubagentKind, @unchecked Sendable {
    let capability: SubagentCapability
    /// The eval spec's own handoff opt-in (drives `makeHandoff()` below). No
    /// longer a `SubagentKind` requirement — the host consumes `makeHandoff()`.
    let needsHandoff: Bool

    private let spec: ScriptedSubagentSpec
    private let recordingHandoff = RecordingSubagentHandoff()
    private let nestedBox = NestedResultBox()

    init(spec: ScriptedSubagentSpec) {
        self.spec = spec
        self.capability = SubagentCapability(
            id: spec.kindId,
            toolNames: [spec.kindId],
            gate: .sandboxExec
        )
        self.needsHandoff = spec.needsHandoff
    }

    /// Whether the residency-handoff middleware wrapped the run.
    var handoffWrapped: Bool { recordingHandoff.wrapped }
    /// Whether the nested sub-agent attempt (when `spec.recurse`) was refused.
    var nestedRefused: Bool? { nestedBox.refused }

    var feedTitle: String { "scripted \(spec.kindId)" }

    func makeHandoff() -> SubagentHandoff {
        needsHandoff ? recordingHandoff : PassthroughHandoff()
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        if let failure = spec.resolveFailure { throw failure.error(context: "resolve") }
        return ResolvedModel(name: spec.modelName, id: spec.modelName, isLocal: true)
    }

    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        switch spec.decision {
        case .allow: return .allow
        case .deny: return .denied("scripted policy denial")
        case .userDeny: return .userDenied("scripted user refusal")
        }
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        for phase in spec.phases { feed.emitPhase(phase, detail: resolved.name) }

        if spec.recurse {
            // A running sub-agent must not be able to start another: drive a
            // nested host run and record whether the unified guard refused it.
            let nested = await SubagentSession.run(
                ScriptedSubagentKind(spec: ScriptedSubagentSpec(kindId: "scripted-nested")),
                tool: "scripted-nested"
            )
            nestedBox.refused =
                ToolEnvelope.isError(nested)
                && (SubagentJobEvaluator.failureKind(nested) == "rejected")
        }

        if let failure = spec.runFailure { throw failure.error(context: "run") }

        return SubagentResult(
            payload: [
                "kind": spec.resultKind,
                "model": resolved.name,
                "summary": spec.summary,
            ] as [String: Any],
            summary: spec.summary
        )
    }
}

/// Records whether `around` wrapped the run, for the scripted handoff
/// assertion. `around` is invoked at most once per run, synchronously before
/// the awaited body, and `wrapped` is read only after the run completes
/// (a happens-before ordering), so a plain flag is sufficient.
final class RecordingSubagentHandoff: SubagentHandoff, @unchecked Sendable {
    private(set) var wrapped = false

    func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult {
        wrapped = true
        return try await body()
    }
}

/// Reference box so the scripted kind can hand its nested-guard observation
/// back out after the run completes.
final class NestedResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _refused: Bool?

    var refused: Bool? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _refused
        }
        set {
            lock.lock()
            _refused = newValue
            lock.unlock()
        }
    }
}
