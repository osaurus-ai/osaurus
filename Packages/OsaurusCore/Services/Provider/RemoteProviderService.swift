//
//  RemoteProviderService.swift
//  osaurus
//
//  Service for proxying requests to remote OpenAI-compatible API providers.
//

import Foundation
import os

/// Logger for the reasoning round-trip. Emitted at `.debug`, so it's quiet by
/// default; stream it with
/// `log stream --debug --predicate 'subsystem == "ai.osaurus" AND category == "reasoning"'`.
private let reasoningLogger = Logger(subsystem: "ai.osaurus", category: "reasoning")
private let wirePairingLogger = Logger(subsystem: "ai.osaurus", category: "wire-pairing")

/// Errors specific to remote provider operations
public enum RemoteProviderServiceError: LocalizedError {
    case invalidURL
    case notConnected
    case requestFailed(String)
    case requestFailedWithDiagnostics(String, ProviderReplayDiagnosticBundle)
    case invalidResponse
    case streamingError(String)
    case noModelsAvailable

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L("Invalid provider URL configuration")
        case .notConnected:
            return L("Provider is not connected")
        case .requestFailed(let message):
            return L("Request failed: \(ProviderDiagnosticRedactor.safe(message, maxLength: 500))")
        case .requestFailedWithDiagnostics(let message, let diagnostics):
            return L(
                "Request failed: \(ProviderDiagnosticRedactor.safe(message, maxLength: 500)). Redacted request evidence: \(diagnostics.summary)"
            )
        case .invalidResponse:
            return L("Invalid response from provider")
        case .streamingError(let message):
            return L("Streaming error: \(message)")
        case .noModelsAvailable:
            return L("No models available from provider")
        }
    }

    var isTransientStreamRetryable: Bool {
        guard case .streamingError(let message) = self else { return false }
        return message.contains("mid-argument")
            || message.contains("arguments were complete")
    }

    public var replayDiagnostics: ProviderReplayDiagnosticBundle? {
        guard case .requestFailedWithDiagnostics(_, let diagnostics) = self else { return nil }
        return diagnostics
    }

    func attachingReplayDiagnostics(_ diagnostics: ProviderReplayDiagnosticBundle) -> RemoteProviderServiceError {
        switch self {
        case .requestFailed(let message):
            return .requestFailedWithDiagnostics(
                ProviderDiagnosticRedactor.safe(message, maxLength: 500),
                diagnostics
            )
        case .invalidResponse:
            return .requestFailedWithDiagnostics("Invalid response from provider", diagnostics)
        case .requestFailedWithDiagnostics:
            return self
        case .invalidURL, .notConnected, .streamingError, .noModelsAvailable:
            return self
        }
    }
}

/// Service that proxies requests to a remote OpenAI-compatible API provider
public actor RemoteProviderService: ToolCapableService {

    public let provider: RemoteProvider
    private let cachedHeaders: [String: String]
    private let providerPrefix: String
    private var availableModels: [String]
    private var session: URLSession
    private var cachedOAuthTokens: RemoteProviderOAuthTokens?

    /// Race-resistant flag set by `invalidateSession()`. The connect-retry
    /// loop in `connectWithRetry` MUST consult this before every
    /// `URLSession.bytes(for:)` attempt: calling `bytes(for:)` on a session
    /// that has already had `invalidateAndCancel()` called raises an
    /// uncatchable Obj-C `NSInvalidArgumentException` from
    /// `-[__NSURLSessionLocal taskForClassInfo:]` (synchronously, inside
    /// the Swift-generated closure passed to `withTaskCancellationHandler`).
    /// Swift `try`/`catch` does not catch Obj-C exceptions, so the
    /// exception unwinds straight into `_objc_terminate` and `abort()`s
    /// the entire xctest process — an entire test bundle dies. The flag
    /// is checked across an actor boundary by a non-isolated, lock-backed
    /// accessor so the producer task can read it without an `await` hop
    /// (no actor reentrancy, no extra suspension point per retry attempt).
    /// Closing the residual microsecond TOCTOU window between this check
    /// and `bytes(for:)` requires an Obj-C `@try`/`@catch` bridge — left
    /// out here because it would require restructuring the package as
    /// mixed-source SPM. The flag-based mitigation eliminates the
    /// dominant 200ms / 800ms backoff-window race that surfaces in
    /// parallel CI test runs.
    private let sessionInvalidatedFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    nonisolated public var id: String {
        "remote-\(provider.id.uuidString)"
    }

    /// Lock-backed sync read of the session-invalidated flag. Safe to call
    /// from any thread / actor / Task without awaiting the actor.
    nonisolated public var isSessionInvalidated: Bool {
        sessionInvalidatedFlag.withLock { $0 }
    }

    public init(
        provider: RemoteProvider,
        models: [String],
        resolvedHeaders: [String: String],
        cachedOAuthTokens: RemoteProviderOAuthTokens? = nil
    ) {
        self.provider = provider
        self.cachedHeaders = resolvedHeaders
        self.cachedOAuthTokens = cachedOAuthTokens
        self.availableModels = models
        // Create a unique prefix for model names (lowercase, sanitized)
        self.providerPrefix = provider.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")

        let config = URLSessionConfiguration.default
        // Request timeout must be generous: thinking models can pause for minutes
        // between tokens. The app-level streamInactivityTimeout handles stall detection.
        // When the user opts into no-timeout mode, every limit is lifted (see
        // RemoteProvider.unboundedTimeout) so long-running turns are never interrupted.
        if provider.disableTimeout {
            config.timeoutIntervalForRequest = RemoteProvider.unboundedTimeout
            config.timeoutIntervalForResource = RemoteProvider.unboundedTimeout
        } else {
            config.timeoutIntervalForRequest = max(provider.timeout, 300)
            config.timeoutIntervalForResource = max(provider.timeout * 2, 600)
        }
        self.session = GlobalProxySettings.makeSession(base: config)
    }

    /// Minimum timeout for image generation models (5 minutes).
    private static let imageModelMinTimeout: TimeInterval = 300

    /// Returns `true` when the model name indicates an image-generation-capable model.
    fileprivate static func isImageCapableModel(_ modelName: String) -> Bool {
        Gemini31FlashImageProfile.matches(modelId: modelName) || GeminiProImageProfile.matches(modelId: modelName)
            || GeminiFlashImageProfile.matches(modelId: modelName)
    }

    /// Thin delegates over `RemoteReasoningPolicy`, which is the single source of
    /// truth for remote reasoning behavior. Kept on the service so existing call
    /// sites and pinned tests continue to work unchanged.
    static func allowsChatCompletionsReasoningObject(
        providerType: RemoteProviderType,
        host: String
    ) -> Bool {
        RemoteReasoningPolicy.resolve(providerType: providerType, host: host, model: "")
            .allowsReasoningObject
    }

    static func chatCompletionsReasoningEffort(
        providerType: RemoteProviderType,
        host: String,
        effort: String?
    ) -> String? {
        RemoteReasoningPolicy.acceptedEffort(providerType: providerType, host: host, effort: effort)
    }

    /// Whether the target provider requires `reasoning_content` to be echoed
    /// back on assistant messages in multi-round conversations (DeepSeek). See
    /// `RemoteReasoningPolicy.Outbound` for the full rationale.
    static func echoesReasoningContent(
        providerType: RemoteProviderType,
        host: String,
        model: String
    ) -> Bool {
        RemoteReasoningPolicy.resolve(providerType: providerType, host: host, model: model)
            .outbound == .echoField
    }

    static func dsv4RemoteEffort(
        host: String,
        model: String,
        effort: String?
    ) -> (effort: String?, thinking: ThinkingConfig?) {
        RemoteReasoningPolicy.dsv4Effort(host: host, model: model, effort: effort)
    }

    static func remoteChatReasoningControls(
        providerType: RemoteProviderType,
        host: String,
        model: String,
        effort: String?
    ) -> (effort: String?, thinking: ThinkingConfig?) {
        RemoteReasoningPolicy.resolve(providerType: providerType, host: host, model: model)
            .controls(effort: effort)
    }

    static func effectiveRequestProviderType(
        configuredProviderType: RemoteProviderType,
        request: RemoteChatRequest
    ) -> RemoteProviderType {
        guard configuredProviderType == .azureOpenAI else {
            return configuredProviderType
        }

        if request.reasoning_effort != nil || request.tools?.isEmpty == false {
            return .openResponses
        }

        return configuredProviderType
    }

    /// Inactivity timeout for streaming: if no bytes arrive within this interval,
    /// assume the provider has stalled and end the stream. Floor of 120s accommodates
    /// thinking models that pause between tokens during reasoning.
    private var streamInactivityTimeout: TimeInterval {
        provider.disableTimeout ? RemoteProvider.unboundedTimeout : max(provider.timeout, 120)
    }

    /// Invalidate the URLSession to release its strong delegate reference.
    /// Must be called before discarding this service instance to avoid leaking.
    ///
    /// Sets `sessionInvalidatedFlag` BEFORE `invalidateAndCancel()` so any
    /// concurrent connect-retry loop in `connectWithRetry` observes the
    /// flag on its next pre-attempt check and bails out with a Swift
    /// `CancellationError` instead of calling `bytes(for:)` on the now-
    /// invalidated session and triggering the uncatchable Obj-C
    /// `NSException` abort. See the doc comment on
    /// `sessionInvalidatedFlag` for the full hazard description.
    public func invalidateSession() {
        sessionInvalidatedFlag.withLock { $0 = true }
        session.invalidateAndCancel()
    }

    /// Update available models (called when connection refreshes)
    public func updateModels(_ models: [String]) {
        self.availableModels = models
    }

    /// Get the prefixed model names for this provider
    public func getPrefixedModels() -> [String] {
        availableModels.map { "\(providerPrefix)/\($0)" }
    }

    /// Get the raw model names without prefix
    public func getRawModels() -> [String] {
        availableModels
    }

    // MARK: - ModelService Protocol

    nonisolated public func isAvailable() -> Bool {
        return provider.enabled
    }

    nonisolated public func handles(requestedModel: String?) -> Bool {
        guard let model = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !model.isEmpty
        else {
            return false
        }

        // Check if model starts with our provider prefix
        let prefix = provider.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")

        return model.lowercased().hasPrefix(prefix + "/")
    }

    /// Extract the actual model name without provider prefix
    private func extractModelName(_ requestedModel: String?) -> String? {
        guard let model = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !model.isEmpty
        else {
            return nil
        }

        // Remove provider prefix if present
        if model.lowercased().hasPrefix(providerPrefix + "/") {
            let startIndex = model.index(model.startIndex, offsetBy: providerPrefix.count + 1)
            return String(model[startIndex...])
        }

        return model
    }

    /// Privacy Filter preflight shared by every cloud-bound entrypoint
    /// (`generateOneShot`, `streamDeltas`, `respondWithTools`,
    /// `streamWithTools`). Wraps the pipeline call so the four call
    /// sites stay one-liners and the cancel translation lives in one
    /// place. Returns the (possibly scrubbed) messages plus the
    /// redaction map needed for inbound unscrubbing — `nil` when the
    /// filter is disabled, the engine is unloaded, or the provider
    /// override is off (all handled in `applyOutbound`).
    ///
    /// `PrivacyFilterPipelineError.reviewCanceled` is rethrown as
    /// `CancellationError` so the chat layer can apply uniform
    /// cancel UX (remove turns, restore draft) without caring whether
    /// the cancel came from the review sheet or from `Task.cancel()`.
    private func applyPrivacyOutbound(
        messages: [ChatMessage],
        parameters: GenerationParameters
    ) async throws -> (messages: [ChatMessage], map: RedactionMap?) {
        do {
            return try await PrivacyFilterPipeline.applyOutbound(
                messages: messages,
                sessionId: parameters.sessionId,
                providerId: provider.id
            )
        } catch PrivacyFilterPipelineError.reviewCanceled {
            throw CancellationError()
        }
    }

    /// Drain a delta stream into a single visible-text string, dropping the
    /// `\u{FFFE}` hint sentinels (billing/reasoning/tool/prefill/stats) that the
    /// streaming path interleaves with model text. The one-shot entrypoint uses
    /// this for the streaming-only Osaurus agent + router providers so sentinels
    /// never leak into the returned text (e.g. the distill JSON). A single
    /// `StreamingToolHint.isSentinel` check covers every variant — they share
    /// the sentinel prefix.
    static func collectVisibleText(
        from stream: AsyncThrowingStream<String, Error>
    ) async throws -> String {
        var result = ""
        for try await chunk in stream {
            if StreamingToolHint.isSentinel(chunk) { continue }
            result += chunk
        }
        return result
    }

    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String {
        // The native Osaurus agent (/agents/{id}/run) and the streaming-first
        // Osaurus Router both reject the non-streaming path below: a
        // `stream:false` request returns a body that isn't a decodable
        // chat-completion, so it throws a DecodingError — the root cause of
        // distillation failing against `osaurus/*` core models. Stream instead
        // and keep only the visible text.
        if provider.providerType == .osaurus || provider.providerType == .osaurusRouter {
            let stream = try await streamDeltas(
                messages: messages,
                parameters: parameters,
                requestedModel: requestedModel,
                stopSequences: []
            )
            return try await Self.collectVisibleText(from: stream)
        }

        guard let modelName = extractModelName(requestedModel) else {
            throw RemoteProviderServiceError.noModelsAvailable
        }

        // Privacy Filter preflight — see `applyPrivacyOutbound` for
        // the no-op / cancel semantics. Map is nil when filtering
        // didn't run; downstream paths short-circuit cheaply on nil.
        let (scrubbedMessages, redactionMap) = try await applyPrivacyOutbound(
            messages: messages,
            parameters: parameters
        )

        let request = buildChatRequest(
            messages: scrubbedMessages,
            parameters: parameters,
            model: modelName,
            stream: false,
            tools: nil,
            toolChoice: nil
        )

        try await refreshCodexOAuthIfNeeded()
        try await refreshXAIOAuthIfNeeded()
        let (data, response) = try await session.data(for: try await buildURLRequest(for: request))
        WireTransportProbe.current?.replaceResponseBody(data)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteProviderServiceError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RemoteProviderServiceError.requestFailed("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        let responseProviderType = Self.effectiveRequestProviderType(
            configuredProviderType: provider.providerType,
            request: request
        )
        let (content, _) = try Self.parseResponse(data, providerType: responseProviderType)
        let (unscrubbedContent, _) = await PrivacyFilterPipeline.unscrubInbound(
            content: content,
            toolCalls: nil,
            map: redactionMap
        )
        return unscrubbedContent ?? ""
    }

    func streamDeltas(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?,
        stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let modelName = extractModelName(requestedModel) else {
            throw RemoteProviderServiceError.noModelsAvailable
        }

        // Privacy Filter preflight — outbound scrub, capture map for
        // the streaming unscrubber wrap below.
        let (scrubbedMessages, redactionMap) = try await applyPrivacyOutbound(
            messages: messages,
            parameters: parameters
        )

        // Gemini image models don't support streamGenerateContent; fall back to generateContent.
        if provider.providerType == .gemini && Self.isImageCapableModel(modelName) {
            let inner = try await geminiImageGenerateContent(
                messages: scrubbedMessages,
                parameters: parameters,
                model: modelName,
                stopSequences: stopSequences,
                tools: nil,
                toolChoice: nil
            )
            return PrivacyFilterPipeline.wrapInboundStream(inner, map: redactionMap)
        }

        let inner = try await _streamRemote(
            modelName: modelName,
            messages: scrubbedMessages,
            parameters: parameters,
            stopSequences: stopSequences,
            tools: nil,
            toolChoice: nil
        )
        return PrivacyFilterPipeline.wrapInboundStream(inner, map: redactionMap)
    }

    // MARK: - ToolCapableService Protocol

    func respondWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> String {
        // Mode 2 — native Osaurus agent run: tools execute server-side and the
        // peer only exposes a streaming endpoint, so route through
        // generateOneShot (consumes the SSE stream). Mode 1 falls through to the
        // standard OpenAI-compatible non-streaming path so local tool calls are
        // surfaced back to the caller.
        if provider.providerType == .osaurus && parameters.runAsRemoteAgent {
            return try await generateOneShot(
                messages: messages,
                parameters: parameters,
                requestedModel: requestedModel
            )
        }

        guard let modelName = extractModelName(requestedModel) else {
            throw RemoteProviderServiceError.noModelsAvailable
        }

        // Privacy Filter preflight (tool-capable one-shot).
        let (scrubbedMessages, redactionMap) = try await applyPrivacyOutbound(
            messages: messages,
            parameters: parameters
        )

        var request = buildChatRequest(
            messages: scrubbedMessages,
            parameters: parameters,
            model: modelName,
            stream: false,
            tools: tools.isEmpty ? nil : tools,
            toolChoice: toolChoice
        )

        if !stopSequences.isEmpty {
            request.stop = stopSequences
        }

        try await refreshCodexOAuthIfNeeded()
        try await refreshXAIOAuthIfNeeded()
        let (data, response) = try await session.data(for: try await buildURLRequest(for: request))
        WireTransportProbe.current?.replaceResponseBody(data)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteProviderServiceError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RemoteProviderServiceError.requestFailed("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        let responseProviderType = Self.effectiveRequestProviderType(
            configuredProviderType: provider.providerType,
            request: request
        )
        let (content, toolCalls) = try Self.parseResponse(data, providerType: responseProviderType)
        let (unscrubbedContent, unscrubbedToolCalls) = await PrivacyFilterPipeline.unscrubInbound(
            content: content,
            toolCalls: toolCalls,
            map: redactionMap
        )

        // Check for tool calls
        if let toolCalls = unscrubbedToolCalls, let firstCall = toolCalls.first {
            throw ServiceToolInvocation(
                toolName: firstCall.function.name,
                jsonArguments: firstCall.function.arguments,
                toolCallId: firstCall.id,
                geminiThoughtSignature: firstCall.geminiThoughtSignature
            )
        }

        return unscrubbedContent ?? ""
    }

    func streamWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        // Mode 2 — native Osaurus agent run. The /agents/{id}/run endpoint
        // handles the full inference+tool loop server-side and streams back
        // only text deltas; no tool invocations are propagated to the client.
        // Mode 1 (no `runAsRemoteAgent`) falls through and treats the `.osaurus`
        // peer as a plain OpenAI-compatible inference backend, keeping tools so
        // the *local* agent loop executes them.
        if provider.providerType == .osaurus && parameters.runAsRemoteAgent {
            RemoteAgentRunLog.client(
                "stream start provider=\(provider.name) type=\(provider.providerType.rawValue) "
                    + "endpoint=\(osaurusEndpointURL(runAsRemoteAgent: true)?.absoluteString ?? "<unresolved>") "
                    + "modelOnWire=omitted msgs=\(messages.count)"
            )
            return try await streamDeltas(
                messages: messages,
                parameters: parameters,
                requestedModel: requestedModel,
                stopSequences: stopSequences
            )
        }

        guard let modelName = extractModelName(requestedModel) else {
            throw RemoteProviderServiceError.noModelsAvailable
        }

        // Privacy Filter preflight (tool-capable streaming).
        let (scrubbedMessages, redactionMap) = try await applyPrivacyOutbound(
            messages: messages,
            parameters: parameters
        )

        // Gemini image models don't support streamGenerateContent; fall back to generateContent.
        if provider.providerType == .gemini && Self.isImageCapableModel(modelName) {
            let inner = try await geminiImageGenerateContent(
                messages: scrubbedMessages,
                parameters: parameters,
                model: modelName,
                stopSequences: stopSequences,
                tools: tools.isEmpty ? nil : tools,
                toolChoice: toolChoice
            )
            return PrivacyFilterPipeline.wrapInboundStream(inner, map: redactionMap)
        }

        let inner = try await _streamRemote(
            modelName: modelName,
            messages: scrubbedMessages,
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools.isEmpty ? nil : tools,
            toolChoice: toolChoice
        )
        return PrivacyFilterPipeline.wrapInboundStream(inner, map: redactionMap)
    }

    // MARK: - Private Helpers

    typealias SSELineParser = OpenAICompatibleStreamFramer.SSELineParser

    @inline(__always)
    static func processSSELine(_ line: Data, into eventData: inout String) {
        OpenAICompatibleStreamFramer.processLine(line, into: &eventData)
    }

    @inline(__always)
    static func processSSELine(_ line: Data, providerType: RemoteProviderType, into eventData: inout String) {
        OpenAICompatibleStreamFramer.processLine(
            line,
            options: openAICompatibleFramingOptions(for: providerType),
            into: &eventData
        )
    }

    private static func openAICompatibleFramingOptions(
        for providerType: RemoteProviderType
    ) -> OpenAICompatibleStreamFramer.Options {
        providerType == .osaurusRouter ? .routerCompatible : .strict
    }

    /// Wraps `URLSession.AsyncBytes` in an `AsyncThrowingStream<Data, Error>`
    /// that batches per-byte arrivals into chunks at line boundaries (or 4 KB).
    /// The producer task pumps the upstream iterator without ever being
    /// cancelled per-byte — only when the consumer terminates the returned
    /// stream — which avoids the iterator-corruption mode where racing
    /// `iterator.next()` against a sleep would leave the underlying URLSession
    /// task in a half-cancelled state and silently truncate the stream.
    /// Idempotent connect-phase retry. Wraps `URLSession.bytes(for:)` so
    /// transient TCP / DNS / TLS failures and 5xx-without-body upstream
    /// hiccups don't surface as fatal errors before the consumer has
    /// seen any bytes. Once the response head arrives (or we've tried
    /// `maxAttempts` times) we hand the result back to the caller and
    /// retry never happens again — by design, mid-stream errors are not
    /// retried because the consumer has already begun seeing tokens.
    ///
    /// Backoff: 200ms, 800ms (exponential, capped). Total wall time at
    /// `maxAttempts = 3` is therefore ≤ ~1s of added latency on success.
    ///
    /// `isCancelled` is consulted after every backoff sleep AND before
    /// each `bytes(for:)` retry. The owning `RemoteProviderService` passes
    /// a closure backed by `isSessionInvalidated`; if `invalidateSession()`
    /// fires while we are sleeping in the retry window, the next
    /// `bytes(for:)` call would raise an uncatchable Obj-C `NSException`
    /// from `-[__NSURLSessionLocal taskForClassInfo:]` and `abort()` the
    /// xctest process. See the long doc comment on
    /// `RemoteProviderService.sessionInvalidatedFlag` for the full
    /// hazard. The default (`{ false }`) preserves the previous behaviour
    /// for any caller that owns its session lifetime explicitly and does
    /// not invalidate concurrently.
    static func connectWithRetry(
        session: URLSession,
        urlRequest: URLRequest,
        maxAttempts: Int = 3,
        isCancelled: @Sendable () -> Bool = { false }
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var lastError: Error?
        for attempt in 0 ..< maxAttempts {
            if attempt > 0 {
                let delayMs: UInt64 = attempt == 1 ? 200_000_000 : 800_000_000
                try? await Task.sleep(nanoseconds: delayMs)
                if Task.isCancelled || isCancelled() {
                    throw lastError ?? CancellationError()
                }
            }
            if Task.isCancelled || isCancelled() {
                throw lastError ?? CancellationError()
            }
            do {
                return try await session.bytes(for: urlRequest)
            } catch {
                if Task.isCancelled || isCancelled() { throw error }
                lastError = error
                // Only retry on classic transient categories. Auth /
                // bad-request type errors are not retried.
                guard Self.isRetryableConnectError(error) else { throw error }
            }
        }
        throw lastError ?? RemoteProviderServiceError.invalidResponse
    }

    /// Heuristic: classify a URLError as a connect-phase transient. We
    /// retry the connection on these and treat everything else as
    /// terminal. Errors on auth / DNS-permanent / cancelled fall through
    /// to the caller untouched.
    private static func isRetryableConnectError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
            .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet,
            .secureConnectionFailed, .serverCertificateUntrusted,
            .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    static func makeChunkStream(
        from bytes: URLSession.AsyncBytes
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream<Data, Error> { continuation in
            let pumpTask = Task {
                var buffer = Data()
                buffer.reserveCapacity(4096)
                do {
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        buffer.append(byte)
                        // Flush at line boundaries (LF) or when the buffer fills,
                        // so consumers see chunks promptly without per-byte awakens.
                        if byte == 0x0A || buffer.count >= 4096 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pumpTask.cancel() }
        }
    }

    /// Mutable holder for an `AsyncThrowingStream<Data, Error>` iterator so it
    /// can be passed into escaping closures (which cannot capture `inout`
    /// parameters directly). Safe because the consumer is single-threaded.
    final class ChunkIteratorRef: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator
        init(_ iterator: AsyncThrowingStream<Data, Error>.AsyncIterator) {
            self.iterator = iterator
        }
        func next() async throws -> Data? { try await iterator.next() }
    }

    /// Thread-safe one-shot holder for the live `URLSessionTask` backing a
    /// streaming response. The stream's `onTermination` (which fires on user
    /// stop, window close, or any consumer teardown — possibly off the producer
    /// thread) cancels the task directly so the socket closes *immediately*,
    /// rather than waiting for the cooperative chunk-stream → pump-task unwind.
    /// Prompt socket close is what trips the peer's channel-close hook, which
    /// cancels the remote agent run (Mode 2) and its generation server-side.
    final class LiveURLSessionTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        func store(_ task: URLSessionTask?) {
            lock.lock()
            defer { lock.unlock() }
            self.task = task
        }
        func cancel() {
            lock.lock()
            let t = task
            task = nil
            lock.unlock()
            t?.cancel()
        }
    }

    /// Reads the next chunk from `ref`, racing against an inactivity timeout.
    /// Returns `nil` if the stream ended naturally or the timeout fired.
    /// Cancelling the local AsyncStream iterator is safe — buffered chunks
    /// remain available for subsequent `next()` calls and the upstream
    /// URLSession iterator (running in `makeChunkStream`'s pump task) is
    /// unaffected.
    static func nextChunk(
        from ref: ChunkIteratorRef,
        timeout: TimeInterval
    ) async throws -> Data? {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await ref.next() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                return nil
            }
            return first
        }
    }

    /// Try to decode `jsonData` as a server-side error payload. Some providers
    /// stream a structured error event rather than closing the connection with
    /// a non-2xx HTTP status — without this check the parse failure was
    /// silently logged and the stream appeared to "end" with no diagnosis.
    static func tryDecodeStreamError(
        _ jsonData: Data,
        providerType: RemoteProviderType
    ) -> String? {
        if providerType == .osaurusRouter,
            let routerError = try? JSONDecoder().decode(OsaurusRouterErrorEnvelope.self, from: jsonData)
        {
            return "\(routerError.error.code): \(routerError.error.message)"
        }

        // Generic OpenAI-compatible error envelope: {"error":{"message":"..."}}
        if let openAIError = try? JSONDecoder().decode(OpenAIError.self, from: jsonData) {
            return openAIError.error.message
        }
        switch providerType {
        case .anthropic:
            // Anthropic mid-stream error: {"type":"error","error":{"type":"...","message":"..."}}
            if let anthropicError = try? JSONDecoder().decode(AnthropicStreamErrorEvent.self, from: jsonData) {
                return anthropicError.error.message
            }
        case .gemini:
            // Gemini error: {"error":{"code":...,"message":"...","status":"..."}}
            if let geminiError = try? JSONDecoder().decode(GeminiErrorResponse.self, from: jsonData) {
                return geminiError.error.message
            }
        default:
            break
        }
        return nil
    }

    private static var routerStreamDebugEnabled: Bool {
        UserDefaults.standard.bool(forKey: "ai.osaurus.router.debugStream")
    }

    private static func routerStreamDebug(
        providerType: RemoteProviderType,
        _ message: @autoclosure () -> String
    ) {
        guard providerType == .osaurusRouter, routerStreamDebugEnabled else { return }
        print("[Osaurus][Router][Stream] \(message())")
    }

    private static func routerStreamFinalDebug(
        providerType: RemoteProviderType,
        marker: String,
        state: StreamingState
    ) {
        routerStreamDebug(
            providerType: providerType,
            "final marker=\(marker) yieldedTextDeltas=\(state.yieldedTextCount) yieldedTextBytes=\(state.yieldedTextBytes) finishReason=\(state.lastFinishReason ?? "nil")"
        )
    }

    private static func logRouterEmptyStreamIfNeeded(_ diagnostics: RouterStreamDiagnostics?) {
        guard let diagnostics, diagnostics.shouldLogEmptyTerminal else { return }
        print("[Osaurus][Router][EmptyStream] \(diagnostics.sanitizedSummary)")
    }

    private static func routerEventDebugSummary(_ dataContent: String) -> String {
        let trimmed = dataContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" { return "done-marker" }
        guard let data = trimmed.data(using: .utf8) else { return "non-utf8 payload" }

        if let summary = try? JSONDecoder().decode(OsaurusRouterSummaryEvent.self, from: data) {
            return
                "summary status=\(summary.osaurus.status) inputTokens=\(summary.osaurus.inputTokens) outputTokens=\(summary.osaurus.outputTokens) costMicro=\(summary.osaurus.costMicro)"
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            return "non-json bytes=\(data.count)"
        }

        if let error = root["error"] as? [String: Any] {
            return "error code=\(error["code"] ?? "nil") messageBytes=\((error["message"] as? String)?.utf8.count ?? 0)"
        }

        if let choices = root["choices"] as? [[String: Any]], let first = choices.first {
            let finish = first["finish_reason"] as? String ?? "nil"
            if let delta = first["delta"] as? [String: Any] {
                return "choice.delta finish=\(finish) \(openAIMessageDebugSummary(delta))"
            }
            if let message = first["message"] as? [String: Any] {
                return "choice.message finish=\(finish) \(openAIMessageDebugSummary(message))"
            }
            return "choice finish=\(finish) keys=\(sortedKeys(first))"
        }

        if let usage = root["usage"] as? [String: Any] {
            return "usage keys=\(sortedKeys(usage))"
        }

        return "object keys=\(sortedKeys(root)) bytes=\(data.count)"
    }

    private static func openAIMessageDebugSummary(_ message: [String: Any]) -> String {
        let contentBytes = (message["content"] as? String)?.utf8.count ?? 0
        let reasoningBytes = (message["reasoning_content"] as? String)?.utf8.count ?? 0
        let toolCallCount = (message["tool_calls"] as? [Any])?.count ?? 0
        return
            "contentBytes=\(contentBytes) reasoningBytes=\(reasoningBytes) toolCalls=\(toolCallCount) keys=\(sortedKeys(message))"
    }

    private static func sortedKeys(_ object: [String: Any]) -> String {
        "[" + object.keys.sorted().joined(separator: ",") + "]"
    }

    private static func streamOutcomeDebugDescription(_ outcome: StreamEventOutcome) -> String {
        switch outcome {
        case .continue:
            return "continue"
        case .finishNormal:
            return "finishNormal"
        case .finishWithToolCall(let invocation):
            return "finishWithToolCall(\(invocation.toolName), argsBytes=\(invocation.jsonArguments.utf8.count))"
        case .finishWithError(let error):
            return "finishWithError(\(error.localizedDescription))"
        }
    }

    struct RouterStreamDiagnostics: Equatable, Sendable {
        let model: String
        let messageCount: Int
        let messageRoles: [String]
        let toolNames: [String]
        let toolChoice: String
        let idempotencyKeySuffix: String?
        let requestBodyBytes: Int
        let routerTransformsApplied: Bool

        var httpStatus: Int?
        var contentType: String?
        var connectAttempt: Int = 0
        var chunkCount: Int = 0
        var byteCount: Int = 0
        var eventCount: Int = 0
        var doneMarkerCount: Int = 0
        var summaryCount: Int = 0
        var usageOnlyCount: Int = 0
        var unrecognizedEventCount: Int = 0
        var visibleTextDeltas: Int = 0
        var visibleTextBytes: Int = 0
        var reasoningDeltas: Int = 0
        var toolHintDeltas: Int = 0
        var billingHintDeltas: Int = 0
        var prefillHintDeltas: Int = 0
        var toolCallFinishes: Int = 0
        var errorFinishes: Int = 0
        var finishMarker: String?
        var pendingEventBytes: Int = 0
        var pendingToolSlots: Int = 0
        var lastEventSummary: String?
        var lastOutcome: String?
        var recentEventSummaries: [String] = []

        init(
            model: String = "osaurus/test",
            messageRoles: [String] = ["user"],
            toolNames: [String] = [],
            toolChoice: String = "auto",
            idempotencyKeySuffix: String? = "test",
            requestBodyBytes: Int = 0,
            routerTransformsApplied: Bool = true
        ) {
            self.model = model
            self.messageCount = messageRoles.count
            self.messageRoles = messageRoles
            self.toolNames = toolNames.sorted()
            self.toolChoice = toolChoice
            self.idempotencyKeySuffix = idempotencyKeySuffix
            self.requestBodyBytes = requestBodyBytes
            self.routerTransformsApplied = routerTransformsApplied
        }

        init(
            request: RemoteChatRequest,
            urlRequest: URLRequest,
            toolNames: [String],
            providerType: RemoteProviderType
        ) {
            self.model = request.model
            self.messageCount = request.messages.count
            self.messageRoles = request.messages.map(\.role)
            self.toolNames = toolNames.sorted()
            self.toolChoice = Self.describeToolChoice(request.tool_choice)
            if let key = request.idempotencyKey, !key.isEmpty {
                self.idempotencyKeySuffix = String(key.suffix(12))
            } else {
                self.idempotencyKeySuffix = nil
            }
            self.requestBodyBytes = urlRequest.httpBody?.count ?? 0
            self.routerTransformsApplied = providerType == .osaurusRouter
        }

        mutating func recordResponse(status: Int, contentType: String?, attempt: Int) {
            httpStatus = status
            self.contentType = contentType
            connectAttempt = attempt
        }

        mutating func recordChunk(_ chunk: Data) {
            chunkCount += 1
            byteCount += chunk.count
        }

        mutating func recordEvent(summary: String) {
            eventCount += 1
            lastEventSummary = summary
            recentEventSummaries.append(summary)
            if recentEventSummaries.count > 5 {
                recentEventSummaries.removeFirst(recentEventSummaries.count - 5)
            }
            if summary == "done-marker" {
                doneMarkerCount += 1
            } else if summary.hasPrefix("summary ") {
                summaryCount += 1
            } else if summary.hasPrefix("usage ") {
                usageOnlyCount += 1
            } else if summary.hasPrefix("non-json") || summary.hasPrefix("object keys=") {
                unrecognizedEventCount += 1
            }
        }

        mutating func recordYield(_ delta: String) {
            if StreamingBillingHint.decode(delta) != nil {
                billingHintDeltas += 1
            } else if StreamingPrefillProgressHint.decode(delta) != nil {
                prefillHintDeltas += 1
            } else if StreamingReasoningHint.decode(delta) != nil {
                reasoningDeltas += 1
            } else if StreamingToolHint.isSentinel(delta) {
                toolHintDeltas += 1
            } else if !delta.isEmpty {
                visibleTextDeltas += 1
                visibleTextBytes += delta.utf8.count
            }
        }

        mutating func recordOutcome(_ outcome: StreamEventOutcome) {
            lastOutcome = RemoteProviderService.streamOutcomeDebugDescription(outcome)
            switch outcome {
            case .finishWithToolCall:
                toolCallFinishes += 1
            case .finishWithError:
                errorFinishes += 1
            case .continue, .finishNormal:
                break
            }
        }

        mutating func recordTerminal(
            marker: String,
            yieldedTextCount: Int,
            yieldedTextBytes: Int,
            pendingToolSlots: Int,
            pendingEventBytes: Int
        ) {
            finishMarker = marker
            self.pendingEventBytes = pendingEventBytes
            self.pendingToolSlots = pendingToolSlots
            visibleTextDeltas = max(visibleTextDeltas, yieldedTextCount)
            visibleTextBytes = max(visibleTextBytes, yieldedTextBytes)
        }

        var modelOutputCount: Int {
            visibleTextDeltas + reasoningDeltas + toolHintDeltas + toolCallFinishes
        }

        var emptyClassification: String {
            if modelOutputCount > 0 { return "non-empty" }
            if chunkCount == 0 && eventCount == 0 { return "raw-empty" }
            if summaryCount > 0 && eventCount == summaryCount + doneMarkerCount { return "summary-only" }
            if usageOnlyCount > 0 && eventCount == usageOnlyCount + doneMarkerCount { return "usage-only" }
            if unrecognizedEventCount > 0 { return "unrecognized-events" }
            return "empty-after-events"
        }

        var shouldLogEmptyTerminal: Bool {
            modelOutputCount == 0 && errorFinishes == 0
        }

        var sanitizedSummary: String {
            [
                "kind=\(emptyClassification)",
                "model=\(model)",
                "messages=\(messageCount)",
                "roles=\(messageRoles.joined(separator: ">"))",
                "tools=\(toolNames.count)[\(toolNames.joined(separator: ","))]",
                "tool_choice=\(toolChoice)",
                "idempotency_suffix=\(idempotencyKeySuffix ?? "nil")",
                "bodyBytes=\(requestBodyBytes)",
                "routerTransforms=\(routerTransformsApplied)",
                "http=\(httpStatus.map(String.init) ?? "nil")",
                "contentType=\(contentType ?? "nil")",
                "attempt=\(connectAttempt)",
                "chunks=\(chunkCount)",
                "bytes=\(byteCount)",
                "events=\(eventCount)",
                "done=\(doneMarkerCount)",
                "summaries=\(summaryCount)",
                "usageOnly=\(usageOnlyCount)",
                "unrecognized=\(unrecognizedEventCount)",
                "visibleDeltas=\(visibleTextDeltas)",
                "visibleBytes=\(visibleTextBytes)",
                "reasoningDeltas=\(reasoningDeltas)",
                "toolHints=\(toolHintDeltas)",
                "billingHints=\(billingHintDeltas)",
                "prefillHints=\(prefillHintDeltas)",
                "toolFinishes=\(toolCallFinishes)",
                "finish=\(finishMarker ?? "nil")",
                "pendingEventBytes=\(pendingEventBytes)",
                "pendingToolSlots=\(pendingToolSlots)",
                "lastOutcome=\(lastOutcome ?? "nil")",
                "lastEvent=\(lastEventSummary ?? "nil")",
                "recentEvents=\(recentEventSummaries.joined(separator: " | "))",
            ].joined(separator: " ")
        }

        private static func describeToolChoice(_ choice: ToolChoiceOption?) -> String {
            guard let choice else { return "nil" }
            switch choice {
            case .auto: return "auto"
            case .none: return "none"
            case .required: return "required"
            case .function(let function): return "function:\(function.function.name)"
            }
        }
    }

    // MARK: - Streaming Pipeline Shared Helpers

    /// Mutable state carried across SSE events for one provider stream.
    /// Bundling the accumulators here keeps the per-provider event handlers'
    /// signatures tractable and lets `_streamRemote` share a single dispatch
    /// loop between `streamDeltas` (no tools) and `streamWithTools` (tools).
    struct StreamingState {
        typealias ToolSlot = (id: String?, name: String?, args: String, thoughtSignature: String?)

        var accumulatedToolCalls: [Int: ToolSlot] = [:]
        var nextFallbackToolCallIndex: Int = 0
        var toolCallIdToIndex: [String: Int] = [:]
        /// Last slot we resolved for a tool-call delta. When a continuation
        /// chunk arrives with no `index` and no `id` (some OpenAI-compatible
        /// providers only send `index` on the first chunk), prefer appending
        /// to this slot rather than allocating a new one — matches the
        /// original `?? 0` behaviour for single-call streams while still
        /// keeping parallel calls (with explicit indices) separate.
        var lastTouchedToolSlot: Int?
        var lastFinishReason: String?

        /// Set once a reasoning item with non-empty `encrypted_content` has
        /// been yielded from the streaming `output_item.done` path, so the
        /// `response.completed` fallback doesn't re-emit the same blob.
        var didCaptureReasoning: Bool = false

        /// Yielded text content. Only used when `trackContent` is `true`
        /// (streamWithTools, for the inline tool-call detection fallback).
        var accumulatedContent: String = ""
        var yieldedTextCount: Int = 0
        var yieldedTextBytes: Int = 0
        var yieldedReasoningCount: Int = 0

        /// Router-only low-volume diagnostics. Nil for all other providers so
        /// the shared parser path stays cheap.
        var routerDiagnostics: RouterStreamDiagnostics?
        /// Stable router request id for local correlation. This is the signed
        /// idempotency key unless the router summary frame provides request_id.
        var routerRequestId: String?

        /// Non-nil only for providers that inline reasoning as `<think>` in the
        /// content rail (MiniMax). When set, content deltas are split so the
        /// think block lands on the reasoning channel instead of leaking.
        var thinkSplitter: InlineThinkSplitter?

        /// Provider-reported token usage from the streaming `usage` chunk
        /// (OpenAI `stream_options.include_usage`). Captured as it streams and
        /// surfaced once at the finish boundary (`dispatchFinal`) as a
        /// `StreamingStatsHint`, so remote runs report real completion-token
        /// counts the same way local vmlx runs do (the chat tok/s display still
        /// comes from the rolling observer, never this). `nil` until a usage
        /// object arrives, so providers that don't send one emit no hint.
        var providerUsage: Usage?

        let stopSequences: [String]
        let trackContent: Bool

        /// Append yielded text to `accumulatedContent` if the caller cares
        /// about the inline-tool-detection fallback.
        @inline(__always)
        mutating func recordYield(_ text: String) {
            guard !text.isEmpty else { return }
            yieldedTextCount += 1
            yieldedTextBytes += text.utf8.count
            if trackContent { accumulatedContent += text }
        }

        /// Record the latest non-nil provider `usage`. OpenAI sends `usage:null`
        /// on every chunk except the dedicated final one, so this no-ops until
        /// the real totals arrive; if a provider sends cumulative usage on each
        /// chunk, the last (complete) value wins. Never emits a hint itself —
        /// that happens once at `dispatchFinal`.
        @inline(__always)
        mutating func captureProviderUsage(_ usage: Usage?) {
            guard let usage else { return }
            providerUsage = usage
        }
    }

    /// Outcome of processing one parsed SSE event.
    enum StreamEventOutcome {
        /// Event was handled (possibly yielded text or tool-call hints) — keep iterating.
        case `continue`
        /// Stream finished normally (provider sent a "done" marker without a tool call).
        case finishNormal
        /// Provider signalled a tool call ready to dispatch.
        case finishWithToolCall(ServiceToolInvocation)
        /// Provider sent a structured error mid-stream.
        case finishWithError(Error)
    }

    /// Resolution of any tool-call accumulated at a final dispatch site.
    enum AccumulatedToolCallResult {
        case none
        case ready(ServiceToolInvocation)
        case truncated(Error)
    }

    /// Inspect any tool-call accumulated by the provider event handler and
    /// classify it for the dispatch site. Used at every "finish" boundary
    /// (`[DONE]`, `STOP`/`MAX_TOKENS`, `message_stop`, `response.completed`,
    /// OpenAI `finish_reason`, and the post-loop drain) so a single call site
    /// honours `wasRepaired` consistently — repaired args mean truncation, not
    /// a successful call to lock into history.
    static func resolveAccumulatedToolCall(
        from accumulated: [Int: StreamingState.ToolSlot],
        finishMarker: String
    ) -> AccumulatedToolCallResult {
        OpenAICompatibleToolCallAccumulator.resolveAccumulatedToolCall(
            from: accumulated,
            finishMarker: finishMarker
        )
    }

    /// Process one fully-framed SSE event payload. Returns `true` when the
    /// outer loop should terminate (event signalled finish, tool call, or
    /// error), `false` to keep iterating. Inlined into `_streamRemote`'s
    /// loop so each provider event yields straight to the consumer without
    /// hopping through an intermediate AsyncStream.
    static func processEventPayload(
        _ dataContent: String,
        state: inout StreamingState,
        providerType: RemoteProviderType,
        tools: [Tool],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) -> Bool {
        let eventSummary = routerEventDebugSummary(dataContent)
        state.routerDiagnostics?.recordEvent(summary: eventSummary)
        routerStreamDebug(providerType: providerType, "event \(eventSummary)")

        if dataContent.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            routerStreamFinalDebug(providerType: providerType, marker: "[DONE]", state: state)
            state.routerDiagnostics?.recordTerminal(
                marker: "[DONE]",
                yieldedTextCount: state.yieldedTextCount,
                yieldedTextBytes: state.yieldedTextBytes,
                pendingToolSlots: state.accumulatedToolCalls.count,
                pendingEventBytes: 0
            )
            logRouterEmptyStreamIfNeeded(state.routerDiagnostics)
            dispatchFinal(
                state: state,
                tools: tools,
                finishMarker: "[DONE]",
                continuation: continuation
            )
            return true
        }

        guard let jsonData = dataContent.data(using: .utf8) else { return false }

        // Server-side agent tool loop trace (`osaurus_agent_tool`). The chunk
        // carries no content (`choices: []`); surface it as a sanitized
        // progress hint so a Mode 2 observer can see which tool is running on
        // the remote agent during the otherwise-silent tool phase. The cheap
        // substring pre-check avoids JSON-parsing every normal content chunk.
        if dataContent.contains("osaurus_agent_tool"),
            let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let trace = root["osaurus_agent_tool"] as? [String: Any],
            let phase = trace["phase"] as? String,
            let name = trace["name"] as? String
        {
            let hint = StreamingAgentToolHint.encode(
                StreamingAgentToolHint.Trace(
                    phase: phase,
                    name: name,
                    callId: trace["call_id"] as? String,
                    isError: (trace["is_error"] as? Bool) ?? false,
                    endRun: (trace["end_run"] as? Bool) ?? false
                )
            )
            state.routerDiagnostics?.recordYield(hint)
            continuation.yield(hint)
            return false
        }

        if providerType == .osaurusRouter,
            let summary = try? JSONDecoder().decode(OsaurusRouterSummaryEvent.self, from: jsonData)
        {
            Task { @MainActor in
                OsaurusRouterAccountService.shared.noteRouterSummary(summary.osaurus)
            }
            // Surface the charge on the stream so the chat layer can keep +
            // explain a billed-but-empty turn and record the on-device ledger
            // row. The `\u{FFFE}` sentinel keeps it out of visible output and
            // token counting; it carries no prompt/response text.
            var billingSummary = RouterBillingSummary(summary.osaurus)
            if billingSummary.requestId == nil {
                billingSummary.requestId = state.routerRequestId
            }
            let hint = StreamingBillingHint.encode(billingSummary)
            state.routerDiagnostics?.recordYield(hint)
            continuation.yield(hint)
            return false
        }

        var emittedDeltas: [String] = []
        let outcome = handleStreamEvent(
            jsonData: jsonData,
            providerType: providerType,
            state: &state,
            yield: {
                emittedDeltas.append($0)
                continuation.yield($0)
            }
        )
        for delta in emittedDeltas {
            state.routerDiagnostics?.recordYield(delta)
        }
        state.routerDiagnostics?.recordOutcome(outcome)

        routerStreamDebug(
            providerType: providerType,
            "event outcome=\(streamOutcomeDebugDescription(outcome)) yieldedTextDeltas=\(state.yieldedTextCount) yieldedTextBytes=\(state.yieldedTextBytes) finishReason=\(state.lastFinishReason ?? "nil")"
        )

        switch outcome {
        case .continue:
            return false
        case .finishNormal:
            routerStreamFinalDebug(providerType: providerType, marker: "finishNormal", state: state)
            state.routerDiagnostics?.recordTerminal(
                marker: "finishNormal",
                yieldedTextCount: state.yieldedTextCount,
                yieldedTextBytes: state.yieldedTextBytes,
                pendingToolSlots: state.accumulatedToolCalls.count,
                pendingEventBytes: 0
            )
            logRouterEmptyStreamIfNeeded(state.routerDiagnostics)
            dispatchFinal(
                state: state,
                tools: tools,
                finishMarker: "finishNormal",
                continuation: continuation
            )
            return true
        case .finishWithToolCall(let invocation):
            continuation.finish(throwing: invocation)
            return true
        case .finishWithError(let error):
            continuation.finish(throwing: error)
            return true
        }
    }

    /// Per-event dispatcher. Decodes the JSON payload for the active provider
    /// type and updates the streaming state, yielding any text deltas via the
    /// callback. Handles structured server-side error envelopes too.
    static func handleStreamEvent(
        jsonData: Data,
        providerType: RemoteProviderType,
        state: inout StreamingState,
        yield: (String) -> Void
    ) -> StreamEventOutcome {
        if let errorMessage = tryDecodeStreamError(jsonData, providerType: providerType) {
            return .finishWithError(RemoteProviderServiceError.requestFailed(errorMessage))
        }

        do {
            switch providerType {
            case .gemini:
                return try handleGeminiEvent(jsonData, state: &state, yield: yield)
            case .anthropic:
                return try handleAnthropicEvent(jsonData, state: &state, yield: yield)
            case .openResponses, .openAICodex:
                return try handleOpenResponsesEvent(jsonData, state: &state, yield: yield)
            case .osaurusRouter:
                return try OpenAICompatibleStreamParser.handleEvent(
                    jsonData: jsonData,
                    options: openAICompatibleParserOptions(for: providerType),
                    state: &state,
                    yield: yield
                )
            case .openaiLegacy, .azureOpenAI, .osaurus:
                return try OpenAICompatibleStreamParser.handleEvent(
                    jsonData: jsonData,
                    options: openAICompatibleParserOptions(for: providerType),
                    state: &state,
                    yield: yield
                )
            }
        } catch {
            print("[Osaurus] Warning: Failed to parse SSE chunk: \(error.localizedDescription)")
            return .continue
        }
    }

    private static func openAICompatibleParserOptions(
        for providerType: RemoteProviderType
    ) -> OpenAICompatibleStreamParser.Options {
        var options: OpenAICompatibleStreamParser.Options =
            providerType == .osaurusRouter ? .routerCompatible : .strict
        // Defer a tool-call finish to the stream's end ONLY for upstreams we
        // requested `usage` from, so the trailing usage chunk is captured and
        // surfaced as completion-token telemetry before the call dispatches.
        options.deferToolCallDispatchUntilUsage = requestsStreamUsageOptions(providerType: providerType)
        return options
    }

    /// OpenAI Chat-Completions upstreams that honor `stream_options.include_usage`
    /// and emit a final `usage` chunk we can surface as completion-token
    /// telemetry. Scoped to the genuinely OpenAI-compatible `/chat/completions`
    /// targets (xAI/Grok, OpenAI-compatible third parties, Azure OpenAI). The
    /// Osaurus Router carries billed token counts in its own summary frame;
    /// Anthropic, Gemini, the Responses API, and Codex use different request and
    /// usage shapes — all excluded here so only the proven-compatible path
    /// changes its outbound request and dispatch timing.
    static func requestsStreamUsageOptions(providerType: RemoteProviderType) -> Bool {
        switch providerType {
        case .openaiLegacy, .azureOpenAI:
            return true
        case .osaurus, .osaurusRouter, .anthropic, .gemini, .openResponses, .openAICodex:
            return false
        }
    }

    /// Whether the target accepts OpenAI's `prompt_cache_key` body field —
    /// a session-scoped routing hint that improves upstream prompt-cache hit
    /// rates for multi-turn conversations (OpenAI already auto-caches
    /// >=1024-token prefixes; the key routes same-session requests to the
    /// same cache shard). Gated to genuine OpenAI hosts only: third-party
    /// OpenAI-compat schemas can be strict about unknown fields (the same
    /// reason `idempotency_key` is router-only), and Gemini/Anthropic have
    /// their own caching (implicit / `cache_control`).
    static func supportsPromptCacheKey(providerType: RemoteProviderType, host: String) -> Bool {
        guard providerType == .openaiLegacy else { return false }
        let normalizedHost = host.lowercased()
        return normalizedHost == "api.openai.com" || normalizedHost.hasSuffix(".openai.com")
    }

    static func remoteChatMaxTokens(
        providerType: RemoteProviderType,
        parameters: GenerationParameters
    ) -> Int? {
        if providerType == .osaurusRouter {
            return parameters.maxTokens
        }
        return parameters.maxTokensExplicit ? parameters.maxTokens : nil
    }

    /// Apply stop-sequence truncation to a text delta. Returns `(maybeTruncated, hitStop)`:
    /// when `hitStop` is true the caller should yield `maybeTruncated` and finish.
    @inline(__always)
    private static func applyStopSequences(
        _ text: String,
        stopSequences: [String]
    ) -> (text: String, hitStop: Bool) {
        guard !stopSequences.isEmpty else { return (text, false) }
        for seq in stopSequences {
            if let range = text.range(of: seq) {
                return (String(text[..<range.lowerBound]), true)
            }
        }
        return (text, false)
    }

    // MARK: - Per-Provider Event Handlers

    private static func handleGeminiEvent(
        _ jsonData: Data,
        state: inout StreamingState,
        yield: (String) -> Void
    ) throws -> StreamEventOutcome {
        let chunk = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: jsonData)

        if let parts = chunk.candidates?.first?.content?.parts {
            for part in parts {
                if part.thought == true { continue }

                switch part.content {
                case .text(let text):
                    if state.accumulatedToolCalls.isEmpty, !text.isEmpty {
                        let output = encodeTextWithSignature(text, signature: part.thoughtSignature)
                        let (truncated, hitStop) = applyStopSequences(
                            output,
                            stopSequences: state.stopSequences
                        )
                        state.recordYield(truncated)
                        yield(truncated)
                        if hitStop { return .finishNormal }
                    }
                case .functionCall(let funcCall):
                    let idx = state.accumulatedToolCalls.count
                    let argsString = geminiArgsJSON(from: funcCall.args)
                    state.accumulatedToolCalls[idx] = (
                        id: geminiToolCallId(),
                        name: funcCall.name,
                        args: argsString,
                        thoughtSignature: funcCall.thoughtSignature
                    )
                    print("[Osaurus] Gemini tool call detected: index=\(idx), name=\(funcCall.name)")
                    yield(StreamingToolHint.encode(funcCall.name))
                    yield(StreamingToolHint.encodeArgs(argsString))
                case .inlineData(let imageData):
                    if state.accumulatedToolCalls.isEmpty {
                        yield(imageMarkdown(imageData, thoughtSignature: part.thoughtSignature))
                    }
                case .functionResponse:
                    break
                }
            }
        }

        if let finishReason = chunk.candidates?.first?.finishReason {
            state.lastFinishReason = finishReason
            if finishReason == "SAFETY" {
                return .finishWithError(
                    RemoteProviderServiceError.requestFailed("Content blocked by safety settings.")
                )
            }
            if finishReason == "STOP" || finishReason == "MAX_TOKENS" {
                switch resolveAccumulatedToolCall(
                    from: state.accumulatedToolCalls,
                    finishMarker: "gemini=\(finishReason)"
                ) {
                case .none: return .finishNormal
                case .ready(let inv): return .finishWithToolCall(inv)
                case .truncated(let err): return .finishWithError(err)
                }
            }
        }

        return .continue
    }

    private static func handleAnthropicEvent(
        _ jsonData: Data,
        state: inout StreamingState,
        yield: (String) -> Void
    ) throws -> StreamEventOutcome {
        guard let event = try? JSONDecoder().decode(AnthropicSSEEvent.self, from: jsonData) else {
            return .continue
        }

        switch event.type {
        case "message_start":
            // Prompt-caching telemetry: `message_start` carries the request's
            // usage split. Log the cache read/write counts so the win from the
            // top-level `cache_control` in `toAnthropicRequest()` is observable
            // per turn (cache reads bill 0.1x input; writes 1.25x).
            if let startEvent = try? JSONDecoder().decode(MessageStartEvent.self, from: jsonData) {
                let usage = startEvent.message.usage
                debugLog(
                    "[Cache][Anthropic] input=\(usage.input_tokens)"
                        + " cacheRead=\(usage.cache_read_input_tokens ?? 0)"
                        + " cacheWrite=\(usage.cache_creation_input_tokens ?? 0)"
                )
            }

        case "content_block_delta":
            guard let deltaEvent = try? JSONDecoder().decode(ContentBlockDeltaEvent.self, from: jsonData)
            else { return .continue }
            if case .textDelta(let textDelta) = deltaEvent.delta {
                let (truncated, hitStop) = applyStopSequences(
                    textDelta.text,
                    stopSequences: state.stopSequences
                )
                state.recordYield(truncated)
                yield(truncated)
                if hitStop { return .finishNormal }
            } else if case .inputJsonDelta(let jsonDelta) = deltaEvent.delta {
                let idx = deltaEvent.index
                var current =
                    state.accumulatedToolCalls[idx] ?? (
                        id: nil, name: nil, args: "", thoughtSignature: nil
                    )
                current.args += jsonDelta.partial_json
                state.accumulatedToolCalls[idx] = current
                yield(StreamingToolHint.encodeArgs(jsonDelta.partial_json))
            }

        case "content_block_start":
            guard let startEvent = try? JSONDecoder().decode(ContentBlockStartEvent.self, from: jsonData)
            else { return .continue }
            if case .toolUse(let toolBlock) = startEvent.content_block {
                let idx = startEvent.index
                state.accumulatedToolCalls[idx] = (
                    id: toolBlock.id, name: toolBlock.name, args: "", thoughtSignature: nil
                )
                print("[Osaurus] Anthropic tool call detected: index=\(idx), name=\(toolBlock.name)")
                yield(StreamingToolHint.encode(toolBlock.name))
            }

        case "message_delta":
            if let deltaEvent = try? JSONDecoder().decode(MessageDeltaEvent.self, from: jsonData),
                let stopReason = deltaEvent.delta.stop_reason
            {
                state.lastFinishReason = stopReason
                // Anthropic safety refusal (`stop_reason: "refusal"`): the
                // API blocks the whole turn with ZERO content blocks, so
                // without this the caller sees a silent empty completion.
                // Surface the structured `stop_details.explanation` as a
                // stream error so the agent loop / chat reports the refusal
                // honestly instead of an empty reply.
                if stopReason == "refusal" {
                    let explanation =
                        (try? JSONDecoder().decode(
                            AnthropicRefusalDeltaEvent.self,
                            from: jsonData
                        ))?.delta.stop_details?.explanation
                    return .finishWithError(
                        RemoteProviderServiceError.requestFailed(
                            "Anthropic refused this request (stop_reason=refusal): "
                                + (explanation
                                    ?? "no explanation provided by the provider")
                        )
                    )
                }
            }

        case "message_stop":
            switch resolveAccumulatedToolCall(
                from: state.accumulatedToolCalls,
                finishMarker: "anthropic message_stop"
            ) {
            case .none: return .finishNormal
            case .ready(let inv): return .finishWithToolCall(inv)
            case .truncated(let err): return .finishWithError(err)
            }

        default:
            break
        }
        return .continue
    }

    private static func handleOpenResponsesEvent(
        _ jsonData: Data,
        state: inout StreamingState,
        yield: (String) -> Void
    ) throws -> StreamEventOutcome {
        guard let event = try? JSONDecoder().decode(OpenResponsesSSEEvent.self, from: jsonData) else {
            return .continue
        }

        switch event.type {
        case "response.output_text.delta":
            if let deltaEvent = try? JSONDecoder().decode(OutputTextDeltaEvent.self, from: jsonData) {
                let (truncated, hitStop) = applyStopSequences(
                    deltaEvent.delta,
                    stopSequences: state.stopSequences
                )
                state.recordYield(truncated)
                yield(truncated)
                if hitStop { return .finishNormal }
            }

        case "response.reasoning_summary_text.delta":
            // Visible reasoning for the Responses path. Parsed untyped (read
            // only `delta`) because OpenAI omits fields the typed event marks
            // required (e.g. `sequence_number`), which would make a strict
            // decode throw and silently drop the summary. Routed through the
            // same reasoning sentinel as `reasoning_content` so ChatView
            // places it in the Think panel.
            if let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                let delta = root["delta"] as? String, !delta.isEmpty
            {
                yield(StreamingReasoningHint.encode(delta))
            }

        case "response.output_item.added":
            if let addedEvent = try? JSONDecoder().decode(OutputItemAddedEvent.self, from: jsonData),
                case .functionCall(let funcCall) = addedEvent.item
            {
                let idx = addedEvent.output_index
                state.accumulatedToolCalls[idx] = (
                    id: funcCall.call_id, name: funcCall.name, args: "", thoughtSignature: nil
                )
                print("[Osaurus] Open Responses tool call detected: index=\(idx), name=\(funcCall.name)")
                yield(StreamingToolHint.encode(funcCall.name))
            }

        case "response.function_call_arguments.delta":
            if let deltaEvent = try? JSONDecoder().decode(
                FunctionCallArgumentsDeltaEvent.self,
                from: jsonData
            ) {
                let idx = deltaEvent.output_index
                var current =
                    state.accumulatedToolCalls[idx] ?? (
                        id: deltaEvent.call_id, name: nil, args: "", thoughtSignature: nil
                    )
                current.args += deltaEvent.delta
                state.accumulatedToolCalls[idx] = current
                yield(StreamingToolHint.encodeArgs(deltaEvent.delta))
            }

        case "response.function_call_arguments.done":
            // Authoritative complete arguments — overwrite accumulated deltas.
            if let doneEvent = try? JSONDecoder().decode(
                FunctionCallArgumentsDoneEvent.self,
                from: jsonData
            ) {
                let idx = doneEvent.output_index
                var current =
                    state.accumulatedToolCalls[idx] ?? (
                        id: doneEvent.call_id, name: nil, args: "", thoughtSignature: nil
                    )
                current.args = doneEvent.arguments
                state.accumulatedToolCalls[idx] = current
            }

        case "response.output_item.done":
            // Capture the encrypted reasoning item untyped. The typed
            // `OpenResponsesReasoningItem` requires `status`/`summary`, which
            // gpt-5.5/Codex omits on the reasoning item, so a typed decode
            // throws and silently drops the blob. The client re-emits it next
            // turn for chain continuity (store:false + include.encrypted_content).
            if !state.didCaptureReasoning,
                let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                let item = root["item"] as? [String: Any],
                (item["type"] as? String) == "reasoning",
                let id = item["id"] as? String, !id.isEmpty,
                let encrypted = item["encrypted_content"] as? String, !encrypted.isEmpty
            {
                state.didCaptureReasoning = true
                reasoningLogger.debug(
                    "captured reasoning from output_item.done bytes=\(encrypted.count, privacy: .public)"
                )
                yield(StreamingReasoningItemHint.encode(id: id, encryptedContent: encrypted))
            }

            // Final confirmed item — extract args from the completed function_call
            // when no `.delta` events landed first (common for short calls).
            if let doneEvent = try? JSONDecoder().decode(OutputItemDoneEvent.self, from: jsonData) {
                switch doneEvent.item {
                case .functionCall(let funcCall):
                    let idx = doneEvent.output_index
                    var current =
                        state.accumulatedToolCalls[idx] ?? (
                            id: funcCall.call_id, name: funcCall.name, args: "", thoughtSignature: nil
                        )
                    if current.args.isEmpty { current.args = funcCall.arguments }
                    state.accumulatedToolCalls[idx] = current
                case .reasoning, .message:
                    break
                }
            }

        case "response.completed":
            state.lastFinishReason = "completed"
            // Defensive fallback: some providers attach
            // `reasoning.encrypted_content` only to the final `response.output`
            // array rather than a streaming `output_item.done`. No-op when we
            // already captured it mid-stream (gpt-5.5/Codex).
            if !state.didCaptureReasoning {
                captureReasoningFromCompleted(jsonData, yield: yield)
            }
            switch resolveAccumulatedToolCall(
                from: state.accumulatedToolCalls,
                finishMarker: "response.completed"
            ) {
            case .none: return .finishNormal
            case .ready(let inv): return .finishWithToolCall(inv)
            case .truncated(let err): return .finishWithError(err)
            }

        default:
            break
        }
        return .continue
    }

    /// Fallback reasoning capture from a `response.completed` payload. Parsed
    /// untyped so an unknown sibling output-item type can't make a strict
    /// `OpenResponsesResponse` decode throw and drop the reasoning blob.
    /// Yields a `StreamingReasoningItemHint` for each reasoning item carrying
    /// a non-empty `encrypted_content` and a usable id.
    private static func captureReasoningFromCompleted(
        _ jsonData: Data,
        yield: (String) -> Void
    ) {
        guard
            let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let response = root["response"] as? [String: Any],
            let output = response["output"] as? [[String: Any]]
        else { return }

        for item in output where (item["type"] as? String) == "reasoning" {
            guard let id = item["id"] as? String, !id.isEmpty,
                let encrypted = item["encrypted_content"] as? String, !encrypted.isEmpty
            else { continue }
            reasoningLogger.debug(
                "captured reasoning from response.completed bytes=\(encrypted.count, privacy: .public)"
            )
            yield(StreamingReasoningItemHint.encode(id: id, encryptedContent: encrypted))
        }
    }

    static func handleOpenAIEvent(
        _ jsonData: Data,
        state: inout StreamingState,
        yield: (String) -> Void
    ) throws -> StreamEventOutcome {
        try OpenAICompatibleStreamParser.handleEvent(
            jsonData: jsonData,
            options: .strict,
            state: &state,
            yield: yield
        )
    }

    static func handleLenientOpenAIEvent(
        _ jsonData: Data,
        state: inout StreamingState,
        yield: (String) -> Void
    ) throws -> StreamEventOutcome {
        try OpenAICompatibleStreamParser.handleEvent(
            jsonData: jsonData,
            options: .routerCompatible,
            state: &state,
            yield: yield
        )
    }

    /// Final dispatch site: drains any tool call still in-flight after the
    /// stream loop ends, then falls back to inline tool-call detection in
    /// accumulated text content (for Llama-style providers that embed tool
    /// calls in plain text rather than the structured field).
    static func dispatchFinal(
        state: StreamingState,
        tools: [Tool],
        finishMarker: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        // Drain any think-splitter tail (a partial tag that never completed, or
        // an unclosed `<think>` block) before the stream finishes.
        if var splitter = state.thinkSplitter {
            for segment in splitter.flush() {
                switch segment {
                case .reasoning(let reasoning):
                    if !reasoning.isEmpty { continuation.yield(StreamingReasoningHint.encode(reasoning)) }
                case .content(let visible):
                    if !visible.isEmpty { continuation.yield(visible) }
                }
            }
        }

        // Surface provider-reported usage (OpenAI `stream_options.include_usage`)
        // as an end-of-stream stats hint, mirroring the local vmlx
        // `.completionInfo` path so the eval harness and chat token count see
        // real remote completion tokens (previously remote runs reported 0).
        // Yield BEFORE resolving the tool/text outcome so the hint reaches the
        // consumer even when the stream finishes-by-throw with a tool call. The
        // tok/s field is provider-supplied when present, else 0 — the chat UI
        // derives its visible tok/s from a rolling observer (it only reads this
        // hint's token count + stop reason), and the eval skips a 0 tps for its
        // decode-speed average while still counting the tokens. `stopReason`
        // carries the provider's real `finish_reason` (`stop`/`length`/
        // `tool_calls`) for HTTP writers that map it back to a `usage` frame.
        if let usage = state.providerUsage {
            continuation.yield(
                StreamingStatsHint.encode(
                    tokenCount: usage.completion_tokens,
                    tokensPerSecond: usage.tokens_per_second ?? 0,
                    stopReason: state.lastFinishReason
                )
            )
        }

        switch resolveAccumulatedToolCall(
            from: state.accumulatedToolCalls,
            finishMarker: finishMarker
        ) {
        case .ready(let invocation):
            print(
                "[Osaurus] Stream ended: emitting tool call '\(invocation.toolName)' "
                    + "(finish_reason: \(state.lastFinishReason ?? "none"))"
            )
            continuation.finish(throwing: invocation)

        case .truncated(let error):
            continuation.finish(throwing: error)

        case .none:
            // Llama-style fallback: search yielded text for an inline tool call.
            if state.trackContent, !state.accumulatedContent.isEmpty, !tools.isEmpty,
                let (name, args) = RemoteToolDetection.detectInlineToolCall(
                    in: state.accumulatedContent,
                    tools: tools
                )
            {
                print("[Osaurus] Fallback: detected inline tool call '\(name)' in text")
                continuation.finish(
                    throwing: ServiceToolInvocation(
                        toolName: name,
                        jsonArguments: args,
                        toolCallId: nil
                    )
                )
                return
            }
            continuation.finish()
        }
    }

    /// Shared streaming pipeline backing both `streamDeltas` and
    /// `streamWithTools`. Build the request, consume framed SSE events, and
    /// dispatch them through the per-provider handlers.
    private func _streamRemote(
        modelName: String,
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?
    ) async throws -> AsyncThrowingStream<String, Error> {
        var request = buildChatRequest(
            messages: messages,
            parameters: parameters,
            model: modelName,
            stream: true,
            tools: tools,
            toolChoice: toolChoice
        )
        if !stopSequences.isEmpty { request.stop = stopSequences }

        try await refreshCodexOAuthIfNeeded()
        try await refreshXAIOAuthIfNeeded()
        let urlRequest = try await buildURLRequest(for: request)
        let currentSession = self.session
        let providerType = Self.effectiveRequestProviderType(
            configuredProviderType: self.provider.providerType,
            request: request
        )
        // Native Osaurus peers: the plaintext request (Bearer included) is
        // sealed into a `/secure/call` envelope per attempt inside the
        // producer, and the SSE response is decrypted frame-by-frame before
        // the line parser. No downgrade path — if the peer can't handshake,
        // the user-facing SecureChannelClientError says to upgrade it.
        let secureProvider = providerType == .osaurus ? self.provider : nil
        let inactivityTimeout = self.streamInactivityTimeout
        let toolList = tools ?? []
        Self.routerStreamDebug(
            providerType: providerType,
            "request model=\(modelName) url=\(urlRequest.url?.absoluteString ?? "nil") stream=\(request.stream) tools=\(toolList.count) bodyBytes=\(urlRequest.httpBody?.count ?? 0)"
        )
        // Only the with-tools path needs accumulated text for the inline
        // tool-call fallback; streamDeltas has no tools, so skip the
        // memory cost of growing a 100% unused buffer.
        let trackContent = !toolList.isEmpty
        let initialRouterDiagnostics =
            providerType == .osaurusRouter
            ? RouterStreamDiagnostics(
                request: request,
                urlRequest: urlRequest,
                toolNames: toolList.map(\.function.name),
                providerType: providerType
            )
            : nil

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        // The producer runs in a `Task` whose closure inherits the
        // calling task's locals (unlike `Task.detached`). Snapshot
        // the probe here so the read happens once on producer
        // entry and we don't re-touch the task-local on every chunk.
        let probe = WireTransportProbe.current

        // Holds the connected URLSession task so stream teardown can close the
        // socket immediately (see `LiveURLSessionTaskBox`). Critical for Mode 2:
        // a prompt close lets the peer cancel the in-flight remote agent run.
        let liveTaskBox = LiveURLSessionTaskBox()

        let producerTask = Task {
            do {
                var state = StreamingState(stopSequences: stopSequences, trackContent: trackContent)
                state.routerDiagnostics = initialRouterDiagnostics
                state.routerRequestId = request.idempotencyKey

                // Idempotent connect-phase retry: only retries the
                // `bytes(for:)` call (no stream data has been delivered
                // upstream yet, so retrying is safe). Once we start
                // iterating bytes / dispatching SSE chunks we never
                // retry — the consumer has already begun seeing output.
                //
                // The `isCancelled` closure is the dominant CI-flake
                // mitigation: between retry attempts (200ms / 800ms
                // sleeps) the owning service's `invalidateSession()` may
                // fire from a sibling test's teardown, after which any
                // further `bytes(for:)` call on this session raises an
                // uncatchable Obj-C `NSException` and `abort()`s the
                // entire xctest process. See the doc comment on
                // `sessionInvalidatedFlag`.
                var connectedBytes: URLSession.AsyncBytes? = nil
                var secureDecoder: SecureFrameStreamDecoder? = nil
                var attempt = 0
                connectLoop: while true {
                    attempt += 1

                    var outboundRequest = urlRequest
                    var secureOpener: SecureResponseOpener? = nil
                    if let secureProvider {
                        // Seal per attempt: each call consumes a fresh
                        // sequence number, so a retry can't be a replay.
                        let wrapped = try await SecureChannelClient.shared.wrappedRequest(
                            for: urlRequest,
                            provider: secureProvider,
                            urlSession: currentSession
                        )
                        outboundRequest = wrapped.request
                        // Hold the opener; the decoder is built only once we
                        // confirm the response is an encrypted SSE stream. A
                        // buffered error envelope is decoded separately below.
                        secureOpener = wrapped.opener
                    }

                    let (bytes, response) = try await Self.connectWithRetry(
                        session: currentSession,
                        urlRequest: outboundRequest,
                        isCancelled: { [weak self] in
                            self?.isSessionInvalidated ?? true
                        }
                    )

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: RemoteProviderServiceError.invalidResponse)
                        return
                    }
                    Self.routerStreamDebug(
                        providerType: providerType,
                        "response status=\(httpResponse.statusCode) contentType=\(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "nil") attempt=\(attempt)"
                    )
                    state.routerDiagnostics?.recordResponse(
                        status: httpResponse.statusCode,
                        contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                        attempt: attempt
                    )

                    if httpResponse.statusCode >= 400 {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        // Server restarted and forgot the session — drop the
                        // cached keys, re-handshake, retry once.
                        if let secureProvider, attempt == 1,
                            SecureChannelClient.isSessionUnknownError(
                                statusCode: httpResponse.statusCode,
                                body: errorData
                            )
                        {
                            await SecureChannelClient.shared.invalidateSession(for: secureProvider)
                            continue connectLoop
                        }
                        let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        continuation.finish(
                            throwing: RemoteProviderServiceError.requestFailed(
                                "HTTP \(httpResponse.statusCode): \(errorMessage)"
                            )
                        )
                        return
                    }

                    // Secure peers seal a streamed agent run as encrypted SSE
                    // (outer `text/event-stream`). An inner response that
                    // finished before any SSE header was written — an early
                    // error (e.g. 403 agent_scope_denied, 503, 400) or a
                    // non-streamed body — instead arrives as a single buffered
                    // frame in an `application/json` envelope (outer 200, real
                    // status inside the ciphertext). Decode it here and surface
                    // the real inner status/body, rather than feeding it to the
                    // SSE frame decoder, which would fail with a misleading
                    // `streamTruncated`.
                    if let secureOpener {
                        let outerContentType =
                            httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
                        if !outerContentType.lowercased().hasPrefix("text/event-stream") {
                            var buffered = Data()
                            for try await byte in bytes {
                                buffered.append(byte)
                            }
                            let inner: SecureChannel.InnerResponse
                            do {
                                inner = try SecureChannelClient.openBufferedResponse(
                                    buffered,
                                    opener: secureOpener
                                )
                            } catch {
                                continuation.finish(throwing: error)
                                return
                            }
                            let innerBody =
                                inner.body.flatMap { Data(base64urlEncoded: $0) } ?? Data()
                            if inner.status >= 400 {
                                let message = String(decoding: innerBody, as: UTF8.self)
                                continuation.finish(
                                    throwing: RemoteProviderServiceError.requestFailed(
                                        "HTTP \(inner.status): \(message)"
                                    )
                                )
                            } else {
                                // Buffered 2xx — unusual for a stream request,
                                // but still a complete answer: surface its body
                                // and finish cleanly.
                                if !innerBody.isEmpty {
                                    continuation.yield(String(decoding: innerBody, as: UTF8.self))
                                }
                                continuation.finish()
                            }
                            return
                        }
                        secureDecoder = SecureFrameStreamDecoder(opener: secureOpener)
                    }

                    connectedBytes = bytes
                    // Expose the live task so `onTermination` can hard-cancel
                    // it (closes the socket) the instant the consumer stops.
                    liveTaskBox.store(bytes.task)
                    break connectLoop
                }

                guard let bytes = connectedBytes else {
                    continuation.finish(throwing: RemoteProviderServiceError.invalidResponse)
                    return
                }

                // MiniMax-style providers inline reasoning as <think> in the
                // content rail; install the splitter so it routes to the Think
                // panel instead of leaking the tags into the visible message.
                if RemoteReasoningPolicy.resolve(
                    providerType: self.provider.providerType,
                    host: self.provider.host,
                    model: modelName
                ).inbound == .inlineThink {
                    state.thinkSplitter = InlineThinkSplitter()
                }

                // Inlined SSE event loop. Each yield from a per-provider
                // handler reaches the consumer in the same task hop as the
                // chunk arrival — no intermediate AsyncStream layer.
                var sseEventData = ""
                var lineParser = SSELineParser()
                var routerChunkCount = 0
                var routerByteCount = 0
                var routerEventCount = 0
                let chunkStream = Self.makeChunkStream(from: bytes)
                let chunkIter = ChunkIteratorRef(chunkStream.makeAsyncIterator())

                chunkLoop: while true {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    let chunk = try await Self.nextChunk(
                        from: chunkIter,
                        timeout: inactivityTimeout
                    )

                    if let chunk = chunk {
                        if providerType == .osaurusRouter {
                            routerChunkCount += 1
                            routerByteCount += chunk.count
                            state.routerDiagnostics?.recordChunk(chunk)
                        }
                        if let secureDecoder {
                            // Decrypt outer secure frames into the original
                            // SSE bytes before line parsing. The probe sees
                            // the decrypted stream (the logical wire) — the
                            // raw bytes are ciphertext.
                            let plain = try secureDecoder.feed(chunk)
                            if !plain.isEmpty {
                                lineParser.append(plain)
                                probe?.appendResponseChunk(plain)
                            }
                        } else {
                            lineParser.append(chunk)
                            // Wire-verification tap. Capture the raw
                            // pre-unscrub bytes before they're parsed
                            // into SSE events. We tap inside the
                            // stream loop (not at the bytes(for:) site)
                            // so the inactivity timeout / cancel paths
                            // still get their last delivered chunk in
                            // the snapshot. No-op when no probe is set.
                            probe?.appendResponseChunk(chunk)
                        }
                    } else {
                        // Stream ended naturally or inactivity timeout fired.
                        // An encrypted stream must have delivered its
                        // authenticated `fin` frame by now, or it was
                        // silently truncated.
                        if let secureDecoder {
                            try secureDecoder.verifyCompleted()
                        }
                        // Flush any unterminated trailing bytes as a final line.
                        lineParser.flushPending()
                    }

                    while let lineBytes = lineParser.nextLine() {
                        if !lineBytes.isEmpty {
                            Self.processSSELine(lineBytes, providerType: providerType, into: &sseEventData)
                            continue
                        }
                        // Blank line — SSE event boundary, dispatch payload.
                        guard !sseEventData.isEmpty else { continue }
                        let dataContent = sseEventData
                        sseEventData = ""
                        if providerType == .osaurusRouter {
                            routerEventCount += 1
                        }
                        if Self.processEventPayload(
                            dataContent,
                            state: &state,
                            providerType: providerType,
                            tools: toolList,
                            continuation: continuation
                        ) {
                            return
                        }
                    }

                    if chunk == nil {
                        // Process any final unterminated event payload before exiting.
                        if !sseEventData.isEmpty {
                            let dataContent = sseEventData
                            sseEventData = ""
                            if providerType == .osaurusRouter {
                                routerEventCount += 1
                            }
                            if Self.processEventPayload(
                                dataContent,
                                state: &state,
                                providerType: providerType,
                                tools: toolList,
                                continuation: continuation
                            ) {
                                return
                            }
                        }
                        break chunkLoop
                    }
                }

                // Stream ended naturally without a finish marker.
                Self.routerStreamDebug(
                    providerType: providerType,
                    "stream-end chunks=\(routerChunkCount) bytes=\(routerByteCount) events=\(routerEventCount) yieldedTextDeltas=\(state.yieldedTextCount) yieldedTextBytes=\(state.yieldedTextBytes) finishReason=\(state.lastFinishReason ?? "nil") pendingEventBytes=\(sseEventData.utf8.count)"
                )
                state.routerDiagnostics?.recordTerminal(
                    marker: "stream-end",
                    yieldedTextCount: state.yieldedTextCount,
                    yieldedTextBytes: state.yieldedTextBytes,
                    pendingToolSlots: state.accumulatedToolCalls.count,
                    pendingEventBytes: sseEventData.utf8.count
                )
                Self.logRouterEmptyStreamIfNeeded(state.routerDiagnostics)
                Self.dispatchFinal(
                    state: state,
                    tools: toolList,
                    finishMarker: "stream-end",
                    continuation: continuation
                )
            } catch {
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }

        continuation.onTermination = { @Sendable _ in
            // Cancel the producer first so its `catch` sees `Task.isCancelled`
            // and finishes cleanly (no spurious URLError surfaced on user
            // stop), then force the socket closed. The explicit task cancel is
            // belt-and-suspenders over the cooperative chunk-stream unwind: it
            // guarantees a prompt FIN so a Mode 2 peer aborts the remote run
            // instead of finishing it after the client has walked away.
            producerTask.cancel()
            liveTaskBox.cancel()
        }
        return stream
    }

    /// Serialise Gemini's `functionCall.args` (`[String: AnyCodableValue]`)
    /// into a compact JSON string. Centralised because the same five-line
    /// extraction repeats at every Gemini parse site (the two SSE
    /// producers and the one-shot response parser).
    private static func geminiArgsJSON(from args: [String: AnyCodableValue]?) -> String {
        let dict = (args ?? [:]).mapValues { $0.value }
        // Sorted keys: replayed verbatim into the next turn's
        // `tool_calls[].function.arguments`. See `JSONDeterminism.swift`.
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .osaurusCanonical),
            let s = String(data: data, encoding: .utf8)
        {
            return s
        }
        return "{}"
    }

    /// Synthetic tool-call id Gemini doesn't provide one for. Same shape
    /// (`gemini-XXXXXXXX`) as the inline call sites used to construct.
    private static func geminiToolCallId() -> String {
        "gemini-\(UUID().uuidString.prefix(8))"
    }

    /// Build a chat completion request structure.
    ///
    /// `internal` (not `private`) so the Mode 1 / Mode 2 wire-shape contract can
    /// be asserted in tests: Mode 2 (`parameters.runAsRemoteAgent`) OMITS the
    /// `model` field on the wire and stamps `runAsRemoteAgent`; Mode 1 preserves
    /// the resolved model and tools.
    func buildChatRequest(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        model: String,
        stream: Bool,
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?
    ) -> RemoteChatRequest {
        let (effortValue, thinking) = Self.remoteChatReasoningControls(
            providerType: provider.providerType,
            host: provider.host,
            model: model,
            effort: parameters.modelOptions["reasoningEffort"]?.stringValue
        )
        let allowsReasoningObject =
            Self.allowsChatCompletionsReasoningObject(
                providerType: provider.providerType,
                host: provider.host
            )
        let isReasoningModel = OpenAIReasoningProfile.matches(modelId: model)

        // Strict wire targets get sanitized tool parameters; Osaurus still
        // validates calls locally against the original full schema.
        let wireTools: [Tool]?
        if let tools,
            Self.enforcesTopLevelParameterSchemaRestrictions(
                providerType: provider.providerType,
                host: provider.host
            )
        {
            wireTools = tools.map(Self.strippingRestrictedTopLevelSchemaKeys)
        } else {
            wireTools = tools
        }

        // Mode 2 (remote agent run): the remote agent owns its generation
        // config. The `model` field is omitted on the wire (see
        // `RemoteChatRequest.encode`) so the peer resolves its own live
        // effective model, and we strip every caller-supplied sampling/reasoning
        // field below — otherwise the host's run loop applies the caller's local
        // defaults and silently overrides the agent's native
        // `generation_config.json` (faithfulness regression). `model` is passed
        // through for Mode 1 and for local reasoning-profile checks only.
        let isAgentRun = parameters.runAsRemoteAgent
        var request = RemoteChatRequest(
            model: model,
            messages: messages,
            // Reasoning models (o1, gpt-5) forbid temperature/top_p when reasoning is active as inferred from
            // https://community.openai.com/t/gpt-5-nano-accepted-parameters/1355086/2
            temperature: isAgentRun ? nil : (isReasoningModel ? nil : parameters.temperature),
            max_completion_tokens: isAgentRun
                ? nil
                : Self.remoteChatMaxTokens(
                    providerType: provider.providerType,
                    parameters: parameters
                ),
            stream: stream,
            top_p: isAgentRun ? nil : (isReasoningModel ? nil : parameters.topPOverride),
            // Forward the raw OpenAI penalties — most upstream OpenAI-
            // compatible providers accept these natively, and stripping
            // them silently was a previous gap that surprised clients.
            frequency_penalty: isAgentRun ? nil : (isReasoningModel ? nil : parameters.frequencyPenalty),
            presence_penalty: isAgentRun ? nil : (isReasoningModel ? nil : parameters.presencePenalty),
            stop: nil,
            tools: wireTools,
            tool_choice: toolChoice,
            reasoning_effort: isAgentRun ? nil : effortValue,
            reasoning: isAgentRun
                ? nil
                : (allowsReasoningObject ? effortValue.map { ReasoningConfig(effort: $0) } : nil),
            thinking: isAgentRun ? nil : thinking,
            modelOptions: parameters.modelOptions,
            veniceParameters: buildVeniceParameters(from: parameters.modelOptions),
            // Router-only: the body is signed, so this rides the existing
            // signature. Gated here so no other OpenAI-compat upstream receives
            // an unexpected `idempotency_key` field (some 422 on unknown keys).
            idempotencyKey: provider.providerType == .osaurusRouter
                ? parameters.idempotencyKey : nil
        )

        // Ask OpenAI Chat-Completions upstreams to emit a final `usage` chunk so
        // the streaming path can report real completion tokens (the parser
        // captures it; `dispatchFinal` surfaces it as a stats hint). Only for
        // streaming requests to providers we know honor it — the non-streaming
        // path already gets `usage` in its single JSON response, and other
        // provider shapes (router/Anthropic/Gemini/Responses) are excluded.
        if stream, Self.requestsStreamUsageOptions(providerType: provider.providerType) {
            request.streamOptions = StreamOptions(include_usage: true)
        }
        // Session-scoped prompt-cache routing hint for genuine OpenAI hosts.
        // The chat surface already threads a stable per-conversation
        // `session_id`; scoping the key to it keeps one conversation's turns
        // on one cache shard without coupling unrelated sessions.
        if !isAgentRun,
            let sessionId = parameters.sessionId, !sessionId.isEmpty,
            Self.supportsPromptCacheKey(providerType: provider.providerType, host: provider.host)
        {
            request.promptCacheKey = "osaurus-session-\(sessionId)"
        }
        request.runAsRemoteAgent = parameters.runAsRemoteAgent
        return request
    }

    /// Extract Venice-specific parameters from model options when the provider is Venice AI.
    /// Returns nil for non-Venice providers or when all values are defaults.
    private func buildVeniceParameters(from options: [String: ModelOptionValue]) -> VeniceParameters? {
        guard provider.host.contains("venice.ai") else { return nil }

        let webSearch = options["enableWebSearch"]?.stringValue
        let disableThinking = options["disableThinking"]?.boolValue
        let includeSystemPrompt = options["includeVeniceSystemPrompt"]?.boolValue

        let hasNonDefaults =
            (webSearch != nil && webSearch != "off")
            || disableThinking == true
            || includeSystemPrompt == false
        guard hasNonDefaults else { return nil }

        return VeniceParameters(
            enable_web_search: (webSearch != nil && webSearch != "off") ? webSearch : nil,
            disable_thinking: disableThinking == true ? true : nil,
            include_venice_system_prompt: includeSystemPrompt == false ? false : nil
        )
    }

    private func refreshCodexOAuthIfNeeded() async throws {
        guard provider.authType == .openAICodexOAuth else { return }
        guard let tokens = cachedOAuthTokens else {
            throw OpenAICodexOAuthError.missingSignInTokens
        }
        guard tokens.isExpired else { return }

        let refreshed = try await OpenAICodexOAuthService.refresh(tokens)
        cachedOAuthTokens = refreshed
        await RemoteProviderKeychain.saveOAuthTokensOffMainActor(refreshed, for: provider.id)
    }

    private func codexOAuthHeaders() throws -> [String: String] {
        guard let tokens = cachedOAuthTokens else {
            throw OpenAICodexOAuthError.missingSignInTokens
        }
        return [
            "Authorization": "Bearer \(tokens.accessToken)",
            "chatgpt-account-id": tokens.accountId,
            "OpenAI-Beta": "responses=experimental",
            "originator": "codex_cli_rs",
        ]
    }

    private func refreshXAIOAuthIfNeeded() async throws {
        guard provider.authType == .xaiOAuth else { return }
        guard let tokens = cachedOAuthTokens else {
            throw XAIOAuthError.missingSignInTokens
        }
        guard tokens.isExpired else { return }

        let refreshed = try await XAIOAuthService.refresh(tokens)
        cachedOAuthTokens = refreshed
        await RemoteProviderKeychain.saveOAuthTokensOffMainActor(refreshed, for: provider.id)
    }

    private func xaiOAuthHeaders() throws -> [String: String] {
        guard let tokens = cachedOAuthTokens else {
            throw XAIOAuthError.missingSignInTokens
        }
        return [
            "Authorization": "Bearer \(tokens.accessToken)"
        ]
    }

    /// Non-streaming `generateContent` fallback for Gemini image models (Nano Banana).
    /// Image models don't support `streamGenerateContent`, so this wraps the
    /// single-shot response in an `AsyncThrowingStream` for the streaming callers.
    private func geminiImageGenerateContent(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        model: String,
        stopSequences: [String],
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?
    ) async throws -> AsyncThrowingStream<String, Error> {
        var request = buildChatRequest(
            messages: messages,
            parameters: parameters,
            model: model,
            stream: false,
            tools: tools,
            toolChoice: toolChoice
        )

        if !stopSequences.isEmpty {
            request.stop = stopSequences
        }

        let urlRequest = try await buildURLRequest(for: request)
        let currentSession = self.session

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        let probe = WireTransportProbe.current

        let producerTask = Task {
            do {
                let (data, response) = try await currentSession.data(for: urlRequest)
                probe?.replaceResponseBody(data)

                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.finish(throwing: RemoteProviderServiceError.invalidResponse)
                    return
                }

                if httpResponse.statusCode >= 400 {
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                    continuation.finish(
                        throwing: RemoteProviderServiceError.requestFailed(
                            "HTTP \(httpResponse.statusCode): \(errorMessage)"
                        )
                    )
                    return
                }

                let geminiResponse = try JSONDecoder().decode(
                    GeminiGenerateContentResponse.self,
                    from: data
                )

                if let parts = geminiResponse.candidates?.first?.content?.parts {
                    var pendingToolCall: ServiceToolInvocation?

                    for part in parts {
                        if part.thought == true { continue }

                        switch part.content {
                        case .text(let text):
                            if !text.isEmpty {
                                continuation.yield(Self.encodeTextWithSignature(text, signature: part.thoughtSignature))
                            }
                        case .inlineData(let imageData):
                            continuation.yield(Self.imageMarkdown(imageData, thoughtSignature: part.thoughtSignature))
                        case .functionCall(let funcCall):
                            pendingToolCall = ServiceToolInvocation(
                                toolName: funcCall.name,
                                jsonArguments: Self.geminiArgsJSON(from: funcCall.args),
                                toolCallId: Self.geminiToolCallId(),
                                geminiThoughtSignature: funcCall.thoughtSignature
                            )
                        case .functionResponse:
                            break
                        }
                    }

                    if let invocation = pendingToolCall {
                        continuation.finish(throwing: invocation)
                        return
                    }
                }

                continuation.finish()
            } catch {
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }

        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }

        return stream
    }

    /// Endpoint URL for a native Osaurus peer, split by mode. This is the single
    /// place the Mode 1 / Mode 2 routing decision lives (exposed `internal` for
    /// tests):
    ///
    /// - Mode 2 (`runAsRemoteAgent == true`): `POST /agents/{identifier}/run`,
    ///   where the agent runs fully server-side (own model/context/tools).
    ///   Address the agent by its pinned crypto address — the identity the
    ///   Secure Channel verifies and the host resolves — falling back to the
    ///   receiver-minted `remoteAgentId` only for legacy providers paired before
    ///   an address was pinned.
    /// - Mode 1 (`runAsRemoteAgent == false`): `POST /chat/completions`. The
    ///   peer is treated as a plain OpenAI-compatible backend; its endpoint is a
    ///   passthrough that honors the caller's model + tools, so the *local*
    ///   agent persona/tools drive the turn and tool calls run locally.
    ///   (`.osaurus.chatEndpoint` is the unused `/run` sentinel, so the path is
    ///   built explicitly here.)
    ///
    /// Returns nil only when a Mode 2 request has no resolvable agent identifier.
    ///
    /// `nonisolated` because it's a pure function of the immutable `provider`
    /// (no actor state), so `ChatEngine` can build Insights connection metadata
    /// for the endpoint synchronously without an actor hop.
    nonisolated func osaurusEndpointURL(runAsRemoteAgent: Bool) -> URL? {
        guard runAsRemoteAgent else {
            return provider.url(for: "/chat/completions")
        }
        let identifier =
            provider.remoteAgentAddress.flatMap { $0.isEmpty ? nil : $0 }
            ?? provider.remoteAgentId?.uuidString
        guard let identifier else { return nil }
        return provider.url(for: "/agents/\(identifier)/run")
    }

    /// Build a URLRequest for the chat completions endpoint.
    ///
    /// `internal` (not `private`) so the Mode 2 defense-in-depth guard — a
    /// `runAsRemoteAgent` request against a non-`.osaurus` provider must throw
    /// rather than POST `/chat/completions` — can be asserted directly in tests.
    func buildURLRequest(for request: RemoteChatRequest) async throws -> URLRequest {
        let url: URL
        let requestProviderType = Self.effectiveRequestProviderType(
            configuredProviderType: provider.providerType,
            request: request
        )

        // Mode 2 hard guard (defense-in-depth): a remote-agent run must only
        // ever target a native Osaurus peer's `/agents/{address}/run`. If
        // routing ever lands a `runAsRemoteAgent` request on a non-Osaurus
        // provider (e.g. a stale model prefix pointing at a local third-party
        // provider), fail fast with a clear error instead of POSTing
        // `/chat/completions` — that path produced the opaque upstream 404
        // ("Model default not found ['fugu', ...]") this guard exists to stop.
        if request.runAsRemoteAgent && provider.providerType != .osaurus {
            RemoteAgentRunLog.clientError(
                "agent run blocked: provider '\(provider.name)' type=\(provider.providerType.rawValue) is not an Osaurus agent endpoint"
            )
            throw RemoteProviderServiceError.requestFailed(
                "Remote agent run cannot use provider '\(provider.name)' — it is not an Osaurus agent endpoint. "
                    + "Reconnect to the remote agent and try again."
            )
        }

        if requestProviderType == .gemini {
            // Gemini uses model-in-URL pattern: /models/{model}:generateContent or :streamGenerateContent
            let action = request.stream ? "streamGenerateContent" : "generateContent"
            // Validate the model segment before interpolating into the
            // URL path. Previously a model name with spaces (e.g. the user
            // typing "gemini 3.1 flash lite preview" as the model ID) flowed
            // unsanitized into URL construction, and `URL(string:)` on
            // the final string would return nil → the caller saw an
            // opaque "invalidURL" throw. We explicitly surface the
            // validation error so the user sees *which* character is
            // rejected. See issue #858.
            //
            // Allowed chars cover:
            // - standard model IDs: `gemini-2.0-flash-exp`, `gemini-1.5-pro-latest`
            // - tuned models: `tunedModels/my-tuned-model`
            // - Google's path-parent syntax: `models/foo/bar` (rare)
            // Disallowed: whitespace, colons (reserved for the action
            // suffix we append), `?` / `&` (query markers), other
            // URL-unsafe chars that would silently corrupt the path.
            let trimmedModel = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedModel.isEmpty {
                throw RemoteProviderServiceError.requestFailed(
                    "Gemini model name is empty. Set a model ID like 'gemini-2.0-flash-exp' in provider settings."
                )
            }
            let allowed = CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._/"
            )
            if trimmedModel.unicodeScalars.contains(where: { !allowed.contains($0) }) {
                throw RemoteProviderServiceError.requestFailed(
                    "Invalid Gemini model name '\(trimmedModel)': only letters, digits, '-', '_', '.', and '/' are allowed. Check provider settings."
                )
            }
            let endpoint = "/models/\(trimmedModel):\(action)"
            guard let geminiURL = provider.url(for: endpoint) else {
                throw RemoteProviderServiceError.invalidURL
            }
            if request.stream {
                // Append ?alt=sse for SSE-formatted streaming
                guard var components = URLComponents(url: geminiURL, resolvingAgainstBaseURL: false) else {
                    throw RemoteProviderServiceError.invalidURL
                }
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "alt", value: "sse")]
                guard let sseURL = components.url else {
                    throw RemoteProviderServiceError.invalidURL
                }
                url = sseURL
            } else {
                url = geminiURL
            }
        } else if requestProviderType == .osaurus {
            // Native Osaurus peer, split by mode (see `osaurusEndpointURL`):
            // Mode 2 (`runAsRemoteAgent`) → /agents/{address}/run (the agent
            // runs fully server-side); Mode 1 → the OpenAI-compatible
            // /chat/completions inference endpoint.
            guard let osaurusURL = osaurusEndpointURL(runAsRemoteAgent: request.runAsRemoteAgent) else {
                throw RemoteProviderServiceError.invalidURL
            }
            url = osaurusURL
        } else {
            let endpoint = requestProviderType.chatEndpoint
            guard let standardURL = provider.url(for: endpoint) else {
                throw RemoteProviderServiceError.invalidURL
            }
            url = standardURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if Self.isImageCapableModel(request.model) {
            urlRequest.timeoutInterval =
                provider.disableTimeout
                ? RemoteProvider.unboundedTimeout
                : max(provider.timeout, Self.imageModelMinTimeout)
        }

        // Set Accept header based on streaming mode
        if request.stream {
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        } else {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        let headers: [String: String]
        if provider.providerType == .osaurusRouter {
            headers = [:]
        } else if provider.authType == .openAICodexOAuth {
            headers = try codexOAuthHeaders()
        } else if provider.authType == .xaiOAuth {
            // Merge the refreshed Bearer over the cached headers so any
            // user-supplied custom headers still apply.
            headers = cachedHeaders.merging(try xaiOAuthHeaders()) { _, new in new }
        } else {
            // Headers are resolved once at service creation time (on @MainActor)
            // to avoid Keychain access issues from the actor's background executor.
            headers = cachedHeaders
        }
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // Canonical (sorted-keys) encoder. Remote prompt-prefix caches
        // (ds4, vLLM, sglang, Anthropic prompt cache, ...) hash the
        // rendered prompt — including inlined tool schemas — byte for
        // byte; see `JSONDeterminism.swift` / `docs/JSON_DETERMINISM.md`.
        let encoder = JSONEncoder.osaurusCanonical(prettyPrinted: true)

        let bodyData: Data
        switch requestProviderType {
        case .anthropic:
            let anthropicRequest = request.toAnthropicRequest()
            bodyData = try encoder.encode(anthropicRequest)
        case .openResponses:
            let openResponsesRequest = request.toOpenResponsesRequest()
            bodyData = try encoder.encode(openResponsesRequest)
        case .openAICodex:
            bodyData = try request.toCodexOpenResponsesRequest().toCodexOAuthPayloadData()
        case .gemini:
            let geminiRequest = request.toGeminiRequest()
            bodyData = try encoder.encode(geminiRequest)
        case .openaiLegacy, .azureOpenAI, .osaurus, .osaurusRouter:
            // OpenAI-compat wire. RemoteReasoningPolicy decides how prior-turn
            // reasoning is re-sent: strip (default), keep `reasoning_content`
            // (DeepSeek), or fold it back into `<think>` content (MiniMax).
            var outbound = request
            outbound.messages = RemoteReasoningPolicy.resolve(
                providerType: requestProviderType,
                host: provider.host,
                model: request.model
            ).transformOutbound(outbound.messages)
            if requestProviderType == .osaurusRouter {
                outbound.messages = Self.routerWireCompatibleMessages(outbound.messages)
                outbound.clamp_to_balance = false
            } else {
                // Plain OpenAI-compat upstreams enforce tool pairing both ways
                // ("an assistant message with tool_calls must be followed by
                // tool messages" and "a tool message must follow tool_calls").
                // Collapse same-id duplicates, then drop any orphaned half-pair
                // so a trimmed/over-budget history can't 400 — same backstop the
                // router, Anthropic, and Gemini paths already run.
                outbound.messages = Self.enforcingToolUseResultPairing(
                    Self.mergingDuplicateToolResults(outbound.messages),
                    provider: String(describing: requestProviderType)
                )
            }
            bodyData = try encoder.encode(outbound)
        }
        urlRequest.httpBody = bodyData
        if provider.providerType == .osaurusRouter {
            // The signer hashes `bodyData`, so the `idempotency_key` embedded
            // above is signature-covered (no separate header to protect).
            //
            // Server-side contract (out of this repo, required to fully close
            // double-billing): the router must treat `idempotency_key` as a
            // dedupe key — a repeat POST with the same key returns the original
            // result/charge instead of billing again — and SHOULD echo a stable
            // `request_id` in the summary frame. Until then, the local ledger
            // uses this signed key as its request id for usage correlation.
            try await OsaurusRouterAuthSigner().sign(request: &urlRequest, body: bodyData)
        }
        // Wire-verification capture: record the post-scrub bytes
        // BEFORE we hand them to URLSession. Idempotent inside the
        // probe (only the first write wins) so request retries
        // don't stomp the original snapshot. No-op when no probe
        // is set (every non-chatUI path).
        WireTransportProbe.current?.recordRequestBody(bodyData)
        return urlRequest
    }

    /// Returns a copy of `messages` with `reasoning_content` cleared.
    /// Delegates to `RemoteReasoningPolicy` (the single source of truth).
    static func strippingReasoningContent(
        from messages: [ChatMessage]
    ) -> [ChatMessage] {
        RemoteReasoningPolicy.strippingReasoning(messages)
    }

    /// Collapse consecutive `tool` messages that share a `tool_call_id` into a
    /// single message. Anthropic — and the Osaurus Router fan-out to Claude —
    /// reject more than one `tool_result` per `tool_use_id` ("each tool_use
    /// must have a single result"). Osaurus intentionally emits extra same-id
    /// `tool` turns to carry transient `[System Notice]` feedback (KV-cache
    /// stable; see `AgentToolLoop.appendingTransientNotices`), so the duplicates
    /// are merged here at the remote wire boundary — concatenating their text so
    /// the model still reads the notice — and never in local history.
    ///
    /// Only adjacent same-id results within one run of consecutive `tool`
    /// messages merge; distinct ids in a parallel batch stay separate and the
    /// order is preserved, so Anthropic's "result immediately follows the
    /// tool_use" ordering is never disturbed.
    static func mergingDuplicateToolResults(_ messages: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        result.reserveCapacity(messages.count)
        // Output index of each tool result seen in the CURRENT consecutive run,
        // keyed by tool_call_id. Cleared whenever a non-tool message (or a tool
        // message with no id) breaks the run.
        var indexByCallId: [String: Int] = [:]

        for message in messages {
            guard message.role.lowercased() == "tool",
                let callId = message.tool_call_id
            else {
                indexByCallId.removeAll(keepingCapacity: true)
                result.append(message)
                continue
            }

            if let existingIndex = indexByCallId[callId] {
                let base = result[existingIndex]
                result[existingIndex] = ChatMessage(
                    role: base.role,
                    content: concatenatedToolContent(base.content, message.content),
                    tool_calls: base.tool_calls,
                    tool_call_id: base.tool_call_id,
                    reasoning_content: base.reasoning_content,
                    reasoning_item_id: base.reasoning_item_id,
                    reasoning_encrypted: base.reasoning_encrypted
                )
            } else {
                indexByCallId[callId] = result.count
                result.append(message)
            }
        }
        return result
    }

    private static func concatenatedToolContent(_ first: String?, _ second: String?) -> String? {
        switch (first, second) {
        case let (first?, second?):
            if first.isEmpty { return second }
            if second.isEmpty { return first }
            return first + "\n\n" + second
        case let (first?, nil):
            return first
        case let (nil, second?):
            return second
        case (nil, nil):
            return nil
        }
    }

    /// True when `text` has at least one non-whitespace character. Anthropic
    /// rejects content blocks that are empty OR whitespace-only ("text content
    /// blocks must contain non-whitespace text"), so the assistant text block
    /// and the empty-`tool_result` placeholder gate on this rather than
    /// `isEmpty` alone — a lone `" "` would still trip the 400.
    static func hasMeaningfulText(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The non-whitespace placeholder a truthful empty/nil tool result rides
    /// as. Anthropic and OpenAI Responses both reject empty/whitespace-only
    /// tool output, yet the result must still be emitted to keep its
    /// `tool_use`/`function_call` paired — so an empty result carries this
    /// marker rather than being dropped or fabricated.
    static let emptyToolResultMarker = "(no output)"

    /// Wire text for a tool result: the content when it carries non-whitespace
    /// text, else `emptyToolResultMarker`. Centralizes the empty → marker rule
    /// the Anthropic and Responses encoders share.
    static func toolResultText(_ content: String?) -> String {
        guard hasMeaningfulText(content), let content else { return emptyToolResultMarker }
        return content
    }

    /// Enforce Anthropic's "every `tool_use` is immediately answered by a
    /// matching `tool_result`" invariant at the wire boundary. History
    /// trimming (`ContextBudgetManager`) is the root-cause fix, but a full
    /// context window can still hand us a half-pair; emitting it trips the
    /// HTTP 400 "tool_use ids were found without tool_result blocks
    /// immediately after". This single forward pass repairs orphans by
    /// TRUTHFUL REMOVAL — never by synthesizing tool output (see AGENTS.md):
    ///
    /// - For an `assistant` turn with `tool_calls`, only the calls whose id
    ///   has a matching `tool` result in the immediately-following run of
    ///   tool messages survive; the assistant is re-emitted with exactly
    ///   those calls. If none survive, the assistant is kept only when it
    ///   still carries visible text (tool_calls dropped), else removed.
    /// - A `tool` result whose id isn't claimed by the preceding assistant's
    ///   surviving calls is dropped (orphan result).
    /// - Parallel-tool batches and message order are preserved. Run
    ///   `mergingDuplicateToolResults` FIRST so notice-ride duplicates are
    ///   collapsed into the real result before pairing is judged.
    static func enforcingToolUseResultPairing(
        _ messages: [ChatMessage],
        provider: String = "remote"
    ) -> [ChatMessage] {
        // Re-wrap an assistant turn with a new content/tool_calls pair while
        // carrying its reasoning fields through unchanged.
        func reassembledAssistant(
            _ source: ChatMessage,
            content: String?,
            toolCalls: [ToolCall]?
        ) -> ChatMessage {
            ChatMessage(
                role: source.role,
                content: content,
                tool_calls: toolCalls,
                tool_call_id: source.tool_call_id,
                reasoning_content: source.reasoning_content,
                reasoning_item_id: source.reasoning_item_id,
                reasoning_encrypted: source.reasoning_encrypted
            )
        }

        var result: [ChatMessage] = []
        result.reserveCapacity(messages.count)
        // Diagnostics: count truthful removals so a full-context 400 leaves a
        // breadcrumb in the log instead of a silent repair.
        var droppedToolUse = 0
        var droppedToolResult = 0

        var index = 0
        while index < messages.count {
            let message = messages[index]
            let role = message.role.lowercased()

            // Only an assistant turn that actually requested tools opens a
            // tool_use/tool_result run; everything else is judged on its own.
            guard role == "assistant", let toolCalls = message.tool_calls, !toolCalls.isEmpty else {
                // A `tool` result with no preceding tool_use to claim it is an
                // orphan (its assistant was trimmed away) — drop it. Anything
                // else passes through untouched.
                if role != "tool" {
                    result.append(message)
                } else {
                    droppedToolResult += 1
                }
                index += 1
                continue
            }

            // A TRAILING assistant tool-call turn has no results yet because
            // they simply haven't been appended — it's the latest turn, not a
            // trimmed-away middle orphan (the reported 400 was messages.78 of
            // 128k, deep in the middle). Keep it verbatim: dropping it would
            // discard the model's pending tool request and break the
            // established "keep trailing assistant tool_call turn" contract.
            if index == messages.count - 1 {
                result.append(message)
                break
            }

            // Gather the contiguous run of tool results answering this turn,
            // recording which tool_call_ids actually came back.
            var runEnd = index + 1
            var answeredCallIds = Set<String>()
            while runEnd < messages.count, messages[runEnd].role.lowercased() == "tool" {
                if let callId = messages[runEnd].tool_call_id {
                    answeredCallIds.insert(callId)
                }
                runEnd += 1
            }

            let keptCalls = toolCalls.filter { answeredCallIds.contains($0.id) }
            let keptCallIds = Set(keptCalls.map(\.id))
            droppedToolUse += toolCalls.count - keptCalls.count

            if keptCalls.count == toolCalls.count {
                // Every call is answered — keep the turn (and its carriers) verbatim.
                result.append(message)
            } else if !keptCalls.isEmpty {
                result.append(reassembledAssistant(message, content: message.content, toolCalls: keptCalls))
            } else if let content = message.content, hasMeaningfulText(content) {
                // No call survived but the turn still said something — keep the
                // text, drop the now-unanswerable tool_calls. Whitespace-only
                // content counts as nothing (Anthropic rejects it), so such a
                // turn falls through and is dropped entirely below.
                result.append(reassembledAssistant(message, content: content, toolCalls: nil))
            }
            // else: empty assistant with no surviving calls — drop entirely.

            // Re-emit the run's results in order, keeping only those that
            // answer a surviving call (drops orphan results in the batch).
            for resultIndex in (index + 1) ..< runEnd {
                let toolMessage = messages[resultIndex]
                if let callId = toolMessage.tool_call_id, keptCallIds.contains(callId) {
                    result.append(toolMessage)
                } else {
                    droppedToolResult += 1
                }
            }

            index = runEnd
        }

        if droppedToolUse > 0 || droppedToolResult > 0 {
            wirePairingLogger.warning(
                """
                Repaired tool_use/tool_result pairing before \(provider, privacy: .public) encode: \
                dropped \(droppedToolUse, privacy: .public) orphan tool_use, \
                \(droppedToolResult, privacy: .public) orphan tool_result (truthful removal)
                """
            )
        }
        return result
    }

    /// Router fan-out advertises one OpenAI-compatible request to many
    /// upstreams, so it uses the strictest shared chat-completions history
    /// shape. User media stays multimodal; assistant history leaves Osaurus as
    /// string `content` because several upstreams reject assistant arrays or
    /// omitted assistant content on tool-call turns.
    static func routerWireCompatibleMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        // Collapse same-id tool results FIRST: the router fans out to Claude,
        // which rejects more than one tool_result per tool_use_id. THEN drop
        // any orphaned tool_use/tool_result half-pair (also a Claude 400) so
        // the fan-out target never sees a dangling tool call.
        let deduped = enforcingToolUseResultPairing(
            mergingDuplicateToolResults(messages),
            provider: "osaurusRouter"
        )
        let wireMessages = routerMessagesDroppingUnsupportedAssistantPrefill(deduped)
        return wireMessages.map { message in
            guard requiresRouterAssistantStringContent(message) else { return message }
            return routerAssistantWireMessage(message)
        }
    }

    private static func routerMessagesDroppingUnsupportedAssistantPrefill(
        _ messages: [ChatMessage]
    ) -> [ChatMessage] {
        guard let last = messages.last,
            isUnsupportedRouterAssistantPrefill(last)
        else { return messages }
        return Array(messages.dropLast())
    }

    private static func isUnsupportedRouterAssistantPrefill(_ message: ChatMessage) -> Bool {
        message.role.lowercased() == "assistant"
            && (message.tool_calls?.isEmpty ?? true)
            && message.tool_call_id == nil
    }

    private static func requiresRouterAssistantStringContent(_ message: ChatMessage) -> Bool {
        message.role.lowercased() == "assistant" && (message.contentParts != nil || message.content == nil)
    }

    private static func routerAssistantWireMessage(_ message: ChatMessage) -> ChatMessage {
        ChatMessage(
            role: message.role,
            content: message.content ?? "",
            tool_calls: message.tool_calls,
            tool_call_id: message.tool_call_id,
            reasoning_content: message.reasoning_content,
            reasoning_item_id: message.reasoning_item_id,
            reasoning_encrypted: message.reasoning_encrypted
        )
    }

    /// Parse response based on provider type
    static func parseResponse(
        _ data: Data,
        providerType: RemoteProviderType
    ) throws -> (content: String?, toolCalls: [ToolCall]?) {
        switch providerType {
        case .anthropic:
            let response = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)
            // Same prompt-caching telemetry as the streaming `message_start`
            // handler, for the non-streaming path.
            debugLog(
                "[Cache][Anthropic] input=\(response.usage.input_tokens)"
                    + " cacheRead=\(response.usage.cache_read_input_tokens ?? 0)"
                    + " cacheWrite=\(response.usage.cache_creation_input_tokens ?? 0)"
            )
            var textContent = ""
            var toolCalls: [ToolCall] = []

            for block in response.content {
                switch block {
                case .text(_, let text):
                    textContent += text
                case .toolUse(_, let id, let name, let input):
                    // Sorted keys: replayed into next-turn
                    // `tool_calls[].function.arguments`.
                    let argsData = try? JSONSerialization.data(
                        withJSONObject: input.mapValues { $0.value },
                        options: .osaurusCanonical
                    )
                    let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    toolCalls.append(
                        ToolCall(
                            id: id,
                            type: "function",
                            function: ToolCallFunction(name: name, arguments: argsString)
                        )
                    )
                }
            }

            return (textContent.isEmpty ? nil : textContent, toolCalls.isEmpty ? nil : toolCalls)

        case .openaiLegacy, .azureOpenAI, .osaurusRouter:
            return try Self.parseOpenAICompatibleChatCompletion(data)

        case .openResponses, .openAICodex:
            let response = try JSONDecoder().decode(OpenResponsesResponse.self, from: data)
            var textContent = ""
            var toolCalls: [ToolCall] = []

            for item in response.output {
                switch item {
                case .message(let message):
                    for content in message.content {
                        if case .outputText(let text) = content {
                            textContent += text.text
                        }
                    }
                case .functionCall(let funcCall):
                    toolCalls.append(
                        ToolCall(
                            id: funcCall.call_id,
                            type: "function",
                            function: ToolCallFunction(name: funcCall.name, arguments: funcCall.arguments)
                        )
                    )
                case .reasoning:
                    // Reasoning summary text is forwarded via
                    // `StreamingReasoningHint` on the streaming path; in
                    // the non-streaming aggregation we drop it (no
                    // `reasoning_content` field on `ChatMessage`).
                    continue
                }
            }

            return (textContent.isEmpty ? nil : textContent, toolCalls.isEmpty ? nil : toolCalls)

        case .gemini:
            let response = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
            var textContent = ""
            var toolCalls: [ToolCall] = []

            if let parts = response.candidates?.first?.content?.parts {
                for part in parts {
                    if part.thought == true { continue }

                    switch part.content {
                    case .text(let text):
                        textContent += Self.encodeTextWithSignature(text, signature: part.thoughtSignature)
                    case .functionCall(let funcCall):
                        toolCalls.append(
                            ToolCall(
                                id: Self.geminiToolCallId(),
                                type: "function",
                                function: ToolCallFunction(
                                    name: funcCall.name,
                                    arguments: Self.geminiArgsJSON(from: funcCall.args)
                                ),
                                geminiThoughtSignature: funcCall.thoughtSignature
                            )
                        )
                    case .inlineData(let imageData):
                        textContent += Self.imageMarkdown(imageData, thoughtSignature: part.thoughtSignature)
                    case .functionResponse:
                        break  // Not expected in responses from model
                    }
                }
            }

            return (textContent.isEmpty ? nil : textContent, toolCalls.isEmpty ? nil : toolCalls)

        case .osaurus:
            // Native Osaurus agents execute tools server-side and expose only
            // text deltas to this client, so no client-dispatched tool_calls
            // are returned from the legacy peer endpoint.
            let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let content = response.choices.first?.message.content
            return (content, nil)
        }
    }

    static func parseOpenAICompatibleChatCompletion(
        _ data: Data
    ) throws -> (content: String?, toolCalls: [ToolCall]?) {
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let message = response.choices.first?.message
        return (message?.content, message?.tool_calls)
    }

    // MARK: - Thought-Signature Round-Trip Helpers

    /// Embed a thought-signature in text via invisible ZWS delimiters: `\u{200B}ts:SIG\u{200B}`.
    static func encodeTextWithSignature(_ text: String, signature: String?) -> String {
        guard let sig = signature else { return text }
        return "\u{200B}ts:\(sig)\u{200B}" + text
    }

    /// Build markdown for an inline image, embedding the thought-signature in the alt text.
    static func imageMarkdown(_ data: GeminiInlineData, thoughtSignature: String?) -> String {
        let alt = thoughtSignature.map { "image|ts:\($0)" } ?? "image"
        return "\n\n![\(alt)](data:\(data.mimeType);base64,\(data.data))\n\n"
    }

    /// Strip a ZWS-delimited thought-signature marker from the start of a text segment.
    private static func stripTextSignature(_ text: String) -> (text: String, thoughtSignature: String?) {
        let prefix = "\u{200B}ts:"
        guard text.hasPrefix(prefix) else { return (text, nil) }
        let rest = text.dropFirst(prefix.count)
        guard let end = rest.firstIndex(of: "\u{200B}") else { return (text, nil) }
        return (String(rest[rest.index(after: end)...]), String(rest[rest.startIndex ..< end]))
    }

    /// Split assistant text into `GeminiPart` array, converting data-URI images to
    /// `inlineData` parts and recovering thought-signatures from both image alt-text
    /// markers (`image|ts:SIG`) and text ZWS markers.
    static func extractInlineImages(from text: String) -> [GeminiPart] {
        let pattern = #"!\[([^\]]*)\]\(data:([^;]+);base64,([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
            !regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).isEmpty
        else {
            let (cleaned, sig) = stripTextSignature(text)
            return [GeminiPart(content: .text(cleaned), thoughtSignature: sig)]
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var parts: [GeminiPart] = []
        var lastEnd = 0

        for match in matches {
            let matchRange = match.range

            if matchRange.location > lastEnd {
                let before = nsText.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))
                let (cleaned, sig) = stripTextSignature(before)
                if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(GeminiPart(content: .text(cleaned), thoughtSignature: sig))
                }
            }

            if let altRange = Range(match.range(at: 1), in: text),
                let mimeRange = Range(match.range(at: 2), in: text),
                let dataRange = Range(match.range(at: 3), in: text)
            {
                let altText = String(text[altRange])
                let sig: String? =
                    altText.hasPrefix("image|ts:")
                    ? String(altText.dropFirst("image|ts:".count)) : nil
                parts.append(
                    GeminiPart(
                        content: .inlineData(
                            GeminiInlineData(
                                mimeType: String(text[mimeRange]),
                                data: String(text[dataRange])
                            )
                        ),
                        thoughtSignature: sig
                    )
                )
            }

            lastEnd = matchRange.location + matchRange.length
        }

        if lastEnd < nsText.length {
            let after = nsText.substring(from: lastEnd)
            if !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(.text(after))
            }
        }

        return parts.isEmpty ? [.text(text)] : parts
    }
}

// MARK: - Helper for Anthropic SSE Event Type Detection

/// Simple struct to decode Anthropic SSE event type
private struct AnthropicSSEEvent: Decodable {
    let type: String
}

/// Decodes the `stop_details` payload of an Anthropic `message_delta`
/// carrying `stop_reason: "refusal"` — the shared `MessageDeltaEvent`
/// model is also used by the server-side Anthropic-compat writer, so the
/// refusal-only field stays in this private decode-side shape.
private struct AnthropicRefusalDeltaEvent: Decodable {
    let delta: Delta

    struct Delta: Decodable {
        let stop_details: StopDetails?

        struct StopDetails: Decodable {
            let explanation: String?
        }
    }
}

/// Decodes an Anthropic mid-stream `error` event payload, e.g.
/// `{"type":"error","error":{"type":"overloaded_error","message":"..."}}`.
struct AnthropicStreamErrorEvent: Decodable {
    let type: String
    let error: ErrorDetail

    struct ErrorDetail: Decodable {
        let type: String
        let message: String
    }
}

// MARK: - Helper for Open Responses SSE Event Type Detection

/// Simple struct to decode Open Responses SSE event type
private struct OpenResponsesSSEEvent: Decodable {
    let type: String
}

// MARK: - Request/Response Models for Remote Provider

/// Reasoning configuration for OpenAI reasoning models (o-series, gpt-5+).
struct ReasoningConfig: Encodable {
    let effort: String
}

/// DeepSeek's thinking-mode toggle. Sent as a top-level `thinking` object
/// with `type` of `"enabled"` or `"disabled"`. DeepSeek's public chat API
/// does NOT accept `reasoning_effort: "instruct"` (only `high`/`max` plus
/// the deprecated `low`/`medium`/`xhigh` aliases), so we translate the
/// local DSV4 `instruct` mode into `thinking.type == "disabled"`.
struct ThinkingConfig: Encodable, Equatable {
    let type: String
}

// Venice-specific parameters injected into the request body for Venice AI providers.
// See https://docs.venice.ai/api-reference/api-spec
// Nil values intentionally omit provider-specific flags from the encoded JSON.
// swiftlint:disable discouraged_optional_boolean
struct VeniceParameters: Encodable {
    var enable_web_search: String?
    var disable_thinking: Bool?
    var include_venice_system_prompt: Bool?
}
// swiftlint:enable discouraged_optional_boolean

/// Chat request structure for remote providers (matches OpenAI format)
struct RemoteChatRequest: Encodable {
    let model: String
    /// `var` so the transport layer can strip `reasoning_content` from
    /// assistant messages for providers that don't expect it (see
    /// `echoesReasoningContent`).
    var messages: [ChatMessage]
    let temperature: Float?
    /// Canonical token-cap field. Named after OpenAI's newer parameter; the
    /// on-the-wire key is chosen in `encode(to:)` based on the model — see
    /// the block below for the Mistral / OpenAI-compat rationale.
    let max_completion_tokens: Int?
    let stream: Bool
    let top_p: Float?
    let frequency_penalty: Float?
    let presence_penalty: Float?
    var stop: [String]?
    let tools: [Tool]?
    let tool_choice: ToolChoiceOption?
    let reasoning_effort: String?
    let reasoning: ReasoningConfig?
    /// DeepSeek-only thinking-mode toggle (see `ThinkingConfig`). Encoded
    /// only when non-nil so other OpenAI-compat providers never see an
    /// unknown `thinking` field (which 422s on strict schemas).
    let thinking: ThinkingConfig?
    let modelOptions: [String: ModelOptionValue]
    let veniceParameters: VeniceParameters?
    /// Router-only billing behavior. `false` keeps insufficient-balance
    /// requests explicit (402) instead of silently shrinking the token cap.
    var clamp_to_balance: Bool? = nil
    /// Router-only idempotency token. Stable across connect-phase and transient
    /// agent-loop retries of the same logical step so the router can dedupe
    /// billing on a re-POST. Lives in the body so it's covered by the request
    /// signature. Only ever set for `.osaurusRouter` (see `buildChatRequest`),
    /// so other OpenAI-compat upstreams never see an unknown field.
    var idempotencyKey: String? = nil
    /// OpenAI `stream_options`. Set (in `buildChatRequest`) only for *streaming*
    /// requests to OpenAI Chat-Completions upstreams that honor it (see
    /// `requestsStreamUsageOptions`), so the provider emits a final `usage`
    /// chunk we surface as completion-token telemetry (`include_usage`). Encoded
    /// only when non-nil, so every other provider/path keeps its exact current
    /// wire bytes (the non-streaming path and Anthropic/Gemini/Responses, which
    /// build their own bodies, never set it).
    var streamOptions: StreamOptions? = nil
    /// OpenAI `prompt_cache_key`: session-scoped routing hint that improves
    /// upstream prompt-cache hit rates (OpenAI auto-caches >=1024-token
    /// prefixes; the key routes same-session requests to the same cache
    /// shard). Set (in `buildChatRequest`) only for genuine OpenAI hosts (see
    /// `supportsPromptCacheKey`) so strict third-party OpenAI-compat schemas
    /// never see an unknown field. Encoded only when non-nil.
    var promptCacheKey: String? = nil
    /// Local-only routing marker (Mode 2). When true, `buildURLRequest` targets
    /// the peer's `/agents/{address}/run` endpoint instead of
    /// `/chat/completions`. Intentionally absent from `CodingKeys` so it never
    /// reaches the wire — the endpoint choice already encodes the intent.
    var runAsRemoteAgent: Bool = false

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, max_completion_tokens, max_tokens, stream
        case top_p, frequency_penalty, presence_penalty, stop, tools, tool_choice
        case reasoning_effort
        case reasoning
        case thinking
        case clamp_to_balance
        case idempotencyKey = "idempotency_key"
        case veniceParameters = "venice_parameters"
        case streamOptions = "stream_options"
        case promptCacheKey = "prompt_cache_key"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Mode 2 (remote agent run): omit `model` entirely. The peer resolves
        // the agent's own effective model server-side; sending any caller-side
        // model — even the "default" sentinel — is wrong and previously leaked
        // to a mis-routed upstream as an opaque 404 ("Model default not
        // found"). The endpoint choice (/agents/{address}/run) already encodes
        // the intent. Every other path keeps its exact current wire bytes.
        if !runAsRemoteAgent {
            try container.encode(model, forKey: .model)
        }
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(temperature, forKey: .temperature)

        // OpenAI-compatible endpoints disagree on the token-cap key:
        //   - OpenAI's o1/o3/o4/gpt-5 reasoning models REQUIRE
        //     `max_completion_tokens` and reject `max_tokens`.
        //   - Mistral, OpenRouter, DeepSeek, Groq, Azure, and most other
        //     "OpenAI-compatible" schemas are strict and reject
        //     `max_completion_tokens` with a 422 (issue #556).
        //   - OpenAI's own non-reasoning models accept BOTH names.
        // Emit the widely-accepted `max_tokens` by default and only switch
        // to `max_completion_tokens` for reasoning-model IDs, which are
        // identified by prefix and don't collide with third-party
        // provider naming.
        if OpenAIReasoningProfile.matches(modelId: model) {
            try container.encodeIfPresent(
                max_completion_tokens,
                forKey: .max_completion_tokens
            )
        } else {
            try container.encodeIfPresent(max_completion_tokens, forKey: .max_tokens)
        }

        try container.encode(stream, forKey: .stream)
        try container.encodeIfPresent(top_p, forKey: .top_p)
        try container.encodeIfPresent(frequency_penalty, forKey: .frequency_penalty)
        try container.encodeIfPresent(presence_penalty, forKey: .presence_penalty)
        try container.encodeIfPresent(stop, forKey: .stop)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(tool_choice, forKey: .tool_choice)
        try container.encodeIfPresent(reasoning_effort, forKey: .reasoning_effort)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(thinking, forKey: .thinking)
        try container.encodeIfPresent(clamp_to_balance, forKey: .clamp_to_balance)
        try container.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
        try container.encodeIfPresent(veniceParameters, forKey: .veniceParameters)
        try container.encodeIfPresent(streamOptions, forKey: .streamOptions)
        try container.encodeIfPresent(promptCacheKey, forKey: .promptCacheKey)
        // `modelOptions` is intentionally not in `CodingKeys` — it stays
        // in-process for model-specific feature flags.
    }

    /// Convert to Anthropic Messages API request format
    func toAnthropicRequest() -> AnthropicMessagesRequest {
        var systemContent: AnthropicSystemContent?
        var anthropicMessages: [AnthropicMessage] = []

        // Collect consecutive tool_result blocks to batch them into a single user message
        // Anthropic requires all tool_results for a tool_use to be in the immediately following user message
        var pendingToolResults: [AnthropicContentBlock] = []

        // Helper to flush pending tool results into a single user message
        func flushToolResults() {
            if !pendingToolResults.isEmpty {
                anthropicMessages.append(
                    AnthropicMessage(
                        role: "user",
                        content: .blocks(pendingToolResults)
                    )
                )
                pendingToolResults = []
            }
        }

        // Collapse same-id tool results so each tool_use_id yields exactly one
        // tool_result block (Anthropic rejects duplicates), THEN drop any
        // tool_use left without its tool_result (or vice-versa) so a trimmed
        // half-pair can't trip the "tool_use ids ... without tool_result"
        // 400. Pairing runs after the merge so a notice-ride duplicate is
        // folded into the real result before the pairing check.
        let pairedMessages = RemoteProviderService.enforcingToolUseResultPairing(
            RemoteProviderService.mergingDuplicateToolResults(messages),
            provider: "anthropic"
        )
        for msg in pairedMessages {
            switch msg.role {
            case "system":
                // Flush any pending tool results before system message
                flushToolResults()
                // Collect system messages
                if let content = msg.content {
                    systemContent = .text(content)
                }

            case "user":
                // Flush any pending tool results before user message
                flushToolResults()
                // Convert user messages
                if let content = msg.content {
                    anthropicMessages.append(
                        AnthropicMessage(
                            role: "user",
                            content: .text(content)
                        )
                    )
                }

            case "assistant":
                // Flush any pending tool results before assistant message
                flushToolResults()
                // Convert assistant messages, including tool calls
                var blocks: [AnthropicContentBlock] = []

                if let content = msg.content, RemoteProviderService.hasMeaningfulText(content) {
                    blocks.append(.text(AnthropicTextBlock(text: content)))
                }

                if let toolCalls = msg.tool_calls {
                    for toolCall in toolCalls {
                        var input: [String: AnyCodableValue] = [:]

                        if let argsData = toolCall.function.arguments.data(using: .utf8),
                            let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                        {
                            input = argsDict.mapValues { AnyCodableValue($0) }
                        }

                        blocks.append(
                            .toolUse(
                                AnthropicToolUseBlock(
                                    id: toolCall.id,
                                    name: toolCall.function.name,
                                    input: input
                                )
                            )
                        )
                    }
                }

                if !blocks.isEmpty {
                    anthropicMessages.append(
                        AnthropicMessage(
                            role: "assistant",
                            content: .blocks(blocks)
                        )
                    )
                }

            case "tool":
                // Collect tool results - they will be batched into a single user message
                // when we encounter a non-tool message or reach the end.
                //
                // ALWAYS emit when a tool_call_id is present, even for nil/empty
                // content: silently skipping it would orphan the matching
                // tool_use and trip the Anthropic 400. `toolResultText` supplies
                // a non-whitespace marker for an empty result.
                if let toolCallId = msg.tool_call_id {
                    let resultText = RemoteProviderService.toolResultText(msg.content)
                    pendingToolResults.append(
                        .toolResult(
                            AnthropicToolResultBlock(
                                type: "tool_result",
                                tool_use_id: toolCallId,
                                content: .text(resultText),
                                is_error: nil
                            )
                        )
                    )
                }
            default:
                // Flush any pending tool results before unknown message type
                flushToolResults()
            }
        }

        // Flush any remaining tool results at the end
        flushToolResults()

        // Convert tools
        let emptySchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])
        var anthropicTools: [AnthropicTool]?
        if let tools = tools {
            anthropicTools = tools.map { tool in
                AnthropicTool(
                    name: tool.function.name,
                    description: tool.function.description,
                    input_schema: tool.function.parameters ?? emptySchema
                )
            }
        }

        // Convert tool choice
        var anthropicToolChoice: AnthropicToolChoice?
        if let choice = tool_choice {
            switch choice {
            case .auto:
                anthropicToolChoice = .auto
            case .none:
                anthropicToolChoice = AnthropicToolChoice.none
            case .required:
                anthropicToolChoice = .any
            case .function(let fn):
                anthropicToolChoice = .tool(name: fn.function.name)
            }
        }

        // The newer adaptive-thinking Claude generations reject sampler knobs
        // outright — HTTP 400 "`temperature` is deprecated for this model."
        // (observed live on claude-fable-5 and claude-opus-4-8). Omit them so
        // the model runs on its native defaults instead of failing the whole
        // request. Older dated snapshots (claude-sonnet-4-5, claude-haiku-4-5,
        // …) still accept the knobs, so match only the affected families by
        // prefix rather than stripping for every Claude model.
        let bareModel =
            model.lowercased().split(separator: "/").last.map(String.init)
            ?? model.lowercased()
        let knobDeprecatingClaudePrefixes = [
            "claude-fable", "claude-mythos",
            "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
            "claude-sonnet-4-6",
        ]
        let deprecatesSamplerKnobs = knobDeprecatingClaudePrefixes.contains {
            bareModel.hasPrefix($0)
        }

        return AnthropicMessagesRequest(
            model: model,
            max_tokens: max_completion_tokens ?? 4096,
            system: systemContent,
            messages: anthropicMessages,
            stream: stream,
            temperature: deprecatesSamplerKnobs ? nil : temperature.map { Double($0) },
            top_p: deprecatesSamplerKnobs ? nil : top_p.map { Double($0) },
            top_k: nil,
            stop_sequences: stop,
            tools: anthropicTools,
            tool_choice: anthropicToolChoice,
            metadata: nil,
            // Top-level automatic prompt caching: Anthropic puts the cache
            // breakpoint on the last cacheable block and advances it as the
            // conversation grows, so multi-turn sessions re-read the whole
            // prefix at 0.1x input price instead of re-paying full rate every
            // turn. Safe to send unconditionally — the canonical JSON encoder
            // already guarantees byte-stable prefixes across turns, and
            // requests below the model's minimum cacheable length are simply
            // processed uncached.
            cache_control: AnthropicCacheControl()
        )
    }

    /// Convert to Gemini GenerateContent API request format
    func toGeminiRequest() -> GeminiGenerateContentRequest {
        var geminiContents: [GeminiContent] = []
        var systemInstruction: GeminiContent?

        // Collect consecutive function responses to batch them
        var pendingFunctionResponses: [GeminiPart] = []

        // Helper to flush pending function responses into a user content
        func flushFunctionResponses() {
            if !pendingFunctionResponses.isEmpty {
                geminiContents.append(GeminiContent(role: "user", parts: pendingFunctionResponses))
                pendingFunctionResponses = []
            }
        }

        // Collapse same-id tool results so a repeated tool_call_id maps to a
        // single functionResponse instead of duplicates, then drop any
        // orphaned tool_use/tool_result half-pair for parity with the
        // Anthropic path (Gemini likewise requires functionResponse to follow
        // functionCall).
        for msg in RemoteProviderService.enforcingToolUseResultPairing(
            RemoteProviderService.mergingDuplicateToolResults(messages),
            provider: "gemini"
        ) {
            switch msg.role {
            case "system":
                // System messages become systemInstruction
                if let content = msg.content {
                    systemInstruction = GeminiContent(parts: [.text(content)])
                }

            case "user":
                flushFunctionResponses()
                var userParts: [GeminiPart] = []

                // Add text content
                if let content = msg.content, !content.isEmpty {
                    userParts.append(.text(content))
                }

                // Add image content from contentParts
                if let parts = msg.contentParts {
                    for part in parts {
                        if case .imageUrl(let url, _) = part {
                            // Parse data URLs: "data:<mimeType>;base64,<data>"
                            if url.hasPrefix("data:"),
                                let semicolonIdx = url.firstIndex(of: ";"),
                                let commaIdx = url.firstIndex(of: ",")
                            {
                                let mimeType = String(url[url.index(url.startIndex, offsetBy: 5) ..< semicolonIdx])
                                let base64Data = String(url[url.index(after: commaIdx)...])
                                userParts.append(
                                    .inlineData(GeminiInlineData(mimeType: mimeType, data: base64Data))
                                )
                            }
                        }
                    }
                }

                if !userParts.isEmpty {
                    geminiContents.append(GeminiContent(role: "user", parts: userParts))
                }

            case "assistant":
                flushFunctionResponses()
                var parts: [GeminiPart] = []

                if let content = msg.content, !content.isEmpty {
                    // Split text and embedded data-URI images into separate parts
                    // so the Gemini API receives images as inlineData (not markdown text)
                    let extracted = RemoteProviderService.extractInlineImages(from: content)
                    parts.append(contentsOf: extracted)
                }

                if let toolCalls = msg.tool_calls {
                    for toolCall in toolCalls {
                        var args: [String: AnyCodableValue] = [:]
                        if let argsData = toolCall.function.arguments.data(using: .utf8),
                            let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                        {
                            args = argsDict.mapValues { AnyCodableValue($0) }
                        }
                        parts.append(
                            .functionCall(
                                GeminiFunctionCall(
                                    name: toolCall.function.name,
                                    args: args,
                                    thoughtSignature: toolCall.geminiThoughtSignature
                                )
                            )
                        )
                    }
                }

                if !parts.isEmpty {
                    geminiContents.append(GeminiContent(role: "model", parts: parts))
                }

            case "tool":
                // Tool results become functionResponse parts in a user message
                if let content = msg.content {
                    // Use the tool_call_id to find the function name, or use a placeholder
                    let funcName = msg.tool_call_id ?? "function"
                    var responseData: [String: AnyCodableValue] = [:]

                    // Try to parse the content as JSON first
                    if let data = content.data(using: .utf8),
                        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    {
                        responseData = json.mapValues { AnyCodableValue($0) }
                    } else {
                        responseData["result"] = AnyCodableValue(content)
                    }

                    pendingFunctionResponses.append(
                        .functionResponse(GeminiFunctionResponse(name: funcName, response: responseData))
                    )
                }

            default:
                flushFunctionResponses()
                if let content = msg.content {
                    geminiContents.append(GeminiContent(role: "user", parts: [.text(content)]))
                }
            }
        }

        // Flush any remaining function responses
        flushFunctionResponses()

        // Convert tools
        var geminiTools: [GeminiTool]?
        if let tools = tools, !tools.isEmpty {
            let declarations = tools.map { tool in
                GeminiFunctionDeclaration(
                    name: tool.function.name,
                    description: tool.function.description,
                    parameters: Self.geminiCompatibleToolParameters(tool.function.parameters)
                )
            }
            geminiTools = [GeminiTool(functionDeclarations: declarations)]
        }

        // Convert tool choice
        var toolConfig: GeminiToolConfig?
        if let choice = tool_choice {
            let mode: String
            switch choice {
            case .auto:
                mode = "AUTO"
            case .none:
                mode = "NONE"
            case .required, .function:
                mode = "ANY"
            }
            toolConfig = GeminiToolConfig(
                functionCallingConfig: GeminiFunctionCallingConfig(mode: mode)
            )
        }

        // Build generation config, using the model profile for image-capable models
        let isImageCapable = RemoteProviderService.isImageCapableModel(model)
        let responseModalities: [String]? = {
            guard isImageCapable else { return nil }
            if modelOptions["outputType"]?.stringValue == "imageOnly" {
                return ["IMAGE"]
            }
            return ["TEXT", "IMAGE"]
        }()

        let imageConfig: GeminiImageConfig? = {
            guard isImageCapable else { return nil }
            let ratio = modelOptions["aspectRatio"]?.stringValue
            let size = modelOptions["imageSize"]?.stringValue
            let effectiveRatio = (ratio == "auto") ? nil : ratio
            let effectiveSize = (size == "auto") ? nil : size
            guard effectiveRatio != nil || effectiveSize != nil else { return nil }
            return GeminiImageConfig(aspectRatio: effectiveRatio, imageSize: effectiveSize)
        }()

        var generationConfig: GeminiGenerationConfig?
        if temperature != nil || max_completion_tokens != nil || top_p != nil || stop != nil
            || responseModalities != nil || imageConfig != nil
        {
            generationConfig = GeminiGenerationConfig(
                temperature: temperature.map { Double($0) },
                maxOutputTokens: max_completion_tokens,
                topP: top_p.map { Double($0) },
                topK: nil,
                stopSequences: stop,
                responseModalities: responseModalities,
                imageConfig: imageConfig
            )
        }

        return GeminiGenerateContentRequest(
            contents: geminiContents,
            tools: geminiTools,
            toolConfig: toolConfig,
            systemInstruction: systemInstruction,
            generationConfig: generationConfig,
            safetySettings: nil
        )
    }

    private static func geminiCompatibleToolParameters(_ parameters: JSONValue?) -> JSONValue? {
        parameters.map(geminiCompatibleSchema)
    }

    /// JSON Schema keywords Gemini's OpenAPI 3.0 validator either rejects (HTTP
    /// 400) or silently ignores. Stripped before send so MCP tool schemas don't
    /// poison the request.
    ///
    /// Allowlist (kept, for reference): `type`, `description`, `enum`, `format`,
    /// `items`, `properties`, `required`, `propertyOrdering`, `nullable`,
    /// `anyOf`, `minimum`, `maximum`, `minItems`, `maxItems`.
    private static let geminiUnsupportedSchemaKeys: Set<String> = [
        // Rejected outright
        "additionalProperties",
        "$ref", "$defs", "$schema", "$id", "definitions",
        "const", "oneOf", "allOf", "not", "if", "then", "else",
        "patternProperties", "propertyNames",
        "contentEncoding", "contentMediaType",
        // Silently ignored — drop to keep payload small and intent clear
        "default", "examples", "title", "readOnly", "writeOnly",
        "pattern", "multipleOf", "uniqueItems",
        "exclusiveMinimum", "exclusiveMaximum",
        "minLength", "maxLength",
    ]

    /// Single funnel for everything Gemini needs done to OpenAI/MCP tool schemas
    /// before they go out on the wire. Recurses children bottom-up, then applies
    /// node-level fixups in a fixed order: union normalization runs before object
    /// inference (so the type check sees a scalar), inference runs before
    /// non-object stripping, and required-filtering runs last on whatever type
    /// survived.
    private static func geminiCompatibleSchema(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var sanitized: [String: JSONValue] = [:]
            for (key, child) in object where !geminiUnsupportedSchemaKeys.contains(key) {
                sanitized[key] = geminiCompatibleSchema(child)
            }

            normalizeNullableTypeUnion(&sanitized)
            inferObjectTypeIfPropertiesPresent(&sanitized)
            stripObjectShapeFromNonObjectTypes(&sanitized)
            filterRequiredAgainstProperties(&sanitized)

            return .object(sanitized)
        case .array(let array):
            return .array(array.map(geminiCompatibleSchema))
        case .string, .number, .bool, .null:
            return value
        }
    }

    /// `type: ["string", "null"]` → `type: "string"` + `nullable: true`. Gemini
    /// rejects array-typed unions but accepts the OpenAPI 3.0 `nullable` boolean.
    /// Bails on multi-type unions (`["string","number","null"]`) — no lossless
    /// translation exists.
    private static func normalizeNullableTypeUnion(_ object: inout [String: JSONValue]) {
        guard case .array(let entries) = object["type"] else { return }

        var hasNull = false
        var scalar: String?
        for entry in entries {
            guard case .string(let s) = entry else { return }
            if s == "null" {
                hasNull = true
            } else if scalar == nil {
                scalar = s
            } else {
                return
            }
        }

        guard hasNull, let scalar else { return }
        object["type"] = .string(scalar)
        object["nullable"] = .bool(true)
    }

    /// Notion-style MCP nested schemas carry `properties`/`required` without an
    /// explicit `type`. Gemini then complains the keys are "only allowed for
    /// OBJECT type". See opencode PR #13150.
    private static func inferObjectTypeIfPropertiesPresent(_ object: inout [String: JSONValue]) {
        guard object["type"] == nil else { return }
        if object["properties"] != nil || object["required"] != nil {
            object["type"] = .string("object")
        }
    }

    /// `properties` and `required` are only valid on object types — Gemini
    /// rejects them on `string`, `array`, etc. See opencode PR #11888.
    private static func stripObjectShapeFromNonObjectTypes(_ object: inout [String: JSONValue]) {
        guard case .string(let typeString) = object["type"], typeString.lowercased() != "object" else {
            return
        }
        object["properties"] = nil
        object["required"] = nil
    }

    /// Direct fix for `required[i]: property is not defined` (opencode #3140):
    /// drop entries that don't reference a declared property. Empty result drops
    /// the key entirely so we don't emit a redundant empty array.
    private static func filterRequiredAgainstProperties(_ object: inout [String: JSONValue]) {
        guard case .array(let required) = object["required"] else { return }

        let declared: Set<String> = {
            guard case .object(let properties) = object["properties"] else { return [] }
            return Set(properties.keys)
        }()

        let filtered = required.filter { entry in
            guard case .string(let name) = entry else { return false }
            return declared.contains(name)
        }

        guard filtered.count < required.count else { return }
        object["required"] = filtered.isEmpty ? nil : .array(filtered)
    }

    /// Convert to Open Responses API request format
    func toOpenResponsesRequest(alwaysUseInputItems: Bool = false) -> OpenResponsesRequest {
        var inputItems: [OpenResponsesInputItem] = []
        var instructions: String?

        // Responses pairs function_call <-> function_call_output by call_id; an
        // unmatched item 400s ("No tool call found for function call output" /
        // "No tool output found for function call"). Collapse same-id duplicates
        // then drop orphaned half-pairs first, mirroring the Anthropic, Gemini,
        // and OpenAI-compat paths.
        let pairedMessages = RemoteProviderService.enforcingToolUseResultPairing(
            RemoteProviderService.mergingDuplicateToolResults(messages),
            provider: "openResponses"
        )
        for msg in pairedMessages {
            switch msg.role {
            case "system":
                // System messages become instructions
                if let content = msg.content {
                    if let existing = instructions {
                        instructions = existing + "\n" + content
                    } else {
                        instructions = content
                    }
                }

            case "user":
                // User messages become message input items
                if let content = msg.content {
                    let msgContent = OpenResponsesMessageContent.text(content)
                    inputItems.append(.message(OpenResponsesMessageItem(role: "user", content: msgContent)))
                }

            case "assistant":
                if let toolCalls = msg.tool_calls, !toolCalls.isEmpty {
                    // Emit any text content first
                    if let content = msg.content, !content.isEmpty {
                        let msgContent = OpenResponsesMessageContent.text(content)
                        inputItems.append(.message(OpenResponsesMessageItem(role: "assistant", content: msgContent)))
                    }
                    // Re-emit the captured reasoning item immediately before its
                    // function_call(s) so a reasoning model resumes its chain
                    // instead of re-deriving it. Only populated on the Responses
                    // path (store:false + include reasoning.encrypted_content).
                    if let itemId = msg.reasoning_item_id, let encrypted = msg.reasoning_encrypted {
                        inputItems.append(
                            .reasoning(
                                OpenResponsesReasoningInputItem(
                                    id: itemId,
                                    encryptedContent: encrypted
                                )
                            )
                        )
                    }
                    // Each tool call becomes a function_call input item so the following
                    // function_call_output items have a matching call_id to reference.
                    for tc in toolCalls {
                        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                        let itemId = "fc_" + String(raw.prefix(24))
                        inputItems.append(
                            .functionCall(
                                OpenResponsesFunctionCall(
                                    id: itemId,
                                    status: .completed,
                                    callId: tc.id,
                                    name: tc.function.name,
                                    arguments: tc.function.arguments
                                )
                            )
                        )
                    }
                } else if let content = msg.content {
                    // Re-emit the captured reasoning item before the assistant
                    // text message too (not only before function_calls), so a
                    // reasoning model resumes its chain on plain-answer turns.
                    if let itemId = msg.reasoning_item_id, let encrypted = msg.reasoning_encrypted {
                        inputItems.append(
                            .reasoning(
                                OpenResponsesReasoningInputItem(
                                    id: itemId,
                                    encryptedContent: encrypted
                                )
                            )
                        )
                    }
                    let msgContent = OpenResponsesMessageContent.text(content)
                    inputItems.append(.message(OpenResponsesMessageItem(role: "assistant", content: msgContent)))
                }

            case "tool":
                // Tool results become function_call_output items. ALWAYS emit
                // when a call_id is present — skipping a nil/empty result would
                // re-orphan its function_call. `toolResultText` supplies a
                // non-whitespace marker for an empty result.
                if let toolCallId = msg.tool_call_id {
                    let output = RemoteProviderService.toolResultText(msg.content)
                    inputItems.append(
                        .functionCallOutput(
                            OpenResponsesFunctionCallOutputItem(
                                callId: toolCallId,
                                output: output
                            )
                        )
                    )
                }

            default:
                // Unknown role - treat as user message
                if let content = msg.content {
                    let msgContent = OpenResponsesMessageContent.text(content)
                    inputItems.append(.message(OpenResponsesMessageItem(role: "user", content: msgContent)))
                }
            }
        }

        // Convert tools
        var openResponsesTools: [OpenResponsesTool]?
        if let tools = tools {
            openResponsesTools = tools.map { tool in
                OpenResponsesTool(
                    name: tool.function.name,
                    description: tool.function.description,
                    parameters: tool.function.parameters
                )
            }
        }

        // Convert tool choice
        var openResponsesToolChoice: OpenResponsesToolChoice?
        if let choice = tool_choice {
            switch choice {
            case .auto:
                openResponsesToolChoice = .auto
            case .none:
                openResponsesToolChoice = OpenResponsesToolChoice.none
            case .required:
                openResponsesToolChoice = .required
            case .function(let fn):
                openResponsesToolChoice = .function(name: fn.function.name)
            }
        }

        // Determine input format
        let input: OpenResponsesInput
        if !alwaysUseInputItems, inputItems.count == 1, case .message(let msg) = inputItems[0], msg.role == "user" {
            // Single user message - use text shorthand
            input = .text(msg.content.plainText)
        } else {
            input = .items(inputItems)
        }

        let reasoning =
            reasoning_effort
            .map { OpenResponsesReasoningConfig(effort: $0, summary: "auto") }
        let isReasoningModel = OpenAIReasoningProfile.matches(modelId: model)

        return OpenResponsesRequest(
            model: model,
            input: input,
            stream: stream,
            tools: openResponsesTools,
            tool_choice: openResponsesToolChoice,
            temperature: isReasoningModel ? nil : temperature,
            max_output_tokens: max_completion_tokens,
            top_p: isReasoningModel ? nil : top_p,
            instructions: instructions,
            previous_response_id: nil,
            metadata: nil,
            reasoning: reasoning
        )
    }

    func toCodexOpenResponsesRequest() -> OpenResponsesRequest {
        toOpenResponsesRequest(alwaysUseInputItems: true)
    }
}

extension OpenResponsesRequest {
    func toCodexOAuthPayloadData() throws -> Data {
        let encoded = try JSONEncoder.osaurusCanonical().encode(self)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            return encoded
        }

        object["store"] = false
        object["include"] = ["reasoning.encrypted_content"]
        object.removeValue(forKey: "max_output_tokens")

        return try JSONSerialization.data(withJSONObject: object, options: .osaurusCanonical)
    }
}

// MARK: - Top-level parameter schema sanitization

extension RemoteProviderService {
    /// Whether the provider route needs the tool schema narrowed for wire
    /// compatibility. This is not local validation weakening: Osaurus still
    /// validates tool calls against the original schema. The narrowed copy is
    /// only what we advertise to remote providers that reject restricted
    /// top-level JSON Schema keys.
    ///
    /// OpenAI's official API 400s with `invalid_function_parameters` on
    /// top-level `oneOf`/`anyOf`/`allOf`/`enum`/`const`/`not` (nested uses are
    /// accepted); Azure OpenAI runs the same validator, and Anthropic's
    /// Messages API rejects top-level `oneOf`/`allOf`/`anyOf` on
    /// `input_schema`. Osaurus Router is a provider-agnostic fan-out boundary,
    /// so it uses the strict wire subset regardless of the current model's
    /// upstream.
    static func enforcesTopLevelParameterSchemaRestrictions(
        providerType: RemoteProviderType,
        host: String
    ) -> Bool {
        switch providerType {
        case .azureOpenAI, .openAICodex, .anthropic, .osaurusRouter: return true
        default: break
        }
        let normalizedHost = host.lowercased()
        return normalizedHost == "api.openai.com" || normalizedHost.hasSuffix(".openai.com")
    }

    /// JSON Schema combinators the providers above forbid at the top level
    /// of a function's `parameters` object.
    private static let restrictedTopLevelSchemaKeys: Set<String> = [
        "oneOf", "anyOf", "allOf", "enum", "const", "not",
    ]

    /// Strip only the top-level offenders; everything nested is preserved.
    /// Osaurus's own preflight still validates tool arguments against the
    /// full schema, so the constraint is enforced locally — it's just not
    /// advertised to a provider that would reject the request outright.
    static func strippingRestrictedTopLevelSchemaKeys(_ tool: Tool) -> Tool {
        guard case .object(let object)? = tool.function.parameters else { return tool }
        let sanitized = object.filter { !restrictedTopLevelSchemaKeys.contains($0.key) }
        guard sanitized.count != object.count else { return tool }
        return Tool(
            type: tool.type,
            function: ToolFunction(
                name: tool.function.name,
                description: tool.function.description,
                parameters: .object(sanitized)
            )
        )
    }
}

// MARK: - Static Factory for Creating Services

extension RemoteProviderService {
    /// Fetch models from a remote provider and create a service instance
    public static func fetchModels(from provider: RemoteProvider) async throws -> [String] {
        if provider.providerType == .openAICodex {
            guard var tokens = await provider.getOAuthTokensOffMainActor() else {
                throw OpenAICodexOAuthError.missingSignInTokens
            }
            if tokens.isExpired {
                let refreshed = try await OpenAICodexOAuthService.refresh(tokens)
                _ = await RemoteProviderKeychain.saveOAuthTokensOffMainActor(refreshed, for: provider.id)
                tokens = refreshed
            }
            return await OpenAICodexOAuthService.availableModels(for: tokens)
        }

        // xAI (Grok) OAuth tokens are denied access to the `/models` endpoint
        // (HTTP 403), so — like Codex — surface the built-in catalog instead of
        // a live query. Chat completions still authorize with the Bearer token.
        if provider.authType == .xaiOAuth {
            return XAIOAuthService.supportedModels
        }

        if provider.providerType == .anthropic {
            guard let baseURL = provider.url(for: "/models") else {
                throw RemoteProviderServiceError.invalidURL
            }
            return try await fetchAnthropicModels(
                baseURL: baseURL,
                headers: await provider.resolvedHeadersOffMainActor(),
                timeout: min(provider.timeout, 30)
            )
        }

        // Gemini uses a different models response format
        if provider.providerType == .gemini {
            return try await fetchGeminiModels(from: provider)
        }

        // Native Osaurus agent — fetch all models from the server's /models endpoint
        if provider.providerType == .osaurus {
            return try await fetchOsaurusModels(from: provider)
        }

        if provider.providerType == .osaurusRouter {
            return try await fetchOsaurusRouterModels(from: provider)
        }

        // OpenAI-compatible providers use /models endpoint
        guard let url = provider.url(for: "/models") else {
            throw RemoteProviderServiceError.invalidURL
        }

        let request = modelDiscoveryRequest(
            url: url,
            headers: await provider.resolvedHeadersOffMainActor(),
            timeout: provider.timeout
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await GlobalProxySettings.sharedSession().data(for: request)
        } catch {
            let diagnostics = ProviderReplayDiagnosticBundle(
                phase: "model_discovery",
                request: request,
                transportError: error,
                configuredSecretHeaderKeys: provider.secretHeaderKeys
            )
            throw RemoteProviderServiceError.requestFailedWithDiagnostics(
                "Network error: \(ProviderDiagnosticRedactor.safe(error.localizedDescription, maxLength: 240))",
                diagnostics
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            let diagnostics = ProviderReplayDiagnosticBundle(
                phase: "model_discovery",
                request: request,
                configuredSecretHeaderKeys: provider.secretHeaderKeys
            )
            throw RemoteProviderServiceError.invalidResponse.attachingReplayDiagnostics(diagnostics)
        }

        let diagnostics = ProviderReplayDiagnosticBundle(
            phase: "model_discovery",
            request: request,
            response: httpResponse,
            responseData: data,
            configuredSecretHeaderKeys: provider.secretHeaderKeys
        )
        do {
            return try decodeOpenAICompatibleModelsResponse(
                data: data,
                statusCode: httpResponse.statusCode,
                provider: provider
            )
        } catch let error as RemoteProviderServiceError {
            throw error.attachingReplayDiagnostics(diagnostics)
        } catch {
            throw RemoteProviderServiceError.requestFailedWithDiagnostics(
                "Invalid /models response: \(ProviderDiagnosticRedactor.safe(error.localizedDescription, maxLength: 240))",
                diagnostics
            )
        }
    }

    static func decodeOpenAICompatibleModelsResponse(
        data: Data,
        statusCode: Int,
        provider: RemoteProvider
    ) throws -> [String] {
        if statusCode >= 400 {
            let errorMessage = extractErrorMessage(from: data, statusCode: statusCode)
            if canUseManualModelDiscoveryFallback(for: provider, statusCode: statusCode),
                let fallbackModels = manualModelDiscoveryFallback(for: provider)
            {
                return fallbackModels
            }
            throw RemoteProviderServiceError.requestFailed(errorMessage)
        }

        do {
            let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return modelsResponse.data.map { $0.id }
        } catch {
            if let fallbackModels = manualModelDiscoveryFallback(for: provider) {
                return fallbackModels
            }
            throw error
        }
    }

    /// Builds a bounded `/models` request so provider connect tests do not hang
    /// longer than the user-configured discovery timeout.
    static func modelDiscoveryRequest(
        url: URL,
        headers: [String: String],
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = modelDiscoveryTimeout(timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        return request
    }

    static func modelDiscoveryTimeout(_ timeout: TimeInterval) -> TimeInterval {
        guard timeout.isFinite else { return 30 }
        return min(max(timeout, 1), 30)
    }

    private static func canUseManualModelDiscoveryFallback(
        for provider: RemoteProvider,
        statusCode: Int
    ) -> Bool {
        guard isOpenAICompatibleModelDiscoveryProvider(provider.providerType) else {
            return false
        }

        switch statusCode {
        case 400, 404, 405, 406, 410, 415, 422, 501:
            return true
        default:
            return false
        }
    }

    private static func manualModelDiscoveryFallback(for provider: RemoteProvider) -> [String]? {
        guard isOpenAICompatibleModelDiscoveryProvider(provider.providerType) else {
            return nil
        }

        let manualModels = provider.mergedModelIds(discovered: [])
        return manualModels.isEmpty ? nil : manualModels
    }

    private static func isOpenAICompatibleModelDiscoveryProvider(_ providerType: RemoteProviderType) -> Bool {
        switch providerType {
        case .openaiLegacy, .openResponses, .azureOpenAI:
            return true
        case .anthropic, .openAICodex, .gemini, .osaurus, .osaurusRouter:
            return false
        }
    }

    private static func fetchOsaurusRouterModels(from provider: RemoteProvider) async throws -> [String] {
        try await fetchOsaurusRouterModelsDiscovery(from: provider).models
    }

    /// Like `fetchOsaurusRouterModels` but returns the full discovery, including
    /// the per-model metadata catalog, so callers (connect/refetch) can cache
    /// pricing/provider/context for the picker without a second request.
    static func fetchOsaurusRouterModelsDiscovery(
        from provider: RemoteProvider
    ) async throws -> OsaurusRouterModelDiscovery {
        guard let url = provider.url(for: "/models") else {
            throw RemoteProviderServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = modelDiscoveryTimeout(provider.timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await OsaurusRouterAuthSigner().sign(request: &request, body: Data())

        let (data, response) = try await GlobalProxySettings.sharedSession().data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteProviderServiceError.invalidResponse
        }
        if httpResponse.statusCode >= 400 {
            // Throw a typed router error that carries the HTTP status so the
            // launch connect-retry can tell retryable 5xx from terminal 4xx.
            // Mirrors `OsaurusRouterAPIClient.ensureOK`.
            if let envelope = try? JSONDecoder().decode(OsaurusRouterErrorEnvelope.self, from: data) {
                throw OsaurusRouterAPIError.from(
                    code: envelope.error.code,
                    message: envelope.error.message,
                    status: httpResponse.statusCode,
                    retryAfter: httpResponse.value(forHTTPHeaderField: "retry-after")
                )
            }
            throw OsaurusRouterAPIError.server(
                code: "HTTP_\(httpResponse.statusCode)",
                message: extractErrorMessage(from: data, statusCode: httpResponse.statusCode),
                status: httpResponse.statusCode
            )
        }

        let discovery = try decodeOsaurusRouterModelsDiscovery(data: data)
        if discovery.staleCount > 0 {
            print(
                "[Osaurus] Router model discovery: \(discovery.models.count) fresh models (\(discovery.staleCount) stale hidden of \(discovery.totalCount) total)"
            )
        }
        return discovery
    }

    static func decodeOsaurusRouterModelsResponse(data: Data) throws -> [String] {
        try decodeOsaurusRouterModelsDiscovery(data: data).models
    }

    static func decodeOsaurusRouterModelsDiscovery(data: Data) throws -> OsaurusRouterModelDiscovery {
        let decoded = try JSONDecoder().decode(OsaurusRouterModelListResponse.self, from: data)
        let freshModels = decoded.data.filter { !$0.stale }
        let freshIds = freshModels.map(\.id)
        let catalog = Dictionary(freshModels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return OsaurusRouterModelDiscovery(
            models: freshIds,
            totalCount: decoded.data.count,
            staleCount: decoded.data.count - freshIds.count,
            catalog: catalog
        )
    }

    /// Fetch models for a native Osaurus agent.
    /// Tries the server's /models endpoint first (returns all available models so the user can
    /// select one in the picker). Falls back to GET /agents/{id} when /models is unavailable.
    private static func fetchOsaurusModels(from provider: RemoteProvider) async throws -> [String] {
        let headers = await provider.resolvedHeadersOffMainActor()
        // Tracks whether the peer answered at all (any HTTP status, even an
        // error). Distinguishes "couldn't reach / Secure Channel handshake
        // failed" (no response) from "reached but degraded" so we fail closed
        // on the former instead of synthesizing a fake ["default"] model that
        // makes an unreachable or unauthenticated peer look connected.
        var reachedPeer = false

        // Try /models first
        if let url = provider.url(for: "/models") {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = min(provider.timeout, 10)
            for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
            if let (data, status) = await osaurusGET(req, provider: provider) {
                reachedPeer = true
                if status < 400,
                    let parsed = try? JSONDecoder().decode(ModelsResponse.self, from: data),
                    !parsed.data.isEmpty
                {
                    return parsed.data.map { $0.id }
                }
            }
        }

        // Fallback: fetch the agent's configured default_model. Address by the
        // crypto address first (the stable identity the host resolves and a
        // paired peer knows), falling back to the minted remoteAgentId, so the
        // host's /agents/{id} resolves the agent instead of 400-ing on a random
        // UUID. Mirrors buildURLRequest.
        let identifier =
            provider.remoteAgentAddress.flatMap { $0.isEmpty ? nil : $0 }
            ?? provider.remoteAgentId?.uuidString
        if let identifier, let url = provider.url(for: "/agents/\(identifier)") {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = min(provider.timeout, 10)
            for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
            if let (data, status) = await osaurusGET(req, provider: provider) {
                reachedPeer = true
                if status < 400 {
                    // A reachable agent with no concrete `default_model` still
                    // degrades to ["default"] here (legit graceful fallback);
                    // only an unreachable/error peer fails below.
                    struct AgentInfo: Decodable { let default_model: String? }
                    let model =
                        (try? JSONDecoder().decode(AgentInfo.self, from: data))?.default_model
                        ?? "default"
                    return [model]
                }
            }
        }

        // No usable response from either endpoint. Fail closed so
        // `RemoteProviderManager.connect` records `lastError` and leaves the
        // provider disconnected, instead of reporting a phantom connection.
        throw RemoteProviderServiceError.requestFailed(
            reachedPeer
                ? "Remote agent rejected the connection (check pairing and authorization)."
                : "Could not reach the remote agent (Secure Channel handshake failed)."
        )
    }

    /// Live metadata for a paired/discovered Osaurus agent, fetched from
    /// `GET /agents/{id}` after connect (Mode 2). All fields are optional so a
    /// partial / legacy peer response still yields whatever it could resolve.
    public struct RemoteAgentMetadata: Sendable, Equatable {
        /// The model the agent will actually run (prefers `effective_model`,
        /// falls back to `default_model`). nil when the peer exposes no
        /// concrete model (i.e. only the `"default"` sentinel).
        public let effectiveModel: String?
        /// The agent's live display name (may differ from the name captured at
        /// pair time if the owner renamed it).
        public let name: String?
        public let description: String?
        /// Mascot avatar id (e.g. "green"); nil = monogram fallback.
        public let avatar: String?
        /// The agent's custom Action Bar (chat quick actions), surfaced in the
        /// empty state so a remote chat offers the agent's own prompt shortcuts
        /// instead of the local neutral defaults. nil = agent uses defaults.
        public let quickActions: [AgentQuickAction]?
    }

    /// Fetch a paired/discovered Osaurus agent's *live* metadata (effective
    /// model + name/description/avatar), used to pin the model chip and surface
    /// the remote agent's own identity/avatar in Mode 2 (remote agent run).
    /// Returns nil only when the peer can't be reached. Routes through the
    /// Secure Channel GET so the Bearer never crosses the wire in cleartext,
    /// mirroring `fetchOsaurusModels`.
    static func fetchOsaurusAgentMetadata(from provider: RemoteProvider) async -> RemoteAgentMetadata? {
        let identifier =
            provider.remoteAgentAddress.flatMap { $0.isEmpty ? nil : $0 }
            ?? provider.remoteAgentId?.uuidString
        guard let identifier, let url = provider.url(for: "/agents/\(identifier)") else {
            return nil
        }
        let headers = await provider.resolvedHeadersOffMainActor()
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = min(provider.timeout, 10)
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        guard let (data, status) = await osaurusGET(req, provider: provider), status < 400 else {
            return nil
        }
        return parseAgentMetadata(from: data)
    }

    /// Decode + normalize a peer's `GET /agents/{id}` body into
    /// `RemoteAgentMetadata`. Split out from the network fetch so the decode /
    /// trimming / sentinel-collapsing contract (notably the mascot `avatar`
    /// field and the `"default"`-model collapse) is unit-testable without a
    /// live peer. Returns nil only when the body isn't decodable JSON.
    static func parseAgentMetadata(from data: Data) -> RemoteAgentMetadata? {
        struct AgentInfo: Decodable {
            let effective_model: String?
            let default_model: String?
            let name: String?
            let description: String?
            let avatar: String?
        }
        guard let info = try? JSONDecoder().decode(AgentInfo.self, from: data) else { return nil }
        let rawModel = info.effective_model ?? info.default_model
        let model: String? =
            (rawModel?.isEmpty == false && rawModel != "default") ? rawModel : nil
        let trimmedName = info.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = info.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAvatar = info.avatar?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteAgentMetadata(
            effectiveModel: model,
            name: (trimmedName?.isEmpty == false) ? trimmedName : nil,
            description: (trimmedDescription?.isEmpty == false) ? trimmedDescription : nil,
            avatar: (trimmedAvatar?.isEmpty == false) ? trimmedAvatar : nil,
            quickActions: parseQuickActions(from: data)
        )
    }

    /// Decode + sanitize the agent's Action Bar (`chat_quick_actions`) from a
    /// `GET /agents/{id}` body. Uses a standalone envelope (not `AgentInfo`) so a
    /// malformed list can't fail the whole metadata decode; drops entries with an
    /// empty text/prompt and caps the count. nil = nothing usable (client falls
    /// back to its neutral defaults).
    private static func parseQuickActions(from data: Data) -> [AgentQuickAction]? {
        struct QuickActionsEnvelope: Decodable { let chat_quick_actions: [AgentQuickAction]? }
        guard
            let raw = (try? JSONDecoder().decode(QuickActionsEnvelope.self, from: data))?
                .chat_quick_actions
        else { return nil }
        let sanitized = raw.compactMap { action -> AgentQuickAction? in
            let text = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = action.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !prompt.isEmpty else { return nil }
            return action
        }
        let capped = Array(sanitized.prefix(6))
        return capped.isEmpty ? nil : capped
    }

    /// Back-compat thin wrapper: just the live effective model id (used to pin
    /// the model chip). Returns nil when unreachable or no concrete model.
    static func fetchOsaurusAgentEffectiveModel(from provider: RemoteProvider) async -> String? {
        await fetchOsaurusAgentMetadata(from: provider)?.effectiveModel
    }

    /// Metadata GET against an Osaurus peer.
    ///
    /// When the provider has a pinned `remoteAgentAddress` the peer is expected
    /// to speak the Secure Channel, so metadata is treated exactly like chat
    /// traffic: it goes **only** through the channel and never downgrades to a
    /// plaintext request. A plaintext GET would put the agent-scoped Bearer on
    /// the wire in cleartext (sniffable on a LAN, and pair-invite keys live
    /// ~1 year), so on any secure failure we fail closed and return nil. The
    /// caller then falls back to a safe default (the pinned chip shows
    /// "Default"; the wire model stays "default", so the run is still correct).
    ///
    /// Only genuinely addressless legacy peers (paired before the channel
    /// existed) use the plaintext path, matching the server keeping `/models`
    /// and agent metadata plaintext-accessible for third-party SDK clients.
    private static func osaurusGET(
        _ request: URLRequest,
        provider: RemoteProvider
    ) async -> (data: Data, statusCode: Int)? {
        let urlSession = GlobalProxySettings.sharedSession()
        if let address = provider.remoteAgentAddress, !address.isEmpty {
            do {
                let (outer, opener) = try await SecureChannelClient.shared.wrappedRequest(
                    for: request,
                    provider: provider,
                    urlSession: urlSession
                )
                let (data, response) = try await urlSession.data(for: outer)
                guard let http = response as? HTTPURLResponse else { return nil }
                if SecureChannelClient.isSessionUnknownError(statusCode: http.statusCode, body: data) {
                    // Session rotated out from under us — drop it so the next
                    // call re-handshakes. Fail closed for this attempt rather
                    // than retrying in plaintext.
                    await SecureChannelClient.shared.invalidateSession(for: provider)
                    return nil
                }
                guard http.statusCode < 400 else { return nil }
                let inner = try SecureChannelClient.openBufferedResponse(data, opener: opener)
                let body = inner.body.flatMap { Data(base64urlEncoded: $0) } ?? Data()
                return (body, inner.status)
            } catch {
                // peerUnsupported, handshake, or transport failure: never fall
                // back to a cleartext Bearer when a secure channel was expected.
                return nil
            }
        }
        guard let (data, response) = try? await urlSession.data(for: request),
            let http = response as? HTTPURLResponse
        else { return nil }
        return (data, http.statusCode)
    }

    /// Fetch models from Gemini API (different response format from OpenAI)
    private static func fetchGeminiModels(from provider: RemoteProvider) async throws -> [String] {
        guard let url = provider.url(for: "/models") else {
            throw RemoteProviderServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Add provider headers (includes x-goog-api-key)
        for (key, value) in await provider.resolvedHeadersOffMainActor() {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = min(provider.timeout, 30)
        // One-shot session with a custom timeout (can't use the shared
        // default-config session). Invalidate so it doesn't leak.
        let session = GlobalProxySettings.makeSession(base: config)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteProviderServiceError.invalidResponse
        }

        if httpResponse.statusCode >= 400 {
            let errorMessage = extractErrorMessage(from: data, statusCode: httpResponse.statusCode)
            throw RemoteProviderServiceError.requestFailed(errorMessage)
        }

        // Parse Gemini models response
        let modelsResponse = try JSONDecoder().decode(GeminiModelsResponse.self, from: data)

        // Filter to models that support generateContent and strip "models/" prefix
        let models = (modelsResponse.models ?? [])
            .filter { model in
                guard let methods = model.supportedGenerationMethods else { return false }
                return methods.contains("generateContent")
            }
            .map { $0.modelId }

        guard !models.isEmpty else {
            throw RemoteProviderServiceError.noModelsAvailable
        }

        return models
    }

    /// Fetch all models from the Anthropic `/v1/models` endpoint, handling pagination.
    ///
    /// Shared between `fetchModels(from:)` and `RemoteProviderManager.testAnthropicConnection`.
    static func fetchAnthropicModels(
        baseURL: URL,
        headers: [String: String],
        timeout: TimeInterval = 30
    ) async throws -> [String] {
        var allModels: [String] = []
        var afterId: String?

        while true {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                throw RemoteProviderServiceError.invalidURL
            }
            var queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let afterId = afterId {
                queryItems.append(URLQueryItem(name: "after_id", value: afterId))
            }
            components.queryItems = queryItems

            guard let url = components.url else {
                throw RemoteProviderServiceError.invalidURL
            }

            let request = modelDiscoveryRequest(url: url, headers: headers, timeout: timeout)

            let (data, response) = try await GlobalProxySettings.sharedSession().data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw RemoteProviderServiceError.invalidResponse
            }

            if httpResponse.statusCode >= 400 {
                let errorMessage = extractErrorMessage(from: data, statusCode: httpResponse.statusCode)
                throw RemoteProviderServiceError.requestFailed(errorMessage)
            }

            let modelsResponse = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
            allModels.append(contentsOf: modelsResponse.data.map { $0.id })

            if modelsResponse.has_more, let lastId = modelsResponse.last_id {
                afterId = lastId
            } else {
                break
            }
        }

        return allModels
    }

    /// Extract a human-readable error message from API error response data
    private static func extractErrorMessage(from data: Data, statusCode: Int) -> String {
        // Try to parse as JSON error response (OpenAI/xAI format)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // OpenAI/xAI format: {"error": {"message": "...", "type": "...", "code": "..."}}
            if let error = json["error"] as? [String: Any] {
                if let message = error["message"] as? String {
                    // Include error code if available for more context
                    if let code = error["code"] as? String {
                        return "\(message) (code: \(code))"
                    }
                    return message
                }
            }
            // Alternative format: {"message": "..."}
            if let message = json["message"] as? String {
                return message
            }
            // Alternative format: {"detail": "..."}
            if let detail = json["detail"] as? String {
                return detail
            }
        }

        // Fallback to raw string if JSON parsing fails
        if let rawMessage = String(data: data, encoding: .utf8), !rawMessage.isEmpty {
            // Truncate very long error messages
            let truncated = rawMessage.count > 200 ? String(rawMessage.prefix(200)) + "..." : rawMessage
            return "HTTP \(statusCode): \(truncated)"
        }

        return "HTTP \(statusCode): Unknown error"
    }
}
