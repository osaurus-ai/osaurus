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
    ///   - priority: Scheduler priority. Defaults to `.maintenance` because
    ///     this service is used by preflight/memory-extraction/summarization
    ///     work that must never starve a user's foreground typing.
    /// - Returns: The model's text response.
    public func generate(
        prompt: String,
        systemPrompt: String? = nil,
        temperature: Double = 0.3,
        maxTokens: Int = 2048,
        timeout: TimeInterval = 60,
        priority: InferencePriority = .maintenance
    ) async throws -> String {
        if let openUntil = circuitOpenUntil, Date() < openUntil {
            throw CoreModelError.circuitBreakerOpen
        }

        let resolvedModel: String? = await MainActor.run {
            ChatConfigurationStore.load().coreModelIdentifier
        }
        guard let model = resolvedModel else {
            throw CoreModelError.modelUnavailable("none")
        }

        let messages: [ChatMessage] =
            if let systemPrompt {
                [ChatMessage(role: "system", content: systemPrompt), ChatMessage(role: "user", content: prompt)]
            } else {
                [ChatMessage(role: "user", content: prompt)]
            }
        let params = GenerationParameters(
            temperature: Float(temperature),
            maxTokens: maxTokens,
            priority: priority
        )

        var lastError: Error?
        for attempt in 0 ..< Self.maxRetries {
            do {
                let result = try await withTimeout(seconds: timeout) {
                    try await self.executeModelCall(model: model, messages: messages, params: params)
                }
                consecutiveFailures = 0
                circuitOpenUntil = nil
                return result
            } catch {
                lastError = error
                let isRetryable = !(error is CoreModelError) || error as? CoreModelError == .timedOut
                if !isRetryable || attempt == Self.maxRetries - 1 { break }
                let delay = Self.baseRetryDelayNanoseconds * UInt64(1 << attempt)
                logger.warning(
                    "Core model call failed (attempt \(attempt + 1)/\(Self.maxRetries)), retrying: \(error)"
                )
                try? await Task.sleep(nanoseconds: delay)
            }
        }

        consecutiveFailures += 1
        if consecutiveFailures >= Self.circuitBreakerThreshold {
            circuitOpenUntil = Date().addingTimeInterval(Self.circuitBreakerCooldownSeconds)
            logger.error(
                "Circuit breaker opened after \(self.consecutiveFailures) consecutive failures"
            )
        }

        throw lastError ?? CoreModelError.modelUnavailable(model)
    }

    // MARK: - Private

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
