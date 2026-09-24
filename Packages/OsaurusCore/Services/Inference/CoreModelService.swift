//
//  CoreModelService.swift
//  osaurus
//
//  Shared actor for lightweight Core Model inference calls.
//  Routes through ModelServiceRouter with retry, timeout, and circuit breaker.
//  Used by MemoryService and other subsystems
//  that need one-shot LLM generation via the user-configured core model.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "core_model")

public enum CoreModelError: Error, LocalizedError, Equatable {
    case modelUnavailable(String)
    case circuitBreakerOpen
    case timedOut
    /// The primary core model accepted the request but produced no output
    /// within its service's first-token deadline. Distinct from `.timedOut`
    /// (the whole-call budget) so logs and the breaker can tell "wedged
    /// before the first token" from "slow generation".
    case unresponsive(String)
    /// A background call wanted a local MLX model that isn't the one
    /// currently resident (or loading). Serving it would evict the
    /// user's model, so the call was declined instead. Best-effort
    /// callers should degrade quietly; this is not a failure.
    case backgroundWouldEvictUserModel(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let model):
            return "Core model '\(model)' is not available"
        case .circuitBreakerOpen:
            return "Core model temporarily unavailable (too many recent failures)"
        case .timedOut:
            return "Core model call timed out"
        case .unresponsive(let model):
            return "Core model '\(model)' produced no output within its first-token deadline"
        case .backgroundWouldEvictUserModel(let model):
            return "Skipped background call to '\(model)': loading it would evict the model in use"
        }
    }
}

/// Who is waiting on a `CoreModelService` call.
///
/// This matters because the runtime is strictly single-model: loading model B
/// evicts resident model A, and a new load cancels an in-flight one. A call the
/// user is waiting on has earned that right. A housekeeping call — memory
/// distillation, voice-transcript cleanup, a greeting — has not: it must never
/// evict the model the user is chatting with, nor cancel the load they are
/// staring at a spinner for.
public enum CoreModelIntent: Sendable {
    /// The user is waiting on this call. May load/evict as needed.
    case interactive
    /// Housekeeping. Declines rather than disturb a resident or loading model.
    case background
}

/// Resolution snapshot for the configured core model. Surfaced in the
/// Memory diagnostics panel so the user can tell whether their
/// Foundation / MLX / remote core model is actually wired up before
/// distillation tries to use it.
public enum CoreModelStatus: Sendable, Equatable {
    /// No core model configured (`coreModelIdentifier == nil`).
    case unset
    /// Configured and the router can resolve it to a live service.
    case available(modelId: String, serviceId: String, effectiveModel: String)
    /// Configured but no available service handles the identifier.
    /// Most common reasons: Apple Intelligence turned off / model still
    /// downloading for Foundation, or a remote provider that was disconnected.
    case unavailable(modelId: String, reason: String)
    /// Breaker is currently open after consecutive failures. Calls that
    /// carry a chat-model fallback are served from the fallback for the
    /// duration; calls without one see `circuitBreakerOpen` until the
    /// cooldown elapses.
    case breakerOpen(modelId: String?, until: Date)
}

public actor CoreModelService {
    public static let shared = CoreModelService()

    private let localServices: [ModelService]

    private static let maxRetries = 3
    private static let baseRetryDelayNanoseconds: UInt64 = 1_000_000_000

    // MARK: Breaker state
    //
    // The breaker protects the *primary* core model (the configured one, or
    // the per-call override). It is opened by primary failures — including
    // failures that the chat-model fallback then rescued — and cleared only
    // by a primary success. A fallback success must not clear it: that would
    // hide a wedged primary and re-probe it on every call. While it is open,
    // calls that carry a distinct fallback skip the primary entirely; only
    // calls without one see `circuitBreakerOpen`.

    /// Generic failures (framework errors, remote 5xx, …) since the last
    /// primary success. Opens the breaker at `circuitBreakerThreshold`.
    private var consecutiveFailures = 0
    /// Hang-type failures (`.timedOut`, `.unresponsive`) since the last
    /// primary success. A hang burns the caller's whole first-token or
    /// timeout budget, so the breaker opens after far fewer of them
    /// (`hangBreakerThreshold`) to stop paying that cost on every call.
    private var consecutiveHangs = 0
    private var circuitOpenUntil: Date?
    /// Last error that contributed to the breaker opening. Surfaced
    /// in log messages so callers (and humans reading the log) can
    /// see the root cause instead of just "circuitBreakerOpen".
    private var lastBreakerError: Error?
    /// Number of times the breaker has re-opened without an
    /// intervening successful call. Drives exponential cooldown so a
    /// genuinely-broken backend (Foundation framework lock contention,
    /// crashed remote provider) doesn't get hammered every minute
    /// forever. Reset to zero on any successful primary generation.
    private var consecutiveBreakerCycles = 0
    /// Set when a cooldown has elapsed and the next primary attempt is a
    /// probe. A single counted failure while probing re-opens the breaker
    /// at the next cooldown bucket instead of needing a full threshold's
    /// worth of failures again.
    private var halfOpenProbe = false

    static let circuitBreakerThreshold = 5
    static let hangBreakerThreshold = 2
    /// Base cooldown after the breaker first opens. Doubles each cycle
    /// the breaker re-opens without a success in between (60s, 120s,
    /// 240s, …) up to `circuitBreakerMaxCooldownSeconds`.
    private static let circuitBreakerCooldownSeconds: TimeInterval = 60
    private static let circuitBreakerMaxCooldownSeconds: TimeInterval = 30 * 60

    private init() {
        localServices = [FoundationModelService(), ClaudeCodeService(), MLXService.shared]
    }

    init(localServices: [ModelService]) {
        self.localServices = localServices
    }

    /// One-shot generation using the core model configured in ChatConfiguration.
    /// - Parameters:
    ///   - prompt: The user prompt.
    ///   - systemPrompt: Optional system prompt.
    ///   - temperature: Sampling temperature (default 0.3); nil preserves model/provider defaults.
    ///   - maxTokens: Maximum response tokens (default 2048).
    ///   - timeout: Maximum wall-clock seconds for the call (default 60).
    ///   - fallbackModel: Model identifier to fall back to when the configured
    ///     core model is unset or cannot serve on this machine. Callers
    ///     should pass the active conversation model so preflight and other
    ///     background calls work out of the box without an explicit Core Model
    ///     setting (root cause of GitHub issue #823 — macOS < 26 ships with
    ///     `coreModelName = "foundation"` persisted but the router can't
    ///     satisfy it). When a distinct fallback is supplied the primary gets
    ///     exactly one attempt (with its service's first-token deadline) and
    ///     every failure except cancellation and an un-opted residency
    ///     refusal moves to the fallback immediately.
    /// - Returns: The model's text response.
    public func generate(
        prompt: String,
        systemPrompt: String? = nil,
        temperature: Double? = 0.3,
        maxTokens: Int = 2048,
        timeout: TimeInterval = 60,
        fallbackModel: String? = nil,
        intent: CoreModelIntent = .interactive,
        modelOverride: String? = nil,
        fallBackOnResidencyRefusal: Bool = false
    ) async throws -> String {
        try await generate(
            prompt: prompt,
            systemPrompt: systemPrompt,
            temperature: temperature,
            maxTokens: maxTokens,
            timeout: timeout,
            fallbackModel: fallbackModel,
            intent: intent,
            modelOverride: modelOverride,
            fallBackOnResidencyRefusal: fallBackOnResidencyRefusal,
            modelOptions: [:]
        )
    }

    /// - Parameter modelOverride: When set, this identifier is used as the
    ///   primary model in place of the globally-configured core model (the
    ///   chat-model fallback still applies). Lets a caller route a specific
    ///   auxiliary call — e.g. a per-agent follow-up model — without changing
    ///   the shared Core Model setting.
    /// - Parameter fallBackOnResidencyRefusal: When true, a `.background`
    ///   primary that is refused because loading it would evict a resident
    ///   model (`.backgroundWouldEvictUserModel`) also falls back to the chat
    ///   model, instead of failing. The chat model is the one the user is
    ///   actively on, so it is already resident (local) or remote — running
    ///   there evicts nothing. Off by default so strict background callers
    ///   (titles, memory) keep their "never touch the resident" guarantee;
    ///   follow-ups opt in so they generate for users chatting on a remote
    ///   provider while a local model happens to be resident.
    func generate(
        prompt: String,
        systemPrompt: String? = nil,
        temperature: Double? = 0.3,
        maxTokens: Int = 2048,
        timeout: TimeInterval = 60,
        fallbackModel: String? = nil,
        intent: CoreModelIntent = .interactive,
        modelOverride: String? = nil,
        fallBackOnResidencyRefusal: Bool = false,
        modelOptions: [String: ModelOptionValue]
    ) async throws -> String {
        // A per-call override wins over the shared Core Model setting; empty
        // strings are treated as "no override" so callers can pass raw config.
        // The `await` can't live in a `??` autoclosure, so resolve it up front
        // and only read settings when there's no override.
        let configured: String?
        if let override = Self.normaliseFallback(modelOverride) {
            configured = override
        } else {
            configured = await MainActor.run {
                ChatConfigurationStore.load().coreModelIdentifier
            }
        }
        let fallback = Self.normaliseFallback(fallbackModel)
        let messages = buildMessages(prompt: prompt, systemPrompt: systemPrompt)
        let params = GenerationParameters(
            temperature: temperature.map { Float($0) },
            maxTokens: maxTokens,
            modelOptions: modelOptions,
            // Carried all the way into `ModelRuntime.loadContainer`, which refuses
            // a background load *at the moment it would evict* — atomically, inside
            // the actor. Probing residency from out here and then loading on a
            // later actor hop is a check-then-act race: whatever the probe saw can
            // change before the load runs.
            loadIntent: intent == .background ? .background : .interactive,
            // Utilities borrow a resident model; they must not overwrite the
            // chat/API/agent owner used by window-close cleanup and handoff.
            preserveExistingResidencyOwner: true,
            // Every CoreModelService one-shot is an internal utility (title,
            // follow-ups, memory distillation, transcript cleanup) whose prompt
            // is never resumed — the engine must not persist its boundaries.
            auxiliaryCacheIntent: true
        )

        let distinctFallback: String? = {
            guard let fb = fallback, fb != configured else { return nil }
            return fb
        }()

        if breakerIsOpen() {
            // The primary is cooling down. A call that carries a distinct
            // fallback is served from it directly — the chat model is healthy
            // and the user is waiting on a title / follow-ups / distillation.
            // Fallback failures here are not counted: the breaker is about
            // the primary.
            if let primary = configured, let fb = distinctFallback {
                logger.info(
                    "Core model '\(primary)' breaker open; serving from chat model '\(fb)' during cooldown")
                return try await runWithRetries(
                    model: fb, messages: messages, params: params, timeout: timeout, intent: intent,
                    role: .fallback)
            }
            throw CoreModelError.circuitBreakerOpen
        }

        return try await runWithChatModelFallback(
            primary: configured,
            fallback: distinctFallback,
            messages: messages,
            params: params,
            timeout: timeout,
            intent: intent,
            fallBackOnResidencyRefusal: fallBackOnResidencyRefusal
        )
    }

    /// Which model a `runWithRetries` pass is running. Decides the retry
    /// budget, whether the first-token deadline applies, and how the result
    /// feeds the breaker.
    private enum ModelRole {
        /// The only model this call can use (configured without a fallback,
        /// or the chat model when nothing is configured). Full retry budget;
        /// success clears the breaker, failure counts toward it.
        case solo
        /// The configured / override model when a distinct fallback exists.
        /// Single attempt with the service's first-token deadline; success
        /// clears the breaker, failure counts toward it and hands over.
        case primaryWithFallback
        /// The chat model after the primary failed or while the breaker is
        /// open. Full retry budget; neither outcome touches the breaker.
        case fallback
    }

    /// Run the primary with at most one chat-model fallback, doing all breaker
    /// accounting so `generate` reads as a flat "resolve + run" pair.
    private func runWithChatModelFallback(
        primary: String?,
        fallback: String?,
        messages: [ChatMessage],
        params: GenerationParameters,
        timeout: TimeInterval,
        intent: CoreModelIntent,
        fallBackOnResidencyRefusal: Bool
    ) async throws -> String {
        guard let primary else {
            guard let fb = fallback else { throw CoreModelError.modelUnavailable("none") }
            logger.info("Core model unset; using chat model '\(fb)' as fallback")
            do {
                return try await runWithRetries(
                    model: fb, messages: messages, params: params, timeout: timeout, intent: intent,
                    role: .solo)
            } catch {
                recordPrimaryFailure(error)
                throw error
            }
        }

        guard let fb = fallback else {
            do {
                return try await runWithRetries(
                    model: primary, messages: messages, params: params, timeout: timeout, intent: intent,
                    role: .solo)
            } catch {
                recordPrimaryFailure(error)
                throw error
            }
        }

        let started = Date()
        let primaryError: Error
        do {
            return try await runWithRetries(
                model: primary, messages: messages, params: params, timeout: timeout, intent: intent,
                role: .primaryWithFallback)
        } catch {
            primaryError = error
        }

        // Caller walked away mid-flight — don't spend the fallback model on a
        // generation no one is waiting for, and don't blame the primary.
        if primaryError is CancellationError { throw primaryError }

        recordPrimaryFailure(primaryError)

        // Which primary failures hand over to the chat model:
        //  - `.modelUnavailable`: the identifier can't be routed at all
        //    (Foundation not available on this Mac, a deleted MLX model, a
        //    disconnected remote provider).
        //  - `.timedOut` / `.unresponsive`: the primary is wedged; the chat
        //    model is resident or remote and can answer now.
        //  - `.backgroundWouldEvictUserModel`: only when the caller opted in
        //    (follow-ups). The primary was refused because loading it would
        //    evict a resident; the chat model is already resident/remote, so
        //    running there generates without eviction.
        //  - Any non-`CoreModelError` (typed Foundation failure, remote 5xx,
        //    MLX runtime error): the backend is wedged below the routing
        //    layer; try the chat model once so best-effort callers still get
        //    useful output.
        if let coreErr = primaryError as? CoreModelError,
            !Self.shouldFallBackToChatModel(for: coreErr, allowResidencyRefusal: fallBackOnResidencyRefusal)
        {
            throw coreErr
        }

        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        logger.warning(
            "Core model '\(primary)' failed after \(elapsedMs)ms (\(primaryError.localizedDescription)); falling back to chat model '\(fb)'"
        )
        return try await runWithRetries(
            model: fb, messages: messages, params: params, timeout: timeout, intent: intent,
            role: .fallback)
    }

    /// Whether a failed primary attempt should retry on the chat model.
    /// Pure so the fallback contract can be pinned without a live runtime.
    ///   - `.modelUnavailable`: the primary can't be routed at all — always
    ///     retry the chat model (issue #823).
    ///   - `.timedOut` / `.unresponsive`: the primary is hung. The chat model
    ///     is the one actually in use (resident or remote), so it can answer
    ///     now; the hang is still counted against the primary's breaker.
    ///   - `.backgroundWouldEvictUserModel`: only when the caller opted in
    ///     (follow-ups). The primary was refused to protect a resident; the
    ///     chat model is the one actually in use, so retrying there
    ///     generates without evicting anything.
    ///   - `.circuitBreakerOpen`: never reaches this decision — an open
    ///     breaker is handled structurally in `generate` before routing.
    static func shouldFallBackToChatModel(
        for error: CoreModelError,
        allowResidencyRefusal: Bool
    ) -> Bool {
        switch error {
        case .modelUnavailable, .timedOut, .unresponsive:
            return true
        case .backgroundWouldEvictUserModel:
            return allowResidencyRefusal
        case .circuitBreakerOpen:
            return false
        }
    }

    /// Trim whitespace and treat empty fallback identifiers as nil so callers
    /// can pass `request.model` through without pre-validating.
    private static func normaliseFallback(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Manually clear breaker state. Used by tests; could be wired
    /// to a Settings affordance if we ever want a "Retry now" button.
    public func resetBreaker() {
        clearBreakerState()
    }

    /// Cooldown end while the breaker is open, else nil. Test hook.
    func breakerOpenUntil() -> Date? {
        guard let until = circuitOpenUntil, Date() < until else { return nil }
        return until
    }

    /// Probe whether the configured core model can be resolved by the
    /// router right now. Does NOT make an LLM call — only iterates the
    /// candidate services' `isAvailable()` / `handles(...)` functions,
    /// which are cheap and side-effect-free.
    ///
    /// Used by the Memory diagnostics panel to surface "Apple Intelligence
    /// is turned off" / "remote provider disconnected" instead of letting
    /// those failures live as `.info` log messages the user never sees.
    public func resolveStatus() async -> CoreModelStatus {
        if let openUntil = breakerOpenUntil() {
            let configured = await MainActor.run {
                ChatConfigurationStore.load().coreModelIdentifier
            }
            return .breakerOpen(modelId: configured, until: openUntil)
        }

        let configured = await MainActor.run {
            ChatConfigurationStore.load().coreModelIdentifier
        }
        guard let modelId = configured else { return .unset }

        let remoteServices: [ModelService] = await MainActor.run {
            RemoteProviderManager.shared.connectedServices()
        }
        let route = ModelServiceRouter.resolve(
            requestedModel: modelId,
            services: localServices,
            remoteServices: remoteServices
        )

        switch route {
        case .service(let service, let effectiveModel):
            return .available(
                modelId: modelId,
                serviceId: service.id,
                effectiveModel: effectiveModel
            )
        case .none:
            let reason = Self.unavailableReason(modelId: modelId)
            return .unavailable(modelId: modelId, reason: reason)
        }
    }

    /// Best-effort human-readable reason for why the router couldn't
    /// satisfy `modelId`. For Foundation this is the framework's own
    /// availability reason (Apple Intelligence off, model downloading, …);
    /// everything else is a heuristic on the identifier shape. No I/O.
    static func unavailableReason(modelId: String) -> String {
        let lowered = modelId.lowercased()
        if lowered == "foundation" || lowered.hasSuffix("/foundation") {
            return FoundationModelService.defaultModelAvailability().unavailableReason?.userDescription
                ?? "Foundation Model is not available on this Mac."
        }
        if lowered.contains("/") {
            let provider = lowered.split(separator: "/").first.map(String.init) ?? lowered
            return
                "Remote provider '\(provider)' is not connected. Reconnect it under Settings → Providers."
        }
        return
            "No local model named '\(modelId)' is downloaded. Pick a different Core Model under Settings → General."
    }

    // MARK: - Private — breaker bookkeeping

    /// True while the cooldown is active. When the cooldown has elapsed,
    /// transitions the breaker to a "half-open" probe state — counters,
    /// cooldown window, and last-error are cleared so the next primary
    /// attempt runs, but `consecutiveBreakerCycles` is PRESERVED and
    /// `halfOpenProbe` is set so a failed probe re-opens immediately at the
    /// next cooldown bucket (60s → 120s → 240s …) instead of restarting the
    /// count — without that, a wedged backend would stay pinned in
    /// fast-retry mode forever.
    private func breakerIsOpen() -> Bool {
        guard let openUntil = circuitOpenUntil else { return false }
        if Date() < openUntil { return true }
        consecutiveFailures = 0
        consecutiveHangs = 0
        circuitOpenUntil = nil
        lastBreakerError = nil
        halfOpenProbe = true
        logger.info("Circuit breaker cooldown elapsed — entering half-open probe")
        return false
    }

    private func clearBreakerState() {
        consecutiveFailures = 0
        consecutiveHangs = 0
        circuitOpenUntil = nil
        lastBreakerError = nil
        halfOpenProbe = false
        // A success between cycles resets the exponential cooldown so
        // the next genuine outage starts at the fast 60s cadence
        // again rather than inheriting yesterday's backoff.
        consecutiveBreakerCycles = 0
    }

    /// Whether a primary failure should count toward opening the breaker.
    ///
    /// `modelUnavailable` is a **configuration** error, not a flaky
    /// backend — the user's `coreModelIdentifier` points at something
    /// the router can't service (Foundation with Apple Intelligence off,
    /// a remote provider that was uninstalled, an MLX model that was
    /// deleted). Counting it would lock the user out of the preflight
    /// path with a misleading "circuitBreakerOpen" that hides the real fix.
    /// A declined background call is a policy decision, not a backend
    /// fault: counting it would let a long chat session — where a model is
    /// legitimately resident the whole time — trip the breaker and lock the
    /// *user's* own interactive calls out. Cancellation isn't a fault either.
    static func countsTowardBreaker(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let coreErr = error as? CoreModelError else { return true }
        switch coreErr {
        case .modelUnavailable, .backgroundWouldEvictUserModel, .circuitBreakerOpen:
            return false
        case .timedOut, .unresponsive:
            return true
        }
    }

    /// Hang-type failures open the breaker after `hangBreakerThreshold`.
    static func isHang(_ error: Error) -> Bool {
        guard let coreErr = error as? CoreModelError else { return false }
        switch coreErr {
        case .timedOut, .unresponsive: return true
        default: return false
        }
    }

    /// Account a primary (or solo) failure. Opens the breaker when a
    /// threshold is reached or when this was the half-open probe.
    private func recordPrimaryFailure(_ error: Error) {
        guard Self.countsTowardBreaker(error) else { return }
        if Self.isHang(error) {
            consecutiveHangs += 1
        } else {
            consecutiveFailures += 1
        }
        let thresholdReached =
            consecutiveHangs >= Self.hangBreakerThreshold
            || consecutiveFailures >= Self.circuitBreakerThreshold
        guard halfOpenProbe || thresholdReached else { return }

        // Exponential cooldown: each consecutive open without an
        // intervening success doubles the wait, capped at 30 min.
        // The shift saturates at cycle 5 anyway (60s × 32 = 1920s
        // already past the 1800s ceiling), so clamping there
        // keeps the multiplier well within `Int` range and the
        // arithmetic readable. Bit-shift over `pow(2, …)` so the
        // type stays `Int`.
        let cycles = min(consecutiveBreakerCycles, 5)
        let multiplier = TimeInterval(1 << cycles)
        let cooldown = min(
            Self.circuitBreakerCooldownSeconds * multiplier,
            Self.circuitBreakerMaxCooldownSeconds
        )
        circuitOpenUntil = Date().addingTimeInterval(cooldown)
        lastBreakerError = error
        consecutiveBreakerCycles += 1
        halfOpenProbe = false
        logger.error(
            "Circuit breaker opened (failures \(self.consecutiveFailures), hangs \(self.consecutiveHangs), cycle \(self.consecutiveBreakerCycles), cooldown \(Int(cooldown))s); last error: \(error.localizedDescription)"
        )
    }

    // MARK: - Private — execution

    /// Returns the model's response on success. Throws the final error after
    /// the role's attempt budget is exhausted; breaker accounting for
    /// failures is the caller's job (`recordPrimaryFailure`).
    private func runWithRetries(
        model: String,
        messages: [ChatMessage],
        params: GenerationParameters,
        timeout: TimeInterval,
        intent: CoreModelIntent,
        role: ModelRole
    ) async throws -> String {
        // With a healthy fallback waiting, a second or third attempt on a
        // failing primary only delays the answer the user is waiting on.
        let attempts = role == .primaryWithFallback ? 1 : Self.maxRetries
        let applyFirstTokenDeadline = role == .primaryWithFallback
        var lastError: Error?
        for attempt in 0 ..< attempts {
            do {
                let result = try await withTimeout(seconds: timeout) {
                    try await self.executeModelCall(
                        model: model, messages: messages, params: params, intent: intent,
                        applyFirstTokenDeadline: applyFirstTokenDeadline)
                }
                if role != .fallback { clearBreakerState() }
                return result
            } catch {
                lastError = error
                // Cancellation is cooperative — retrying a torn-down call
                // just burns inference. Propagate instead of retrying.
                if error is CancellationError || Task.isCancelled { throw error }
                if !Self.isRetryable(error) || attempt == attempts - 1 { break }
                let delay = Self.baseRetryDelayNanoseconds * UInt64(1 << attempt)
                logger.warning(
                    "Core model call failed (attempt \(attempt + 1)/\(attempts)), retrying: \(error.localizedDescription)"
                )
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError ?? CoreModelError.modelUnavailable(model)
    }

    /// Whether an error from `executeModelCall` should trigger a
    /// retry within the same `generate` call. The contract:
    /// unknown failures (network blips, decode errors, service-specific
    /// transient errors) are retryable; typed Foundation failures are
    /// retryable only when the framework says the condition is momentary
    /// (`rateLimited`, `concurrentRequests`) — assets, locale, guardrail,
    /// and context-window failures won't change shape across consecutive
    /// sub-second attempts; the only `CoreModelError` worth retrying is
    /// `.timedOut`, since `.modelUnavailable`, `.unresponsive`, and
    /// `.circuitBreakerOpen` won't either. Cancellation is never retryable.
    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        // A second Claude Code subprocess would spend the same subscription
        // quota (or repeat the same auth/install failure). The CLI already owns
        // its transport retries, so never replay a failed turn here.
        if error is ClaudeCodeError { return false }
        if let fm = error as? FoundationModelServiceError { return fm.isTransient }
        guard let coreErr = error as? CoreModelError else { return true }
        return coreErr == .timedOut
    }

    private func buildMessages(prompt: String, systemPrompt: String?) -> [ChatMessage] {
        if let systemPrompt {
            return [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: prompt),
            ]
        }
        return [ChatMessage(role: "user", content: prompt)]
    }

    private func executeModelCall(
        model: String,
        messages: [ChatMessage],
        params: GenerationParameters,
        intent: CoreModelIntent,
        applyFirstTokenDeadline: Bool
    ) async throws -> String {
        let remoteServices: [ModelService] = await MainActor.run {
            RemoteProviderManager.shared.connectedServices()
        }

        let route = ModelServiceRouter.resolve(
            requestedModel: model,
            services: localServices,
            remoteServices: remoteServices
        )

        switch route {
        case .service(let service, let effectiveModel):
            let promptLen = messages.last?.content?.count ?? 0
            logger.debug(
                "Routing to \(service.id) (model: \(effectiveModel), prompt: \(promptLen) chars)"
            )
            do {
                if applyFirstTokenDeadline, let deadline = service.firstTokenDeadline {
                    let stream = try await service.streamDeltas(
                        messages: messages,
                        parameters: params,
                        requestedModel: model,
                        stopSequences: []
                    )
                    return try await Self.collect(
                        stream, firstTokenDeadline: deadline, model: effectiveModel)
                }
                return try await service.generateOneShot(
                    messages: messages,
                    parameters: params,
                    requestedModel: model
                )
            } catch let refusal as ModelRuntime.ResidencyRefusedError {
                // `params.loadIntent == .background` and the load would have
                // disturbed the user's model. Not a backend fault — surface it as
                // the existing skip error so the breaker stays out of it.
                logger.info("\(refusal.errorDescription ?? "background load refused")")
                throw CoreModelError.backgroundWouldEvictUserModel(effectiveModel)
            }
        case .none:
            throw CoreModelError.modelUnavailable(model)
        }
    }

    /// Drain a delta stream into a single string, giving up with
    /// `.unresponsive` when no first token arrives within `firstTokenDeadline`.
    /// Once the first token is in, generation may take as long as the
    /// caller's overall `timeout` allows — a slow-but-progressing answer is
    /// never cut off here. On the deadline the consumer task is cancelled,
    /// which terminates the stream and (via the service's `onTermination`)
    /// the producer behind it.
    static func collect(
        _ stream: AsyncThrowingStream<String, Error>,
        firstTokenDeadline: TimeInterval,
        model: String
    ) async throws -> String {
        let (firstToken, signal) = AsyncStream<Void>.makeStream()
        let consumer = Task<String, Error> {
            defer { signal.finish() }
            var text = ""
            var signalled = false
            for try await delta in stream {
                text += delta
                if !signalled, !delta.isEmpty {
                    signalled = true
                    signal.yield(())
                }
            }
            return text
        }

        do {
            // Resolves on the first non-empty delta, or when the stream ends /
            // fails before producing one (the consumer then reports why).
            try await valueWithDeadline(seconds: firstTokenDeadline, operationName: "first token") {
                var iterator = firstToken.makeAsyncIterator()
                _ = await iterator.next()
            }
        } catch is DeadlineExceededError {
            consumer.cancel()
            logger.warning(
                "Core model '\(model)' produced no output within \(Int(firstTokenDeadline))s; abandoning")
            throw CoreModelError.unresponsive(model)
        } catch is CancellationError {
            consumer.cancel()
            throw CancellationError()
        }

        // The overall `timeout` racer cancels this task when it fires; pass
        // that on so the producer stops generating for a caller that is gone.
        return try await withTaskCancellationHandler {
            try await consumer.value
        } onCancel: {
            consumer.cancel()
        }
    }

    /// Non-rejoining timeout: native model work that ignores cancellation is
    /// abandoned at the deadline instead of blocking the caller (a task-group
    /// race would re-join the stuck child at scope exit).
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await valueWithDeadline(
                seconds: seconds, operationName: "core model request", operation: operation)
        } catch is DeadlineExceededError {
            throw CoreModelError.timedOut
        }
    }
}
