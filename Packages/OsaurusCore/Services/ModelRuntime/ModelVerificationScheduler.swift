//
//  ModelVerificationScheduler.swift
//  osaurus
//
//  Background capability verification on model install ("autorun").
//
//  When a model finishes downloading, `ModelDownloadService` posts a
//  `modelInstalled(name:localDirectory:)` event here. The scheduler waits —
//  at `.utility` priority, polling with backoff — for the inference runtime
//  to go fully idle, then runs a deliberately MINIMAL in-process probe set
//  (NOT the full HTTP gauntlet, which lives in the `osaurus verify` CLI,
//  #1916):
//
//    * load probe — cold-load the model and run a hidden 8-token greedy
//      generation through the real request path (the same micro-generation
//      pattern `MLXBatchAdapter.warmupNativeMTPAtLoad` uses at load).
//    * templateLeak probe — scan that output for chat-template control
//      tokens leaking into visible text.
//
//  Results are written to the model-capability ledger
//  (`ModelVerificationLedger`, `~/.osaurus/config/model-ledger.json`) for
//  the gauntlet CLI and future gates to read. Autorun NEVER writes the
//  `productionServing` field — a background probe must never be able to
//  block a model (see ModelVerificationLedger.swift).
//
//  Give-up semantics: if the runtime never goes idle within
//  `idleWaitDeadline` (default 30 min), the run is SKIPPED and logged — it
//  is intentionally NOT re-queued for the next launch. Autorun v1 is a
//  best-effort evidence collector, not a gate: a machine that is busy for
//  30 straight minutes is actively serving, which is itself decent evidence
//  the model economy works, and the explicit gauntlet remains the
//  authoritative path. Persisting a retry queue would add state + startup
//  work for marginal value.
//
//  Feature flag: `ai.osaurus.verification.autoRunOnInstall` (UserDefaults
//  Bool), DEFAULT FALSE in v1 — a background GPU load after every download
//  is surprising behavior to ship silently. The intended end-state default
//  is TRUE once the maintainer has reviewed the probe cost in the field;
//  flipping `defaultsValueWhenUnset` below is the only change needed.
//

import Foundation
import os

private let autorunLog = Logger(subsystem: "com.dinoki.osaurus", category: "VerificationAutorun")

// MARK: - Probe outcome types

/// Verdict of a single autorun probe, mirroring the ledger contract's
/// `verdict` field values.
enum VerificationProbeVerdict: String, Sendable, Equatable {
    case pass
    case fail
    /// The probe could not run (e.g. the leak scan when the load failed).
    case skipped
}

/// Result of one autorun probe pass over a freshly installed model.
struct VerificationProbeOutcome: Sendable, Equatable {
    let loadVerdict: VerificationProbeVerdict
    let loadEvidence: String
    let templateLeakVerdict: VerificationProbeVerdict
    let templateLeakEvidence: String
    /// Wall-clock seconds for the whole probe pass (load + generation).
    let elapsedSeconds: Double
}

// MARK: - Injection seams (tests)

/// "Is the inference runtime idle enough to run a background probe?"
protocol VerificationIdleChecking: Sendable {
    func isRuntimeIdle() async -> Bool
}

/// Runs the actual probes against a model. Production uses
/// `RuntimeVerificationProber`; tests inject a fake.
protocol VerificationProbing: Sendable {
    func runProbes(modelName: String, localDirectory: URL?) async -> VerificationProbeOutcome
}

/// Persists a probe outcome. Production writes the ledger file.
protocol VerificationRecording: Sendable {
    func record(modelName: String, outcome: VerificationProbeOutcome) async
}

// MARK: - Scheduler

actor ModelVerificationScheduler {
    /// UserDefaults feature flag. Default false in v1; intended end-state
    /// default is true (see header).
    static let autoRunOnInstallDefaultsKey = "ai.osaurus.verification.autoRunOnInstall"
    private static let defaultsValueWhenUnset = false

    struct Configuration: Sendable {
        /// First idle-poll wait; doubles (capped) on every busy poll.
        var initialPollInterval: TimeInterval = 5
        var maxPollInterval: TimeInterval = 60
        var backoffMultiplier: Double = 2
        /// Total time to wait for an idle window before skipping the run.
        var idleWaitDeadline: TimeInterval = 30 * 60
        /// Feature-flag read, injectable so tests don't touch real defaults.
        var isAutoRunEnabled: @Sendable () -> Bool = {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: ModelVerificationScheduler.autoRunOnInstallDefaultsKey) != nil else {
                return ModelVerificationScheduler.defaultsValueWhenUnset
            }
            return defaults.bool(forKey: ModelVerificationScheduler.autoRunOnInstallDefaultsKey)
        }
    }

    /// What a single verification run did — surfaced for tests/diagnostics.
    enum RunResult: Sendable, Equatable {
        /// Feature flag off: the event was dropped without any polling.
        case disabled
        /// Runtime stayed busy past `idleWaitDeadline`; run skipped, NOT
        /// re-queued (see header for why).
        case skippedBusy
        case completed(VerificationProbeOutcome)
    }

    static let shared = ModelVerificationScheduler()

    private let configuration: Configuration
    private let idleChecker: any VerificationIdleChecking
    private let prober: any VerificationProbing
    private let recorder: any VerificationRecording

    /// Pending install events. Runs are strictly serialized so two installs
    /// finishing together can never race two probe loads onto the GPU.
    private var queue: [(name: String, localDirectory: URL?)] = []
    private var isDraining = false

    init(
        configuration: Configuration = Configuration(),
        idleChecker: any VerificationIdleChecking = RuntimeVerificationIdleChecker(),
        prober: any VerificationProbing = RuntimeVerificationProber(),
        recorder: any VerificationRecording = LedgerVerificationRecorder()
    ) {
        self.configuration = configuration
        self.idleChecker = idleChecker
        self.prober = prober
        self.recorder = recorder
    }

    // MARK: Event intake

    /// Fire-and-forget install event. Safe to call from any actor (the
    /// download-completion path is `@MainActor`); the verification work runs
    /// on a detached-from-caller `.utility` task.
    nonisolated func modelInstalled(name: String, localDirectory: URL?) {
        Task(priority: .utility) {
            await self.enqueue(name: name, localDirectory: localDirectory)
        }
    }

    private func enqueue(name: String, localDirectory: URL?) async {
        queue.append((name: name, localDirectory: localDirectory))
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            _ = await verifyNow(name: next.name, localDirectory: next.localDirectory)
        }
    }

    // MARK: Single run

    /// One full verification run: flag gate → idle wait (poll w/ backoff,
    /// bounded by `idleWaitDeadline`) → probes → ledger write → one log line.
    /// Exposed (internal) so tests can drive a run synchronously.
    @discardableResult
    func verifyNow(name: String, localDirectory: URL?) async -> RunResult {
        guard configuration.isAutoRunEnabled() else {
            autorunLog.debug(
                "autorun disabled (\(Self.autoRunOnInstallDefaultsKey, privacy: .public)); dropping install event for \(name, privacy: .public)"
            )
            return .disabled
        }

        let deadline = Date().addingTimeInterval(configuration.idleWaitDeadline)
        var interval = max(0.001, configuration.initialPollInterval)
        while await !idleChecker.isRuntimeIdle() {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                // Deliberately not re-queued — best-effort evidence only.
                print(
                    "[Osaurus] autorun: model=\(name) skipped (runtime busy past "
                        + "\(Int(configuration.idleWaitDeadline))s idle deadline; not re-queued)"
                )
                return .skippedBusy
            }
            try? await Task.sleep(for: .seconds(min(interval, remaining)))
            interval = min(interval * configuration.backoffMultiplier, configuration.maxPollInterval)
        }

        let outcome = await prober.runProbes(modelName: name, localDirectory: localDirectory)
        await recorder.record(modelName: name, outcome: outcome)
        print(
            "[Osaurus] autorun: model=\(name) load=\(outcome.loadVerdict.rawValue) "
                + "templateLeak=\(outcome.templateLeakVerdict.rawValue) "
                + "(\(String(format: "%.1f", outcome.elapsedSeconds))s)"
        )
        return .completed(outcome)
    }
}

// MARK: - Production idle checker

/// Idle = no live chat generation (`InferenceLoadCoordinator`), no container
/// load in flight, and no tracked non-chat generation (HTTP API / plugin
/// streams are GPU work too, even though the chat coordinator doesn't count
/// them).
struct RuntimeVerificationIdleChecker: VerificationIdleChecking {
    func isRuntimeIdle() async -> Bool {
        if await InferenceLoadCoordinator.shared.activeCount > 0 { return false }
        return await !ModelRuntime.shared.hasLoadOrGenerationInFlight
    }
}

// MARK: - Production prober

/// v1 in-process probe set. Reuses the runtime's real load + generate
/// surface (`ModelRuntime.respondWithTools`) so the probe exercises exactly
/// what a first user request would — same hidden-micro-generation idea as
/// the MTP warmup `MLXBatchAdapter.warmupNativeMTPAtLoad` runs at load.
struct RuntimeVerificationProber: VerificationProbing {
    func runProbes(modelName: String, localDirectory: URL?) async -> VerificationProbeOutcome {
        let startedAt = Date()

        guard let found = ModelManager.findInstalledModel(named: modelName) else {
            let elapsed = Date().timeIntervalSince(startedAt)
            return VerificationProbeOutcome(
                loadVerdict: .fail,
                loadEvidence: "installed model not found for \(modelName)"
                    + (localDirectory.map { " (dir: \($0.path))" } ?? ""),
                templateLeakVerdict: .skipped,
                templateLeakEvidence: "load probe did not produce output",
                elapsedSeconds: elapsed
            )
        }

        let wasResident = await ModelRuntime.shared.isResident(name: found.name)

        // Hidden 8-token greedy micro-generation. `suppressProgressUI` keeps
        // the load out of the global progress HUD (the warmup side channel
        // still gets it), temperature 0 makes the sample deterministic, and
        // `.httpAPI` request-source is the conservative residency class.
        let parameters = GenerationParameters(
            temperature: 0.0,
            maxTokens: 8,
            suppressProgressUI: true,
            requestSource: .httpAPI
        )

        var loadVerdict: VerificationProbeVerdict
        var loadEvidence: String
        var leakVerdict: VerificationProbeVerdict
        var leakEvidence: String
        do {
            let text = try await ModelRuntime.shared.respondWithTools(
                messages: [ChatMessage(role: "user", content: "Reply with one short word.")],
                parameters: parameters,
                stopSequences: [],
                tools: [],
                toolChoice: nil,
                modelId: found.id,
                modelName: found.name
            )
            let elapsed = Date().timeIntervalSince(startedAt)
            loadVerdict = .pass
            loadEvidence = String(
                format: "loaded and generated %d-token greedy sample in %.1fs",
                parameters.maxTokens,
                elapsed
            )
            if let leaked = AutorunTemplateLeakScan.firstLeakedToken(in: text) {
                leakVerdict = .fail
                leakEvidence = "template control token \(leaked) leaked into visible output"
            } else {
                leakVerdict = .pass
                leakEvidence = "no template control tokens in \(parameters.maxTokens)-token greedy sample"
            }
        } catch {
            loadVerdict = .fail
            loadEvidence = "load/generate failed: \(error.localizedDescription)"
            leakVerdict = .skipped
            leakEvidence = "load probe did not produce output"
        }

        // Residency: if the probe cold-loaded the model purely for
        // verification and nothing else picked it up meanwhile (no lease),
        // release the unified memory immediately instead of holding
        // gigabytes hostage to the idle-residency timer. A model that was
        // already resident — or that a user/API client started using during
        // the probe — is left exactly as the normal residency policy would
        // have it.
        if !wasResident {
            let stillResident = await ModelRuntime.shared.isResident(name: found.name)
            let leaseCount = await ModelLease.shared.count(for: found.name)
            if stillResident, leaseCount == 0 {
                await ModelRuntime.shared.unload(name: found.name)
            }
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        return VerificationProbeOutcome(
            loadVerdict: loadVerdict,
            loadEvidence: loadEvidence,
            templateLeakVerdict: leakVerdict,
            templateLeakEvidence: leakEvidence,
            elapsedSeconds: elapsed
        )
    }
}

// MARK: - Production recorder

/// Writes outcomes into the capability ledger. Failures are logged, never
/// thrown — autorun is best-effort and must not surface errors to install UX.
struct LedgerVerificationRecorder: VerificationRecording {
    func record(modelName: String, outcome: VerificationProbeOutcome) async {
        do {
            try ModelVerificationLedger.recordAutorunProbes(
                modelName: modelName,
                outcome: outcome,
                chip: ModelVerificationLedger.currentChipBrandString()
            )
        } catch {
            autorunLog.error(
                "autorun: ledger write failed for \(modelName, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}

// MARK: - Template-leak scan

/// CROSS-REFERENCE: vendored mirror of the token list in
/// `StreamTemplateLeakDetector` (Services/ModelRuntime on the
/// `mlx-perf/runtime-guardrails` branch, unmerged). This PR branches from
/// `main` where that detector does not exist yet; when the guardrails PR
/// lands, delete this enum and call the detector instead. Named distinctly
/// so the eventual merge cannot collide.
enum AutorunTemplateLeakScan {
    /// Chat-template control tokens that must never appear in visible model
    /// output. Substring match is intentional — these markers are unusual
    /// enough that any occurrence in an 8-token greedy sample is a leak.
    static let leakTokens: [String] = [
        // ChatML (Qwen, many fine-tunes)
        "<|im_start|>", "<|im_end|>",
        // GPT-2/OSS lineage
        "<|endoftext|>",
        // Llama 3 header protocol
        "<|begin_of_text|>", "<|end_of_text|>",
        "<|start_header_id|>", "<|end_header_id|>",
        "<|eot_id|>", "<|eom_id|>",
        // Phi-style role tags
        "<|system|>", "<|user|>", "<|assistant|>",
        // Harmony (gpt-oss) channel protocol
        "<|channel|>", "<|message|>", "<|return|>",
        // Gemma turn markers
        "<start_of_turn>", "<end_of_turn>",
        // Llama 2 / Mistral instruct wrappers
        "[INST]", "[/INST]", "<<SYS>>", "<</SYS>>",
        // Sentencepiece EOS leaking as text
        "</s>",
    ]

    /// First leaked control token found in `text`, or nil when clean.
    static func firstLeakedToken(in text: String) -> String? {
        leakTokens.first { text.contains($0) }
    }
}
