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

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let model):
            return "Core model '\(model)' is not available"
        case .circuitBreakerOpen:
            return "Core model temporarily unavailable (too many recent failures)"
        case .timedOut:
            return "Core model call timed out"
        }
    }
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
    /// Most common reason: Foundation Model on a pre-macOS-26 system,
    /// or a remote provider that was disconnected.
    case unavailable(modelId: String, reason: String)
    /// Breaker is currently open after consecutive failures; the next
    /// call will probe the model anyway, but distillation will see
    /// `circuitBreakerOpen` until the cooldown elapses.
    case breakerOpen(modelId: String?, until: Date)
}

public actor CoreModelService {
    public static let shared = CoreModelService()

    private let localServices: [ModelService] = [FoundationModelService(), MLXService.shared]

    private static let maxRetries = 3
    private static let baseRetryDelayNanoseconds: UInt64 = 1_000_000_000

    private var consecutiveFailures = 0
    private var circuitOpenUntil: Date?
    /// Last error that contributed to the breaker opening. Surfaced
    /// in log messages so callers (and humans reading the log) can
    /// see the root cause instead of just "circuitBreakerOpen".
    private var lastBreakerError: Error?
    /// Number of times the breaker has re-opened without an
    /// intervening successful call. Drives exponential cooldown so a
    /// genuinely-broken backend (Foundation framework lock contention,
    /// crashed remote provider) doesn't get hammered every minute
    /// forever. Reset to zero on any successful generation.
    private var consecutiveBreakerCycles = 0
    private static let circuitBreakerThreshold = 5
    /// Base cooldown after the breaker first opens. Doubles each cycle
    /// the breaker re-opens without a success in between (60s, 120s,
    /// 240s, …) up to `circuitBreakerMaxCooldownSeconds`. The cap
    /// matches the greeting pool's TTL so a wedged backend can't keep
    /// the user locked out longer than a single fresh-greeting cycle.
    private static let circuitBreakerCooldownSeconds: TimeInterval = 60
    private static let circuitBreakerMaxCooldownSeconds: TimeInterval = 30 * 60

    private init() {}

    /// One-shot generation using the core model configured in ChatConfiguration.
    /// - Parameters:
    ///   - prompt: The user prompt.
    ///   - systemPrompt: Optional system prompt.
    ///   - temperature: Sampling temperature (default 0.3).
    ///   - maxTokens: Maximum response tokens (default 2048).
    ///   - timeout: Maximum wall-clock seconds for the call (default 60).
    ///   - fallbackModel: Model identifier to fall back to when the configured
    ///     core model is unset or `modelUnavailable` on this machine. Callers
    ///     should pass the active conversation model so preflight and other
    ///     background calls work out of the box without an explicit Core Model
    ///     setting (root cause of GitHub issue #823 — macOS < 26 ships with
    ///     `coreModelName = "foundation"` persisted but the router can't
    ///     satisfy it). Transient failures (timeouts, breaker open) do NOT
    ///     trigger the fallback.
    /// - Returns: The model's text response.
    public func generate(
        prompt: String,
        systemPrompt: String? = nil,
        temperature: Double = 0.3,
        maxTokens: Int = 2048,
        timeout: TimeInterval = 60,
        fallbackModel: String? = nil
    ) async throws -> String {
        try await generate(
            prompt: prompt,
            systemPrompt: systemPrompt,
            temperature: temperature,
            maxTokens: maxTokens,
            timeout: timeout,
            fallbackModel: fallbackModel,
            modelOptions: [:]
        )
    }

    func generate(
        prompt: String,
        systemPrompt: String? = nil,
        temperature: Double = 0.3,
        maxTokens: Int = 2048,
        timeout: TimeInterval = 60,
        fallbackModel: String? = nil,
        modelOptions: [String: ModelOptionValue]
    ) async throws -> String {
        try checkBreakerOrEnterHalfOpen()

        let configured = await MainActor.run {
            ChatConfigurationStore.load().coreModelIdentifier
        }
        let fallback = Self.normaliseFallback(fallbackModel)
        let messages = buildMessages(prompt: prompt, systemPrompt: systemPrompt)
        let params = GenerationParameters(
            temperature: Float(temperature),
            maxTokens: maxTokens,
            modelOptions: modelOptions
        )

        do {
            return try await runWithChatModelFallback(
                primary: configured,
                fallback: fallback,
                messages: messages,
                params: params,
                timeout: timeout
            )
        } catch {
            try recordFailureAndThrow(error)
        }
    }

    /// Single-attempt run with at most one chat-model fallback. Split out so
    /// `generate(...)` reads as a flat "run + bookkeeping" pair instead of
    /// nested do-catch arms.
    private func runWithChatModelFallback(
        primary: String?,
        fallback: String?,
        messages: [ChatMessage],
        params: GenerationParameters,
        timeout: TimeInterval
    ) async throws -> String {
        guard let primary else {
            guard let fb = fallback else { throw CoreModelError.modelUnavailable("none") }
            logger.info("Core model unset; using chat model '\(fb)' as fallback")
            return try await runWithRetries(model: fb, messages: messages, params: params, timeout: timeout)
        }

        do {
            return try await runWithRetries(model: primary, messages: messages, params: params, timeout: timeout)
        } catch let coreErr as CoreModelError {
            // Configuration-level failure: the primary's identifier
            // can't be routed at all (Foundation Model on pre-26 macOS,
            // a deleted MLX model, a disconnected remote provider).
            // `.timedOut` and `.circuitBreakerOpen` are deliberately
            // NOT in this branch — they're transient and retrying with
            // a different model would just mask the real issue.
            guard case .modelUnavailable = coreErr,
                let fb = fallback,
                fb != primary
            else { throw coreErr }
            logger.info("Core model '\(primary)' unavailable; falling back to chat model '\(fb)'")
            return try await runWithRetries(model: fb, messages: messages, params: params, timeout: timeout)
        } catch is CancellationError {
            // Caller walked away mid-flight — don't spend the fallback
            // model on a generation no one is waiting for.
            throw CancellationError()
        } catch {
            // Runtime failure that isn't a CoreModelError. The primary
            // backend is wedged below the routing layer — Foundation
            // framework lock contention (the OS-level "Too many open
            // files" / `failedToRetrieveAssetSet` cycle), MLX runtime
            // crashes, or a remote provider returning malformed JSON.
            // `runWithRetries` already gave the primary three chances;
            // try the chat-model fallback once before bubbling so
            // best-effort callers (greetings, preflight) still get
            // useful output. If the fallback isn't viable (missing or
            // identical to primary), preserve the original error.
            guard let fb = fallback, fb != primary else { throw error }
            logger.warning(
                "Core model '\(primary)' exhausted retries (\(error.localizedDescription)); falling back to chat model '\(fb)'"
            )
            return try await runWithRetries(
                model: fb,
                messages: messages,
                params: params,
                timeout: timeout
            )
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

    /// Probe whether the configured core model can be resolved by the
    /// router right now. Does NOT make an LLM call — only iterates the
    /// candidate services' `isAvailable()` / `handles(...)` functions,
    /// which are cheap and side-effect-free.
    ///
    /// Used by the Memory diagnostics panel to surface "Foundation
    /// Model unavailable on this OS" / "remote provider disconnected"
    /// instead of letting those failures live as `.info` log messages
    /// the user never sees.
    public func resolveStatus() async -> CoreModelStatus {
        if let openUntil = circuitOpenUntil, Date() < openUntil {
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
    /// satisfy `modelId`. Pure heuristics — no I/O.
    private static func unavailableReason(modelId: String) -> String {
        let lowered = modelId.lowercased()
        if lowered == "foundation" || lowered.hasSuffix("/foundation") {
            return "Foundation Model not available on this OS (requires macOS 26+)."
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

    /// Throws `circuitBreakerOpen` while the cooldown is active.
    /// When the cooldown has elapsed, transitions the breaker to a
    /// "half-open" probe state: the failure counter, cooldown
    /// window, and last-error are cleared so the next call runs,
    /// but `consecutiveBreakerCycles` is PRESERVED so a failed probe
    /// escalates to the next cooldown bucket (60s → 120s → 240s …)
    /// instead of restarting at 60s — without that, a wedged backend
    /// would stay pinned in fast-retry mode forever.
    private func checkBreakerOrEnterHalfOpen() throws {
        guard let openUntil = circuitOpenUntil else { return }
        if Date() < openUntil {
            throw CoreModelError.circuitBreakerOpen
        }
        consecutiveFailures = 0
        circuitOpenUntil = nil
        lastBreakerError = nil
        logger.info("Circuit breaker cooldown elapsed — entering half-open probe")
    }

    private func clearBreakerState() {
        consecutiveFailures = 0
        circuitOpenUntil = nil
        lastBreakerError = nil
        // A success between cycles resets the exponential cooldown so
        // the next genuine outage starts at the fast 60s cadence
        // again rather than inheriting yesterday's backoff.
        consecutiveBreakerCycles = 0
    }

    /// Returns the model's response on success (and clears breaker
    /// state). Throws the final error after all retries are
    /// exhausted; the caller is responsible for the failure-
    /// accounting path via `recordFailureAndThrow`.
    private func runWithRetries(
        model: String,
        messages: [ChatMessage],
        params: GenerationParameters,
        timeout: TimeInterval
    ) async throws -> String {
        var lastError: Error?
        for attempt in 0 ..< Self.maxRetries {
            do {
                let result = try await withTimeout(seconds: timeout) {
                    try await self.executeModelCall(model: model, messages: messages, params: params)
                }
                clearBreakerState()
                return result
            } catch {
                lastError = error
                // Cancellation is cooperative — retrying a torn-down call
                // just burns inference. Propagate instead of retrying.
                if error is CancellationError || Task.isCancelled { throw error }
                if !Self.isRetryable(error) || attempt == Self.maxRetries - 1 { break }
                let delay = Self.baseRetryDelayNanoseconds * UInt64(1 << attempt)
                logger.warning(
                    "Core model call failed (attempt \(attempt + 1)/\(Self.maxRetries)), retrying: \(error.localizedDescription)"
                )
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError ?? CoreModelError.modelUnavailable(model)
    }

    /// Bookkeeping for a final failure: throws-through configuration
    /// errors (`modelUnavailable`) without touching the breaker, and
    /// otherwise increments the failure counter and opens the breaker
    /// once the threshold is reached. Always throws.
    ///
    /// `modelUnavailable` is a **configuration** error, not a flaky
    /// backend — the user's `coreModelIdentifier` points at something
    /// the router can't service (Foundation Model on pre-26 macOS, a
    /// remote provider that was uninstalled, an MLX model that was
    /// deleted). Counting it toward the breaker would lock the user
    /// out of the preflight path permanently with a misleading
    /// "circuitBreakerOpen" symptom that hides the real fix.
    private func recordFailureAndThrow(_ error: Error) throws -> Never {
        // Cancellation isn't a backend fault — don't let it trip the
        // breaker and lock out real calls.
        if error is CancellationError {
            throw error
        }
        if let coreErr = error as? CoreModelError, case .modelUnavailable = coreErr {
            throw coreErr
        }

        consecutiveFailures += 1
        if consecutiveFailures >= Self.circuitBreakerThreshold {
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
            logger.error(
                "Circuit breaker opened after \(self.consecutiveFailures) consecutive failures (cycle \(self.consecutiveBreakerCycles), cooldown \(Int(cooldown))s); last error: \(error.localizedDescription)"
            )
        }

        throw error
    }

    /// Whether an error from `executeModelCall` should trigger a
    /// retry within the same `generate` call. The contract:
    /// non-`CoreModelError` failures (network blips, decode errors,
    /// service-specific transient errors) are retryable; the only
    /// `CoreModelError` worth retrying is `.timedOut`, since
    /// `.modelUnavailable` and `.circuitBreakerOpen` won't change
    /// shape across consecutive sub-second attempts. Cancellation is
    /// never retryable.
    private static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
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

    // MARK: - Private — execution

    private func executeModelCall(
        model: String,
        messages: [ChatMessage],
        params: GenerationParameters
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
            return try await service.generateOneShot(
                messages: messages,
                parameters: params,
                requestedModel: model
            )
        case .none:
            throw CoreModelError.modelUnavailable(model)
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CoreModelError.timedOut
            }
            guard let result = try await group.next() else {
                throw CoreModelError.timedOut
            }
            group.cancelAll()
            return result
        }
    }
}
