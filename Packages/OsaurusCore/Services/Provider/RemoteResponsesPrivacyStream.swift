import Foundation

/// Restores portable output and native SSE through the same map. Ambiguous
/// split placeholders retain their original frames until the rail resolves;
/// lifecycle/indices are never replaced by synthetic transport events.
enum RemoteResponsesPrivacyStream {
    static let maxPendingBytes = 1_048_576
    struct PendingFrameLimitError: Error, LocalizedError {
        var errorDescription: String? {
            "Privacy restoration exceeded its bounded pending-frame buffer while waiting for a split placeholder. The stream was stopped without replay."
        }
    }

    static func wrap(_ upstream: AsyncThrowingStream<ResponsesGenerationEvent, Error>, map: RedactionMap?,
        pendingByteLimit: Int = maxPendingBytes
    ) -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
        guard let map else { return upstream }
        return AsyncThrowingStream { continuation in
            let task = Task {
                let state = State(map: map, limit: pendingByteLimit)
                do {
                    for try await event in upstream {
                        try Task.checkCancellation()
                        for restored in try await state.consume(event) { continuation.yield(restored) }
                    }
                    for restored in await state.finish() { continuation.yield(restored) }
                    continuation.finish()
                } catch {
                    // An upstream failure does not erase already received
                    // frames. Flush literal unmatched suffixes on those same
                    // frames, then preserve the original terminal error. The
                    // over-budget path deliberately never drains its queue.
                    if !(error is PendingFrameLimitError) {
                        for restored in await state.finish() { continuation.yield(restored) }
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private final class Rail {
        let native: StreamingUnscrubber
        let portable: StreamingUnscrubber
        var rawIndex: Int?
        var portableIndex: Int?
        init(native: StreamingUnscrubber, portable: StreamingUnscrubber) { self.native = native; self.portable = portable }
        var pending: Bool { native.hasPendingFragment || portable.hasPendingFragment }
    }
    /// Owned exclusively by the single stream-consumer task.
    private final class State {
        let map: RedactionMap
        let limit: Int
        var rails: [String: Rail] = [:]
        var queued: [ResponsesGenerationEvent] = []
        var heldBytes = 0
        var currentKeys: [String: String] = [:]
        var currentVisibleKey: String?
        init(map: RedactionMap, limit: Int) { self.map = map; self.limit = limit }

        func rail(_ key: String) async -> Rail {
            if let value = rails[key] { return value }
            let escaping = key.hasPrefix("arguments:")
            let value = Rail(native: await StreamingUnscrubber.make(for: map, jsonStringEscaping: escaping),
                portable: await StreamingUnscrubber.make(for: map, jsonStringEscaping: escaping))
            rails[key] = value
            return value
        }
        var hasPending: Bool { rails.values.contains { $0.pending } }

        func consume(_ input: ResponsesGenerationEvent) async throws -> [ResponsesGenerationEvent] {
            var event = input
            var rawRail: Rail?
            var portableRail: Rail?
            switch input {
            case .providerEvent(let value):
                if case .object(var object) = value, case .string(let type) = object["type"] {
                    let index: String = object["output_index"].map(Self.identity) ?? object["item_id"].map(Self.identity) ?? "0"
                    let part = object["content_index"].map(Self.identity) ?? object["summary_index"].map(Self.identity) ?? "0"
                    let kind: String?
                    switch type {
                    case "response.output_text.delta", "response.output_text.done": kind = "text"
                    case "response.reasoning_text.delta", "response.reasoning_text.done",
                         "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done": kind = "reasoning"
                    case "response.function_call_arguments.delta", "response.function_call_arguments.done": kind = "arguments"
                    case "response.refusal.delta", "response.refusal.done": kind = "refusal"
                    default: kind = nil
                    }
                    if let kind {
                        let key = "\(kind):\(index):\(part)"
                        currentKeys[kind] = key
                        if kind == "text" || kind == "refusal" { currentVisibleKey = key }
                        let value = await rail(key)
                        if type.hasSuffix(".delta"), case .string(let delta) = object["delta"] {
                            object["delta"] = .string(await value.native.push(delta))
                            rawRail = value
                        } else if type.hasSuffix(".done") { await flush(value) }
                    }
                    if type == "response.output_item.done" {
                        for (key, rail) in rails where key.split(separator: ":").dropFirst().first.map(String.init) == index {
                            await flush(rail)
                        }
                    }
                    if ["response.completed", "response.incomplete", "response.cancelled", "response.failed", "error"].contains(type) {
                        await flushAll()
                    }
                    event = .providerEvent(await PrivacyFilterPipeline.unscrubInboundJSON(.object(object), map: map))
                } else { event = .providerEvent(await PrivacyFilterPipeline.unscrubInboundJSON(value, map: map)) }
            case .outputTextDelta(let delta):
                let value = await rail(currentVisibleKey ?? "text:portable:0")
                event = .outputTextDelta(await value.portable.push(delta)); portableRail = value
            case .reasoningDelta(let delta):
                let value = await rail(currentKeys["reasoning"] ?? "reasoning:portable:0")
                event = .reasoningDelta(await value.portable.push(delta)); portableRail = value
            case .functionArgumentsPreview(let delta):
                let value = await rail(currentKeys["arguments"] ?? "arguments:portable:0")
                event = .functionArgumentsPreview(await value.portable.push(delta)); portableRail = value
            case .providerOutputItem(let value):
                event = .providerOutputItem(await PrivacyFilterPipeline.unscrubInboundJSON(value, map: map))
            case .functionCallAdded(let call): event = .functionCallAdded(await restored(call))
            case .anthropicThinkingBlock:
                // Signed text and redacted payloads are immutable. Restore
                // the separate portable reasoning rail for UI presentation.
                break
            case .responseCompleted(let completion):
                await flushAll()
                var calls: [ResponsesFunctionCall] = []
                for call in completion.functionCalls { calls.append(await restored(call)) }
                event = .responseCompleted(.init(responseID: completion.responseID, status: completion.status,
                    functionCalls: calls, tokenCount: completion.tokenCount, tokensPerSecond: completion.tokensPerSecond,
                    unclosedReasoning: completion.unclosedReasoning, stopReason: completion.stopReason,
                    promptTokensPerSecond: completion.promptTokensPerSecond, mtp: completion.mtp,
                    inputTokenCount: completion.inputTokenCount, cachedInputTokenCount: completion.cachedInputTokenCount))
            default: break
            }
            if !hasPending {
                // Once ambiguity resolves, emit the earlier original frames
                // before this event. A large valid terminal/Item need not fit
                // in the pending-placeholder queue at all.
                return drainIfReady() + [event]
            }
            let index = queued.count
            let bytes = Self.estimatedBytes(event)
            guard bytes <= limit - heldBytes else { throw PendingFrameLimitError() }
            queued.append(event)
            rawRail?.rawIndex = index
            portableRail?.portableIndex = index
            heldBytes += bytes
            return []
        }

        private func restored(_ call: ResponsesFunctionCall) async -> ResponsesFunctionCall {
            let value = await PrivacyFilterPipeline.unscrubInboundJSON(.object([
                "type": .string("function_call"), "id": .string(call.id), "call_id": .string(call.callID),
                "name": .string(call.name), "arguments": .string(call.arguments),
            ]), map: map)
            var args = call.arguments
            if case .object(let body) = value, case .string(let string) = body["arguments"] { args = string }
            return .init(id: call.id, callID: call.callID, name: call.name, arguments: args,
                geminiThoughtSignature: call.geminiThoughtSignature)
        }
        private func flush(_ rail: Rail) async {
            let native = await rail.native.flush()
            if !native.isEmpty, let index = rail.rawIndex, queued.indices.contains(index),
                case .providerEvent(.object(var object)) = queued[index], case .string(let delta) = object["delta"]
            { object["delta"] = .string(delta + native); queued[index] = .providerEvent(.object(object)) }
            let portable = await rail.portable.flush()
            if !portable.isEmpty, let index = rail.portableIndex, queued.indices.contains(index) {
                switch queued[index] {
                case .outputTextDelta(let delta): queued[index] = .outputTextDelta(delta + portable)
                case .reasoningDelta(let delta): queued[index] = .reasoningDelta(delta + portable)
                case .functionArgumentsPreview(let delta): queued[index] = .functionArgumentsPreview(delta + portable)
                default: break
                }
            }
            heldBytes = queued.reduce(0) { $0 + Self.estimatedBytes($1) }
        }
        private func flushAll() async { for rail in rails.values { await flush(rail) } }
        func finish() async -> [ResponsesGenerationEvent] {
            await flushAll()
            return drainIfReady()
        }
        private func drainIfReady() -> [ResponsesGenerationEvent] {
            guard !hasPending else { return [] }
            let values = queued
            queued.removeAll(keepingCapacity: true); heldBytes = 0
            for rail in rails.values { rail.rawIndex = nil; rail.portableIndex = nil }
            return values
        }
        private static func identity(_ value: JSONValue) -> String {
            switch value { case .string(let value): return value; case .number(let value): return value.isFinite && value >= Double(Int.min) && value < Double(Int.max) ? String(Int(value)) : String(value); default: return "0" }
        }
        private static func estimatedBytes(_ event: ResponsesGenerationEvent) -> Int {
            switch event {
            case .providerEvent(let value), .providerOutputItem(let value): return (try? JSONEncoder().encode(value).count) ?? 0
            case .outputTextDelta(let value), .reasoningDelta(let value), .functionArgumentsPreview(let value): return value.utf8.count
            case .functionCallAdded(let call): return call.arguments.utf8.count + call.name.utf8.count
            case .anthropicThinkingBlock(let value): return (try? JSONEncoder().encode(value).count) ?? 0
            default: return 64
            }
        }
    }
}
