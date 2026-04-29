//
//  CoreModelService.swift
//  osaurus
//
//  Shared actor for lightweight Core Model inference calls.
//  Routes through ModelServiceRouter with retry, timeout, and circuit breaker.
//  Used by MemoryService, PreflightCapabilitySearch, and other subsystems
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
    private static let circuitBreakerThreshold = 5
    private static let circuitBreakerCooldownSeconds: TimeInterval = 60

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
        try checkBreakerOrEnterHalfOpen()

        let configured = await MainActor.run {
            ChatConfigurationStore.load().coreModelIdentifier
        }
        let fallback = Self.normaliseFallback(fallbackModel)
        let messages = buildMessages(prompt: prompt, systemPrompt: systemPrompt)
        let params = GenerationParameters(temperature: Float(temperature), maxTokens: maxTokens)

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
            // Only fall back when the configured model is fundamentally
            // unusable on this machine. `.timedOut` and `.circuitBreakerOpen`
            // are transient — retrying with a different model would mask
            // the real issue.
            guard case .modelUnavailable = coreErr,
                let fb = fallback,
                fb != primary
            else { throw coreErr }
            logger.info("Core model '\(primary)' unavailable; falling back to chat model '\(fb)'")
            return try await runWithRetries(model: fb, messages: messages, params: params, timeout: timeout)
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

    // MARK: - Private — breaker bookkeeping

    /// Throws `circuitBreakerOpen` while the cooldown is active.
    /// When the cooldown has elapsed, transitions the breaker to
    /// "half-open" by clearing all counters so the upcoming probe
    /// has a clean slate. Without this the counter would sit at
    /// `circuitBreakerThreshold` forever and a single subsequent
    /// failure would immediately re-open the breaker — making it
    /// permanently sticky.
    private func checkBreakerOrEnterHalfOpen() throws {
        guard let openUntil = circuitOpenUntil else { return }
        if Date() < openUntil {
            throw CoreModelError.circuitBreakerOpen
        }
        clearBreakerState()
        logger.info("Circuit breaker cooldown elapsed — entering half-open probe")
    }

    private func clearBreakerState() {
        consecutiveFailures = 0
        circuitOpenUntil = nil
        lastBreakerError = nil
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
        if let coreErr = error as? CoreModelError, case .modelUnavailable = coreErr {
            throw coreErr
        }

        consecutiveFailures += 1
        if consecutiveFailures >= Self.circuitBreakerThreshold {
            circuitOpenUntil = Date().addingTimeInterval(Self.circuitBreakerCooldownSeconds)
            lastBreakerError = error
            logger.error(
                "Circuit breaker opened after \(self.consecutiveFailures) consecutive failures; last error: \(error.localizedDescription)"
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
    /// shape across consecutive sub-second attempts.
    private static func isRetryable(_ error: Error) -> Bool {
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
