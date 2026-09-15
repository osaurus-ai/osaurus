//
//  EvalRunnerHTTPAPI.swift
//  OsaurusEvalsKit
//
//  Runner for the `http_api` domain — the live HTTP contract lane. The
//  first case lazily starts ONE in-process `OsaurusServer` bound to an
//  ephemeral loopback port (never 1337, so a user's running Osaurus is
//  never touched) and every case drives real HTTP requests at it through
//  URLSession: SSE chunk shape, `/v1/responses` event ordering,
//  `/admin/cache-stats` contract, behavioral params (stop sequences,
//  max_tokens truncation, typed errors), structured-output JSON mode,
//  chat-vs-agents parity, and concurrent-request isolation.
//
//  Loopback connections skip Bearer auth by design (trustLoopback), so
//  the lane needs no key material — exactly the production local-client
//  shape. The server is torn down with the process (matching the pattern
//  the sandbox container uses); cases share it because NIO group startup
//  is expensive and the server is stateless between requests.
//

import Foundation
import OsaurusCore

// MARK: - Shared in-process server

/// Lazily-started shared server for the whole suite process.
@MainActor
enum EvalHTTPServerHost {
    private static var server: OsaurusServer?
    private static var port: Int?
    private static var startError: String?

    /// Start (once) and return the bound ephemeral port, or the sticky
    /// start-failure message (retrying a failed NIO bind mid-suite would
    /// just burn every case on the same error).
    static func ensureStarted() async -> (port: Int?, error: String?) {
        if let port { return (port, nil) }
        if let startError { return (nil, startError) }
        let server = OsaurusServer()
        do {
            try await server.start(
                OsaurusServer.Config(host: "127.0.0.1", port: 0, trustLoopback: true)
            )
        } catch {
            let message = "in-process OsaurusServer failed to start: \(error)"
            startError = message
            return (nil, message)
        }
        guard let bound = await server.boundPort() else {
            let message = "in-process OsaurusServer started but reported no bound port"
            startError = message
            return (nil, message)
        }
        Self.server = server
        Self.port = bound
        FileHandle.standardError.write(
            Data("[evals] http_api lane: in-process server on 127.0.0.1:\(bound)\n".utf8)
        )
        return (bound, nil)
    }
}

// MARK: - SSE plumbing

/// One parsed SSE event: optional `event:` name plus the joined `data:`
/// payload. `[DONE]` sentinels come through with `data == "[DONE]"`.
struct EvalSSEEvent {
    let name: String?
    let data: String
}

extension EvalRunner {

    // MARK: HTTP helpers

    private static func evalRequestModel() -> String {
        ChatConfigurationStore.load().coreModelIdentifier ?? "foundation"
    }

    private static func makeRequest(
        port: Int,
        path: String,
        method: String = "POST",
        body: [String: Any]? = nil
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 600
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private static func httpJSON(
        port: Int,
        path: String,
        method: String = "POST",
        body: [String: Any]? = nil
    ) async throws -> (status: Int, json: [String: Any]?, raw: String) {
        let (data, response) = try await URLSession.shared.data(
            for: makeRequest(port: port, path: path, method: method, body: body)
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (status, json, String(decoding: data, as: UTF8.self))
    }

    /// Stream an SSE response to completion and return the parsed events.
    private static func httpSSE(
        port: Int,
        path: String,
        body: [String: Any]
    ) async throws -> (status: Int, events: [EvalSSEEvent]) {
        let (bytes, response) = try await URLSession.shared.bytes(
            for: makeRequest(port: port, path: path, body: body)
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        var events: [EvalSSEEvent] = []
        var currentName: String?
        var currentData: [String] = []
        func flush() {
            if !currentData.isEmpty {
                events.append(
                    EvalSSEEvent(name: currentName, data: currentData.joined(separator: "\n"))
                )
            }
            currentName = nil
            currentData = []
        }
        // Manual byte-level line split: `bytes.lines` DROPS empty lines,
        // which are the SSE event delimiter — with it, `flush()` never ran
        // mid-stream and every `data:` payload collapsed into one giant
        // unparseable event.
        func handle(_ line: String) {
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("event:") {
                currentName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                currentData.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        var lineBuffer = Data()
        for try await byte in bytes {
            if byte == UInt8(ascii: "\n") {
                var line = String(decoding: lineBuffer, as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                lineBuffer.removeAll(keepingCapacity: true)
                handle(line)
            } else {
                lineBuffer.append(byte)
            }
        }
        if !lineBuffer.isEmpty {
            handle(String(decoding: lineBuffer, as: UTF8.self))
        }
        flush()
        return (status, events)
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// Nonisolated raw fetch with a Sendable result, for concurrent
    /// `async let` pairs (JSON parsing happens back on the main actor).
    nonisolated private static func fetchRaw(
        _ request: URLRequest
    ) async throws -> (status: Int, body: String) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (
            (response as? HTTPURLResponse)?.statusCode ?? -1,
            String(decoding: data, as: UTF8.self)
        )
    }

    // MARK: Case entry

    static func runHTTPAPICase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.httpAPI else {
            return Self.errored(
                testCase, label: label, modelId: modelId,
                note: "missing `expect.httpAPI`"
            )
        }

        let startResult = await EvalHTTPServerHost.ensureStarted()
        guard let port = startResult.port else {
            return Self.errored(
                testCase, label: label, modelId: modelId,
                note: startResult.error ?? "in-process server unavailable"
            )
        }

        var notes: [String] = ["scenario: \(exp.scenario) · port \(port)"]
        var passed = true
        func check(_ ok: Bool, pass: String, fail: String) {
            if ok {
                notes.append("ok: \(pass)")
            } else {
                passed = false
                notes.append("FAIL: \(fail)")
            }
        }

        let prompt = exp.prompt ?? testCase.query
        let maxTokens = exp.maxTokens ?? 256
        let started = Date()

        do {
            switch exp.scenario {
            case "sse_contract":
                try await runSSEContract(
                    port: port, prompt: prompt, maxTokens: maxTokens, check: check
                )
            case "chat_completion":
                try await runChatCompletion(
                    port: port, prompt: prompt, maxTokens: maxTokens,
                    responseContains: exp.responseContains, check: check
                )
            case "responses_ordering":
                try await runResponsesOrdering(
                    port: port, prompt: prompt, maxTokens: maxTokens, check: check
                )
            case "cache_stats":
                try await runCacheStats(
                    port: port, prompt: prompt, prefixProbe: exp.prefixProbe ?? false,
                    check: check, note: { notes.append($0) }
                )
            case "chat_agents_parity":
                try await runChatAgentsParity(
                    port: port, prompt: prompt, maxTokens: maxTokens,
                    responseContains: exp.responseContains, check: check
                )
            case "stop_sequence":
                try await runStopSequence(
                    port: port, prompt: prompt, maxTokens: maxTokens,
                    stopSequence: exp.stopSequence ?? "STOP-HERE", check: check
                )
            case "max_tokens_length":
                try await runMaxTokensLength(
                    port: port, prompt: prompt, maxTokens: maxTokens, check: check
                )
            case "typed_error":
                try await runTypedError(
                    port: port, prompt: prompt, maxTokens: maxTokens,
                    bodyOverride: exp.body, expectStatus: exp.expectStatus ?? 400,
                    errorContains: exp.errorContains ?? [], check: check
                )
            case "structured_output":
                try await runStructuredOutput(
                    port: port, prompt: prompt, maxTokens: maxTokens,
                    outputSchema: exp.outputSchema, stream: false, check: check,
                    note: { notes.append($0) }
                )
            case "structured_output_stream":
                try await runStructuredOutput(
                    port: port, prompt: prompt, maxTokens: maxTokens,
                    outputSchema: exp.outputSchema, stream: true, check: check,
                    note: { notes.append($0) }
                )
            case "concurrent_isolation":
                try await runConcurrentIsolation(
                    port: port, maxTokens: maxTokens,
                    echoTokens: exp.echoTokens ?? ["ALPHA-7391", "BRAVO-2648"], check: check
                )
            case "multimodal_image":
                if let skip = try await runMultimodalImage(
                    port: port, maxTokens: maxTokens, requireMediaSupport: exp.requireMediaSupport ?? false,
                    check: check, note: { notes.append($0) }
                ) {
                    return .terminal(
                        id: testCase.id, label: label, domain: testCase.domain,
                        outcome: .skipped, notes: notes + ["SKIP: \(skip)"], modelId: modelId
                    )
                }
            case "multimodal_video":
                if let skip = try await runMultimodalVideo(
                    port: port, maxTokens: maxTokens, requireMediaSupport: exp.requireMediaSupport ?? false,
                    check: check, note: { notes.append($0) }
                ) {
                    return .terminal(
                        id: testCase.id, label: label, domain: testCase.domain,
                        outcome: .skipped, notes: notes + ["SKIP: \(skip)"], modelId: modelId
                    )
                }
            default:
                return Self.errored(
                    testCase, label: label, modelId: modelId,
                    note: "unknown http_api scenario '\(exp.scenario)'"
                )
            }
        } catch {
            return EvalCaseReport(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                query: testCase.query,
                outcome: .errored,
                notes: notes + ["transport error: \(error)"],
                modelId: modelId,
                latencyMs: Date().timeIntervalSince(started) * 1000
            )
        }

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: Date().timeIntervalSince(started) * 1000
        )
    }

    // MARK: Scenarios

    private static func chatBody(
        prompt: String,
        maxTokens: Int,
        stream: Bool,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": evalRequestModel(),
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
            "temperature": 0,
            "stream": stream,
        ]
        for (key, value) in extra { body[key] = value }
        return body
    }

    private static func runSSEContract(
        port: Int,
        prompt: String,
        maxTokens: Int,
        check: (Bool, String, String) -> Void
    ) async throws {
        let (status, events) = try await httpSSE(
            port: port,
            path: "/v1/chat/completions",
            body: chatBody(prompt: prompt, maxTokens: maxTokens, stream: true)
        )
        check(status == 200, "status 200", "status \(status)")

        let dataEvents = events.filter { $0.data != "[DONE]" }
        let chunks = dataEvents.compactMap { jsonObject($0.data) }
        check(!chunks.isEmpty, "\(chunks.count) parseable chunks", "no parseable SSE chunks")
        check(
            chunks.count == dataEvents.count,
            "every data event parses as JSON",
            "\(dataEvents.count - chunks.count) unparseable data event(s)"
        )
        check(
            events.last?.data == "[DONE]",
            "[DONE] terminator present",
            "stream did not end with [DONE]"
        )
        check(
            chunks.allSatisfy { ($0["object"] as? String) == "chat.completion.chunk" },
            "all chunks are chat.completion.chunk",
            "chunk with wrong `object` value"
        )

        func delta(_ chunk: [String: Any]) -> [String: Any]? {
            ((chunk["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any]
        }
        func finishReason(_ chunk: [String: Any]) -> String? {
            let choice = (chunk["choices"] as? [[String: Any]])?.first
            return choice?["finish_reason"] as? String
        }

        if let first = chunks.first {
            check(
                (delta(first)?["role"] as? String) == "assistant",
                "role-first delta (assistant)",
                "first chunk delta is not role: assistant"
            )
        }
        let content = chunks.compactMap { delta($0)?["content"] as? String }.joined()
        check(!content.isEmpty, "streamed content non-empty", "no content deltas streamed")
        let finishReasons = chunks.compactMap(finishReason)
        check(
            !finishReasons.isEmpty,
            "terminal finish_reason: \(finishReasons.last ?? "?")",
            "no chunk carried a finish_reason"
        )
    }

    private static func runChatCompletion(
        port: Int,
        prompt: String,
        maxTokens: Int,
        responseContains: [String]?,
        check: (Bool, String, String) -> Void
    ) async throws {
        let (status, json, raw) = try await httpJSON(
            port: port,
            path: "/v1/chat/completions",
            body: chatBody(prompt: prompt, maxTokens: maxTokens, stream: false)
        )
        check(status == 200, "status 200", "status \(status): \(raw.prefix(200))")
        guard let json else {
            check(false, "", "response body is not a JSON object")
            return
        }
        check(
            (json["object"] as? String) == "chat.completion",
            "object == chat.completion",
            "object == \(json["object"] ?? "nil")"
        )
        let message = ((json["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any]
        check(
            (message?["role"] as? String) == "assistant",
            "message.role == assistant",
            "message.role == \(message?["role"] ?? "nil")"
        )
        let content = (message?["content"] as? String) ?? ""
        check(!content.isEmpty, "content non-empty", "content empty")
        for needle in responseContains ?? [] {
            check(
                content.lowercased().contains(needle.lowercased()),
                "content contains '\(needle)'",
                "content missing '\(needle)'"
            )
        }
    }

    private static func runResponsesOrdering(
        port: Int,
        prompt: String,
        maxTokens: Int,
        check: (Bool, String, String) -> Void
    ) async throws {
        let (status, events) = try await httpSSE(
            port: port,
            path: "/v1/responses",
            body: [
                "model": evalRequestModel(),
                "input": prompt,
                "max_output_tokens": maxTokens,
                "stream": true,
            ]
        )
        check(status == 200, "status 200", "status \(status)")
        let named = events.compactMap(\.name)
        check(
            named.first == "response.created",
            "first event is response.created",
            "first event is \(named.first ?? "nil")"
        )
        check(
            named.contains("response.output_text.delta"),
            "output_text deltas present",
            "no response.output_text.delta events"
        )
        check(
            named.last == "response.completed",
            "last named event is response.completed",
            "last named event is \(named.last ?? "nil")"
        )
        if let createdIdx = named.firstIndex(of: "response.created"),
            let firstDeltaIdx = named.firstIndex(of: "response.output_text.delta"),
            let completedIdx = named.lastIndex(of: "response.completed")
        {
            check(
                createdIdx < firstDeltaIdx && firstDeltaIdx < completedIdx,
                "ordering created → deltas → completed",
                "event ordering violated: created@\(createdIdx) delta@\(firstDeltaIdx) completed@\(completedIdx)"
            )
        }
        check(
            events.last?.data == "[DONE]",
            "[DONE] terminator present",
            "stream did not end with [DONE]"
        )
    }

    private static func runCacheStats(
        port: Int,
        prompt: String,
        prefixProbe: Bool,
        check: (Bool, String, String) -> Void,
        note: (String) -> Void
    ) async throws {
        let (status, json, raw) = try await httpJSON(
            port: port, path: "/admin/cache-stats", method: "GET"
        )
        check(status == 200, "status 200", "status \(status): \(raw.prefix(200))")
        guard let json else {
            check(false, "", "cache-stats body is not a JSON object")
            return
        }
        for field in ["status", "models", "aggregate", "memory_safety", "storage_locations"] {
            check(json[field] != nil, "field `\(field)` present", "field `\(field)` MISSING")
        }
        let aggregate = json["aggregate"] as? [String: Any] ?? [:]
        for field in ["prefix_hits", "prefix_misses", "disk_l2_hits", "disk_l2_misses", "disk_l2_stores"] {
            check(
                aggregate[field] is Int,
                "aggregate.\(field) present",
                "aggregate.\(field) MISSING"
            )
        }

        guard prefixProbe else { return }
        // Live cross-check for the in-process cache_proof deltas: two
        // prefix-sharing chat requests must move the aggregate counters.
        // Requires a local cache-enabled model; SKIP-shaped soft note when
        // the host has none (foundation/remote route).
        let batchBefore = json["batch_diagnostics"] as? [String: Any]
        guard let before = batchBefore?["prefix_hits"] as? Int,
            let diskBefore = batchBefore?["disk_l2_hits"] as? Int
        else {
            note(
                "note: prefixProbe skipped — no batch_diagnostics (no local MLX engine resolved)"
            )
            return
        }
        let sharedPrefix = String(repeating: prompt + " ", count: 8)
        for attempt in 1 ... 2 {
            let (requestStatus, response, responseRaw) = try await httpJSON(
                port: port,
                path: "/v1/chat/completions",
                body: chatBody(prompt: sharedPrefix, maxTokens: 16, stream: false)
            )
            check(requestStatus == 200,
                  "prefix request \(attempt) status 200",
                  "prefix request \(attempt) status \(requestStatus): \(responseRaw.prefix(200))")
            check(!chatContent(response).isEmpty,
                  "prefix request \(attempt) produced content",
                  "prefix request \(attempt) produced no content")
        }
        let (_, jsonAfter, _) = try await httpJSON(
            port: port, path: "/admin/cache-stats", method: "GET"
        )
        let batchAfter = jsonAfter?["batch_diagnostics"] as? [String: Any]
        let after = (batchAfter?["prefix_hits"] as? Int) ?? before
        let diskAfter = (batchAfter?["disk_l2_hits"] as? Int) ?? diskBefore
        // Rotating and recurrent cache topologies restore their shared prefix
        // through the v2 disk payload. Requiring the memory-tier counter alone
        // falsely fails a real disk-prefix hit. Keep both deltas visible.
        let counters = "memory prefix_hits \(before) → \(after); disk_l2_hits \(diskBefore) → \(diskAfter)"
        check(
            after > before || diskAfter > diskBefore,
            "prefix reuse observed (\(counters))",
            "no prefix reuse observed (\(counters))"
        )
    }

    private static func runChatAgentsParity(
        port: Int,
        prompt: String,
        maxTokens: Int,
        responseContains: [String]?,
        check: (Bool, String, String) -> Void
    ) async throws {
        // Chat side.
        let (chatStatus, chatJson, _) = try await httpJSON(
            port: port,
            path: "/v1/chat/completions",
            body: chatBody(prompt: prompt, maxTokens: maxTokens, stream: false)
        )
        check(chatStatus == 200, "chat status 200", "chat status \(chatStatus)")
        let chatContent =
            ((((chatJson?["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any])?[
                "content"
            ] as? String) ?? ""
        check(!chatContent.isEmpty, "chat answer non-empty", "chat answer empty")

        // Agents side: the built-in default agent is rejected on external
        // surfaces by design, so parity runs against a temporary CUSTOM
        // agent (registered like the agent_loop lane's eval agent). The
        // run endpoint takes a chat-completion body (model resolves
        // server-side to the agent's effective model when omitted) and
        // ALWAYS streams SSE text deltas.
        // Pin the agent to the eval's model: without this the agent falls
        // back to the USER'S configured chat default (a local model the
        // SwiftPM harness can't load), so the parity comparison would run
        // two different models and the agents side streamed nothing.
        let agent = Agent(
            id: UUID(),
            name: "Osaurus Eval HTTP Agent",
            description: "Temporary agent registered by OsaurusEvals; safe to delete.",
            defaultModel: evalRequestModel()
        )
        AgentStore.save(agent)
        AgentManager.shared.refresh()
        defer {
            AgentStore.delete(id: agent.id)
            AgentManager.shared.refresh()
        }

        let (agentStatus, agentEvents) = try await httpSSE(
            port: port,
            path: "/agents/\(agent.id.uuidString)/run",
            body: [
                "messages": [["role": "user", "content": prompt]],
                "max_tokens": maxTokens,
                "temperature": 0,
                "stream": true,
            ]
        )
        check(
            agentStatus == 200,
            "agents/run status 200",
            "agents/run status \(agentStatus)"
        )
        let agentContent = agentEvents
            .filter { $0.data != "[DONE]" }
            .compactMap { jsonObject($0.data) }
            .compactMap { chunk -> String? in
                let delta = ((chunk["choices"] as? [[String: Any]])?.first)?["delta"]
                    as? [String: Any]
                return delta?["content"] as? String
            }
            .joined()
        check(!agentContent.isEmpty, "agents/run answer non-empty", "agents/run answer empty")

        for needle in responseContains ?? [] {
            check(
                chatContent.lowercased().contains(needle.lowercased()),
                "chat answer contains '\(needle)'",
                "chat answer missing '\(needle)'"
            )
            check(
                agentContent.lowercased().contains(needle.lowercased()),
                "agents/run answer contains '\(needle)'",
                "agents/run answer missing '\(needle)'"
            )
        }
    }

    private static func runStopSequence(
        port: Int,
        prompt: String,
        maxTokens: Int,
        stopSequence: String,
        check: (Bool, String, String) -> Void
    ) async throws {
        let (status, json, raw) = try await httpJSON(
            port: port,
            path: "/v1/chat/completions",
            body: chatBody(
                prompt: prompt, maxTokens: maxTokens, stream: false,
                extra: ["stop": [stopSequence]]
            )
        )
        check(status == 200, "status 200", "status \(status): \(raw.prefix(200))")
        let choice = (json?["choices"] as? [[String: Any]])?.first
        let content = ((choice?["message"] as? [String: Any])?["content"] as? String) ?? ""
        check(
            !content.contains(stopSequence),
            "stop text absent from content",
            "content CONTAINS the stop sequence '\(stopSequence)'"
        )
        let finishReason = (choice?["finish_reason"] as? String) ?? "nil"
        check(
            finishReason == "stop",
            "finish_reason == stop",
            "finish_reason == \(finishReason)"
        )
    }

    private static func runMaxTokensLength(
        port: Int,
        prompt: String,
        maxTokens: Int,
        check: (Bool, String, String) -> Void
    ) async throws {
        let (status, json, raw) = try await httpJSON(
            port: port,
            path: "/v1/chat/completions",
            body: chatBody(prompt: prompt, maxTokens: maxTokens, stream: false)
        )
        check(status == 200, "status 200", "status \(status): \(raw.prefix(200))")
        let choice = (json?["choices"] as? [[String: Any]])?.first
        let finishReason = (choice?["finish_reason"] as? String) ?? "nil"
        check(
            finishReason == "length",
            "finish_reason == length (decode cap honored)",
            "finish_reason == \(finishReason) — max_tokens \(maxTokens) not enforced"
        )
        if let usage = json?["usage"] as? [String: Any],
            let completion = usage["completion_tokens"] as? Int
        {
            check(
                completion <= maxTokens,
                "completion_tokens \(completion) ≤ max_tokens \(maxTokens)",
                "completion_tokens \(completion) EXCEEDS max_tokens \(maxTokens)"
            )
        }
    }

    private static func runTypedError(
        port: Int,
        prompt: String,
        maxTokens: Int,
        bodyOverride: JSONValue?,
        expectStatus: Int,
        errorContains: [String],
        check: (Bool, String, String) -> Void
    ) async throws {
        var body = chatBody(prompt: prompt, maxTokens: maxTokens, stream: false)
        if let bodyOverride, let overrides = jsonValueToAny(bodyOverride) as? [String: Any] {
            for (key, value) in overrides { body[key] = value }
        }
        let (status, json, raw) = try await httpJSON(
            port: port, path: "/v1/chat/completions", body: body
        )
        check(
            status == expectStatus,
            "status \(status) matches expected \(expectStatus)",
            "status \(status), expected \(expectStatus): \(raw.prefix(300))"
        )
        check(
            json?["error"] != nil,
            "typed JSON error body present",
            "no `error` object in body: \(raw.prefix(300))"
        )
        let lowered = raw.lowercased()
        for needle in errorContains {
            check(
                lowered.contains(needle.lowercased()),
                "error mentions '\(needle)'",
                "error body missing '\(needle)'"
            )
        }
    }

    private static func runStructuredOutput(
        port: Int,
        prompt: String,
        maxTokens: Int,
        outputSchema: JSONValue?,
        stream: Bool,
        check: (Bool, String, String) -> Void,
        note: (String) -> Void
    ) async throws {
        let content: String
        if stream {
            // Streaming variant: JSON mode must survive chunked delivery —
            // the JOINED deltas are what must parse/validate.
            let (status, events) = try await httpSSE(
                port: port,
                path: "/v1/chat/completions",
                body: chatBody(
                    prompt: prompt, maxTokens: maxTokens, stream: true,
                    extra: ["response_format": ["type": "json_object"]]
                )
            )
            check(status == 200, "status 200", "status \(status)")
            check(
                events.last?.data == "[DONE]",
                "[DONE] terminator present",
                "stream did not end with [DONE]"
            )
            content = events
                .filter { $0.data != "[DONE]" }
                .compactMap { jsonObject($0.data) }
                .compactMap { chunk -> String? in
                    let delta = ((chunk["choices"] as? [[String: Any]])?.first)?["delta"]
                        as? [String: Any]
                    return delta?["content"] as? String
                }
                .joined()
        } else {
            let (status, json, raw) = try await httpJSON(
                port: port,
                path: "/v1/chat/completions",
                body: chatBody(
                    prompt: prompt, maxTokens: maxTokens, stream: false,
                    extra: ["response_format": ["type": "json_object"]]
                )
            )
            check(status == 200, "status 200", "status \(status): \(raw.prefix(200))")
            content =
                ((((json?["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any])?[
                    "content"
                ] as? String) ?? ""
        }
        check(!content.isEmpty, "content non-empty", "content empty")
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(content.utf8)) else {
            check(false, "", "content is not valid JSON: \(content.prefix(200))")
            return
        }
        check(true, "content parses as JSON", "")
        if let outputSchema {
            let result = SchemaValidator.validate(arguments: parsed, against: outputSchema)
            check(
                result.isValid,
                "content validates against outputSchema",
                "schema validation failed: \(result.errorMessage ?? "unknown")"
                    + (result.field.map { " (field: \($0))" } ?? "")
            )
        }
        note("content: \(String(content.prefix(160)))")
    }

    // MARK: Multimodal scenarios

    /// Chat-completion body whose user message carries a text part plus one
    /// media content part (`image_url` / `video_url` with a data: URL).
    private static func multimodalBody(
        prompt: String,
        mediaType: String,
        dataURL: String,
        maxTokens: Int
    ) -> [String: Any] {
        let mediaPart: [String: Any] =
            mediaType == "video_url"
            ? ["type": "video_url", "video_url": ["url": dataURL]]
            : ["type": "image_url", "image_url": ["url": dataURL]]
        return [
            "model": evalRequestModel(),
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        mediaPart,
                    ],
                ]
            ],
            "max_tokens": maxTokens,
            "stream": false,
        ]
    }

    private static func chatContent(_ json: [String: Any]?) -> String {
        ((((json?["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any])?[
            "content"
        ] as? String) ?? ""
    }

    /// Real-image contract + the media-salt cache check, in one case:
    ///   1. image A (red background, centered blue square) — the answer
    ///      must say the background is red;
    ///   2. the IDENTICAL request again — same correct answer (identical
    ///      media may reuse the media-salted cache, but must stay correct);
    ///   3. the inverted twin (blue background, red square) — the answer
    ///      must flip to blue. A stale cross-media cache hit (the failure
    ///      media salts exist to prevent) surfaces here as image B being
    ///      answered with image A's colors.
    /// Then exercise streamed chat, the agent route, retained image history,
    /// and a changed image after history. Identical replay must hit the cache;
    /// full responses and cache telemetry are retained for triage. Only a known
    /// unsupported bundle's typed rejection can skip an optional media case.
    private static func runMultimodalImage(
        port: Int,
        maxTokens: Int,
        requireMediaSupport: Bool,
        check: (Bool, String, String) -> Void,
        note: (String) -> Void
    ) async throws -> String? {
        guard let imageA = EvalMediaFixtures.pngDataURL(background: .red, square: .blue),
            let imageB = EvalMediaFixtures.pngDataURL(background: .blue, square: .red)
        else {
            check(false, "", "PNG fixture generation failed (CoreGraphics)")
            return nil
        }
        let model = evalRequestModel()
        let installed = InstalledVisionEvaluation.inspect(modelID: model)
        if let installed {
            note("installed model=\(installed.modelID) architecture=\(installed.modelType) "
                 + "image=\(installed.supportsImage) tensors=\(installed.tensorCount): \(installed.reason)")
        }
        let prompt = "What color is the background, excluding the small centered square? Answer with exactly one word."
        let bodyA = multimodalBody(prompt: prompt, mediaType: "image_url", dataURL: imageA, maxTokens: maxTokens)
        let bodyB = multimodalBody(prompt: prompt, mediaType: "image_url", dataURL: imageB, maxTokens: maxTokens)
        func validate(_ label: String, _ status: Int, _ json: [String: Any]?, _ raw: String, _ color: String) {
            note("\(label) HTTP \(status): \(raw)")
            check(status == 200, "\(label) status 200", "\(label) HTTP \(status)")
            let problems = HTTPMediaContract.terminalProblems(json)
            check(problems.isEmpty, "\(label) complete visible response with throughput",
                  "\(label): \(problems.joined(separator: "; "))")
            check(HTTPMediaContract.exactColor(chatContent(json), expected: color),
                  "\(label) exact color \(color)", "\(label) expected only \(color), got: \(chatContent(json))")
        }
        let (statusA, jsonA, rawA) = try await httpJSON(port: port, path: "/v1/chat/completions", body: bodyA)
        if statusA != 200 {
            let errorType = (jsonA?["error"] as? [String: Any])?["type"] as? String
            if HTTPMediaContract.maySkipUnsupported(status: statusA, errorType: errorType,
                installedSupportsMedia: installed?.supportsImage, required: requireMediaSupport) {
                return "installed bundle does not support images: \(rawA)"
            }
            validate("image A", statusA, jsonA, rawA, "red")
            return nil
        }
        validate("image A", statusA, jsonA, rawA, "red")
        let (_, cacheA, _) = try await httpJSON(port: port, path: "/admin/cache-stats", method: "GET")
        let (statusA2, jsonA2, rawA2) = try await httpJSON(port: port, path: "/v1/chat/completions", body: bodyA)
        validate("image A replay", statusA2, jsonA2, rawA2, "red")
        let (_, cacheA2, cacheRawA2) = try await httpJSON(port: port, path: "/admin/cache-stats", method: "GET")
        if installed != nil {
            func hits(_ stats: [String: Any]?) -> Int? {
                guard let aggregate = stats?["aggregate"] as? [String: Any],
                    let prefix = aggregate["prefix_hits"] as? Int,
                    let disk = aggregate["disk_l2_hits"] as? Int else { return nil }
                return prefix + disk
            }
            let before = hits(cacheA), after = hits(cacheA2)
            check(before != nil && after != nil && after! > before!,
                  "identical image replay increased cache hits",
                  "image replay cache hit unproved: before=\(String(describing: before)) after=\(String(describing: after))")
        }
        note("cache after identical replay: \(cacheRawA2)")
        let (statusB, jsonB, rawB) = try await httpJSON(port: port, path: "/v1/chat/completions", body: bodyB)
        validate("different image B", statusB, jsonB, rawB, "blue")

        func streamAndValidate(_ label: String, path: String, body: [String: Any], color: String) async throws {
            var streamed = body
            streamed["stream"] = true
            streamed["stream_options"] = ["include_usage": true]
            let (status, events) = try await httpSSE(port: port, path: path, body: streamed)
            let dataEvents = events.filter { $0.data != "[DONE]" }
            let chunks = dataEvents.compactMap { jsonObject($0.data) }
            note("\(label) raw SSE: \(events.map(\.data).joined(separator: "\n"))")
            check(chunks.count == dataEvents.count && !chunks.isEmpty,
                  "\(label) all chunks parse", "\(label) malformed or empty stream")
            check(events.last?.data == "[DONE]", "\(label) DONE", "\(label) missing DONE")
            let choices = chunks.flatMap { $0["choices"] as? [[String: Any]] ?? [] }
            let content = choices.compactMap { ($0["delta"] as? [String: Any])?["content"] as? String }.joined()
            let reasons = choices.compactMap { $0["finish_reason"] as? String }
            check(reasons == ["stop"], "\(label) one normal finish", "\(label) terminal reasons: \(reasons)")
            let usage = chunks.compactMap { $0["usage"] as? [String: Any] }.last ?? [:]
            // Project actual deltas/usage into the same assertion shape as a
            // non-streaming response. Preserve raw SSE above for inspection.
            let projected: [String: Any] = ["choices": [["finish_reason": reasons.last ?? "",
                "message": ["content": content]]], "usage": usage]
            validate(label, status, projected, "content=\(content) usage=\(usage)", color)
        }
        try await streamAndValidate("streamed image", path: "/v1/chat/completions", body: bodyB, color: "blue")
        let agent = Agent(id: UUID(), name: "Osaurus Vision Eval",
            description: "Temporary real-media parity fixture.", defaultModel: model,
            toolsEnabled: false, memoryEnabled: false)
        AgentStore.save(agent)
        AgentManager.shared.refresh()
        defer {
            AgentStore.delete(id: agent.id)
            AgentManager.shared.refresh()
        }
        try await streamAndValidate("agent image", path: "/agents/\(agent.id.uuidString)/run", body: bodyA, color: "red")

        // Real multimodal history: preserve the image payload, actual assistant
        // answer and follow-up. Then replace media in a subsequent user turn.
        var historyBody = bodyA
        var history = bodyA["messages"] as? [[String: Any]] ?? []
        history.append(["role": "assistant", "content": chatContent(jsonA)])
        history.append(["role": "user", "content": "What was the background color in my image? Answer with exactly one word."])
        historyBody["messages"] = history
        let (statusH, jsonH, rawH) = try await httpJSON(port: port, path: "/v1/chat/completions", body: historyBody)
        validate("image history follow-up", statusH, jsonH, rawH, "red")
        history.append(["role": "assistant", "content": chatContent(jsonH)])
        history.append(contentsOf: bodyB["messages"] as? [[String: Any]] ?? [])
        historyBody["messages"] = history
        let (statusHB, jsonHB, rawHB) = try await httpJSON(port: port, path: "/v1/chat/completions", body: historyBody)
        validate("changed image after history", statusHB, jsonHB, rawHB, "blue")
        let (_, _, finalCache) = try await httpJSON(port: port, path: "/admin/cache-stats", method: "GET")
        note("cache after media history: \(finalCache)")
        return nil
    }

    /// Real-video contract: a tiny generated MP4 of red frames followed by
    /// blue frames, asked as a temporal-order question. Returns a skip
    /// reason when the route/model has no video support (typed error).
    private static func runMultimodalVideo(
        port: Int,
        maxTokens: Int,
        requireMediaSupport: Bool,
        check: (Bool, String, String) -> Void,
        note: (String) -> Void
    ) async throws -> String? {
        guard
            let video = await EvalMediaFixtures.mp4DataURL(first: .red, second: .blue)
        else {
            check(false, "", "MP4 fixture generation failed (AVFoundation)")
            return nil
        }
        let prompt =
            "This short video shows one solid color, then a different solid color. "
            + "Which color appears FIRST and which appears SECOND? "
            + "Answer in the form: first=<color> second=<color>."

        let (status, json, raw) = try await httpJSON(
            port: port, path: "/v1/chat/completions",
            body: multimodalBody(
                prompt: prompt, mediaType: "video_url", dataURL: video, maxTokens: maxTokens
            )
        )
        if status != 200 {
            let installed = InstalledVisionEvaluation.inspect(modelID: evalRequestModel())
            let errorType = (json?["error"] as? [String: Any])?["type"] as? String
            let supportsVideo = installed.map {
                ModelMediaCapabilities.from(directory: URL(fileURLWithPath: $0.directory), modelId: $0.modelID).supportsVideo
            }
            if HTTPMediaContract.maySkipUnsupported(status: status, errorType: errorType,
                installedSupportsMedia: supportsVideo, required: requireMediaSupport) {
                return "installed bundle does not support video: \(raw)"
            }
            check(false, "", "video request failed HTTP \(status): \(raw)")
            return nil
        }
        let problems = HTTPMediaContract.terminalProblems(json)
        check(problems.isEmpty, "video complete with throughput", problems.joined(separator: "; "))
        note("video response: \(raw)")
        let answer = chatContent(json)
        note("video answer: \(String(answer.prefix(160)))")
        check(!answer.isEmpty, "video answer non-empty", "video answer empty")
        let lowered = answer.lowercased()
        check(
            lowered.contains("red") && lowered.contains("blue"),
            "video: both colors named",
            "video: expected 'red' and 'blue' in answer, got: \(String(answer.prefix(160)))"
        )
        if let redIdx = lowered.range(of: "red")?.lowerBound,
            let blueIdx = lowered.range(of: "blue")?.lowerBound
        {
            check(
                redIdx < blueIdx,
                "video: temporal order correct (red before blue)",
                "video: order wrong — 'blue' named before 'red': \(String(answer.prefix(160)))"
            )
        }
        return nil
    }

    private static func runConcurrentIsolation(
        port: Int,
        maxTokens: Int,
        echoTokens: [String],
        check: (Bool, String, String) -> Void
    ) async throws {
        guard echoTokens.count >= 2 else {
            check(false, "", "concurrent_isolation needs two echoTokens")
            return
        }
        let tokenA = echoTokens[0]
        let tokenB = echoTokens[1]
        // Build the requests on the main actor, then race them through a
        // nonisolated Sendable-result helper (raw status + body string) so
        // the concurrent `async let` pair doesn't have to move `[String:
        // Any]` across the actor boundary.
        let requestA = makeRequest(
            port: port, path: "/v1/chat/completions",
            body: chatBody(
                prompt: "Repeat this exact code and nothing else: \(tokenA)",
                maxTokens: maxTokens, stream: false
            )
        )
        let requestB = makeRequest(
            port: port, path: "/v1/chat/completions",
            body: chatBody(
                prompt: "Repeat this exact code and nothing else: \(tokenB)",
                maxTokens: maxTokens, stream: false
            )
        )
        async let rawA = fetchRaw(requestA)
        async let rawB = fetchRaw(requestB)
        let (resultA, resultB) = try await (rawA, rawB)

        func content(_ raw: String) -> String {
            let json = jsonObject(raw)
            return ((((json?["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any])?[
                "content"
            ] as? String) ?? ""
        }
        let contentA = content(resultA.body)
        let contentB = content(resultB.body)
        check(resultA.status == 200, "request A status 200", "request A status \(resultA.status)")
        check(resultB.status == 200, "request B status 200", "request B status \(resultB.status)")
        check(
            contentA.contains(tokenA),
            "response A carries its own token",
            "response A missing its token \(tokenA): \(contentA.prefix(120))"
        )
        check(
            contentB.contains(tokenB),
            "response B carries its own token",
            "response B missing its token \(tokenB): \(contentB.prefix(120))"
        )
        check(
            !contentA.contains(tokenB),
            "response A does not leak B's token",
            "response A LEAKED B's token \(tokenB)"
        )
        check(
            !contentB.contains(tokenA),
            "response B does not leak A's token",
            "response B LEAKED A's token \(tokenA)"
        )
    }
}
