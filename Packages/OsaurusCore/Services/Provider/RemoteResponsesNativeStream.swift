import Foundation
import os

/// Native Responses SSE reduction. Retains only call arguments and completed
/// Items, never a second growing text/reasoning transcript. Raw lifecycle
/// events reach the consumer before their portable projections.
final class RemoteResponsesNativeStream: RemoteNativeStreamConsumer, @unchecked Sendable {
    private struct State {
        var observed = false
        var completed = false
        var responseID: String?
        var itemIndices: [String: Int] = [:]
        var emittedItemIDs: Set<String> = []
        var emittedItemIndices: Set<Int> = []
        var textRails: Set<String> = []
        var refusalRails: Set<String> = []
        var reasoningRails: Set<String> = []
        var calls: [Int: ResponsesFunctionCall] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let yield: @Sendable (ResponsesGenerationEvent) -> Void
    init(yield: @escaping @Sendable (ResponsesGenerationEvent) -> Void) { self.yield = yield }
    var observed: Bool { state.withLock { $0.observed } }
    var completed: Bool { state.withLock { $0.completed } }

    func consume(_ payload: String) throws -> Bool {
        if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            guard completed else { throw ResponsesGenerationResult.CollectionError.missingCompletion }
            return true
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
        guard case .object(let event) = value, let type = event["type"]?.string else {
            throw RemoteProviderServiceError.streamingError("Responses SSE event omitted its type.")
        }
        return try state.withLock { state in
            guard !state.completed else { return true }
            state.observed = true
            yield(.providerEvent(value))
            if let response = event["response"]?.object, let id = response["id"]?.string { state.responseID = id }
            let index = event["output_index"]?.integer
                ?? event["item_id"]?.string.flatMap { state.itemIndices[$0] } ?? 0
            let contentIndex = event["content_index"]?.integer ?? event["summary_index"]?.integer ?? 0
            let rail = "\(index):\(contentIndex)"
            switch type {
            case "response.output_text.delta":
                state.textRails.insert(rail)
                if let delta = event["delta"]?.string { yield(.outputTextDelta(delta)) }
            case "response.refusal.delta":
                state.refusalRails.insert(rail)
                if let delta = event["delta"]?.string { yield(.outputTextDelta(delta)) }
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                state.reasoningRails.insert(rail)
                if let delta = event["delta"]?.string { yield(.reasoningDelta(delta)) }
            case "response.output_text.done":
                if state.textRails.insert(rail).inserted, let text = event["text"]?.string { yield(.outputTextDelta(text)) }
            case "response.refusal.done":
                if state.refusalRails.insert(rail).inserted, let text = event["refusal"]?.string { yield(.outputTextDelta(text)) }
            case "response.reasoning_summary_text.done", "response.reasoning_text.done":
                if state.reasoningRails.insert(rail).inserted, let text = event["text"]?.string { yield(.reasoningDelta(text)) }
            case "response.output_item.added":
                if let item = event["item"]?.object {
                    if let id = item["id"]?.string { state.itemIndices[id] = index }
                    if item["type"]?.string == "function_call" {
                        let call = Self.call(item)
                        if let call { state.calls[index] = call; yield(.functionNamePreview(call.name)) }
                    }
                }
            case "response.function_call_arguments.delta":
                if let delta = event["delta"]?.string {
                    if let call = state.calls[index] {
                        state.calls[index] = .init(id: call.id, callID: call.callID, name: call.name,
                            arguments: call.arguments + delta, geminiThoughtSignature: call.geminiThoughtSignature)
                    }
                    yield(.functionArgumentsPreview(delta))
                }
            case "response.function_call_arguments.done":
                if let call = state.calls[index], let arguments = event["arguments"]?.string {
                    state.calls[index] = .init(id: call.id, callID: call.callID, name: call.name,
                        arguments: arguments, geminiThoughtSignature: call.geminiThoughtSignature)
                }
            case "response.output_item.done":
                if let item = event["item"] { capture(item, index: index, state: &state) }
            case "response.completed", "response.incomplete", "response.cancelled":
                guard let response = event["response"]?.object,
                    let responseID = response["id"]?.string ?? state.responseID, !responseID.isEmpty
                else { throw RemoteProviderServiceError.streamingError("Responses terminal omitted its response ID.") }
                if let output = response["output"]?.array {
                    for (index, item) in output.enumerated() { capture(item, index: index, state: &state) }
                }
                let status: ResponsesGenerationCompletion.Status
                let reason: String
                if type == "response.cancelled" || response["status"]?.string == "cancelled" {
                    status = .cancelled; reason = "cancelled"
                } else if type == "response.incomplete" || response["status"]?.string == "incomplete" {
                    status = .incomplete
                    let nativeReason = response["incomplete_details"]?.object?["reason"]?.string
                    reason = nativeReason == "max_output_tokens" ? "length" : (nativeReason ?? "incomplete")
                } else {
                    status = .completed; reason = "stop"
                    guard Set(state.calls.values.map(\.callID)).count == state.calls.count else {
                        throw RemoteProviderServiceError.streamingError("Responses completed with duplicate function call IDs.")
                    }
                    // The terminal is authoritative. Do not repair a malformed
                    // complete call or silently dispatch a partial JSON value.
                    for call in state.calls.values {
                        _ = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8), options: [.fragmentsAllowed])
                    }
                }
                let usage = response["usage"]?.object
                let input = usage?["input_tokens"]?.nonnegativeInteger
                let output = usage?["output_tokens"]?.nonnegativeInteger
                let cached = usage?["input_tokens_details"]?.object?["cached_tokens"]?.nonnegativeInteger
                if let input { yield(.inputTokenCount(input)) }
                state.completed = true
                yield(.responseCompleted(.init(responseID: responseID, status: status,
                    functionCalls: state.calls.sorted { $0.key < $1.key }.map(\.value),
                    tokenCount: output, tokensPerSecond: usage?["tokens_per_second"]?.finiteNumber,
                    unclosedReasoning: false, stopReason: reason,
                    promptTokensPerSecond: usage?["prefill_tokens_per_second"]?.finiteNumber,
                    mtp: nil, inputTokenCount: input, cachedInputTokenCount: cached)))
                return true
            case "response.failed", "error":
                let response = event["response"]?.object
                let error = response?["error"]?.object ?? event["error"]?.object
                throw RemoteProviderServiceError.streamingError(error?["message"]?.string ?? "The provider failed its Responses request.")
            default:
                break
            }
            return false
        }
    }

    private func capture(_ value: JSONValue, index: Int, state: inout State) {
        guard let item = value.object else { return }
        if let id = item["id"]?.string { state.itemIndices[id] = index }
        if let call = Self.call(item) {
            // An Item may be repeated in the terminal object's full output
            // array; retain its provider identity even if a sparse peer
            // omitted earlier array entries when framing that terminal.
            for (oldIndex, old) in state.calls where oldIndex != index && old.id == call.id && old.callID == call.callID {
                state.calls.removeValue(forKey: oldIndex)
            }
            state.calls[index] = call
        }
        let id = item["id"]?.string
        let alreadyEmitted = id.map { state.emittedItemIDs.contains($0) } ?? state.emittedItemIndices.contains(index)
        guard !alreadyEmitted else { return }
        if let id { state.emittedItemIDs.insert(id) }
        state.emittedItemIndices.insert(index)
        yield(.providerOutputItem(value))
        switch item["type"]?.string {
        case "function_call":
            if let call = state.calls[index] { yield(.functionCallAdded(call)) }
        case "reasoning":
            if let id = item["id"]?.string, let encrypted = item["encrypted_content"]?.string {
                yield(.reasoningItem(.init(id: id, encryptedContent: encrypted)))
            }
            for (part, summary) in (item["summary"]?.array ?? []).enumerated() {
                let rail = "\(index):\(part)"
                if state.reasoningRails.insert(rail).inserted, let text = summary.object?["text"]?.string {
                    yield(.reasoningDelta(text))
                }
            }
        case "message":
            for (part, content) in (item["content"]?.array ?? []).enumerated() {
                let rail = "\(index):\(part)"
                if content.object?["type"]?.string == "output_text",
                    state.textRails.insert(rail).inserted, let text = content.object?["text"]?.string
                { yield(.outputTextDelta(text)) }
                if content.object?["type"]?.string == "refusal",
                    state.refusalRails.insert(rail).inserted, let text = content.object?["refusal"]?.string
                { yield(.outputTextDelta(text)) }
            }
        default: break
        }
    }
    private static func call(_ item: [String: JSONValue]) -> ResponsesFunctionCall? {
        guard item["type"]?.string == "function_call", let id = item["id"]?.string,
            let callID = item["call_id"]?.string, let name = item["name"]?.string,
            let arguments = item["arguments"]?.string
        else { return nil }
        return .init(id: id, callID: callID, name: name, arguments: arguments)
    }
}

private extension JSONValue {
    var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var finiteNumber: Double? { if case .number(let value) = self, value.isFinite, value >= 0 { return value }; return nil }
    var integer: Int? {
        guard case .number(let value) = self, value.isFinite, value.rounded() == value,
            value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }
    var nonnegativeInteger: Int? { integer.flatMap { $0 >= 0 ? $0 : nil } }
}
