import Foundation
import os

/// Enforces explicit API tool choice against the whole completed response.
/// It never alters prompts, schemas, sampling, call names or arguments.
enum ResponsesToolChoiceContract {
    static func failure(_ message: String) -> NSError {
        NSError(domain: "OsaurusToolChoice", code: 422, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func choice(_ request: ResponsesInferenceRequest) -> ToolChoiceOption? {
        guard let choice = request.providerOptions?.toolChoice else { return request.toolChoice }
        switch choice {
        case .auto: return .auto
        case .none: return ToolChoiceOption.none
        case .required: return .required
        case .function(let name): return .function(.init(type: "function", function: .init(name: name)))
        }
    }

    private static func functionNames(_ request: ResponsesInferenceRequest) -> Set<String> {
        Set((request.tools ?? []).map(\.function.name)
            + (request.providerOptions?.tools ?? []).filter(\.isFunction).compactMap(\.name))
    }

    static func preflight(_ request: ResponsesInferenceRequest) throws {
        guard let choice = choice(request) else { return }
        let names = functionNames(request)
        switch choice {
        case .auto, .none: break
        case .required:
            guard !names.isEmpty || request.providerOptions?.unsupportedPortableTools.isEmpty == false else {
                throw failure("tool_choice required needs at least one declared tool. No generation was started.")
            }
        case .function(let target):
            guard names.contains(target.function.name) else {
                throw failure("The named tool '\(target.function.name)' is not declared. No generation was started.")
            }
        }
    }

    /// Hosted calls are provider-owned output Items, not local function calls.
    /// These protocol item kinds must not be mistaken for a missing function.
    private struct HostedCall: Sendable {
        let type: String
        let identity: String?
        let name: String?
        let status: String?
    }
    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let text) = value { return text }; return nil
    }
    private static func hostedCall(_ value: JSONValue) -> HostedCall? {
        guard case .object(let item) = value, let type = string(item["type"]),
            (type.hasSuffix("_call") && type != "function_call") || type == "mcp_approval_request" else { return nil }
        return HostedCall(type: type, identity: string(item["id"]) ?? string(item["call_id"]),
            name: string(item["name"]), status: string(item["status"]))
    }
    private static func matches(_ call: HostedCall, declaration: OpenResponsesTool) -> Bool {
        guard !declaration.isFunction, call.identity?.isEmpty == false,
            call.status == nil || call.status == "completed" else { return false }
        // An actual MCP approval request is a tool decision awaiting consent,
        // not proof of execution. Preserve it for the owning API client.
        if declaration.type == "mcp" && call.type == "mcp_approval_request" { return true }
        let kind: String
        switch declaration.type {
        case "web_search_preview": kind = "web_search_call"
        case "computer_use_preview", "computer": kind = "computer_call"
        case "custom": kind = "custom_tool_call"
        default: kind = declaration.type + "_call"
        }
        guard call.type == kind else { return false }
        if declaration.type == "custom", case .object(let raw) = declaration.raw,
            let expected = string(raw["name"]) { return call.name == expected }
        return true
    }

    private static func validate(
        _ completion: ResponsesGenerationCompletion, request: ResponsesInferenceRequest, hosted: [HostedCall]
    ) throws {
        // Length, upstream cancellation and unfinished reasoning retain their
        // real status; none becomes a missing-tool retry or fake success.
        guard completion.status == .completed, !completion.unclosedReasoning,
            completion.stopReason != "length", let choice = choice(request) else { return }
        let calls = completion.functionCalls
        switch choice {
        case .auto: return
        case .none:
            guard calls.isEmpty && hosted.isEmpty else {
                throw failure("The model returned tool calls although tool_choice was none. No local tool was executed.")
            }
        case .required:
            let declarations = request.providerOptions?.tools ?? []
            let hasHosted = hosted.contains { call in declarations.contains { matches(call, declaration: $0) } }
            guard !calls.isEmpty || hasHosted else {
                throw failure("The model completed without the required tool call. No local tool was executed.")
            }
            let declared = functionNames(request)
            guard calls.allSatisfy({ declared.contains($0.name) }) else {
                throw failure("The model returned a tool outside the declared required tools. No local tool was executed.")
            }
        case .function(let target):
            guard !calls.isEmpty, hosted.isEmpty,
                calls.allSatisfy({ $0.name == target.function.name }) else {
                throw failure("The whole response must call '\(target.function.name)' only. No local tool was executed.")
            }
        }
        let ids = calls.map(\.callID)
        guard ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
            Set(ids).count == ids.count else {
            throw failure("The model returned empty or duplicate call IDs. No local tool was executed.")
        }
    }

    static func enforce(
        _ upstream: AsyncThrowingStream<ResponsesGenerationEvent, Error>, request: ResponsesInferenceRequest
    ) -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
        guard let choice = choice(request) else { return upstream }
        if case .auto = choice { return upstream }
        let (stream, continuation) = AsyncThrowingStream<ResponsesGenerationEvent, Error>.makeStream()
        let completed = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            var hosted: [HostedCall] = []
            var pendingNativeSuccess: JSONValue?
            do {
                for try await event in upstream {
                    if Task.isCancelled { continue }
                    if case .providerOutputItem(let item) = event, let call = hostedCall(item) { hosted.append(call) }
                    if case .providerEvent(let value) = event, case .object(let fields) = value,
                        string(fields["type"]) == "response.completed" {
                        guard pendingNativeSuccess == nil else { throw ResponsesGenerationResult.CollectionError.duplicateCompletion }
                        pendingNativeSuccess = value
                        continue
                    }
                    if case .responseCompleted(let response) = event {
                        do {
                            try validate(response, request: request, hosted: hosted)
                        } catch {
                            let original = error as NSError
                            var info = original.userInfo
                            info["response_id"] = response.responseID
                            throw NSError(domain: original.domain, code: original.code, userInfo: info)
                        }
                        completed.withLock { $0 = true }
                        // Native success must not escape before original API
                        // intent validates. Keep its original identity/order.
                        if let raw = pendingNativeSuccess { continuation.yield(.providerEvent(raw)); pendingNativeSuccess = nil }
                    }
                    continuation.yield(event)
                }
                if Task.isCancelled { throw CancellationError() }
                if pendingNativeSuccess != nil { throw ResponsesGenerationResult.CollectionError.missingCompletion }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { reason in
            if case .cancelled = reason, !completed.withLock({ $0 }) { task.cancel() }
        }
        return stream
    }
}
