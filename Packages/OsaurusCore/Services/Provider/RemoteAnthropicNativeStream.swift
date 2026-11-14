import Foundation
import os

protocol RemoteNativeStreamConsumer: Sendable {
    var observed: Bool { get }
    var completed: Bool { get }
    func consume(_ payload: String) throws -> Bool
}

/// Anthropic stays an explicit provider adapter. Signed thinking is retained
/// as Anthropic data; it never masquerades as OpenAI Responses output Items.
final class RemoteAnthropicNativeStream: RemoteNativeStreamConsumer, @unchecked Sendable {
    private struct Call {
        let id: String
        let name: String
        let initialArguments: String
        var deltaArguments: String?
        var arguments: String { deltaArguments ?? initialArguments }
    }
    private struct State {
        var observed = false
        var completed = false
        var responseID: String?
        var thinking: [Int: [String: JSONValue]] = [:]
        var emittedThinking: Set<Int> = []
        var calls: [Int: Call] = [:]
        var promptTokens: Int?
        var outputTokens: Int?
        var cachedTokens: Int?
        var stopReason: String?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let yield: @Sendable (ResponsesGenerationEvent) -> Void
    init(yield: @escaping @Sendable (ResponsesGenerationEvent) -> Void) { self.yield = yield }
    var observed: Bool { state.withLock { $0.observed } }
    var completed: Bool { state.withLock { $0.completed } }

    func consume(_ payload: String) throws -> Bool {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
        guard let event = Self.object(value), let type = Self.string(event["type"]) else {
            throw RemoteProviderServiceError.streamingError("Anthropic SSE event omitted its type.")
        }
        return try state.withLock { state in
            state.observed = true
            let index = Self.integer(event["index"]) ?? 0
            switch type {
            case "message_start":
                if let message = Self.object(event["message"]) {
                    state.responseID = Self.string(message["id"])
                    if let usage = Self.object(message["usage"]) {
                        if let input = Self.integer(usage["input_tokens"]) {
                            state.promptTokens = input + (Self.integer(usage["cache_read_input_tokens"]) ?? 0)
                                + (Self.integer(usage["cache_creation_input_tokens"]) ?? 0)
                        }
                        state.cachedTokens = Self.integer(usage["cache_read_input_tokens"])
                        state.outputTokens = Self.integer(usage["output_tokens"])
                    }
                }
            case "content_block_start":
                guard let block = Self.object(event["content_block"]) else { break }
                switch Self.string(block["type"]) {
                case "thinking", "redacted_thinking":
                    state.thinking[index] = block
                    if let thinking = Self.string(block["thinking"]), !thinking.isEmpty { yield(.reasoningDelta(thinking)) }
                case "tool_use":
                    if let id = Self.string(block["id"]), let name = Self.string(block["name"]), let input = block["input"] {
                        let arguments = String(decoding: try JSONEncoder.osaurusCanonical().encode(input), as: UTF8.self)
                        state.calls[index] = Call(id: id, name: name, initialArguments: arguments)
                        yield(.functionNamePreview(name))
                    }
                case "text":
                    if let text = Self.string(block["text"]), !text.isEmpty { yield(.outputTextDelta(text)) }
                default: break
                }
            case "content_block_delta":
                guard let delta = Self.object(event["delta"]) else { break }
                switch Self.string(delta["type"]) {
                case "thinking_delta":
                    if let text = Self.string(delta["thinking"]) {
                        var block = state.thinking[index] ?? ["type": .string("thinking")]
                        block["thinking"] = .string((Self.string(block["thinking"]) ?? "") + text)
                        state.thinking[index] = block
                        yield(.reasoningDelta(text))
                    }
                case "signature_delta":
                    if let signature = Self.string(delta["signature"]) {
                        var block = state.thinking[index] ?? ["type": .string("thinking")]
                        block["signature"] = .string((Self.string(block["signature"]) ?? "") + signature)
                        state.thinking[index] = block
                    }
                case "text_delta":
                    if let text = Self.string(delta["text"]) { yield(.outputTextDelta(text)) }
                case "input_json_delta":
                    if let fragment = Self.string(delta["partial_json"]), var call = state.calls[index] {
                        call.deltaArguments = (call.deltaArguments ?? "") + fragment
                        state.calls[index] = call
                        yield(.functionArgumentsPreview(fragment))
                    }
                default: break
                }
            case "content_block_stop":
                emitThinking(index, state: &state)
                if let call = state.calls[index] {
                    yield(.functionCallAdded(.init(id: call.id, callID: call.id, name: call.name, arguments: call.arguments)))
                }
            case "message_delta":
                if let usage = Self.object(event["usage"]), let output = Self.integer(usage["output_tokens"]) { state.outputTokens = output }
                if let delta = Self.object(event["delta"]), let reason = Self.string(delta["stop_reason"]) { state.stopReason = reason }
            case "message_stop":
                guard !state.completed else { return true }
                guard let responseID = state.responseID, !responseID.isEmpty else {
                    throw RemoteProviderServiceError.streamingError("Anthropic terminal omitted its message ID.")
                }
                for index in state.thinking.keys.sorted() { emitThinking(index, state: &state) }
                let status: ResponsesGenerationCompletion.Status
                let reason: String
                switch state.stopReason {
                case "max_tokens": status = .incomplete; reason = "length"
                case "pause_turn": status = .incomplete; reason = "pause_turn"
                case "tool_use": status = .completed; reason = "tool_calls"
                case "end_turn", "stop_sequence": status = .completed; reason = "stop"
                case "refusal":
                    throw RemoteProviderServiceError.streamingError("The Anthropic provider refused this request.")
                default:
                    throw RemoteProviderServiceError.streamingError("Anthropic stream ended without a stop reason.")
                }
                if case .completed = status {
                    for call in state.calls.values {
                        _ = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8), options: [.fragmentsAllowed])
                    }
                }
                state.completed = true
                if let prompt = state.promptTokens { yield(.inputTokenCount(prompt)) }
                yield(.responseCompleted(.init(responseID: responseID, status: status,
                    functionCalls: state.calls.sorted { $0.key < $1.key }.map { _, call in
                        .init(id: call.id, callID: call.id, name: call.name, arguments: call.arguments)
                    }, tokenCount: state.outputTokens, tokensPerSecond: nil, unclosedReasoning: false,
                    stopReason: reason, promptTokensPerSecond: nil, mtp: nil,
                    inputTokenCount: state.promptTokens, cachedInputTokenCount: state.cachedTokens)))
                return true
            case "error":
                let message = Self.object(event["error"]).flatMap { Self.string($0["message"]) }
                throw RemoteProviderServiceError.streamingError(message ?? "The Anthropic stream failed.")
            default: break
            }
            return false
        }
    }
    private func emitThinking(_ index: Int, state: inout State) {
        guard let block = state.thinking[index], state.emittedThinking.insert(index).inserted else { return }
        yield(.anthropicThinkingBlock(.object(block)))
    }
    private static func object(_ value: JSONValue?) -> [String: JSONValue]? { if case .object(let value) = value { return value }; return nil }
    private static func string(_ value: JSONValue?) -> String? { if case .string(let value) = value { return value }; return nil }
    private static func integer(_ value: JSONValue?) -> Int? {
        guard case .number(let value) = value, value.isFinite, value >= 0, value < Double(Int.max), value.rounded() == value else { return nil }
        return Int(value)
    }
}
