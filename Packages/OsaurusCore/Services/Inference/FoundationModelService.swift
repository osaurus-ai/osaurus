//
//  FoundationModelService.swift
//  osaurus
//
//  Created by Terence on 10/14/25.
//

import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Why `SystemLanguageModel.default` cannot serve right now. Mirrors
/// `SystemLanguageModel.Availability.UnavailableReason` plus the two
/// build/OS-level cases the framework can't report itself. Surfaced in the
/// Core Model picker and Memory diagnostics so "Foundation is set but
/// nothing works" has a concrete, user-actionable explanation.
enum FoundationUnavailableReason: Sendable, Equatable {
    /// Hardware can't run Apple Intelligence (e.g. Intel, older Apple silicon).
    case deviceNotEligible
    /// Apple Intelligence is turned off in System Settings.
    case appleIntelligenceNotEnabled
    /// Apple Intelligence is on but the on-device model is still
    /// downloading / being provisioned. Transient.
    case modelNotReady
    /// Running on macOS < 26.
    case osTooOld
    /// Built without the FoundationModels framework.
    case frameworkMissing
    /// The framework reported a reason this build doesn't know about.
    case unknown

    /// Short user-facing explanation, phrased as the fix when there is one.
    var userDescription: String {
        switch self {
        case .deviceNotEligible:
            return "This Mac is not eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off. Enable it in System Settings → Apple Intelligence & Siri."
        case .modelNotReady:
            return "The Apple Intelligence model is still downloading. Try again in a few minutes."
        case .osTooOld:
            return "Foundation Model requires macOS 26 or later."
        case .frameworkMissing:
            return "This build of Osaurus does not include Foundation Models support."
        case .unknown:
            return "Apple Intelligence is not available right now."
        }
    }
}

/// Availability snapshot for the system default language model.
enum FoundationAvailability: Sendable, Equatable {
    case available
    case unavailable(FoundationUnavailableReason)

    var isAvailable: Bool { self == .available }

    var unavailableReason: FoundationUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// Typed mirror of `LanguageModelSession.GenerationError`. Lets the
/// routing layer (`CoreModelService`) decide "retry", "fall back", or
/// "surface" without importing FoundationModels or matching on a
/// framework type that only exists on macOS 26+.
enum FoundationGenerationFailure: Sendable, Equatable {
    case exceededContextWindowSize
    case assetsUnavailable
    case guardrailViolation
    case unsupportedGuide
    case unsupportedLanguageOrLocale
    case decodingFailure
    case rateLimited
    case concurrentRequests
    case refusal
    case unknown

    /// True when an immediate retry against the same model has a real
    /// chance of succeeding. Everything else is either a property of this
    /// Mac (assets, locale), of this prompt (context window, guardrail,
    /// refusal, guide), or a framework bug (decoding) — retrying just burns
    /// the caller's timeout budget before the fallback gets a turn.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .concurrentRequests: return true
        default: return false
        }
    }

    var summary: String {
        switch self {
        case .exceededContextWindowSize: return "prompt exceeds the Foundation Model context window"
        case .assetsUnavailable: return "Foundation Model assets are unavailable"
        case .guardrailViolation: return "Foundation Model guardrail blocked the request"
        case .unsupportedGuide: return "Foundation Model does not support the requested output guide"
        case .unsupportedLanguageOrLocale: return "Foundation Model does not support this language or locale"
        case .decodingFailure: return "Foundation Model output could not be decoded"
        case .rateLimited: return "Foundation Model is rate limited"
        case .concurrentRequests: return "Foundation Model rejected a concurrent request"
        case .refusal: return "Foundation Model refused the request"
        case .unknown: return "Foundation Model generation failed"
        }
    }
}

enum FoundationModelServiceError: Error, LocalizedError, Equatable {
    case notAvailable(FoundationUnavailableReason)
    case generation(FoundationGenerationFailure, detail: String)
    /// The Foundation Models system model is text-only on macOS 26.
    /// When the request carries image parts we surface this instead of
    /// silently degrading to text — callers can choose to retry against
    /// an MLX VLM or a remote provider with vision support.
    case visionUnsupported

    var errorDescription: String? {
        switch self {
        case .notAvailable(let reason):
            return "Foundation Model is not available: \(reason.userDescription)"
        case .generation(let failure, let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? failure.summary : "\(failure.summary) (\(trimmed))"
        case .visionUnsupported:
            return
                "Foundation Models is text-only and cannot accept image inputs. "
                + "Use an MLX VLM (e.g. Qwen3.5-VL) or a remote provider with vision support."
        }
    }

    /// Whether `CoreModelService` should retry the same model for this error.
    /// `notAvailable` is never transient at call scale: even `.modelNotReady`
    /// (asset download) resolves in minutes, not within a retry backoff.
    var isTransient: Bool {
        switch self {
        case .notAvailable: return false
        case .generation(let failure, _): return failure.isTransient
        case .visionUnsupported: return false
        }
    }
}

actor FoundationModelService: ToolCapableService {
    /// Stable service identifier. Also the model id the router resolves the
    /// system default to (`"default"`/empty → `"foundation"`), so other code
    /// (e.g. telemetry derivation) can match against this one constant
    /// instead of a bare string literal.
    static let serviceId = "foundation"
    let id: String = serviceId

    /// Returns true if the system default language model is available on this device/OS.
    static func isDefaultModelAvailable() -> Bool {
        defaultModelAvailability().isAvailable
    }

    /// Availability of the system default language model *with the reason*
    /// when it isn't. Cheap and side-effect-free (a framework property
    /// read), so it is safe to consult right before every request — the
    /// state flips at runtime when the user toggles Apple Intelligence in
    /// System Settings or while the model assets are still downloading.
    static func defaultModelAvailability() -> FoundationAvailability {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                switch SystemLanguageModel.default.availability {
                case .available:
                    return .available
                case .unavailable(let reason):
                    switch reason {
                    case .deviceNotEligible: return .unavailable(.deviceNotEligible)
                    case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceNotEnabled)
                    case .modelNotReady: return .unavailable(.modelNotReady)
                    @unknown default: return .unavailable(.unknown)
                    }
                }
            } else {
                return .unavailable(.osTooOld)
            }
        #else
            return .unavailable(.frameworkMissing)
        #endif
    }

    /// Fail fast with the concrete reason instead of letting the framework
    /// hang or throw an opaque error when the model can't serve. The router
    /// already gates on `isAvailable()`, but availability can change between
    /// routing and the request, and callers outside the router (tests,
    /// direct `generateOneShot`) need the same guarantee.
    private static func requireAvailable() throws {
        if let reason = defaultModelAvailability().unavailableReason {
            throw FoundationModelServiceError.notAvailable(reason)
        }
    }

    /// Translate a framework error into the typed service error so the
    /// routing layer can decide retry / fall back / surface without
    /// depending on FoundationModels types. Errors that are already typed,
    /// cancellation, and anything unrecognised pass through unchanged.
    nonisolated static func mapFrameworkError(_ error: Error) -> Error {
        if error is FoundationModelServiceError || error is CancellationError { return error }
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *),
                let generation = error as? LanguageModelSession.GenerationError
            {
                return map(generation)
            }
        #endif
        return error
    }

    #if canImport(FoundationModels)
        @available(macOS 26.0, *)
        nonisolated static func map(_ error: LanguageModelSession.GenerationError)
            -> FoundationModelServiceError
        {
            switch error {
            case .exceededContextWindowSize(let ctx):
                return .generation(.exceededContextWindowSize, detail: ctx.debugDescription)
            case .assetsUnavailable(let ctx):
                return .generation(.assetsUnavailable, detail: ctx.debugDescription)
            case .guardrailViolation(let ctx):
                return .generation(.guardrailViolation, detail: ctx.debugDescription)
            case .unsupportedGuide(let ctx):
                return .generation(.unsupportedGuide, detail: ctx.debugDescription)
            case .unsupportedLanguageOrLocale(let ctx):
                return .generation(.unsupportedLanguageOrLocale, detail: ctx.debugDescription)
            case .decodingFailure(let ctx):
                return .generation(.decodingFailure, detail: ctx.debugDescription)
            case .rateLimited(let ctx):
                return .generation(.rateLimited, detail: ctx.debugDescription)
            case .concurrentRequests(let ctx):
                return .generation(.concurrentRequests, detail: ctx.debugDescription)
            case .refusal(_, let ctx):
                return .generation(.refusal, detail: ctx.debugDescription)
            @unknown default:
                return .generation(.unknown, detail: error.localizedDescription)
            }
        }
    #endif

    /// Real on-device context window of the system default model, in tokens,
    /// or `nil` when Foundation Models is unavailable on this device/OS.
    ///
    /// `SystemLanguageModel.contextSize` is `@backDeployed(before: macOS 26.4)`:
    /// it back-deploys to the 26.0 runtime floor, but the *declaration* only ships
    /// in the macOS 26.4+ SDK, so referencing it fails to compile on older SDKs
    /// (≤ 26.2). The `HAS_FM_CONTEXT_SIZE` compilation condition — defined in
    /// Package.swift when building against a 26.4+ SDK — gates the read; on older
    /// SDKs we fall back to `nil` (window unknown). When present the value is the
    /// device + OS constant for the life of the process (4096 on the macOS 26.x
    /// baseline, 8192 on 27.0+ hardware), so it's memoized once: `ContextSizeResolver`
    /// is a pure, synchronous function called during UI layout and must not pay a
    /// framework round-trip per resolve. A `static let` is `nonisolated` and its
    /// initializer runs at most once (thread-safe), so the resolver can read it
    /// without an actor hop.
    static let defaultModelContextSize: Int? = {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let model = SystemLanguageModel.default
                guard model.isAvailable else { return nil }
                #if HAS_FM_CONTEXT_SIZE
                    return model.contextSize
                #endif
            }
        #endif
        return nil
    }()

    nonisolated func isAvailable() -> Bool { Self.isDefaultModelAvailable() }

    /// The system model is always resident and normally answers a short
    /// utility prompt in well under a second; no output for this long means
    /// the framework is wedged (asset lock contention, a stuck XPC session),
    /// and `CoreModelService` should hand the call to the chat model.
    static let firstTokenDeadlineSeconds: TimeInterval = 5
    nonisolated var firstTokenDeadline: TimeInterval? { Self.firstTokenDeadlineSeconds }

    nonisolated func handles(requestedModel: String?) -> Bool {
        let t = (requestedModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.caseInsensitiveCompare("default") == .orderedSame
            || t.caseInsensitiveCompare("foundation") == .orderedSame
    }

    /// Generate a single response from the system default language model.
    /// Falls back to throwing when the framework is unavailable.
    static func generateOneShot(
        prompt: String,
        temperature: Float?,
        maxTokens: Int
    ) async throws -> String {
        try requireAvailable()
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let session = LanguageModelSession()

                let options = GenerationOptions(
                    sampling: nil,
                    temperature: temperature.map(Double.init),
                    maximumResponseTokens: maxTokens
                )
                do {
                    let response = try await session.respond(to: prompt, options: options)
                    return response.content
                } catch {
                    throw mapFrameworkError(error)
                }
            } else {
                throw FoundationModelServiceError.notAvailable(.osTooOld)
            }
        #else
            throw FoundationModelServiceError.notAvailable(.frameworkMissing)
        #endif
    }

    func streamDeltas(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?,
        stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        if Self.hasImageContent(messages) {
            throw FoundationModelServiceError.visionUnsupported
        }
        let prompt = OpenAIPromptBuilder.buildPrompt(from: messages)
        try Self.requireAvailable()
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let session = LanguageModelSession()

                let options = GenerationOptions(
                    sampling: nil,
                    temperature: parameters.temperature.map(Double.init),
                    maximumResponseTokens: parameters.maxTokens
                )

                let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
                let producerTask = Task {
                    var previous = ""
                    do {
                        var iterator = session.streamResponse(to: prompt, options: options).makeAsyncIterator()
                        while let snapshot = try await iterator.next() {
                            // Check for task cancellation to allow early termination
                            if Task.isCancelled {
                                continuation.finish()
                                return
                            }
                            var current = snapshot.content
                            if !stopSequences.isEmpty,
                                let r = stopSequences.compactMap({ current.range(of: $0)?.lowerBound }).first
                            {
                                current = String(current[..<r])
                            }
                            let delta: String
                            if current.hasPrefix(previous) {
                                delta = String(current.dropFirst(previous.count))
                            } else {
                                delta = current
                            }
                            if !delta.isEmpty {
                                continuation.yield(delta)
                            }
                            previous = current
                        }
                        continuation.finish()
                    } catch {
                        // Handle cancellation gracefully
                        if Task.isCancelled {
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: Self.mapFrameworkError(error))
                        }
                    }
                }

                // Cancel producer task when consumer stops consuming
                continuation.onTermination = { @Sendable _ in
                    producerTask.cancel()
                }

                return stream
            } else {
                throw FoundationModelServiceError.notAvailable(.osTooOld)
            }
        #else
            throw FoundationModelServiceError.notAvailable(.frameworkMissing)
        #endif
    }

    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String {
        if Self.hasImageContent(messages) {
            throw FoundationModelServiceError.visionUnsupported
        }
        let prompt = OpenAIPromptBuilder.buildPrompt(from: messages)
        return try await Self.generateOneShot(
            prompt: prompt,
            temperature: parameters.temperature,
            maxTokens: parameters.maxTokens
        )
    }

    // MARK: - Tool calling bridge (OpenAI tools -> FoundationModels)

    func respondWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> String {
        if Self.hasImageContent(messages) {
            throw FoundationModelServiceError.visionUnsupported
        }
        let prompt = OpenAIPromptBuilder.buildPrompt(from: messages)
        try Self.requireAvailable()
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let appleTools: [any FoundationModels.Tool] =
                    tools
                    .filter { self.shouldEnableTool($0, choice: toolChoice) }
                    .map { self.toAppleTool($0) }

                let options = GenerationOptions(
                    sampling: nil,
                    temperature: parameters.temperature.map(Double.init),
                    maximumResponseTokens: parameters.maxTokens
                )

                do {
                    let session = LanguageModelSession(model: .default, tools: appleTools, instructions: nil)
                    let response = try await session.respond(to: prompt, options: options)
                    var reply = response.content
                    if !stopSequences.isEmpty {
                        for s in stopSequences {
                            if let r = reply.range(of: s) {
                                reply = String(reply[..<r.lowerBound])
                                break
                            }
                        }
                    }
                    return reply
                } catch let error as LanguageModelSession.ToolCallError {
                    if let inv = error.underlyingError as? ToolInvocationError {
                        // Re-throw using shared ServiceToolInvocation so callers don't need Foundation type
                        throw ServiceToolInvocation(toolName: inv.toolName, jsonArguments: inv.jsonArguments)
                    }
                    throw error
                } catch {
                    throw Self.mapFrameworkError(error)
                }
            } else {
                throw FoundationModelServiceError.notAvailable(.osTooOld)
            }
        #else
            throw FoundationModelServiceError.notAvailable(.frameworkMissing)
        #endif
    }

    func streamWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        if Self.hasImageContent(messages) {
            throw FoundationModelServiceError.visionUnsupported
        }
        let prompt = OpenAIPromptBuilder.buildPrompt(from: messages)
        try Self.requireAvailable()
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let appleTools: [any FoundationModels.Tool] =
                    tools
                    .filter { self.shouldEnableTool($0, choice: toolChoice) }
                    .map { self.toAppleTool($0) }

                let options = GenerationOptions(
                    sampling: nil,
                    temperature: parameters.temperature.map(Double.init),
                    maximumResponseTokens: parameters.maxTokens
                )

                let session = LanguageModelSession(model: .default, tools: appleTools, instructions: nil)
                let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
                let producerTask = Task {
                    var previous = ""
                    do {
                        var iterator = session.streamResponse(to: prompt, options: options).makeAsyncIterator()
                        while let snapshot = try await iterator.next() {
                            // Check for task cancellation to allow early termination
                            if Task.isCancelled {
                                continuation.finish()
                                return
                            }
                            var current = snapshot.content
                            if !stopSequences.isEmpty,
                                let r = stopSequences.compactMap({ current.range(of: $0)?.lowerBound }).first
                            {
                                current = String(current[..<r])
                            }
                            let delta: String
                            if current.hasPrefix(previous) {
                                delta = String(current.dropFirst(previous.count))
                            } else {
                                delta = current
                            }
                            if !delta.isEmpty {
                                continuation.yield(delta)
                            }
                            previous = current
                        }
                        continuation.finish()
                    } catch let error as LanguageModelSession.ToolCallError {
                        if let inv = error.underlyingError as? ToolInvocationError {
                            continuation.finish(
                                throwing: ServiceToolInvocation(
                                    toolName: inv.toolName,
                                    jsonArguments: inv.jsonArguments
                                )
                            )
                        } else {
                            continuation.finish(throwing: error)
                        }
                    } catch {
                        // Handle cancellation gracefully
                        if Task.isCancelled {
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: Self.mapFrameworkError(error))
                        }
                    }
                }

                // Cancel producer task when consumer stops consuming
                continuation.onTermination = { @Sendable _ in
                    producerTask.cancel()
                }

                return stream
            } else {
                throw FoundationModelServiceError.notAvailable(.osTooOld)
            }
        #else
            throw FoundationModelServiceError.notAvailable(.frameworkMissing)
        #endif
    }

    // MARK: - Capability detection

    /// True when any message carries image content (either an `image_url`
    /// part or a non-empty `imageUrls` accessor). Used to fast-fail the
    /// FoundationModels path with `visionUnsupported` instead of silently
    /// dropping images at the prompt builder.
    nonisolated static func hasImageContent(_ messages: [ChatMessage]) -> Bool {
        for msg in messages {
            if !msg.imageUrls.isEmpty { return true }
        }
        return false
    }

    // MARK: - Private helpers

    #if canImport(FoundationModels)
        @available(macOS 26.0, *)
        private struct ToolInvocationError: Error {
            let toolName: String
            let jsonArguments: String
        }

        @available(macOS 26.0, *)
        private struct OpenAIToolAdapter: FoundationModels.Tool {
            typealias Output = String
            typealias Arguments = GeneratedContent

            let name: String
            let description: String
            let parameters: GenerationSchema
            var includesSchemaInInstructions: Bool { true }

            func call(arguments: GeneratedContent) async throws -> String {
                // Serialize arguments as JSON and throw to signal a tool call back to the server
                let json = arguments.jsonString
                throw ToolInvocationError(toolName: name, jsonArguments: json)
            }
        }

        @available(macOS 26.0, *)
        private func toAppleTool(_ tool: Tool) -> any FoundationModels.Tool {
            let desc = tool.function.description ?? ""
            let schema: GenerationSchema = makeGenerationSchema(
                from: tool.function.parameters,
                toolName: tool.function.name,
                description: desc
            )
            return OpenAIToolAdapter(name: tool.function.name, description: desc, parameters: schema)
        }

        // Convert OpenAI JSON Schema (as JSONValue) to FoundationModels GenerationSchema
        @available(macOS 26.0, *)
        private func makeGenerationSchema(
            from parameters: JSONValue?,
            toolName: String,
            description: String?
        ) -> GenerationSchema {
            guard let parameters else {
                return GenerationSchema(
                    type: GeneratedContent.self,
                    description: description,
                    properties: []
                )
            }
            if let root = dynamicSchema(from: parameters, name: toolName) {
                if let schema = try? GenerationSchema(root: root, dependencies: []) {
                    return schema
                }
            }
            return GenerationSchema(type: GeneratedContent.self, description: description, properties: [])
        }

        // Build a DynamicGenerationSchema recursively from a minimal subset of JSON Schema
        @available(macOS 26.0, *)
        private func dynamicSchema(from json: JSONValue, name: String) -> DynamicGenerationSchema? {
            switch json {
            case .object(let dict):
                // enum of strings
                if case .array(let enumVals)? = dict["enum"],
                    case .string = enumVals.first
                {
                    let choices: [String] = enumVals.compactMap { v in
                        if case .string(let s) = v { return s } else { return nil }
                    }
                    return DynamicGenerationSchema(
                        name: name,
                        description: jsonStringOrNil(dict["description"]),
                        anyOf: choices
                    )
                }

                // type can be string or array
                var typeString: String? = nil
                if let t = dict["type"] {
                    switch t {
                    case .string(let s): typeString = s
                    case .array(let arr):
                        // Prefer first non-null type
                        typeString =
                            arr.compactMap { v in
                                if case .string(let s) = v, s != "null" { return s } else { return nil }
                            }.first
                    default: break
                    }
                }

                let desc = jsonStringOrNil(dict["description"])

                switch typeString ?? "object" {
                case "string":
                    return DynamicGenerationSchema(type: String.self)
                case "integer":
                    return DynamicGenerationSchema(type: Int.self)
                case "number":
                    return DynamicGenerationSchema(type: Double.self)
                case "boolean":
                    return DynamicGenerationSchema(type: Bool.self)
                case "array":
                    if let items = dict["items"],
                        let itemSchema = dynamicSchema(from: items, name: name + "Item")
                    {
                        let minItems = jsonIntOrNil(dict["minItems"])
                        let maxItems = jsonIntOrNil(dict["maxItems"])
                        return DynamicGenerationSchema(
                            arrayOf: itemSchema,
                            minimumElements: minItems,
                            maximumElements: maxItems
                        )
                    }
                    // Fallback to array of strings
                    return DynamicGenerationSchema(
                        arrayOf: DynamicGenerationSchema(type: String.self),
                        minimumElements: nil,
                        maximumElements: nil
                    )
                case "object": fallthrough
                default:
                    // Build object properties
                    var required: Set<String> = []
                    if case .array(let reqArr)? = dict["required"] {
                        required = Set(
                            reqArr.compactMap { v in if case .string(let s) = v { return s } else { return nil } }
                        )
                    }
                    var properties: [DynamicGenerationSchema.Property] = []
                    if case .object(let propsDict)? = dict["properties"] {
                        for (propName, propSchemaJSON) in propsDict {
                            let propSchema =
                                dynamicSchema(from: propSchemaJSON, name: name + "." + propName)
                                ?? DynamicGenerationSchema(type: String.self)
                            let isOptional = !required.contains(propName)
                            let prop = DynamicGenerationSchema.Property(
                                name: propName,
                                description: nil,
                                schema: propSchema,
                                isOptional: isOptional
                            )
                            properties.append(prop)
                        }
                    }
                    return DynamicGenerationSchema(name: name, description: desc, properties: properties)
                }

            case .string:
                return DynamicGenerationSchema(type: String.self)
            case .number:
                return DynamicGenerationSchema(type: Double.self)
            case .bool:
                return DynamicGenerationSchema(type: Bool.self)
            case .array(let arr):
                // Attempt array of first element type
                if let first = arr.first, let item = dynamicSchema(from: first, name: name + "Item") {
                    return DynamicGenerationSchema(arrayOf: item, minimumElements: nil, maximumElements: nil)
                }
                return DynamicGenerationSchema(
                    arrayOf: DynamicGenerationSchema(type: String.self),
                    minimumElements: nil,
                    maximumElements: nil
                )
            case .null:
                // Default to string when null only
                return DynamicGenerationSchema(type: String.self)
            }
        }

        // Helpers to extract primitive values from JSONValue
        private func jsonStringOrNil(_ value: JSONValue?) -> String? {
            guard let value else { return nil }
            if case .string(let s) = value { return s }
            return nil
        }
        private func jsonIntOrNil(_ value: JSONValue?) -> Int? {
            guard let value else { return nil }
            switch value {
            case .number(let d): return Int(d)
            case .string(let s): return Int(s)
            default: return nil
            }
        }

        @available(macOS 26.0, *)
        private func shouldEnableTool(_ tool: Tool, choice: ToolChoiceOption?) -> Bool {
            guard let choice else { return true }
            switch choice {
            case .auto, .required: return true
            case .none: return false
            case .function(let n):
                return n.function.name == tool.function.name
            }
        }
    #endif
}
