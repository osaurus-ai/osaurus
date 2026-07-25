import Foundation
import Testing

@testable import OsaurusCore

@Suite("OpenAI-compatible stream parser")
struct OpenAICompatibleStreamParserTests {
    @Test func framer_joinsCRLFMultilineDataEvent() {
        let payload = "data: {\r\ndata:   \"x\":1\r\ndata: }\r\n\r\n"
        var parser = OpenAICompatibleStreamFramer.SSELineParser()
        parser.append(Data(payload.utf8))

        let dispatched = dispatchEvents(from: &parser, options: .strict)
        #expect(dispatched.count == 1)
        let data = Data((dispatched.first ?? "").utf8)
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(root?["x"] as? Int == 1)
    }

    @Test func framer_reassemblesRawPrettyJSONWhenPolicyAllowsFallback() {
        var event = ""
        for line in [
            "{",
            #"  "choices": [{"#,
            #"    "message": {"role": "assistant", "content": "raw"}"#,
            "  }]",
            "}",
        ] {
            OpenAICompatibleStreamFramer.processLine(
                Data(line.utf8),
                options: .routerCompatible,
                into: &event
            )
        }

        let data = Data(event.utf8)
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = root?["choices"] as? [[String: Any]]
        #expect(choices?.count == 1)
    }

    @Test func parser_recoversToolArgumentsSplitByPhysicalNewlineWhenPolicyAllowsRepair() throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var yielded: [String] = []
        let splitPayload = """
            {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"sandbox_write_file","arguments":"{\\\"path\\\":\\\"tet
            ris.html\\\"}"}}]}}]}
            """

        let first = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(splitPayload.utf8),
            options: .routerCompatible,
            state: &state,
            yield: { yielded.append($0) }
        )
        guard case .continue = first else {
            Issue.record("Expected first split payload to continue, got \(first)")
            return
        }

        let finish = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#.utf8),
            options: .routerCompatible,
            state: &state,
            yield: { yielded.append($0) }
        )
        guard case .finishWithToolCall(let invocations) = finish, let invocation = invocations.first
        else {
            Issue.record("Expected recovered tool call, got \(finish)")
            return
        }

        #expect(invocations.count == 1)
        #expect(invocation.toolName == "sandbox_write_file")
        #expect(invocation.toolCallId == "call_1")
        #expect(invocation.jsonArguments == #"{"path":"tetris.html"}"#)
        #expect(yielded.contains { StreamingToolHint.decode($0) == "sandbox_write_file" })
    }

    @Test func parser_foldsContinuationChunksWithoutIndexIntoSameSlot() throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: true)
        var yielded: [String] = []
        let env = #""id":"chatcmpl-1","object":"chat.completion.chunk","created":0,"model":"m""#
        let payloads = [
            #"{\#(env),"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_xyz","type":"function","function":{"name":"file_write","arguments":""}}]},"finish_reason":null}]}"#,
            #"{\#(env),"choices":[{"index":0,"delta":{"tool_calls":[{"function":{"arguments":"{\"path\":"}}]},"finish_reason":null}]}"#,
            #"{\#(env),"choices":[{"index":0,"delta":{"tool_calls":[{"function":{"arguments":"\"a.html\","}}]},"finish_reason":null}]}"#,
            #"{\#(env),"choices":[{"index":0,"delta":{"tool_calls":[{"function":{"arguments":"\"content\":\"x\"}"}}]},"finish_reason":null}]}"#,
        ]

        for payload in payloads {
            let outcome = try OpenAICompatibleStreamParser.handleEvent(
                jsonData: Data(payload.utf8),
                options: .strict,
                state: &state,
                yield: { yielded.append($0) }
            )
            guard case .continue = outcome else {
                Issue.record("Expected continuation payload to continue, got \(outcome)")
                return
            }
        }

        #expect(state.accumulatedToolCalls.keys.sorted() == [0])
        #expect(state.accumulatedToolCalls[0]?.name == "file_write")
        #expect(state.accumulatedToolCalls[0]?.id == "call_xyz")
        #expect(state.accumulatedToolCalls[0]?.args == #"{"path":"a.html","content":"x"}"#)
        #expect(yielded.compactMap { StreamingToolHint.decodeArgs($0) }.joined() == #"{"path":"a.html","content":"x"}"#)
    }

    @Test(arguments: [7_996, 9_000, 16_000])
    func parser_preservesLargeSingleEventToolArguments(contentBytes: Int) throws {
        let arguments = #"{"path":"probe.txt","content":""#
            + String(repeating: "x", count: contentBytes)
            + #""}"#
        let event: [String: Any] = [
            "id": "chatcmpl-large",
            "object": "chat.completion.chunk",
            "created": 0,
            "model": "m",
            "choices": [
                [
                    "index": 0,
                    "delta": [
                        "tool_calls": [
                            [
                                "index": 0,
                                "id": "call_large",
                                "type": "function",
                                "function": [
                                    "name": "file_write",
                                    "arguments": arguments,
                                ],
                            ]
                        ]
                    ],
                    "finish_reason": NSNull(),
                ]
            ],
        ]
        let eventData = try JSONSerialization.data(withJSONObject: event)
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)

        let delta = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: eventData,
            options: .routerCompatible,
            state: &state,
            yield: { _ in }
        )
        guard case .continue = delta else {
            Issue.record("Expected large argument event to continue, got \(delta)")
            return
        }

        let finish = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#.utf8),
            options: .routerCompatible,
            state: &state,
            yield: { _ in }
        )
        guard case .finishWithToolCall(let invocations) = finish,
            let invocation = invocations.first
        else {
            Issue.record("Expected large tool call to finish, got \(finish)")
            return
        }
        #expect(invocation.jsonArguments == arguments)
        #expect(invocation.jsonArguments.utf8.count > contentBytes)
    }

    @Test func parser_doesNotDispatchNamedToolSlotWithNoArgumentBytesOnAbruptEnd() {
        let accumulated: [Int: RemoteProviderService.StreamingState.ToolSlot] = [
            0: (
                id: "call_empty",
                name: "file_write",
                args: "",
                thoughtSignature: nil
            )
        ]

        // Abrupt end (no declared finish): zero argument bytes means the
        // stream was cut before the first argument event — quarantine.
        let result = OpenAICompatibleToolCallAccumulator.resolveAccumulatedToolCall(
            from: accumulated,
            finishMarker: "stream-end"
        )

        guard case .truncated(let error) = result else {
            Issue.record("Expected blank accumulated arguments to be quarantined, got \(result)")
            return
        }
        #expect(error.localizedDescription.contains("received 0 bytes"))
    }

    @Test func parser_dispatchesNoArgumentToolCallOnDeclaredFinish() {
        // Anthropic-style upstreams emit a no-input tool_use with ZERO
        // argument deltas. When the provider declares the finish, that is a
        // real no-argument call — `{}` — not a truncated stream. (Observed
        // live: Claude calling `browser_read_page` failed every retry with
        // "received 0 bytes" until declared finishes were distinguished.)
        let accumulated: [Int: RemoteProviderService.StreamingState.ToolSlot] = [
            0: (
                id: "call_noargs",
                name: "browser_read_page",
                args: "",
                thoughtSignature: nil
            )
        ]

        let result = OpenAICompatibleToolCallAccumulator.resolveAccumulatedToolCall(
            from: accumulated,
            finishMarker: "finish_reason=tool_calls",
            emptyArgsAreComplete: true
        )

        guard case .ready(let invocations) = result, let invocation = invocations.first else {
            Issue.record("Expected a no-argument call to dispatch on a declared finish, got \(result)")
            return
        }
        #expect(invocation.toolName == "browser_read_page")
        #expect(invocation.jsonArguments == "{}")
    }

    /// The full router wire shape that failed live: a name-only tool-call
    /// delta (no `arguments` field at all) followed by a clean
    /// `finish_reason=tool_calls` must dispatch the call with `{}` args.
    @Test func parser_nameOnlyToolCallDeltaThenToolCallsFinishDispatches() throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let start =
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"toolu_01","type":"function","function":{"name":"browser_read_page"}}]},"finish_reason":null}]}"#
        _ = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(start.utf8),
            options: .routerCompatible,
            state: &state,
            yield: { _ in }
        )

        let finish = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#.utf8),
            options: .routerCompatible,
            state: &state,
            yield: { _ in }
        )

        guard case .finishWithToolCall(let invocations) = finish, let invocation = invocations.first
        else {
            Issue.record("Expected the no-argument tool call to dispatch, got \(finish)")
            return
        }
        #expect(invocation.toolName == "browser_read_page")
        #expect(invocation.jsonArguments == "{}")
    }

    @Test func parser_lengthFinishRejectsEvenSyntacticallyCompletePendingTool() throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let start =
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"file_write","arguments":"{}"}}]},"finish_reason":null}]}"#
        _ = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(start.utf8),
            options: .routerCompatible,
            state: &state,
            yield: { _ in }
        )

        let finish = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(#"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#.utf8),
            options: .routerCompatible,
            state: &state,
            yield: { _ in }
        )

        guard case .finishWithError(let error) = finish else {
            Issue.record("Expected output-limited tool call to fail, got \(finish)")
            return
        }
        #expect(error.localizedDescription.contains("output token limit"))
    }

    @Test func parser_preservesParallelToolCallIndices() throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: true)
        let env = #""id":"chatcmpl-1","object":"chat.completion.chunk","created":0,"model":"m""#
        let payloads = [
            #"{\#(env),"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","type":"function","function":{"name":"toolA","arguments":""}}]},"finish_reason":null}]}"#,
            #"{\#(env),"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"b","type":"function","function":{"name":"toolB","arguments":""}}]},"finish_reason":null}]}"#,
            #"{\#(env),"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"x\":1}"}}]},"finish_reason":null}]}"#,
            #"{\#(env),"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\"y\":2}"}}]},"finish_reason":null}]}"#,
        ]

        for payload in payloads {
            _ = try OpenAICompatibleStreamParser.handleEvent(
                jsonData: Data(payload.utf8),
                options: .strict,
                state: &state,
                yield: { _ in }
            )
        }

        #expect(state.accumulatedToolCalls.keys.sorted() == [0, 1])
        #expect(state.accumulatedToolCalls[0]?.name == "toolA")
        #expect(state.accumulatedToolCalls[0]?.args == #"{"x":1}"#)
        #expect(state.accumulatedToolCalls[1]?.name == "toolB")
        #expect(state.accumulatedToolCalls[1]?.args == #"{"y":2}"#)
    }

    @Test func parser_dispatchesAllParallelToolCallsAtFinish() throws {
        // Regression: parallel tool calls used to be silently collapsed to the
        // lowest-index call. All accumulated slots must dispatch, in slot order.
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: true)
        let env = #""id":"chatcmpl-1","object":"chat.completion.chunk","created":0,"model":"m""#
        let payloads = [
            #"{\#(env),"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","type":"function","function":{"name":"toolA","arguments":"{\"x\":1}"}}]},"finish_reason":null}]}"#,
            #"{\#(env),"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"b","type":"function","function":{"name":"toolB","arguments":"{\"y\":2}"}}]},"finish_reason":null}]}"#,
        ]
        for payload in payloads {
            _ = try OpenAICompatibleStreamParser.handleEvent(
                jsonData: Data(payload.utf8),
                options: .strict,
                state: &state,
                yield: { _ in }
            )
        }

        let finish = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(#"{\#(env),"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#.utf8),
            options: .strict,
            state: &state,
            yield: { _ in }
        )
        guard case .finishWithToolCall(let invocations) = finish else {
            Issue.record("Expected parallel tool-call finish, got \(finish)")
            return
        }
        #expect(invocations.map(\.toolName) == ["toolA", "toolB"])
        #expect(invocations.map(\.toolCallId) == ["a", "b"])
        #expect(invocations.map(\.jsonArguments) == [#"{"x":1}"#, #"{"y":2}"#])

        // The finish-by-throw shape must be the batch error for >1 call so the
        // agent loop's `catch let invs as ServiceToolInvocations` sees them all.
        let thrown = RemoteProviderService.toolInvocationFinishError(invocations)
        #expect((thrown as? ServiceToolInvocations)?.invocations.count == 2)
    }

    @Test func parser_lenientFullBodyMessageToolCallFinishesWithInvocation() throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var yielded: [String] = []

        let outcome = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(
                """
                {
                  "id":"chatcmpl_1",
                  "object":"chat.completion",
                  "choices":[{
                    "index":0,
                    "message":{
                      "role":"assistant",
                      "content":null,
                      "tool_calls":[{
                        "index":0,
                        "id":"call_1",
                        "type":"function",
                        "function":{"name":"sandbox_write_file","arguments":"{\\\"path\\\":\\\"tetris.html\\\"}"}
                      }]
                    },
                    "finish_reason":"tool_calls"
                  }]
                }
                """.utf8
            ),
            options: .routerCompatible,
            state: &state,
            yield: { yielded.append($0) }
        )

        guard case .finishWithToolCall(let invocations) = outcome, let invocation = invocations.first
        else {
            Issue.record("Expected full-body tool call, got \(outcome)")
            return
        }
        #expect(invocations.count == 1)
        #expect(invocation.toolName == "sandbox_write_file")
        #expect(invocation.toolCallId == "call_1")
        #expect(invocation.jsonArguments == #"{"path":"tetris.html"}"#)
        #expect(yielded.contains { StreamingToolHint.decode($0) == "sandbox_write_file" })
    }

    @Test func parser_lenientUsageOnlyChunkContinuesWithoutOutput() throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var yielded: [String] = []

        let outcome = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(#"{"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}"#.utf8),
            options: .routerCompatible,
            state: &state,
            yield: { yielded.append($0) }
        )

        guard case .continue = outcome else {
            Issue.record("Expected usage-only chunk to continue, got \(outcome)")
            return
        }
        #expect(yielded.isEmpty)
    }

    @Test func parser_lengthFinishWithoutOutputIsError() throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var yielded: [String] = []

        let outcome = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(#"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#.utf8),
            options: .routerCompatible,
            state: &state,
            yield: { yielded.append($0) }
        )

        guard case .finishWithError(let error) = outcome else {
            Issue.record("Expected length-without-output error, got \(outcome)")
            return
        }
        #expect(error.localizedDescription.contains("output token limit"))
        #expect(yielded.isEmpty)
    }

    @Test func parser_lengthFinishAfterContentDoesNotError() throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var yielded: [String] = []

        let content = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(#"{"choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":null}]}"#.utf8),
            options: .routerCompatible,
            state: &state,
            yield: { yielded.append($0) }
        )
        guard case .continue = content else {
            Issue.record("Expected content chunk to continue, got \(content)")
            return
        }

        let finish = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(#"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#.utf8),
            options: .routerCompatible,
            state: &state,
            yield: { yielded.append($0) }
        )

        guard case .continue = finish else {
            Issue.record("Expected length after content to continue, got \(finish)")
            return
        }
        #expect(yielded == ["partial"])
    }

    @Test func parser_routesMistralStructuredThinkingContentToReasoning() throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var yielded: [String] = []

        // Thinking phase: Mistral streams `content` as an array of chunks.
        let thinking = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(
                #"{"id":"x","object":"chat.completion.chunk","created":0,"model":"mistral-medium-3.5","choices":[{"index":0,"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"let me think"}]}]},"finish_reason":null}]}"#
                    .utf8),
            options: .strict,
            state: &state,
            yield: { yielded.append($0) }
        )
        guard case .continue = thinking else {
            Issue.record("Expected thinking chunk to continue, got \(thinking)")
            return
        }

        // Transition chunk: a closing think chunk plus the first text chunk.
        _ = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(
                #"{"id":"x","object":"chat.completion.chunk","created":0,"model":"mistral-medium-3.5","choices":[{"index":0,"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":" done"}]},{"type":"text","text":"Answer"}]},"finish_reason":null}]}"#
                    .utf8),
            options: .strict,
            state: &state,
            yield: { yielded.append($0) }
        )

        // Answer phase: `content` becomes a plain string.
        _ = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(#"{"id":"x","object":"chat.completion.chunk","created":0,"model":"mistral-medium-3.5","choices":[{"index":0,"delta":{"content":" text"},"finish_reason":null}]}"#.utf8),
            options: .strict,
            state: &state,
            yield: { yielded.append($0) }
        )

        let reasoning = yielded.compactMap { StreamingReasoningHint.decode($0) }
        let visible = yielded.filter { StreamingReasoningHint.decode($0) == nil }
        #expect(reasoning == ["let me think", " done"])
        #expect(visible == ["Answer", " text"])
    }

    @Test func parser_routesSeparateReasoningContentFieldToReasoning() throws {
        // Regression guard for the flexible `DeltaContent` decoder: the
        // DeepSeek/Qwen/vLLM separate `reasoning_content` string field must
        // still route to the reasoning channel and plain `content` to visible.
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        var yielded: [String] = []

        _ = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(
                #"{"id":"x","object":"chat.completion.chunk","created":0,"model":"deepseek-reasoner","choices":[{"index":0,"delta":{"reasoning_content":"thinking"},"finish_reason":null}]}"#
                    .utf8),
            options: .strict,
            state: &state,
            yield: { yielded.append($0) }
        )
        _ = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(
                #"{"id":"x","object":"chat.completion.chunk","created":0,"model":"deepseek-reasoner","choices":[{"index":0,"delta":{"content":"answer"},"finish_reason":null}]}"#
                    .utf8),
            options: .strict,
            state: &state,
            yield: { yielded.append($0) }
        )

        let reasoning = yielded.compactMap { StreamingReasoningHint.decode($0) }
        let visible = yielded.filter { StreamingReasoningHint.decode($0) == nil }
        #expect(reasoning == ["thinking"])
        #expect(visible == ["answer"])
    }

    @Test func parser_strictDecodesFinishChunkWithoutDelta() throws {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let finishChunk =
            #"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"deepseek-v4-flash","choices":[{"index":0,"finish_reason":"stop"}]}"#

        let outcome = try OpenAICompatibleStreamParser.handleEvent(
            jsonData: Data(finishChunk.utf8),
            options: .strict,
            state: &state,
            yield: { _ in }
        )
        guard case .continue = outcome else {
            Issue.record("Expected delta-less finish chunk to decode and continue, got \(outcome)")
            return
        }
        #expect(state.lastFinishReason == "stop")
    }

    @Test func service_skipsUnparseableChunkOutsideToolArguments() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let unknownShape = #"{"unexpected":"frame","payload":[1,2,3]}"#

        let outcome = RemoteProviderService.handleStreamEvent(
            jsonData: Data(unknownShape.utf8),
            providerType: .openaiLegacy,
            state: &state,
            yield: { _ in }
        )
        guard case .continue = outcome else {
            Issue.record("Expected unknown chunk shape to be skipped, got \(outcome)")
            return
        }
    }

    @Test func service_failsUnparseableChunkWhileReceivingToolArguments() {
        var state = RemoteProviderService.StreamingState(stopSequences: [], trackContent: false)
        let toolStart =
            #"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"file_write","arguments":"{\"pa"}}]}}]}"#
        _ = RemoteProviderService.handleStreamEvent(
            jsonData: Data(toolStart.utf8),
            providerType: .openaiLegacy,
            state: &state,
            yield: { _ in }
        )

        let outcome = RemoteProviderService.handleStreamEvent(
            jsonData: Data(#"{"unexpected":"frame"}"#.utf8),
            providerType: .openaiLegacy,
            state: &state,
            yield: { _ in }
        )
        guard case .finishWithError(let error) = outcome else {
            Issue.record("Expected unparseable chunk mid-arguments to fail, got \(outcome)")
            return
        }
        #expect(error.localizedDescription.contains("while receiving tool arguments"))
    }

    private func dispatchEvents(
        from parser: inout OpenAICompatibleStreamFramer.SSELineParser,
        options: OpenAICompatibleStreamFramer.Options
    ) -> [String] {
        var event = ""
        var dispatched: [String] = []
        while let line = parser.nextLine() {
            if line.isEmpty {
                if !event.isEmpty {
                    dispatched.append(event)
                    event = ""
                }
            } else {
                OpenAICompatibleStreamFramer.processLine(line, options: options, into: &event)
            }
        }
        return dispatched
    }
}
