//
//  SwarmModelServiceTests.swift
//  OsaurusCoreTests
//
//  The Swarm request path against in-process simulated nodes: identity and
//  catalog, picker rows, routing, the request body, event mapping, tool-call
//  dispatch, Stop, and lost-lease retry.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Swarm identity and catalog")
struct SwarmIdentityTests {
    @Test func slugAndRoundTrip() throws {
        #expect(SwarmModelIdentity.slug(forPoolName: "Raptor Pool #1") == "raptor-pool-1")
        #expect(SwarmModelIdentity.slug(forPoolName: "  Qwen 27B  ") == "qwen-27b")
        #expect(SwarmModelIdentity.slug(forPoolName: "###") == "pool")
        let id = SwarmModelIdentity.make(poolName: "Raptor Pool #1", modelId: "OsaurusAI/Qwen3.6-27B-JANG_4M")
        #expect(id == "osaurus-swarm/raptor-pool-1/OsaurusAI/Qwen3.6-27B-JANG_4M")
        let parsed = try #require(SwarmModelIdentity.parse(id))
        #expect(parsed.poolSlug == "raptor-pool-1")
        #expect(parsed.modelId == "OsaurusAI/Qwen3.6-27B-JANG_4M")
        #expect(SwarmModelIdentity.parse("openai/gpt-5") == nil)
        #expect(SwarmModelIdentity.parse("osaurus-swarm/only-pool") == nil)
    }

    @Test func huggingFaceLinks() {
        #expect(
            SwarmInstallSource.huggingFaceRepoId(from: "https://huggingface.co/OsaurusAI/Model-4B")
                == "OsaurusAI/Model-4B"
        )
        #expect(
            SwarmInstallSource.huggingFaceRepoId(from: "https://huggingface.co/OsaurusAI/Model-4B/tree/main")
                == "OsaurusAI/Model-4B"
        )
        #expect(SwarmInstallSource.huggingFaceRevision(from: "https://huggingface.co/a/b/tree/v2") == "v2")
        #expect(SwarmInstallSource.huggingFaceRepoId(from: "OsaurusAI/Model-4B") == "OsaurusAI/Model-4B")
        #expect(SwarmInstallSource.huggingFaceRepoId(from: "https://example.com/a/b") == nil)
        #expect(SwarmInstallSource.huggingFaceRepoId(from: "just-a-name") == nil)
        #expect(SwarmInstallSource.huggingFaceRepoId(from: "") == nil)
        #expect(
            SwarmInstallSource.huggingFaceRepoId(from: "https://huggingface.co/OsaurusAI/Qwen3.6-27B-JANG_4M")
                == "OsaurusAI/Qwen3.6-27B-JANG_4M"
        )
        #expect(
            SwarmInstallSource.huggingFaceRepoId(from: "https://hf.co/OsaurusAI/Qwen3.6-27B-JANG_4M?x=1#readme")
                == "OsaurusAI/Qwen3.6-27B-JANG_4M"
        )
        #expect(SwarmInstallSource.huggingFaceRepoId(from: "https://huggingface.co/models/a/b") == "a/b")
        #expect(SwarmInstallSource.huggingFaceRepoId(from: "ftp://huggingface.co/a/b") == nil)
        #expect(SwarmInstallSource.huggingFaceRepoId(from: "javascript:alert/x") == nil)
        #expect(SwarmInstallSource.huggingFaceRepoId(from: "a b/c") == nil)
        #expect(SwarmInstallSource.huggingFaceRevision(from: "https://huggingface.co/a/b") == nil)
    }

    /// Node-supplied text never becomes a link or markup where Markdown is
    /// interpreted (chat error turns): a hostile node name stays inert.
    /// Node-supplied text never becomes a link or markup where Markdown is
    /// rendered (chat error turns): it is quoted as an inline code span, which
    /// renderers never linkify, whatever the text looks like.
    @Test func peerTextIsQuotedAsCodeInErrors() throws {
        let hostiles = [
            "[click](https://example.com) **bold** <b>x</b> `code`\nsecond line",
            "www.example.com", "a@b.co", "tel:123", "custom-scheme:x", "mailto:a@b.co", "https://x.example",
        ]
        for hostile in hostiles {
            let quoted = SwarmText.inert(hostile)
            #expect(quoted.hasPrefix("`") && quoted.hasSuffix("`"), "\(quoted)")
            #expect(quoted.dropFirst().dropLast().contains("`") == false, "\(quoted)")
            #expect(!quoted.contains("\n"))
            let errors: [SwarmError] = [
                .nodeOffline(hostile), .nodePaused(node: hostile, reason: hostile), .fitRefused(hostile),
                .modelNotInstalled(model: hostile, node: hostile), .leaseLost(reason: hostile),
                .engine(status: 400, message: hostile), .transport(hostile), .nodeNotFound(hostile),
                .invalidToolCall(name: hostile, reason: .notOffered),
            ]
            for error in errors {
                // Outside code spans nothing of the peer text remains.
                let outside = try #require(error.errorDescription).replacing(/`[^`]*`/, with: "")
                for marker in ["](", "**", "<b>", "www.", "@", "tel:", "custom-scheme:", "mailto:", "https:"] {
                    #expect(!outside.contains(marker), "\(error.code) leaks \(marker): \(outside)")
                }
            }
        }
        #expect(SwarmText.inert("OsaurusAI/Qwen3.6-27B-JANG_4M") == "`OsaurusAI/Qwen3.6-27B-JANG_4M`")
        #expect(SwarmText.inert("   ") == "")
    }

    @Test func pairingCodeGroups() {
        let offer = SwarmPairingOffer(code: "ABCDEFGHJKLM", qrPayload: "x", expiresAt: .distantFuture)
        #expect(offer.groupedCode == "ABCD-EFGH-JKLM")
    }

    static func node(
        _ id: String,
        models: [(String, SwarmModelLoadState)],
        availability: SwarmNodeAvailability = .available
    )
        -> SwarmNodeSnapshot
    {
        SwarmNodeSnapshot(
            id: id,
            name: id,
            hardware: .init(
                os: "macOS",
                cpu: "M4",
                gpu: "M4",
                backend: .metal,
                trexVersion: "t",
                protocolVersion: 1,
                memoryTotalBytes: 64 << 30,
                memoryCapBytes: 48 << 30
            ),
            telemetry: .init(memoryInUseBytes: 0, diskFreeBytes: 500 << 30, gpuUtilization: 0, lastHeartbeat: Date()),
            availability: availability,
            path: .lan,
            rttMs: 1,
            models: models.map {
                .init(modelId: $0.0, sizeBytes: 1 << 30, digest: nil, loadState: $0.1, preheat: false)
            }
        )
    }

    @Test func catalogCountsMembersAvailabilityAndWarmth() throws {
        let pool = SwarmPool(
            id: "p1",
            name: "Raptor Pool #1",
            modelIds: ["org/a", "org/b"],
            nodeIds: ["n1", "n2", "n3"],
            leaseSeconds: 60,
            maxQueueWaitSeconds: 10,
            contextLength: 32_768
        )
        let nodes = [
            Self.node("n1", models: [("org/a", .warm)]),
            Self.node("n2", models: [("org/a", .cold), ("org/b", .cold)], availability: .paused(reason: "owner")),
            Self.node("n3", models: []),
        ]
        let catalog = SwarmCatalogEntry.entries(pools: [pool], nodes: nodes)
        #expect(catalog.count == 2)
        let a = try #require(catalog.first { $0.modelId == "org/a" })
        #expect(a.memberNodes == 2)
        #expect(a.availableNodes == 1)
        #expect(a.warmNodes == 1)
        #expect(a.displayName == "a · Raptor Pool #1")
        let b = try #require(catalog.first { $0.modelId == "org/b" })
        #expect(b.availableNodes == 0)
        #expect(b.capacityText == "No nodes available")
    }
}

@Suite("Swarm request path")
struct SwarmRequestPathTests {
    /// A started simulator with one pool over `nodeCount` nodes that have `model`.
    static func makeSwarm(nodeCount: Int = 1, model: String = "OsaurusAI/Tiny-1B", wait: Int = 5) async throws -> (
        SwarmSimulatorBackend, SwarmModelService, SwarmCatalogEntry
    ) {
        let backend = SwarmSimulatorBackend(timing: .fast)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swarm-test-\(UUID().uuidString)")
        try await backend.start(masterName: "test", stateDirectory: dir)
        var ids: [SwarmNodeID] = []
        for index in 0 ..< nodeCount {
            let node = await backend.simulatePairNode(name: "Node \(index + 1)")
            await backend.simulateInstalled(model, on: node.id, warm: true)
            ids.append(node.id)
        }
        let pool = try await backend.createPool(
            SwarmPoolDraft(
                name: "Test Pool",
                modelIds: [model],
                nodeIds: ids,
                leaseSeconds: 60,
                maxQueueWaitSeconds: wait
            )
        )
        let nodes = await backend.nodes()
        let entry = try #require(SwarmCatalogEntry.entries(pools: [pool], nodes: nodes).first)
        let service = SwarmModelService()
        service.update(
            backend: backend,
            catalog: [entry],
            nodeNames: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.name) })
        )
        return (backend, service, entry)
    }

    static func params(session: String = UUID().uuidString, idempotencyKey: String? = nil) -> GenerationParameters {
        GenerationParameters(
            temperature: 0.7,
            maxTokens: 512,
            maxTokensExplicit: false,
            samplingParametersAreImplicit: true,
            sessionId: session,
            idempotencyKey: idempotencyKey
        )
    }

    static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: "user", content: text)
    }

    @Test func routerPicksSwarmServiceForPoolModelIds() async throws {
        let (_, service, entry) = try await Self.makeSwarm()
        guard
            case .service(let routed, let model) = ModelServiceRouter.resolve(
                requestedModel: entry.pickerModelId,
                services: [],
                remoteServices: [service]
            )
        else {
            Issue.record("no route")
            return
        }
        #expect(routed.id == "osaurus-swarm")
        #expect(model == entry.pickerModelId)
        #expect(!service.handles(requestedModel: "osaurus-swarm/other-pool/OsaurusAI/Tiny-1B"))
    }

    @Test func streamsContentReasoningAndStats() async throws {
        let (_, service, entry) = try await Self.makeSwarm()
        let stream = try await service.streamWithTools(
            messages: [Self.user("hello swarm")],
            parameters: Self.params(),
            stopSequences: [],
            tools: [],
            toolChoice: nil,
            requestedModel: entry.pickerModelId
        )
        var text = ""
        var reasoning = ""
        var stats: (tokenCount: Int, tokensPerSecond: Double)?
        for try await delta in stream {
            if let r = StreamingReasoningHint.decode(delta) {
                reasoning += r
            } else if let s = StreamingStatsHint.decode(delta) {
                stats = (s.tokenCount, s.tokensPerSecond)
            } else if !StreamingToolHint.isSentinel(delta) {
                text += delta
            }
        }
        #expect(text.contains("Simulated reply from Node 1 running OsaurusAI/Tiny-1B"))
        #expect(text.contains("hello swarm"))
        #expect(reasoning.contains("Node 1"))
        let s = try #require(stats)
        #expect(s.tokenCount > 0)
        #expect(s.tokensPerSecond > 0)
    }

    @Test func toolCallFinishesWithInvocation() async throws {
        let (_, service, entry) = try await Self.makeSwarm()
        let tool = Tool(
            type: "function",
            function: ToolFunction(name: "get_time", description: "time", parameters: .object([:]))
        )
        let stream = try await service.streamWithTools(
            messages: [Self.user(#"please swarm-sim:call get_time {"zone":"UTC"}"#)],
            parameters: Self.params(),
            stopSequences: [],
            tools: [tool],
            toolChoice: .auto,
            requestedModel: entry.pickerModelId
        )
        var previewName: String?
        do {
            for try await delta in stream {
                if let name = StreamingToolHint.decode(delta) { previewName = name }
            }
            Issue.record("a tool call must finish the stream by throwing the invocation")
        } catch let invocation as ServiceToolInvocation {
            #expect(invocation.toolName == "get_time")
            #expect(invocation.jsonArguments == #"{"zone":"UTC"}"#)
            #expect(invocation.toolCallId?.hasPrefix("call_") == true)
        }
        #expect(previewName == "get_time")
    }

    @Test func toolResultContinues() async throws {
        let (_, service, entry) = try await Self.makeSwarm()
        let messages = [
            Self.user("swarm-sim:call get_time {}"),
            ChatMessage(
                role: "assistant",
                content: nil,
                tool_calls: [
                    ToolCall(
                        id: "call_1",
                        type: "function",
                        function: ToolCallFunction(name: "get_time", arguments: "{}")
                    )
                ],
                tool_call_id: nil
            ),
            ChatMessage(role: "tool", content: "12:00 UTC", tool_calls: nil, tool_call_id: "call_1"),
        ]
        let text = try await service.generateOneShot(
            messages: messages,
            parameters: Self.params(),
            requestedModel: entry.pickerModelId
        )
        #expect(text.contains("got the tool result: 12:00 UTC"))
    }

    @Test func stopCancelsOnTheNode() async throws {
        let (backend, service, entry) = try await Self.makeSwarm()
        let stream = try await service.streamWithTools(
            messages: [Self.user(String(repeating: "long ", count: 400))],
            parameters: Self.params(),
            stopSequences: [],
            tools: [],
            toolChoice: nil,
            requestedModel: entry.pickerModelId
        )
        let consumer = Task {
            var count = 0
            for try await _ in stream {
                count += 1
                if count == 3 { break }
            }
            return count
        }
        _ = try await consumer.value
        // The node's request ends and its lease goes idle (not in flight).
        var idle = false
        for _ in 0 ..< 100 {
            let leases = await backend.activeLeases()
            if let lease = leases.first {
                let busyNodes = await backend.nodes().filter { $0.availability == .busy }
                if busyNodes.isEmpty || lease.expiresAt > Date() {
                    idle = true
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(idle)
    }

    @Test func poolBusyIsTypedWhenEveryNodeIsLeased() async throws {
        let (backend, service, entry) = try await Self.makeSwarm(wait: 0)
        // Another caller holds the only node.
        _ = try await backend.acquireLease(
            SwarmLeaseRequest(
                poolId: entry.pool.id,
                nodeIds: [],
                modelId: entry.modelId,
                leaseSeconds: 60,
                maxWaitSeconds: 0,
                callerKey: "someone-else"
            )
        )
        let stream = try await service.streamWithTools(
            messages: [Self.user("hi")],
            parameters: Self.params(),
            stopSequences: [],
            tools: [],
            toolChoice: nil,
            requestedModel: entry.pickerModelId
        )
        await #expect(throws: SwarmError.poolBusy(pool: "Test Pool", waitedSeconds: 0)) {
            for try await _ in stream {}
        }
    }

    @Test func pausedNodeBeforeOutputRetriesOnAnotherNode() async throws {
        let (backend, service, entry) = try await Self.makeSwarm(nodeCount: 2)
        let nodes = await backend.nodes()
        // Pin this caller to node 1, then pause it as its owner would.
        let callerSession = "session-retry"
        let first = try await backend.acquireLease(
            SwarmLeaseRequest(
                poolId: entry.pool.id,
                nodeIds: [nodes[0].id],
                modelId: entry.modelId,
                leaseSeconds: 60,
                maxWaitSeconds: 0,
                callerKey: "session:\(callerSession)"
            )
        )
        #expect(first.nodeId == nodes[0].id)
        await backend.simulatePause(nodes[0].id, reason: "You're using this Mac")
        let text = try await service.generateOneShot(
            messages: [Self.user("retry me")],
            parameters: Self.params(session: callerSession),
            requestedModel: entry.pickerModelId
        )
        #expect(text.contains("Node 2"))
    }

    @Test func bodySendsOnlyExplicitSampling() throws {
        let implicit = try Self.decode(
            SwarmModelService.chatBody(
                modelId: "org/m",
                messages: [Self.user("x")],
                parameters: Self.params(),
                stopSequences: [],
                tools: [],
                toolChoice: nil
            )
        )
        #expect(implicit["model"] as? String == "org/m")
        #expect(implicit["stream"] as? Bool == true)
        #expect(implicit["temperature"] == nil)
        #expect(implicit["max_tokens"] == nil)
        #expect(implicit["top_p"] == nil)
        #expect(implicit["chat_template_kwargs"] == nil)

        let explicit = try Self.decode(
            SwarmModelService.chatBody(
                modelId: "org/m",
                messages: [Self.user("x")],
                parameters: GenerationParameters(
                    temperature: 0.2,
                    maxTokens: 64,
                    maxTokensExplicit: true,
                    topPOverride: 0.9,
                    topKOverride: 20,
                    samplingParametersAreImplicit: false,
                    seed: 7,
                    modelOptions: ["disableThinking": .bool(true)]
                ),
                stopSequences: ["</s>"],
                tools: [],
                toolChoice: nil
            )
        )
        #expect((explicit["temperature"] as? Double).map { abs($0 - 0.2) < 0.0001 } == true)
        #expect(explicit["max_tokens"] as? Int == 64)
        #expect(explicit["top_k"] as? Int == 20)
        #expect(explicit["seed"] as? Int == 7)
        #expect(explicit["stop"] as? [String] == ["</s>"])
        #expect((explicit["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)
    }

    @Test func mapperEndsTruncatedToolCallsWithoutRunningThem() {
        var mapper = SwarmEventMapper(offeredToolNames: ["write_file"])
        _ = mapper.map(.toolCall(index: 0, id: "c1", name: "write_file", argumentsJSON: "{\"path\":"))
        _ = mapper.map(
            .completion(
                SwarmCompletionInfo(
                    promptTokens: 5,
                    completionTokens: 9,
                    cachedPromptTokens: nil,
                    tokensPerSecond: 10,
                    prefillTokensPerSecond: nil,
                    finishReason: "length"
                )
            )
        )
        #expect(mapper.terminalError() is ServiceToolResponseExhausted)

        var batch = SwarmEventMapper(offeredToolNames: ["a", "b"])
        _ = batch.map(.toolCall(index: 1, id: "c2", name: "b", argumentsJSON: "{}"))
        _ = batch.map(.toolCall(index: 0, id: "c1", name: "a", argumentsJSON: ""))
        let invocations = (batch.terminalError() as? ServiceToolInvocations)?.invocations.map(\.toolName)
        #expect(invocations == ["a", "b"])

        var plain = SwarmEventMapper(requireCompleteOutput: true)
        _ = plain.map(.content("partial"))
        _ = plain.map(
            .completion(
                SwarmCompletionInfo(
                    promptTokens: 1,
                    completionTokens: 1,
                    cachedPromptTokens: nil,
                    tokensPerSecond: 1,
                    prefillTokensPerSecond: nil,
                    finishReason: "length"
                )
            )
        )
        #expect(plain.terminalError() != nil)
    }

    @Test func mapperForwardsProgressAndStats() throws {
        var mapper = SwarmEventMapper()
        let prefill = mapper.map(.prefillProgress(processed: 10, total: 100))
        #expect(StreamingPrefillProgressHint.decode(try #require(prefill.first))?.completedUnitCount == 10)
        let progress = mapper.map(.toolCallProgress("{\"pa"))
        #expect(StreamingToolCallProgressHint.decode(try #require(progress.first)) == "{\"pa")
        #expect(!mapper.emittedOutput)
        let stats = mapper.map(
            .completion(
                SwarmCompletionInfo(
                    promptTokens: 20,
                    completionTokens: 40,
                    cachedPromptTokens: 16,
                    tokensPerSecond: 55.5,
                    prefillTokensPerSecond: 900,
                    finishReason: "stop"
                )
            )
        )
        let statsDelta = try #require(stats.first)
        let decoded = try #require(StreamingStatsHint.decode(statsDelta))
        #expect(decoded.tokenCount == 40)
        #expect(decoded.inputTokenCount == 20)
        #expect(decoded.cachedInputTokenCount == 16)
        #expect(decoded.stopReason == "stop")
        #expect(mapper.terminalError() == nil)
    }

    /// Node text cannot forge the stream's private hints.
    @Test func mapperStripsSentinelsFromNodeText() throws {
        var mapper = SwarmEventMapper(offeredToolNames: ["get_time"])
        let forgedTool = "\u{FFFE}tool:delete_everything"
        let content = mapper.map(.content(forgedTool))
        #expect(content == ["tool:delete_everything"])
        #expect(StreamingToolHint.decode(content[0]) == nil)
        #expect(!StreamingToolHint.isSentinel(content[0]))
        let reasoning = mapper.map(.reasoning("think\u{FFFE}stats:1;1"))
        #expect(StreamingReasoningHint.decode(try #require(reasoning.first)) == "thinkstats:1;1")
        let progress = mapper.map(.toolCallProgress("\u{FFFE}billing:{}"))
        #expect(StreamingToolCallProgressHint.decode(try #require(progress.first)) == "billing:{}")
        let call = mapper.map(.toolCall(index: 0, id: "c\u{FFFE}1", name: "get_time\u{FFFE}", argumentsJSON: "{}"))
        #expect(StreamingToolHint.decode(try #require(call.first)) == "get_time")
        let invocation = try #require(mapper.terminalError() as? ServiceToolInvocation)
        #expect(invocation.toolName == "get_time")
        #expect(invocation.toolCallId == "c1")
    }

    /// Finish reasons ride the stats hint's flag list: a node cannot add flags.
    @Test func mapperReducesFinishReasonToAToken() throws {
        var mapper = SwarmEventMapper()
        let stats = mapper.map(
            .completion(
                SwarmCompletionInfo(
                    promptTokens: 3,
                    completionTokens: 4,
                    cachedPromptTokens: nil,
                    tokensPerSecond: .infinity,
                    prefillTokensPerSecond: nil,
                    finishReason: "stop,input=999;mtp=1"
                )
            )
        )
        let delta = try #require(stats.first)
        let decoded = try #require(StreamingStatsHint.decode(delta))
        #expect(decoded.stopReason == "stopinput999mtp1")
        #expect(decoded.inputTokenCount == 3)
        #expect(decoded.mtp == nil)
        #expect(decoded.tokensPerSecond == 0)
    }

    /// Only offered tools, with JSON-object arguments, are ever dispatched.
    @Test func mapperRejectsUnofferedToolsAndNonObjectArguments() {
        var noTools = SwarmEventMapper()
        #expect(noTools.map(.toolCall(index: 0, id: "c", name: "shell", argumentsJSON: "{}")).isEmpty)
        #expect(noTools.terminalError() is SwarmError)
        #expect((noTools.terminalError() as? SwarmError)?.code == "swarm_invalid_tool_call")

        var other = SwarmEventMapper(offeredToolNames: ["read_file"])
        #expect(other.map(.toolCall(index: 0, id: "c", name: "write_file", argumentsJSON: "{}")).isEmpty)
        #expect(other.violation != nil)
        #expect(!(other.terminalError() is ServiceToolInvocation))

        var array = SwarmEventMapper(offeredToolNames: ["read_file"])
        _ = array.map(.toolCall(index: 0, id: "c", name: "read_file", argumentsJSON: "[1,2]"))
        _ = array.map(
            .completion(
                SwarmCompletionInfo(
                    promptTokens: 1,
                    completionTokens: 1,
                    cachedPromptTokens: nil,
                    tokensPerSecond: 1,
                    prefillTokensPerSecond: nil,
                    finishReason: "tool_calls"
                )
            )
        )
        #expect((array.terminalError() as? SwarmError)?.code == "swarm_invalid_tool_call")

        var garbage = SwarmEventMapper(offeredToolNames: ["read_file"])
        _ = garbage.map(.toolCall(index: 0, id: "c", name: "read_file", argumentsJSON: "{\"path\":"))
        _ = garbage.map(
            .completion(
                SwarmCompletionInfo(
                    promptTokens: 1,
                    completionTokens: 1,
                    cachedPromptTokens: nil,
                    tokensPerSecond: 1,
                    prefillTokensPerSecond: nil,
                    finishReason: "tool_calls"
                )
            )
        )
        #expect((garbage.terminalError() as? SwarmError)?.code == "swarm_invalid_tool_call")
    }

    /// Through the service: a node that calls a tool the request did not
    /// offer fails the request typed, and nothing is dispatched.
    @Test func serviceFailsTypedOnUnofferedToolCall() async throws {
        let (backend, service, entry) = try await Self.makeSwarm()
        await backend.simulateRogueToolCall("delete_everything")
        let offered = Tool(
            type: "function",
            function: ToolFunction(name: "get_time", description: "time", parameters: .object([:]))
        )
        let stream = try await service.streamWithTools(
            messages: [Self.user("what time is it?")],
            parameters: Self.params(),
            stopSequences: [],
            tools: [offered],
            toolChoice: .auto,
            requestedModel: entry.pickerModelId
        )
        var sawToolHint = false
        do {
            for try await delta in stream where StreamingToolHint.decode(delta) != nil {
                sawToolHint = true
            }
            Issue.record("an unoffered tool call must fail the request")
        } catch let error as SwarmError {
            #expect(error.code == "swarm_invalid_tool_call")
        } catch {
            Issue.record("expected SwarmError, got \(error)")
        }
        #expect(!sawToolHint)
    }

    static func decode(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }
}
