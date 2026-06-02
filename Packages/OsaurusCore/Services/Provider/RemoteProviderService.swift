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

/// Errors specific to remote provider operations
public enum RemoteProviderServiceError: LocalizedError {
    case invalidURL
    case notConnected
    case requestFailed(String)
    case invalidResponse
    case streamingError(String)
    case noModelsAvailable

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid provider URL configuration"
        case .notConnected:
            return "Provider is not connected"
        case .requestFailed(let message):
            return "Request failed: \(message)"
        case .invalidResponse:
            return "Invalid response from provider"
        case .streamingError(let message):
            return "Streaming error: \(message)"
        case .noModelsAvailable:
            return "No models available from provider"
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

    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String {
        // Native Osaurus agents only support the streaming /agents/{id}/run endpoint.
        // Consume the SSE stream and concatenate all text deltas into a single string.
        if provider.providerType == .osaurus {
            let stream = try await streamDeltas(
                messages: messages,
                parameters: parameters,
                requestedModel: requestedModel,
                stopSequences: []
            )
            var result = ""
            for try await chunk in stream {
                result += chunk
            }
            return result
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
        let (data, response) = try await session.data(for: try buildURLRequest(for: request))
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
        let (content, _) = try parseResponse(data, providerType: responseProviderType)
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
            let inner = try geminiImageGenerateContent(
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
        // Native Osaurus agents run tools server-side and only expose a streaming endpoint.
        // Route through generateOneShot, which consumes the SSE stream for .osaurus.
        if provider.providerType == .osaurus {
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
        let (data, response) = try await session.data(for: try buildURLRequest(for: request))
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
        let (content, toolCalls) = try parseResponse(data, providerType: responseProviderType)
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
        // Native Osaurus agents run tools server-side — the /agents/{id}/run endpoint handles
        // the full inference+tool loop and streams back only text deltas. No tool invocations
        // are propagated to the client.
        if provider.providerType == .osaurus {
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
            let inner = try geminiImageGenerateContent(
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

    /// Byte-level SSE line tokenizer. Splits a stream of bytes into logical SSE
    /// lines, treating LF (`\n`), CR (`\r`), and CRLF (`\r\n`) as a single
    /// terminator. Critically, it does NOT split on `\v`, `\f`, NEL (U+0085),
    /// LS (U+2028), or PS (U+2029) — `Character.isNewline` matches those, but
    /// they can legitimately appear unescaped inside JSON string values, and
    /// treating them as line breaks corrupts SSE-framed JSON payloads.
    struct SSELineParser {
        private var lineBuffer = Data()
        private var carriageReturnLast = false
        private var completedLines: [Data] = []
        private var nextOutputIndex = 0

        /// Feed a chunk of bytes; appends complete lines to the internal queue
        /// for `nextLine()` to drain.
        mutating func append(_ data: Data) {
            for byte in data {
                switch byte {
                case 0x0D:  // CR
                    completedLines.append(lineBuffer)
                    lineBuffer = Data()
                    carriageReturnLast = true
                case 0x0A:  // LF
                    if carriageReturnLast {
                        // CRLF — the CR already emitted the line; consume the LF as part of
                        // the same terminator without emitting a spurious blank line.
                        carriageReturnLast = false
                    } else {
                        completedLines.append(lineBuffer)
                        lineBuffer = Data()
                    }
                default:
                    carriageReturnLast = false
                    lineBuffer.append(byte)
                }
            }
        }

        /// Returns the next completed line (terminator stripped), or `nil` if
        /// the queue is empty. An empty `Data` indicates a blank line, which
        /// per the SSE spec terminates the current event.
        mutating func nextLine() -> Data? {
            guard nextOutputIndex < completedLines.count else {
                if nextOutputIndex > 0 {
                    completedLines.removeFirst(nextOutputIndex)
                    nextOutputIndex = 0
                }
                return nil
            }
            let line = completedLines[nextOutputIndex]
            nextOutputIndex += 1
            return line
        }

        /// Flush any unterminated trailing bytes as a final line. Call once
        /// when the upstream stream has ended; any subsequent `nextLine()` call
        /// will return that flushed content.
        mutating func flushPending() {
            if !lineBuffer.isEmpty {
                completedLines.append(lineBuffer)
                lineBuffer = Data()
            }
            carriageReturnLast = false
        }
    }

    /// Parse a single SSE line per the W3C spec and merge its payload into
    /// `eventData`. Recognises `data`/`event`/`id`/`retry`/comment fields with
    /// optional space after the colon; bare `data:value` (no space) is honoured
    /// just like `data: value`. Multiple `data:` lines in a single event are
    /// joined with `\n` per spec.
    @inline(__always)
    static func processSSELine(_ line: Data, into eventData: inout String) {
        guard !line.isEmpty else { return }

        // Decode the line as UTF-8. SSE field names and the optional space after
        // the colon are ASCII; lossy decoding is safe for any non-UTF-8 bytes
        // that would only appear inside the value portion.
        // swiftlint:disable:next optional_data_string_conversion
        let lineStr = String(decoding: line, as: UTF8.self)

        // Comment line — entire line starts with ":" (no field name).
        if lineStr.first == ":" { return }

        let field: Substring
        var value: Substring
        if let colonIdx = lineStr.firstIndex(of: ":") {
            field = lineStr[..<colonIdx]
            value = lineStr[lineStr.index(after: colonIdx)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            // No colon — entire line is the field name with empty value.
            field = Substring(lineStr)
            value = Substring("")
        }

        switch field {
        case "data":
            if eventData.isEmpty {
                eventData = String(value)
            } else {
                eventData += "\n" + value
            }
        default:
            // event, id, retry, and any unknown field are ignored per spec.
            break
        }
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

        /// Non-nil only for providers that inline reasoning as `<think>` in the
        /// content rail (MiniMax). When set, content deltas are split so the
        /// think block lands on the reasoning channel instead of leaking.
        var thinkSplitter: InlineThinkSplitter?

        let stopSequences: [String]
        let trackContent: Bool

        /// Append yielded text to `accumulatedContent` if the caller cares
        /// about the inline-tool-detection fallback.
        @inline(__always)
        mutating func recordYield(_ text: String) {
            if trackContent { accumulatedContent += text }
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
        guard let (invocation, wasRepaired) = makeToolInvocation(from: accumulated) else {
            return .none
        }
        if wasRepaired {
            return .truncated(
                truncatedToolCallError(
                    from: accumulated,
                    toolName: invocation.toolName,
                    finishMarker: finishMarker
                )
            )
        }
        return .ready(invocation)
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
        if dataContent.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            dispatchFinal(
                state: state,
                tools: tools,
                finishMarker: "[DONE]",
                continuation: continuation
            )
            return true
        }

        guard let jsonData = dataContent.data(using: .utf8) else { return false }

        let outcome = handleStreamEvent(
            jsonData: jsonData,
            providerType: providerType,
            state: &state,
            yield: { continuation.yield($0) }
        )

        switch outcome {
        case .continue:
            return false
        case .finishNormal:
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
        do {
            switch providerType {
            case .gemini:
                return try handleGeminiEvent(jsonData, state: &state, yield: yield)
            case .anthropic:
                return try handleAnthropicEvent(jsonData, state: &state, yield: yield)
            case .openResponses, .openAICodex:
                return try handleOpenResponsesEvent(jsonData, state: &state, yield: yield)
            case .openaiLegacy, .azureOpenAI, .osaurus:
                return try handleOpenAIEvent(jsonData, state: &state, yield: yield)
            }
        } catch {
            // Server-side error payload? Some providers stream a structured
            // error event mid-stream rather than closing with a non-2xx; if
            // we don't surface it the user sees an opaque "stream ended".
            if let errorMessage = tryDecodeStreamError(jsonData, providerType: providerType) {
                return .finishWithError(RemoteProviderServiceError.requestFailed(errorMessage))
            }
            print("[Osaurus] Warning: Failed to parse SSE chunk: \(error.localizedDescription)")
            return .continue
        }
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
        let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: jsonData)

        // Tool calls FIRST so we can suppress text yields once we know the
        // delta is structurally a function call.
        if let toolCalls = chunk.choices.first?.delta.tool_calls {
            for toolCall in toolCalls {
                let idx = resolveToolCallSlot(
                    explicitIndex: toolCall.index,
                    callId: toolCall.id,
                    accumulated: state.accumulatedToolCalls,
                    idToIndex: &state.toolCallIdToIndex,
                    nextFallback: &state.nextFallbackToolCallIndex,
                    lastTouchedSlot: state.lastTouchedToolSlot
                )
                var current =
                    state.accumulatedToolCalls[idx] ?? (
                        id: nil, name: nil, args: "", thoughtSignature: nil
                    )
                if let id = toolCall.id { current.id = id }
                if let name = toolCall.function?.name, current.name == nil {
                    current.name = name
                    print("[Osaurus] OpenAI tool call detected: index=\(idx), name=\(name)")
                    yield(StreamingToolHint.encode(name))
                }
                if let args = toolCall.function?.arguments {
                    current.args += args
                    yield(StreamingToolHint.encodeArgs(args))
                }
                state.accumulatedToolCalls[idx] = current
                state.lastTouchedToolSlot = idx
            }
        }

        // Reasoning text on a dedicated `reasoning_content` channel
        // (DeepSeek, Qwen, Together, vLLM). Forwarded as a sentinel so the
        // SSE layer routes it onto `reasoning_content` and ChatView places
        // it in the Think panel — without ever emitting `<think>` literals.
        if state.accumulatedToolCalls.isEmpty,
            let reasoning = chunk.choices.first?.delta.reasoning_content,
            !reasoning.isEmpty
        {
            yield(StreamingReasoningHint.encode(reasoning))
        }

        // Only yield content if no tool calls have been detected, to avoid
        // function-call JSON leaking into the chat UI.
        if state.accumulatedToolCalls.isEmpty,
            let delta = chunk.choices.first?.delta.content, !delta.isEmpty
        {
            if var splitter = state.thinkSplitter {
                // MiniMax-style inline `<think>`: route reasoning to the Think
                // panel and only the visible remainder to the content rail.
                let segments = splitter.process(delta)
                state.thinkSplitter = splitter
                for segment in segments {
                    switch segment {
                    case .reasoning(let reasoning):
                        if !reasoning.isEmpty { yield(StreamingReasoningHint.encode(reasoning)) }
                    case .content(let visible):
                        guard !visible.isEmpty else { continue }
                        let (truncated, hitStop) = applyStopSequences(
                            visible,
                            stopSequences: state.stopSequences
                        )
                        state.recordYield(truncated)
                        yield(truncated)
                        if hitStop { return .finishNormal }
                    }
                }
            } else {
                let (truncated, hitStop) = applyStopSequences(delta, stopSequences: state.stopSequences)
                state.recordYield(truncated)
                yield(truncated)
                if hitStop { return .finishNormal }
            }
        }

        // Emit on finish_reason — applies whether or not there's a tool call.
        if let finishReason = chunk.choices.first?.finish_reason, !finishReason.isEmpty {
            state.lastFinishReason = finishReason
            switch resolveAccumulatedToolCall(
                from: state.accumulatedToolCalls,
                finishMarker: "finish_reason=\(finishReason)"
            ) {
            case .none: break
            case .ready(let inv): return .finishWithToolCall(inv)
            case .truncated(let err): return .finishWithError(err)
            }
        }

        return .continue
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
        let urlRequest = try buildURLRequest(for: request)
        let currentSession = self.session
        let providerType = Self.effectiveRequestProviderType(
            configuredProviderType: self.provider.providerType,
            request: request
        )
        let inactivityTimeout = self.streamInactivityTimeout
        let toolList = tools ?? []
        // Only the with-tools path needs accumulated text for the inline
        // tool-call fallback; streamDeltas has no tools, so skip the
        // memory cost of growing a 100% unused buffer.
        let trackContent = !toolList.isEmpty

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()

        // The producer runs in a `Task` whose closure inherits the
        // calling task's locals (unlike `Task.detached`). Snapshot
        // the probe here so the read happens once on producer
        // entry and we don't re-touch the task-local on every chunk.
        let probe = WireTransportProbe.current

        let producerTask = Task {
            do {
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
                let (bytes, response) = try await Self.connectWithRetry(
                    session: currentSession,
                    urlRequest: urlRequest,
                    isCancelled: { [weak self] in
                        self?.isSessionInvalidated ?? true
                    }
                )

                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.finish(throwing: RemoteProviderServiceError.invalidResponse)
                    return
                }

                if httpResponse.statusCode >= 400 {
                    var errorData = Data()
                    for try await byte in bytes {
                        errorData.append(byte)
                    }
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    continuation.finish(
                        throwing: RemoteProviderServiceError.requestFailed(
                            "HTTP \(httpResponse.statusCode): \(errorMessage)"
                        )
                    )
                    return
                }

                var state = StreamingState(stopSequences: stopSequences, trackContent: trackContent)
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
                        lineParser.append(chunk)
                        // Wire-verification tap. Capture the raw
                        // pre-unscrub bytes before they're parsed
                        // into SSE events. We tap inside the
                        // stream loop (not at the bytes(for:) site)
                        // so the inactivity timeout / cancel paths
                        // still get their last delivered chunk in
                        // the snapshot. No-op when no probe is set.
                        probe?.appendResponseChunk(chunk)
                    } else {
                        // Stream ended naturally or inactivity timeout fired.
                        // Flush any unterminated trailing bytes as a final line.
                        lineParser.flushPending()
                    }

                    while let lineBytes = lineParser.nextLine() {
                        if !lineBytes.isEmpty {
                            Self.processSSELine(lineBytes, into: &sseEventData)
                            continue
                        }
                        // Blank line — SSE event boundary, dispatch payload.
                        guard !sseEventData.isEmpty else { continue }
                        let dataContent = sseEventData
                        sseEventData = ""
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

        continuation.onTermination = { @Sendable _ in producerTask.cancel() }
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

    /// Creates a `ServiceToolInvocation` from the first accumulated tool call entry,
    /// validating the JSON arguments. Returns `nil` if there are no accumulated calls
    /// or the first entry has no name. `wasRepaired` is true when the args JSON was
    /// malformed and had to be structurally closed — strong signal that the stream
    /// was truncated mid-argument, especially when no `finish_reason` was ever seen.
    private static func makeToolInvocation(
        from accumulated: [Int: (id: String?, name: String?, args: String, thoughtSignature: String?)]
    ) -> (invocation: ServiceToolInvocation, wasRepaired: Bool)? {
        guard let first = accumulated.min(by: { $0.key < $1.key }),
            let name = first.value.name
        else { return nil }

        let validated = validateToolCallJSON(first.value.args)
        return (
            ServiceToolInvocation(
                toolName: name,
                jsonArguments: validated.json,
                toolCallId: first.value.id,
                geminiThoughtSignature: first.value.thoughtSignature
            ),
            validated.wasRepaired
        )
    }

    /// Build a short diagnostic summary of the truncated args buffer for the
    /// log line emitted on a discarded tool call. Helps identify *where* the
    /// stream was cut (e.g. "received 33 bytes, ends with `.html\"`")
    /// instead of just "args needed repair".
    private static func truncatedArgsSummary(
        from accumulated: [Int: (id: String?, name: String?, args: String, thoughtSignature: String?)],
        toolName: String
    ) -> String {
        guard let entry = accumulated.first(where: { $0.value.name == toolName })?.value
        else { return "received 0 bytes" }
        let args = entry.args
        let bytes = args.utf8.count
        let tail = args.suffix(40).replacingOccurrences(of: "\n", with: "\\n")
        return "received \(bytes) bytes, ends with `\(tail)`"
    }

    /// Wrap a repaired-mid-stream tool call into the same `streamingError` we
    /// throw at the post-loop drain. Centralised because every dispatch site
    /// (`[DONE]`, `STOP`/`MAX_TOKENS`, `message_stop`, `response.completed`,
    /// OpenAI `finish_reason`) needs to honour `wasRepaired` — silently
    /// emitting a partial-args call locks the broken payload into history and
    /// the model can only loop on the truncated call.
    private static func truncatedToolCallError(
        from accumulated: [Int: (id: String?, name: String?, args: String, thoughtSignature: String?)],
        toolName: String,
        finishMarker: String
    ) -> RemoteProviderServiceError {
        let argsSummary = truncatedArgsSummary(from: accumulated, toolName: toolName)
        print(
            "[Osaurus] Discarding truncated tool call '\(toolName)' — "
                + "args needed repair (finish marker: \(finishMarker)). \(argsSummary)"
        )
        return RemoteProviderServiceError.streamingError(
            "Stream ended before tool call '\(toolName)' arguments were complete "
                + "(finish marker: \(finishMarker)). The provider closed the connection "
                + "mid-argument; retry the request."
        )
    }

    /// Resolve the slot index for an incoming OpenAI-format tool-call delta.
    /// Resolution order:
    ///   1. Explicit `index` (the standard OpenAI streaming contract).
    ///   2. Known `id` correlation (for providers that only send `id` once).
    ///   3. The last slot we touched (for providers like Venice that send
    ///      `index` on the first chunk only and leave continuation chunks
    ///      bare — without this fallback the second args delta would get
    ///      assigned to a fresh slot and the streamed args would fragment).
    ///   4. A freshly allocated slot — only when there's truly no signal that
    ///      this is a continuation (new tool call without index or id).
    @inline(__always)
    private static func resolveToolCallSlot(
        explicitIndex: Int?,
        callId: String?,
        accumulated: [Int: (id: String?, name: String?, args: String, thoughtSignature: String?)],
        idToIndex: inout [String: Int],
        nextFallback: inout Int,
        lastTouchedSlot: Int?
    ) -> Int {
        if let idx = explicitIndex {
            if let id = callId { idToIndex[id] = idx }
            nextFallback = max(nextFallback, idx + 1)
            return idx
        }
        if let id = callId, let known = idToIndex[id] {
            return known
        }
        // No explicit index. If the previous delta opened/extended a slot,
        // assume this delta is a continuation of the same call — most
        // providers omit `index` on subsequent chunks for a single call.
        if callId == nil, let last = lastTouchedSlot, accumulated[last] != nil {
            return last
        }
        let highest = accumulated.keys.max() ?? -1
        let idx = max(highest + 1, nextFallback)
        nextFallback = idx + 1
        if let id = callId { idToIndex[id] = idx }
        return idx
    }

    /// Outcome of validating streamed tool-call JSON.
    private struct ValidatedToolCallJSON {
        /// Either the original (already-valid) JSON or a best-effort repair.
        let json: String
        /// True when the input was malformed and we structurally closed it.
        /// Callers paired with `lastFinishReason == nil` should treat this as
        /// "stream truncated mid-args" rather than emitting a partial call.
        let wasRepaired: Bool
    }

    /// Validates that tool call arguments JSON is well-formed.
    /// If the JSON is incomplete (e.g., stream was cut off mid-argument), attempts to repair it.
    /// Returns the original string + `wasRepaired: false` if valid, or a best-effort
    /// repair + `wasRepaired: true`.
    private static func validateToolCallJSON(_ json: String) -> ValidatedToolCallJSON {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty args ARE valid for tools that take no arguments — no repair flag.
        guard !trimmed.isEmpty else { return ValidatedToolCallJSON(json: "{}", wasRepaired: false) }

        // Quick validation: try to parse as-is.
        if let data = trimmed.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            return ValidatedToolCallJSON(json: trimmed, wasRepaired: false)
        }

        // Attempt repair: close unclosed braces/brackets and escape literal newlines
        var repaired = ""
        var inString = false
        var isEscaped = false
        var braceCount = 0
        var bracketCount = 0

        for ch in trimmed {
            if inString {
                if isEscaped {
                    isEscaped = false
                    repaired.append(ch)
                } else if ch == "\\" {
                    isEscaped = true
                    repaired.append(ch)
                } else if ch == "\"" {
                    inString = false
                    repaired.append(ch)
                } else if ch.isNewline {
                    if ch == "\n" {
                        repaired.append("\\n")
                    } else if ch == "\r" {
                        repaired.append("\\r")
                    }
                } else {
                    repaired.append(ch)
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    braceCount += 1
                } else if ch == "}" {
                    braceCount -= 1
                } else if ch == "[" {
                    bracketCount += 1
                } else if ch == "]" {
                    bracketCount -= 1
                }
                repaired.append(ch)
            }
        }

        // Close any unclosed strings
        if inString {
            if isEscaped {
                repaired.append("\\")
            }
            repaired.append("\"")
        }

        // Remove trailing comma before closing
        let trimmedForComma = repaired.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedForComma.hasSuffix(",") {
            repaired = String(trimmedForComma.dropLast())
        }

        // Close unclosed brackets and braces
        for _ in 0 ..< bracketCount {
            repaired.append("]")
        }
        for _ in 0 ..< braceCount {
            repaired.append("}")
        }

        // Verify the repair worked
        if let data = repaired.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            print("[Osaurus] Repaired incomplete tool call JSON (\(json.count) -> \(repaired.count) chars)")
            return ValidatedToolCallJSON(json: repaired, wasRepaired: true)
        }

        // Repair failed - return original and let downstream handle the error.
        print("[Osaurus] Warning: Tool call JSON is malformed and could not be repaired: \(json.prefix(200))")
        return ValidatedToolCallJSON(json: json, wasRepaired: true)
    }

    /// Build a chat completion request structure
    private func buildChatRequest(
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

        return RemoteChatRequest(
            model: model,
            messages: messages,
            // Reasoning models (o1, gpt-5) forbid temperature/top_p when reasoning is active as inferred from
            // https://community.openai.com/t/gpt-5-nano-accepted-parameters/1355086/2
            temperature: isReasoningModel ? nil : parameters.temperature,
            max_completion_tokens: parameters.maxTokensExplicit ? parameters.maxTokens : nil,
            stream: stream,
            top_p: isReasoningModel ? nil : parameters.topPOverride,
            // Forward the raw OpenAI penalties — most upstream OpenAI-
            // compatible providers accept these natively, and stripping
            // them silently was a previous gap that surprised clients.
            frequency_penalty: isReasoningModel ? nil : parameters.frequencyPenalty,
            presence_penalty: isReasoningModel ? nil : parameters.presencePenalty,
            stop: nil,
            tools: tools,
            tool_choice: toolChoice,
            reasoning_effort: effortValue,
            reasoning: allowsReasoningObject ? effortValue.map { ReasoningConfig(effort: $0) } : nil,
            thinking: thinking,
            modelOptions: parameters.modelOptions,
            veniceParameters: buildVeniceParameters(from: parameters.modelOptions)
        )
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
    ) throws -> AsyncThrowingStream<String, Error> {
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

        let urlRequest = try buildURLRequest(for: request)
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

    /// Build a URLRequest for the chat completions endpoint
    private func buildURLRequest(for request: RemoteChatRequest) throws -> URLRequest {
        let url: URL
        let requestProviderType = Self.effectiveRequestProviderType(
            configuredProviderType: provider.providerType,
            request: request
        )

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
            // Native Osaurus agent: POST /agents/{remoteAgentId}/run
            guard let agentId = provider.remoteAgentId else {
                throw RemoteProviderServiceError.invalidURL
            }
            guard let agentURL = provider.url(for: "/agents/\(agentId.uuidString)/run") else {
                throw RemoteProviderServiceError.invalidURL
            }
            url = agentURL
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
        if provider.authType == .openAICodexOAuth {
            headers = try codexOAuthHeaders()
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
        case .openaiLegacy, .azureOpenAI, .osaurus:
            // OpenAI-compat wire. RemoteReasoningPolicy decides how prior-turn
            // reasoning is re-sent: strip (default), keep `reasoning_content`
            // (DeepSeek), or fold it back into `<think>` content (MiniMax).
            var outbound = request
            outbound.messages = RemoteReasoningPolicy.resolve(
                providerType: requestProviderType,
                host: provider.host,
                model: request.model
            ).transformOutbound(outbound.messages)
            bodyData = try encoder.encode(outbound)
        }
        urlRequest.httpBody = bodyData
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

    /// Parse response based on provider type
    private func parseResponse(
        _ data: Data,
        providerType: RemoteProviderType
    ) throws -> (content: String?, toolCalls: [ToolCall]?) {
        switch providerType {
        case .anthropic:
            let response = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)
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

        case .openaiLegacy, .azureOpenAI:
            let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let content = response.choices.first?.message.content
            let toolCalls = response.choices.first?.message.tool_calls
            return (content, toolCalls)

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
            // Native Osaurus agent returns OpenAI-compatible responses
            let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let content = response.choices.first?.message.content
            return (content, nil)
        }
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

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, max_completion_tokens, max_tokens, stream
        case top_p, frequency_penalty, presence_penalty, stop, tools, tool_choice
        case reasoning_effort
        case reasoning
        case thinking
        case veniceParameters = "venice_parameters"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
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
        try container.encodeIfPresent(veniceParameters, forKey: .veniceParameters)
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

        for msg in messages {
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

                if let content = msg.content, !content.isEmpty {
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
                // when we encounter a non-tool message or reach the end
                if let toolCallId = msg.tool_call_id, let content = msg.content {
                    pendingToolResults.append(
                        .toolResult(
                            AnthropicToolResultBlock(
                                type: "tool_result",
                                tool_use_id: toolCallId,
                                content: .text(content),
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

        return AnthropicMessagesRequest(
            model: model,
            max_tokens: max_completion_tokens ?? 4096,
            system: systemContent,
            messages: anthropicMessages,
            stream: stream,
            temperature: temperature.map { Double($0) },
            top_p: top_p.map { Double($0) },
            top_k: nil,
            stop_sequences: stop,
            tools: anthropicTools,
            tool_choice: anthropicToolChoice,
            metadata: nil
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

        for msg in messages {
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

        for msg in messages {
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
                // Tool results become function_call_output items
                if let toolCallId = msg.tool_call_id, let content = msg.content {
                    inputItems.append(
                        .functionCallOutput(
                            OpenResponsesFunctionCallOutputItem(
                                callId: toolCallId,
                                output: content
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

        // OpenAI-compatible providers use /models endpoint
        guard let url = provider.url(for: "/models") else {
            throw RemoteProviderServiceError.invalidURL
        }

        let request = modelDiscoveryRequest(
            url: url,
            headers: await provider.resolvedHeadersOffMainActor(),
            timeout: provider.timeout
        )

        let (data, response) = try await GlobalProxySettings.sharedSession().data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteProviderServiceError.invalidResponse
        }

        return try decodeOpenAICompatibleModelsResponse(
            data: data,
            statusCode: httpResponse.statusCode,
            provider: provider
        )
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
        case .anthropic, .openAICodex, .gemini, .osaurus:
            return false
        }
    }

    /// Fetch models for a native Osaurus agent.
    /// Tries the server's /models endpoint first (returns all available models so the user can
    /// select one in the picker). Falls back to GET /agents/{id} when /models is unavailable.
    private static func fetchOsaurusModels(from provider: RemoteProvider) async throws -> [String] {
        let headers = await provider.resolvedHeadersOffMainActor()

        // Try /models first
        if let url = provider.url(for: "/models") {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = min(provider.timeout, 10)
            for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
            if let (data, response) = try? await GlobalProxySettings.sharedSession().data(for: req),
                let http = response as? HTTPURLResponse, http.statusCode < 400,
                let parsed = try? JSONDecoder().decode(ModelsResponse.self, from: data),
                !parsed.data.isEmpty
            {
                return parsed.data.map { $0.id }
            }
        }

        // Fallback: fetch the agent's configured default_model
        guard let agentId = provider.remoteAgentId,
            let url = provider.url(for: "/agents/\(agentId.uuidString)")
        else {
            return ["default"]
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = min(provider.timeout, 10)
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        guard let (data, response) = try? await GlobalProxySettings.sharedSession().data(for: req),
            let http = response as? HTTPURLResponse, http.statusCode < 400
        else {
            return ["default"]
        }
        struct AgentInfo: Decodable { let default_model: String? }
        let model = (try? JSONDecoder().decode(AgentInfo.self, from: data))?.default_model ?? "default"
        return [model]
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
