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
//    - spawn / spawn_model: drive the real `TextSubagentKind` through the host
//      (the same path `spawn_agent` / `spawn_model` drive) — `spawn` against a
//      user-configured spawnable agent, `spawn_model` against a bare
//      spawnable model id with no agent.
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
/// `imageCount`, and the spawn lane carries the agent digest in `summary`.
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
    /// Scripted lane: whether a nested subagent call was refused by the
    /// unified recursion guard (the BUG-class regression guard). `nil` unless
    /// the scripted spec asked to recurse.
    public let nestedRefused: Bool?
    /// Failure message when `!succeeded`.
    public let error: String?
    /// Wall-clock milliseconds for the host run.
    public let latencyMs: Double
    /// Worker usage from the spawn payload (`prompt_tokens` /
    /// `completion_tokens` / `total_tokens` / `tokens_per_second`), when the
    /// run reported it. Numbers normalized to Double for one Codable shape.
    public let usage: [String: Double]?
    /// Context-saved accounting from the spawn payload (`worker_tokens` /
    /// `digest_tokens` / `context_saved_tokens`) — the measurable "what did
    /// delegation save the parent" record.
    public let contextAccounting: [String: Int]?
    /// Residency phase durations (seconds) recorded by the host from the
    /// feed timeline (`unloading_chat_models`, `restoring_chat_models`,
    /// `waiting for local GPU`, `coexisting`, …) — the handoff-latency proof.
    public let residencyPhases: [String: Double]?
    /// Post-run cache counters (`prefix_hits` / `disk_l2_hits` / …) captured
    /// for local runs — the resume prefix-hit / L2 mitigation signal.
    public let postRunCache: [String: Int]?
    /// Parallel-batch lane only: peak concurrent `run()` bodies observed.
    public let maxConcurrent: Int?
    /// Parallel-batch lane only: how many of the batch's runs completed
    /// (success envelopes).
    public let runsCompleted: Int?
    /// Residency lane only: whether the local orchestrator was verified
    /// GPU-resident again AFTER the run (before the lane's cleanup) — the
    /// "restore verified resident" proof. `nil` when the case had no local
    /// orchestrator to restore (`ensureResident: false`) or the run failed.
    public let restoredResident: Bool?

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
        latencyMs: Double,
        usage: [String: Double]? = nil,
        contextAccounting: [String: Int]? = nil,
        residencyPhases: [String: Double]? = nil,
        postRunCache: [String: Int]? = nil,
        maxConcurrent: Int? = nil,
        runsCompleted: Int? = nil,
        restoredResident: Bool? = nil
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
        self.usage = usage
        self.contextAccounting = contextAccounting
        self.residencyPhases = residencyPhases
        self.postRunCache = postRunCache
        self.maxConcurrent = maxConcurrent
        self.runsCompleted = runsCompleted
        self.restoredResident = restoredResident
    }
}

// MARK: - Scripted lane spec

/// Knobs for the model-free scripted lane. A `ScriptedSubagentKind` built
/// from this exercises the host's whole lifecycle deterministically: pick
/// the permission verdict, throw a typed `SubagentError` at resolve or run
/// time, opt into the handoff middleware, and (optionally) attempt a nested
/// subagent so the unified recursion guard can refuse it.
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
    /// Attempt a nested subagent inside `run` (the recursion-guard probe).
    public var recurse: Bool
    /// Lifecycle phases the scripted kind emits onto the feed.
    public var phases: [String]
    /// Prose digest the scripted run returns (also the terminal feed status).
    public var summary: String
    /// Result payload discriminator the scripted kind returns.
    public var resultKind: String
    /// Resolved model name the scripted kind returns.
    public var modelName: String
    /// Resolve as a REMOTE model (`isLocal: false`), so the host's default
    /// admission class is `.remote` — the parallel fan-out lane.
    public var remote: Bool
    /// Hold `run()` open for this long (polling the interrupt token every
    /// ~20 ms), so an external interrupt or a sibling batch run can land
    /// mid-run. An interrupt observed during the wait throws the honest
    /// user-stop error (mirrors `TextSubagentKind`'s cancel mapping).
    public var runDelayMs: Int
    /// Attach canned `usage` + `context` accounting to the success payload so
    /// the transcript/scoring plumbing for the live spawn fields is testable
    /// deterministically (this is the model-free TEST kind, not production).
    public var includeUsageAccounting: Bool
    /// Parallel-batch rendezvous: hold `run()` open until this many sibling
    /// runs have ENTERED the shared overlap probe (bounded wait), so a
    /// fan-out lane observes true overlap deterministically instead of
    /// depending on sleep timing. `0` = off. Only meaningful with a probe;
    /// never set it for a serialized (exclusive) batch — the later runs can't
    /// enter until the earlier ones exit, so the wait would just time out.
    public var rendezvousArrivals: Int

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
        modelName: String = "scripted-model",
        remote: Bool = false,
        runDelayMs: Int = 0,
        includeUsageAccounting: Bool = false,
        rendezvousArrivals: Int = 0
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
        self.remote = remote
        self.runDelayMs = runDelayMs
        self.includeUsageAccounting = includeUsageAccounting
        self.rendezvousArrivals = rendezvousArrivals
    }
}

// MARK: - Facade

public enum SubagentJobEvaluator {

    /// Run the model-free scripted lane: build a `ScriptedSubagentKind` from
    /// `spec`, drive it through the real `SubagentSession` host, and read back
    /// the envelope + feed + handoff/recursion observations. No tokens, no
    /// model, CI-safe — this is the deterministic seam the whole subagent
    /// family rides on.
    ///
    /// `interruptAfterMs` trips the run's `InterruptToken` through the REAL
    /// `SubagentInterruptCenter` (the feed row's stop-button path) after the
    /// delay — pair with `spec.runDelayMs` so the run is still open when the
    /// interrupt lands (the deterministic interrupt-mid-run lane).
    public static func runScripted(
        _ spec: ScriptedSubagentSpec,
        interruptAfterMs: Int? = nil
    ) async -> SubagentJobTranscript {
        let kind = ScriptedSubagentKind(spec: spec)
        let toolCallId = freshToolCallId()
        let started = Date()
        let stopper = scheduleInterrupt(afterMs: interruptAfterMs, toolCallId: toolCallId)
        let envelope = await withEvalScope(toolCallId: toolCallId) {
            await SubagentSession.run(kind, tool: spec.kindId)
        }
        stopper?.cancel()
        let latency = Date().timeIntervalSince(started) * 1000
        return transcript(
            fromEnvelope: envelope,
            tool: spec.kindId,
            kindId: spec.kindId,
            toolCallId: toolCallId,
            latencyMs: latency,
            // Always record for the scripted lane: a `needsHandoff: false` kind
            // vends a `PassthroughHandoff`, so the recording handoff is never
            // invoked and this reads `false` — the host-level proof that a
            // same-model kind runs WITHOUT a residency wrap (the passthrough
            // branch). `needsHandoff: true` reads `true` (the wrap branch).
            handoffWrapped: kind.handoffWrapped,
            nestedRefused: spec.recurse ? kind.nestedRefused : nil
        )
    }

    /// Run `count` copies of the scripted spec CONCURRENTLY through the host —
    /// the parallel-batch lane. Every run gets its own tool-call id + feed
    /// (like a real parallel tool batch), and all share one overlap probe, so
    /// the transcript reports the substantive observation: `maxConcurrent`
    /// (did the admission gate serialize the local-exclusive runs, or fan the
    /// remote runs out) and `runsCompleted` (nobody deadlocked or refused).
    /// The combined transcript takes envelope/summary from the FIRST FAILURE
    /// when one exists (so expectations catch it), else from the first run.
    public static func runScriptedParallelBatch(
        _ spec: ScriptedSubagentSpec,
        count: Int
    ) async -> SubagentJobTranscript {
        let runs = max(2, count)
        let probe = SubagentOverlapProbe()
        let started = Date()

        let results: [SubagentJobTranscript] = await withTaskGroup(
            of: (Int, SubagentJobTranscript).self
        ) { group in
            for index in 0 ..< runs {
                group.addTask {
                    let kind = ScriptedSubagentKind(spec: spec, overlapProbe: probe)
                    let toolCallId = freshToolCallId()
                    let envelope = await withEvalScope(toolCallId: toolCallId) {
                        await SubagentSession.run(kind, tool: spec.kindId)
                    }
                    return (
                        index,
                        transcript(
                            fromEnvelope: envelope,
                            tool: spec.kindId,
                            kindId: spec.kindId,
                            toolCallId: toolCallId,
                            latencyMs: 0
                        )
                    )
                }
            }
            var collected: [(Int, SubagentJobTranscript)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        let latency = Date().timeIntervalSince(started) * 1000
        let completed = results.filter(\.succeeded).count
        let primary = results.first { !$0.succeeded } ?? results[0]
        return SubagentJobTranscript(
            tool: primary.tool,
            kindId: primary.kindId,
            succeeded: completed == runs,
            envelopeKind: primary.envelopeKind,
            resultKind: primary.resultKind,
            mode: primary.mode,
            model: primary.model,
            summary: primary.summary,
            imageCount: nil,
            feedEventKinds: primary.feedEventKinds,
            feedPhases: primary.feedPhases,
            handoffWrapped: nil,
            nestedRefused: nil,
            error: primary.error,
            latencyMs: latency,
            usage: primary.usage,
            contextAccounting: primary.contextAccounting,
            residencyPhases: primary.residencyPhases,
            postRunCache: primary.postRunCache,
            maxConcurrent: probe.maxConcurrent,
            runsCompleted: completed
        )
    }

    /// Run the live spawn-agent lane through the host + `TextSubagentKind` (the
    /// same path `spawn_agent` drives). The caller is responsible for skipping
    /// when the agent/model is unavailable — the transcript's `envelopeKind`
    /// surfaces a `rejected`/`unavailable` envelope so the runner can decide
    /// skip vs. fail.
    ///
    /// When `modelId` is provided, the spawned agent runs on THAT model
    /// instead of its own configured one, so `spawn` becomes a real
    /// cross-model column in the matrix (the production kind otherwise pins to
    /// the agent's model, which wouldn't vary with the eval `--model`). The
    /// agent must still exist and be spawnable; only the effective model is
    /// overridden.
    public static func runSpawn(
        agent: String,
        input: String,
        modelId: String? = nil,
        interruptAfterMs: Int? = nil
    ) async -> SubagentJobTranscript {
        let toolCallId = freshToolCallId()
        let kind = TextSubagentKind(agentName: agent, input: input, modelOverride: modelId)
        let started = Date()
        let stopper = scheduleInterrupt(afterMs: interruptAfterMs, toolCallId: toolCallId)
        let envelope = await withEvalScope(toolCallId: toolCallId) {
            await SubagentSession.run(kind, tool: "spawn_agent")
        }
        stopper?.cancel()
        let latency = Date().timeIntervalSince(started) * 1000
        return transcript(
            fromEnvelope: envelope,
            tool: "spawn_agent",
            kindId: "spawn",
            toolCallId: toolCallId,
            latencyMs: latency
        )
    }

    /// Run the live spawn-model lane through the host + `TextSubagentKind` (the
    /// same path `spawn_model` drives) — a bare model id with NO agent/system
    /// prompt. `model` is both the pool-gated target AND the run model (the eval
    /// seam forces it with residency passthrough, so the lane is a real
    /// cross-model column without depending on GPU residency). The caller seeds
    /// the model into the spawnable pool for happy-path cases; negative guards
    /// (unseeded id) surface a `rejected` envelope so the runner skips vs. fails.
    public static func runSpawnModel(
        model: String,
        input: String,
        interruptAfterMs: Int? = nil
    ) async -> SubagentJobTranscript {
        let toolCallId = freshToolCallId()
        let kind = TextSubagentKind(model: model, input: input, modelOverride: model)
        let started = Date()
        let stopper = scheduleInterrupt(afterMs: interruptAfterMs, toolCallId: toolCallId)
        let envelope = await withEvalScope(toolCallId: toolCallId) {
            await SubagentSession.run(kind, tool: "spawn_model")
        }
        stopper?.cancel()
        let latency = Date().timeIntervalSince(started) * 1000
        return transcript(
            fromEnvelope: envelope,
            tool: "spawn_model",
            kindId: "spawn",
            toolCallId: toolCallId,
            latencyMs: latency
        )
    }

    /// Run the live RESIDENCY-DIRECTION lane: drive the PRODUCTION `spawn_model`
    /// resolution (`modelOverride: nil`, so the eval passthrough seam is NOT
    /// used) with an independently chosen `orchestrator` (the resident chat
    /// model) and `target`, so the real `SubagentResidency.resolve` decision and
    /// `ResidencyHandoff` middleware run end-to-end. This is the only lane that
    /// proves the actual unload/reload, so it covers all four directions:
    ///
    ///   - orchestrator LOCAL + resident, target a DIFFERENT local + handoff ON
    ///     → unload chat model → run target → reload (the real swap).
    ///   - same pair, handoff OFF → rejected BEFORE evict (the gate).
    ///   - local→local same / local→remote / remote→local / remote→remote
    ///     → run in place (no swap).
    ///
    /// `ModelRuntime` residency is process-global, so this CLEAN-SLATES the
    /// resident set before and after, making each direction order-independent.
    /// It returns an `unavailable` envelope (so the runner SKIPS rather than
    /// fails) when the host can't satisfy the case: a local orchestrator that
    /// must be made resident isn't installed, or the target can neither run
    /// locally (not installed) nor route remotely (no connected provider /
    /// missing key). Peak RAM is sampled by the EVAL RUNNER around this call
    /// (`ResourceSampler` lives in the eval kit, not OsaurusCore).
    ///
    /// `ensureResident` should be `true` for a local orchestrator and `false`
    /// for a remote one (a remote orchestrator has no resident local chat model
    /// to evict). `handoffEnabled` toggles the "Local Orchestrator Handoff"
    /// switch for the run only; the prior config is restored after.
    public static func runSpawnModelResidency(
        orchestrator: String,
        target: String,
        handoffEnabled: Bool,
        ensureResident: Bool,
        input: String
    ) async -> SubagentJobTranscript {
        let toolCallId = freshToolCallId()
        let started = Date()

        // Classify by installation: a model the host has on disk is "local"
        // (its run evicts/loads the GPU); anything else is remote and must be
        // routable by a connected provider or there is nothing to run.
        let orchestratorLocal = ModelManager.findInstalledModel(named: orchestrator) != nil
        let targetLocal = ModelManager.findInstalledModel(named: target) != nil
        let targetRoutableRemote: Bool =
            targetLocal
            ? false
            : await MainActor.run { RemoteProviderManager.shared.findService(forModel: target) != nil }

        // Availability SKIP (surface `unavailable`, which the runner skips on):
        // can't make a non-installed local orchestrator resident, and can't run
        // a target that is neither installed locally nor routable remotely.
        let missingLocalOrchestrator = ensureResident && !orchestratorLocal
        let targetUnrunnable = !targetLocal && !targetRoutableRemote
        if missingLocalOrchestrator || targetUnrunnable {
            let why =
                missingLocalOrchestrator
                ? "orchestrator '\(orchestrator)' is not installed locally"
                : "target '\(target)' is neither installed locally nor routable via a connected provider"
            let env = ToolEnvelope.failure(
                kind: .unavailable,
                message: "residency lane unavailable: \(why)",
                tool: "spawn_model"
            )
            return transcript(
                fromEnvelope: env,
                tool: "spawn_model",
                kindId: "spawn",
                toolCallId: toolCallId,
                latencyMs: Date().timeIntervalSince(started) * 1000
            )
        }

        // Snapshot config so a developer's real settings are untouched. Only the
        // two core-model strings are captured (the struct stays on the main
        // actor); the whole delegation config is `Sendable` and captured whole.
        let priorChat: (provider: String?, name: String?) = await MainActor.run {
            let c = ChatConfigurationStore.load()
            return (c.coreModelProvider, c.coreModelName)
        }
        let priorConfig: SubagentConfiguration = await MainActor.run {
            SubagentConfigurationStore.snapshot()
        }

        // Clean slate: free any resident local model so the residency decision
        // sees ONLY the orchestrator we set up next (order-independent cases).
        await ModelRuntime.shared.unloadModelsNotIn([])

        // Faithfully point the chat/core model at the orchestrator.
        await MainActor.run {
            var c = ChatConfigurationStore.load()
            if let slash = orchestrator.firstIndex(of: "/") {
                c.coreModelProvider = String(orchestrator[..<slash])
                c.coreModelName = String(orchestrator[orchestrator.index(after: slash)...])
            } else {
                c.coreModelProvider = nil
                c.coreModelName = orchestrator
            }
            ChatConfigurationStore.save(c)
        }

        // Make a local orchestrator actually resident so a DIFFERENT local
        // target triggers the real unload/reload; a remote orchestrator stays
        // non-resident (nothing local to evict).
        if ensureResident && orchestratorLocal {
            try? await ModelRuntime.shared.preload(name: orchestrator)
        }

        // Seed the target into the global spawnable MODEL pool and set the
        // handoff gate to the case's value (OFF + a different local target ⇒
        // reject-before-evict; ON ⇒ the swap is allowed).
        await MainActor.run {
            var updated = priorConfig
            if !priorConfig.isModelSpawnable(target) {
                updated.spawnableModelNames = priorConfig.spawnableModelNames + [target]
            }
            updated.localTextDelegationEnabled = handoffEnabled
            SubagentConfigurationStore.save(updated)
        }

        // PRODUCTION path: `modelOverride: nil` ⇒ `requestedModel: target` ⇒
        // live `SubagentResidency.resolve` (NOT the eval passthrough seam).
        let kind = TextSubagentKind(model: target, input: input, modelOverride: nil)
        let envelope = await withEvalScope(toolCallId: toolCallId) {
            await SubagentSession.run(kind, tool: "spawn_model")
        }
        let latency = Date().timeIntervalSince(started) * 1000

        // The success payload carries `handoff` (`residencyPlan.shouldUnload`) —
        // the real "did the model swap happen" signal — so surface it as
        // `handoffWrapped`. A rejected envelope (handoff-OFF gate) has no
        // payload, leaving it `nil`, and the case asserts `rejected` instead.
        let payload = (ToolEnvelope.successPayload(envelope) as? [String: Any]) ?? [:]
        let handoffFlag = payload["handoff"] as? Bool

        // Restore-verified-resident: after a successful run with a LOCAL
        // orchestrator, the orchestrator must be back in the live resident set
        // (the restore leg actually reloaded it — or, for in-place directions,
        // never dropped it). Checked BEFORE the clean-slate below tears it down.
        // The runtime caches models under the canonical installed short name
        // (lowercased repo folder), not the case file's `owner/Repo` string,
        // so canonicalize before comparing.
        var restoredResident: Bool?
        if ensureResident && orchestratorLocal && ToolEnvelope.isSuccess(envelope) {
            let canonical = ModelManager.findInstalledModel(named: orchestrator)?.name ?? orchestrator
            let resident = await ModelRuntime.shared.cachedModelSummaries().map(\.name)
            restoredResident = resident.contains {
                $0.caseInsensitiveCompare(canonical) == .orderedSame
            }
        }

        // Restore config + core model, then drop the (reloaded) orchestrator so
        // the next case starts from a clean resident set.
        await MainActor.run {
            SubagentConfigurationStore.save(priorConfig)
            var c = ChatConfigurationStore.load()
            c.coreModelProvider = priorChat.provider
            c.coreModelName = priorChat.name
            ChatConfigurationStore.save(c)
        }
        await ModelRuntime.shared.unloadModelsNotIn([])

        return transcript(
            fromEnvelope: envelope,
            tool: "spawn_model",
            kindId: "spawn",
            toolCallId: toolCallId,
            latencyMs: latency,
            handoffWrapped: handoffFlag,
            restoredResident: restoredResident
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

    // MARK: - Eval agent seeding

    /// Seed a spawnable agent named `name` for the duration of `body`, then
    /// restore. Creates an `Agent` with that name (when absent, with a concise
    /// agent prompt) and adds it to the Default agent's GLOBAL spawnable pool
    /// (`SubagentConfiguration.spawnableAgentNames`, which the Default/main-chat
    /// agent the eval scope uses consults), so the `spawn` lane RUNS across
    /// models on any host instead of skipping for lack of a configured agent.
    /// Also forces `localTextDelegationEnabled` (the "Local Orchestrator
    /// Handoff" switch) ON for the run so a LOCAL run model can actually hand
    /// off to the local text subagent (unload/reload) instead of skipping —
    /// this is the real documented capability switch (the RAM-safety preflight
    /// still guards it), so `spawn` becomes a true cross-model column including
    /// local MLX, not just `foundation`/remote. The whole prior
    /// `SubagentConfiguration` is snapshotted and restored, and the seeded
    /// agent removed, leaving a developer's real config untouched. The
    /// seeded agent's own model is irrelevant — the eval passes the run model as
    /// a `TextSubagentKind` override. Seed/restore run on the main actor
    /// (`AgentStore`/`AgentManager` are main-actor state);
    /// `SubagentConfigurationStore` is nonisolated.
    public static func withSpawnableAgent<T: Sendable>(
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
                            "You are a concise subagent. Answer the task directly and follow any "
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
                // spawn the local agent (the chat model unloads to make
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

    /// Seed a spawnable MODEL `id` for the duration of `body`, then restore — the
    /// `spawn_model` analogue of `withSpawnableAgent`. Adds `id` to the Default
    /// agent's GLOBAL spawnable model pool (`SubagentConfiguration
    /// .spawnableModelNames`, which the Default/main-chat scope the eval uses
    /// consults) and forces `localTextDelegationEnabled` ON so a LOCAL target can
    /// hand off (unload/reload) instead of being denied. No `Agent` is created —
    /// model spawns carry no agent. The whole `SubagentConfiguration` is
    /// snapshotted and restored, leaving a developer's real config untouched.
    /// `SubagentConfigurationStore` is nonisolated, but this hops to the main
    /// actor to match `withSpawnableAgent`'s ordering against `AgentManager`.
    ///
    /// `toolAccess` (when non-nil) also sets the Default agent's global
    /// `spawnToolAccess` for the run — the tool-capable spawn lane (the child
    /// sees the curated read-only toolset instead of running text-only).
    public static func withSpawnableModel<T: Sendable>(
        id: String,
        toolAccess: SpawnToolAccess? = nil,
        _ body: @Sendable () async -> T
    ) async -> T {
        let state: (priorConfig: SubagentConfiguration, configChanged: Bool) = await MainActor.run {
            let priorConfig = SubagentConfigurationStore.snapshot()
            var updated = priorConfig
            if !priorConfig.isModelSpawnable(id) {
                updated.spawnableModelNames = priorConfig.spawnableModelNames + [id]
            }
            updated.localTextDelegationEnabled = true
            if let toolAccess { updated.spawnToolAccess = toolAccess }
            let configChanged = updated != priorConfig
            if configChanged { SubagentConfigurationStore.save(updated) }
            return (priorConfig, configChanged)
        }
        let result = await body()
        await MainActor.run {
            if state.configChanged {
                SubagentConfigurationStore.save(state.priorConfig)
            }
        }
        return result
    }

    // MARK: - Shared plumbing

    /// Schedule an interrupt through the REAL `SubagentInterruptCenter` (the
    /// feed row's stop-button path) after `afterMs`. Retries until the run's
    /// token is actually registered (a slow host may still be resolving when
    /// the delay elapses), so the stop can't be silently missed. Returns the
    /// task so the caller cancels it when the run finishes first. `nil` = no-op.
    private static func scheduleInterrupt(afterMs: Int?, toolCallId: String) -> Task<Void, Never>? {
        guard let afterMs, afterMs > 0 else { return nil }
        return Task {
            try? await Task.sleep(nanoseconds: UInt64(afterMs) * 1_000_000)
            while !Task.isCancelled {
                if SubagentInterruptCenter.shared.interrupt(toolCallId) { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

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
        nestedRefused: Bool? = nil,
        restoredResident: Bool? = nil
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

        // Usage / context-saved / residency telemetry from the payload, when
        // the run recorded them (spawn success payloads + the host's
        // residency object). All numeric maps, normalized for Codable.
        let usage = numberMap(payload["usage"])
        let contextAccounting = intMap(payload["context"])
        let residency = payload["residency"] as? [String: Any]
        let residencyPhases = numberMap(residency?["phases"])
        let postRunCache = intMap(residency?["post_run_cache"])

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
            latencyMs: latencyMs,
            usage: usage,
            contextAccounting: contextAccounting,
            residencyPhases: residencyPhases,
            postRunCache: postRunCache,
            restoredResident: restoredResident
        )
    }

    /// `[String: any number]` → `[String: Double]` (nil when absent/empty).
    private static func numberMap(_ value: Any?) -> [String: Double]? {
        guard let dict = value as? [String: Any] else { return nil }
        var result: [String: Double] = [:]
        for (key, raw) in dict {
            if let number = raw as? NSNumber { result[key] = number.doubleValue }
        }
        return result.isEmpty ? nil : result
    }

    /// `[String: any number]` → `[String: Int]` (nil when absent/empty).
    private static func intMap(_ value: Any?) -> [String: Int]? {
        guard let dict = value as? [String: Any] else { return nil }
        var result: [String: Int] = [:]
        for (key, raw) in dict {
            if let number = raw as? NSNumber { result[key] = number.intValue }
        }
        return result.isEmpty ? nil : result
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
    /// Optional shared overlap probe for the parallel-batch lane (enter/exit
    /// around `run`, so peak concurrency across sibling runs is observable).
    private let overlapProbe: SubagentOverlapProbe?

    init(spec: ScriptedSubagentSpec, overlapProbe: SubagentOverlapProbe? = nil) {
        self.spec = spec
        self.capability = SubagentCapability(
            id: spec.kindId,
            toolNames: [spec.kindId],
            gate: .sandboxExec
        )
        self.needsHandoff = spec.needsHandoff
        self.overlapProbe = overlapProbe
    }

    /// Whether the residency-handoff middleware wrapped the run.
    var handoffWrapped: Bool { recordingHandoff.wrapped }
    /// Whether the nested subagent attempt (when `spec.recurse`) was refused.
    var nestedRefused: Bool? { nestedBox.refused }

    var feedTitle: String { "scripted \(spec.kindId)" }

    func makeHandoff() -> SubagentHandoff {
        needsHandoff ? recordingHandoff : PassthroughHandoff()
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        if let failure = spec.resolveFailure { throw failure.error(context: "resolve") }
        return ResolvedModel(name: spec.modelName, id: spec.modelName, isLocal: !spec.remote)
    }

    /// A handoff-opted scripted kind models the local residency swap, so it
    /// admits as `.localExclusive` (a parallel batch of two serializes —
    /// the batch-race lane). Otherwise the protocol default applies (local
    /// in-place / remote fan-out from `spec.remote`).
    func admissionClass(_ resolved: ResolvedModel) -> SubagentAdmissionClass {
        if needsHandoff { return .localExclusive }
        return resolved.isLocal ? .localInPlace : .remote
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
        overlapProbe?.enter()
        defer { overlapProbe?.exit() }
        for phase in spec.phases { feed.emitPhase(phase, detail: resolved.name) }

        // Fan-out rendezvous: wait (bounded) until every sibling has entered,
        // so overlap is observed by construction, not by sleep timing.
        // Arrivals are monotonic, so a sibling that already exited still counts.
        if spec.rendezvousArrivals > 0, let probe = overlapProbe {
            let deadline = Date().addingTimeInterval(3)
            while probe.arrivals < spec.rendezvousArrivals, Date() < deadline {
                if interrupt.isInterrupted { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        if spec.recurse {
            // A running subagent must not be able to start another: drive a
            // nested host run and record whether the unified guard refused it.
            let nested = await SubagentSession.run(
                ScriptedSubagentKind(spec: ScriptedSubagentSpec(kindId: "scripted-nested")),
                tool: "scripted-nested"
            )
            nestedBox.refused =
                ToolEnvelope.isError(nested)
                && (SubagentJobEvaluator.failureKind(nested) == "rejected")
        }

        // Hold the run open, polling the interrupt token — the deterministic
        // interrupt-mid-run lane (feed stop button → InterruptCenter → token
        // → honest user-stop error), plus the overlap window for the
        // parallel-batch lane. Mirrors `TextSubagentKind`'s cancel mapping.
        if spec.runDelayMs > 0 {
            let deadline = Date().addingTimeInterval(Double(spec.runDelayMs) / 1000)
            while Date() < deadline {
                if interrupt.isInterrupted {
                    throw SubagentError.userDenied(
                        "Scripted subagent was stopped by the user."
                    )
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if interrupt.isInterrupted {
                throw SubagentError.userDenied("Scripted subagent was stopped by the user.")
            }
        }

        if let failure = spec.runFailure { throw failure.error(context: "run") }

        var payload: [String: Any] = [
            "kind": spec.resultKind,
            "model": resolved.name,
            "summary": spec.summary,
        ]
        if spec.includeUsageAccounting {
            // Canned numbers exercising the SAME payload keys the live spawn
            // path emits, so the transcript + scoring plumbing is CI-testable.
            payload["usage"] =
                [
                    "prompt_tokens": 120,
                    "completion_tokens": 40,
                    "total_tokens": 160,
                    "tokens_per_second": 42.5,
                ] as [String: Any]
            payload["context"] = [
                "worker_tokens": 160,
                "digest_tokens": 12,
                "context_saved_tokens": 148,
            ]
        }
        return SubagentResult(payload: payload, summary: spec.summary)
    }
}

/// Shared enter/exit concurrency probe for the parallel-batch lane: sibling
/// scripted runs report peak overlap of their `run()` bodies, which is the
/// substantive "did the admission gate serialize / fan out" observation.
public final class SubagentOverlapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var entries = 0

    public init() {}

    public var maxConcurrent: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
    /// Total number of runs that ENTERED (monotonic — rendezvous-safe).
    public var arrivals: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func enter() {
        lock.lock()
        active += 1
        peak = max(peak, active)
        entries += 1
        lock.unlock()
    }
    func exit() {
        lock.lock()
        active -= 1
        lock.unlock()
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
