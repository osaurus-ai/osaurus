//
//  SpawnToolTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Model-free guardrail tests for the spawn family — `spawn_agent` (agent
//  context) and `spawn_model` (bare model). The full nested loop needs a live
//  model (covered by the AgentLoop eval suite); these pin everything that must
//  hold without one: the unified recursion guard, argument validation, the
//  registry-timeout opt-out, and the per-agent / per-pool reject-before-evict
//  gates for BOTH tools.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SpawnToolTests {

    @Test func childToolNamesFoldInKnowledgeBuiltins() {
        // A knowledge (non-curator) agent's spawned child carries the knowledge
        // read/annotate tools even with an EMPTY manual allowlist — they are
        // feature-gated builtins, not manual-list entries, so without this fold a
        // spawned knowledge agent would be silently tool-less.
        let knowledge = Set(
            TextSubagentKind.childToolNames(
                manual: [], knowledgeEnabled: true, knowledgeCuratorEnabled: false
            )
        )
        #expect(knowledge.contains("list_knowledge"))
        #expect(knowledge.contains("search_knowledge"))
        #expect(knowledge.contains("flag_knowledge_stale"))
        // Curator-only tools stay out until the curator role is on.
        #expect(!knowledge.contains("propose_knowledge_update"))
        #expect(!knowledge.contains("update_knowledge_ticket"))

        // A curator agent additionally carries the proposal/ticket tools.
        let curator = Set(
            TextSubagentKind.childToolNames(
                manual: [], knowledgeEnabled: true, knowledgeCuratorEnabled: true
            )
        )
        #expect(curator.contains("propose_knowledge_update"))
        #expect(curator.contains("update_knowledge_ticket"))

        // Knowledge off → the manual allowlist only, no knowledge tools.
        let plain = Set(
            TextSubagentKind.childToolNames(
                manual: ["read_file"], knowledgeEnabled: false, knowledgeCuratorEnabled: false
            )
        )
        #expect(plain == ["read_file"])

        // Spawn-capability tools and `clarify` are always dropped for children.
        let filtered = Set(
            TextSubagentKind.childToolNames(
                manual: ["read_file", "clarify", SubagentCapabilityRegistry.spawnAgentToolName],
                knowledgeEnabled: false,
                knowledgeCuratorEnabled: false
            )
        )
        #expect(filtered == ["read_file"])
    }

    @Test func refusesRecursion() async throws {
        // The recursion guard is the unified host guard
        // (`SubagentSession.activeKindId`), shared across the whole subagent
        // family — a running subagent of ANY kind blocks a nested spawn.
        let agentResult = try await SubagentSession.$activeKindId.withValue("image") {
            try await SpawnAgentTool().execute(
                argumentsJSON:
                    #"{"agent":"00000000-0000-4000-8000-000000000098","input":"summarize"}"#
            )
        }
        #expect(ToolEnvelope.isError(agentResult))
        #expect(agentResult.contains("cannot be called from inside"))

        let modelResult = try await SubagentSession.$activeKindId.withValue("image") {
            try await SpawnModelTool().execute(
                argumentsJSON: #"{"model":"qwen3-4b-4bit","input":"summarize"}"#
            )
        }
        #expect(ToolEnvelope.isError(modelResult))
        #expect(modelResult.contains("cannot be called from inside"))

        let batchResult = try await SubagentSession.$activeKindId.withValue("image") {
            try await SpawnBatchTool().execute(
                argumentsJSON:
                    #"{"jobs":[{"id":"a","target_type":"model","target":"qwen3-4b-4bit","input":"summarize"}]}"#
            )
        }
        #expect(ToolEnvelope.isError(batchResult))
        #expect(batchResult.contains("cannot be called from inside"))
    }

    @Test func spawnAgentRejectsMissingArguments() async throws {
        let missingAgent = try await SpawnAgentTool().execute(argumentsJSON: #"{"input":"do a thing"}"#)
        #expect(ToolEnvelope.isError(missingAgent))
        #expect(missingAgent.contains("agent"))

        let missingInput = try await SpawnAgentTool().execute(argumentsJSON: #"{"agent":"helper"}"#)
        #expect(ToolEnvelope.isError(missingInput))
        #expect(missingInput.contains("input"))

        let malformed = try await SpawnAgentTool().execute(argumentsJSON: "not json")
        #expect(ToolEnvelope.isError(malformed))
    }

    @Test func spawnModelRejectsMissingArguments() async throws {
        let missingModel = try await SpawnModelTool().execute(argumentsJSON: #"{"input":"do a thing"}"#)
        #expect(ToolEnvelope.isError(missingModel))
        #expect(missingModel.contains("model"))

        let missingInput = try await SpawnModelTool().execute(argumentsJSON: #"{"model":"qwen3-4b-4bit"}"#)
        #expect(ToolEnvelope.isError(missingInput))
        #expect(missingInput.contains("input"))

        let malformed = try await SpawnModelTool().execute(argumentsJSON: "not json")
        #expect(ToolEnvelope.isError(malformed))
    }

    @Test func spawnModelRejectsWhitespaceModelBeforeSpawnabilityGate() async throws {
        let result = try await SpawnModelTool().execute(
            argumentsJSON: #"{"input":"do a thing","model":"   \n\t"}"#
        )
        #expect(ToolEnvelope.isError(result))
        #expect(ToolEnvelope.failureMessage(result).contains("cannot be blank"))
        #expect(!ToolEnvelope.failureMessage(result).contains("Model '' is not spawnable"))
    }

    @Test func bypassesRegistryTimeout() {
        // The nested loop outlives the registry's per-tool wall clock; both spawn
        // tools must opt out so the host owns the deadline.
        #expect(SpawnAgentTool().bypassRegistryTimeout)
        #expect(SpawnModelTool().bypassRegistryTimeout)
        #expect(SpawnBatchTool().bypassRegistryTimeout)
    }

    @Test func toolNamesMatchTheRegistry() {
        // The two tools are the SSOT names from the shared `spawn` capability.
        #expect(SpawnAgentTool().name == "spawn_agent")
        #expect(SpawnModelTool().name == "spawn_model")
        #expect(SpawnBatchTool().name == "spawn_batch")
        #expect(
            SubagentCapabilityRegistry.spawn.toolNames
                == ["spawn_agent", "spawn_model", "spawn_batch"]
        )
    }

    @Test func spawnAgentDescriptionStatesCancellationAuditedToolBoundary() {
        let description = SpawnAgentTool().description
        #expect(description.contains("cancellation-audited for spawned execution"))
        #expect(description.contains("other direct-chat tools remain parent-owned"))
        #expect(!description.contains("calendar agent can create events"))
    }

    @Test func everySpawnSchemaUsesTheStandaloneInputContract() throws {
        func inputDescription(
            _ tool: any OsaurusTool,
            nestedInJobs: Bool = false
        ) throws -> String {
            guard case .object(let root)? = tool.parameters,
                case .object(let properties)? = root["properties"]
            else {
                Issue.record("Expected object tool schema with properties")
                return ""
            }
            let input: [String: JSONValue]
            if nestedInJobs {
                guard case .object(let jobs)? = properties["jobs"],
                    case .object(let items)? = jobs["items"],
                    case .object(let jobProperties)? = items["properties"],
                    case .object(let nestedInput)? = jobProperties["input"]
                else {
                    Issue.record("Expected nested spawn_batch input schema")
                    return ""
                }
                input = nestedInput
            } else {
                guard case .object(let directInput)? = properties["input"] else {
                    Issue.record("Expected direct spawn input schema")
                    return ""
                }
                input = directInput
            }
            guard case .string(let description)? = input["description"] else {
                Issue.record("Expected string input description")
                return ""
            }
            return description
        }

        let expected = SpawnInputContract.schemaDescription
        #expect(try inputDescription(SpawnAgentTool()) == expected)
        #expect(try inputDescription(SpawnModelTool()) == expected)
        #expect(try inputDescription(SpawnBatchTool(), nestedInJobs: true) == expected)
        #expect(expected.contains("complete standalone task"))
        #expect(expected.contains("cannot see the parent chat"))
        #expect(expected.contains("Never refer to a previous/earlier message"))
    }

    @Test func allSpawnSurfacesDoNotLexicallyRejectParentReferencePhrases() {
        let inputs = [
            (
                input: #"Translate the quoted phrase "previous message" into French."#,
                field: "input",
                tool: "spawn_model"
            ),
            (
                input: #"Review this code: let label = "message above"."#,
                field: "input",
                tool: "spawn_agent"
            ),
            (
                input: "Translate '이전 메시지' into English.",
                field: "jobs[0].input",
                tool: "spawn_batch"
            ),
        ]
        for value in inputs {
            #expect(
                SpawnInputContract.validationFailure(
                    input: value.input,
                    field: value.field,
                    tool: value.tool
                ) == nil
            )
        }
    }

    @Test func nonEmptySpawnInputsPassTheStructuralContract() {
        let accepted = [
            "Reply exactly SCHEMA-ALPHA-7391 and nothing else.",
            "Compare the previous and current values: previous=7, current=9.",
            "Summarize the previous message.",
            #"Translate "previous message" into French."#,
            #"Explain this code: let label = "message above"."#,
            "Translate 'предыдущего сообщения' into English.",
        ]
        for input in accepted {
            #expect(
                SpawnInputContract.validationFailure(
                    input: input,
                    tool: "spawn_model"
                ) == nil
            )
        }
    }

    @Test func allSpawnSurfacesRejectBlankInputStructurally() async throws {
        let model = try await SpawnModelTool().execute(
            argumentsJSON: #"{"input":" \n\t ","model":"not-allowed"}"#
        )
        #expect(ToolEnvelope.isError(model))
        #expect(ToolEnvelope.failureMessage(model).contains("cannot be blank"))
        #expect(model.contains(#""field":"input""#))
        #expect(!ToolEnvelope.failureMessage(model).contains("not spawnable"))

        let agent = try await SpawnAgentTool().execute(
            argumentsJSON: #"{"input":"   ","agent":"not-allowed"}"#
        )
        #expect(ToolEnvelope.isError(agent))
        #expect(ToolEnvelope.failureMessage(agent).contains("cannot be blank"))
        #expect(agent.contains(#""field":"input""#))
        #expect(!ToolEnvelope.failureMessage(agent).contains("not spawnable"))

        let batch = try await SpawnBatchTool().execute(
            argumentsJSON:
                #"{"jobs":[{"id":"a","target_type":"model","target":"not-allowed","input":" \n\t "}]} "#
        )
        #expect(ToolEnvelope.isError(batch))
        #expect(ToolEnvelope.failureMessage(batch).contains("blank `target` or `input`"))
    }

    @Test func agentKindShape() {
        let helperID = UUID(uuidString: "AAAAAAAA-1111-4111-8111-111111111111")!
        let kind = TextSubagentKind(agentID: helperID, input: "x")
        #expect(kind.capability.id == "spawn")
        #expect(
            kind.capability.toolNames
                == ["spawn_agent", "spawn_model", "spawn_batch"]
        )
        // spawn runs the chosen agent's model → it may resolve a DIFFERENT
        // local model and run the residency handoff (unlike the same-model
        // image / computer_use / sandbox kinds).
        #expect(kind.capability.modelSource == .agent)
        #expect(kind.feedTitle.contains(helperID.uuidString))
    }

    @Test func modelKindShape() {
        // The model-mode kind shares the same capability but titles itself with
        // the bare model id (no agent).
        let kind = TextSubagentKind(model: "qwen3-4b-4bit", input: "x")
        #expect(kind.capability.id == "spawn")
        #expect(kind.feedTitle.contains("qwen3-4b-4bit"))
    }

    @Test func spawnModelUsagePrefersPositiveProviderThroughput() {
        let resolved = AgentSubagentRunner.resolvedTokensPerSecond(
            reported: 73.5,
            completionTokens: 42,
            elapsed: 2.0
        )
        #expect(resolved == 73.5)
    }

    @Test func spawnModelUsageMeasuresThroughputWhenProviderReportsZero() {
        let resolved = AgentSubagentRunner.resolvedTokensPerSecond(
            reported: 0,
            completionTokens: 5,
            elapsed: 0.25
        )
        #expect(resolved == 20)
    }

    @Test func spawnModelUsageDoesNotInventThroughputWithoutMeasurement() {
        #expect(
            AgentSubagentRunner.resolvedTokensPerSecond(
                reported: nil,
                completionTokens: 5,
                elapsed: 0
            ) == nil
        )
        #expect(
            AgentSubagentRunner.resolvedTokensPerSecond(
                reported: .nan,
                completionTokens: 0,
                elapsed: 1
            ) == nil
        )
    }

    @Test func childRunnerPreservesInterleavedReasoningWithoutInlineThinkLeakage() async throws {
        let probe = InterleavedReasoningStreamProbe()
        let channelProbe = ChannelDeltaProbe()
        let toolset = AgentSubagentToolset(
            specs: [
                Tool(
                    type: "function",
                    function: ToolFunction(
                        name: "lookup",
                        description: "Return a deterministic test value.",
                        parameters: .object([:])
                    )
                )
            ],
            execute: { invocation in
                #expect(invocation.toolName == "lookup")
                return ToolEnvelope.success(tool: invocation.toolName, result: ["value": "ok"])
            }
        )

        let result = try await AgentSubagentRunner.run(
            modelName: "scripted-reasoning-tool-model",
            seedMessages: [
                ChatMessage(role: "system", content: "Use tools when needed."),
                ChatMessage(role: "user", content: "Look up the value, then answer.")
            ],
            maxTokens: 64,
            maxIterations: 3,
            deadline: Date().addingTimeInterval(10),
            sessionId: "reasoning-tool-final-regression",
            enableThinking: true,
            toolset: toolset,
            onChannelDelta: { delta in
                channelProbe.record(delta)
            },
            streamProvider: { request in
                try await probe.stream(for: request)
            }
        )

        #expect(result.exit == .finalResponse)
        #expect(result.iterations == 2)
        #expect(result.digest == "Visible final answer.")
        #expect(result.digest?.contains("<think>") == false)
        #expect(result.digest?.contains("private reasoning") == false)
        #expect(
            channelProbe.snapshot() == [
                .reasoning("private reasoning before tool"),
                .reasoning("private reasoning after tool"),
                .content("Visible final answer."),
            ]
        )

        let requests = await probe.requests()
        #expect(requests.count == 2)
        let followup = try #require(requests.last)
        let assistantToolMessage = try #require(
            followup.messages.first {
                $0.role == "assistant" && !($0.tool_calls?.isEmpty ?? true)
            }
        )
        #expect(assistantToolMessage.content == nil)
        #expect(assistantToolMessage.reasoning_content == "private reasoning before tool")
        #expect(assistantToolMessage.tool_calls?.first?.id == "call_lookup")
        #expect(assistantToolMessage.tool_calls?.first?.function.name == "lookup")
        #expect(
            followup.messages.allSatisfy {
                !($0.content ?? "").contains("<think>")
                    && !($0.content ?? "").contains("private reasoning")
            }
        )

        let toolResult = try #require(
            followup.messages.first { $0.role == "tool" }
        )
        #expect(toolResult.tool_call_id == "call_lookup")
        #expect(toolResult.content?.contains(#""ok":true"#) == true)
    }

    /// Per-agent spawnable enforcement (agents): a CUSTOM launching agent may
    /// only spawn agents in its OWN `spawnableAgentIDs` list — the global
    /// pool does NOT apply to it. Here the main chat's pool lists "Helper", but
    /// the launching agent is a custom agent with an empty list, so `resolveModel`
    /// must reject BEFORE any model/residency work (reject-before-evict). Binding
    /// `ChatExecutionContext.currentAgentId` to a non-default id that
    /// AgentManager doesn't know about resolves the per-agent list to empty.
    @Test func customAgentSpawnRejectsTargetOutsideItsOwnList() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-per-agent-enforcement")
        defer { lease.release() }
        let helperID = UUID(uuidString: "AAAAAAAA-2222-4222-8222-222222222222")!
        SubagentConfigurationStore.save(
            SubagentConfiguration(
                spawnableAgentIDs: [helperID]
            )
        )

        let customAgentId = UUID()
        await ChatExecutionContext.$currentAgentId.withValue(customAgentId) {
            do {
                _ = try await TextSubagentKind(agentID: helperID, input: "x")
                    .resolveModel(SubagentScope.current())
                Issue.record("custom agent spawn of an unlisted target should be denied")
            } catch let SubagentError.denied(message) {
                // The custom-agent message points at the agent's own Subagents
                // tab, not the global Main Chat pool.
                #expect(message.contains("not spawnable from this agent"))
            } catch {
                Issue.record("expected SubagentError.denied, got \(error)")
            }
        }
    }

    /// Per-pool enforcement (models): the main chat's `spawn_model` pool is
    /// authoritative for the Default agent. With an empty model pool, a
    /// `spawn_model` against any id must reject before model/residency work.
    @Test func mainChatSpawnModelRejectsModelOutsideItsPool() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-model-pool-enforcement")
        defer { lease.release() }
        SubagentConfigurationStore.save(
            SubagentConfiguration(spawnableModelNames: ["allowed-model"])
        )

        await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            do {
                _ = try await TextSubagentKind(model: "not-in-pool", input: "x")
                    .resolveModel(SubagentScope.current())
                Issue.record("spawn_model of a model outside the pool should be denied")
            } catch let SubagentError.denied(message) {
                #expect(message.contains("not spawnable"))
            } catch {
                Issue.record("expected SubagentError.denied, got \(error)")
            }
        }
    }

    /// Per-agent permission enforcement for the main chat: the Default agent
    /// reads its spawn permission from the GLOBAL config (not `AgentSettings`).
    /// With the target in the global pool but the spawn permission set to
    /// `.deny`, `resolveModel` must reject with the per-agent permission message
    /// before any model / agent work (reject-before-evict).
    @Test func mainChatSpawnRespectsGlobalPermissionDeny() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-main-chat-permission-deny")
        defer { lease.release() }
        let helperID = UUID(uuidString: "AAAAAAAA-3333-4333-8333-333333333333")!
        var perms = SubagentPermissionDefaults()
        perms.setPolicy(.deny, for: SubagentCapabilityRegistry.spawn.id)
        SubagentConfigurationStore.save(
            SubagentConfiguration(
                spawnableAgentIDs: [helperID],
                permissionDefaults: perms
            )
        )

        await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            do {
                _ = try await TextSubagentKind(agentID: helperID, input: "x")
                    .resolveModel(SubagentScope.current())
                Issue.record("a denied spawn permission should reject resolveModel")
            } catch let SubagentError.denied(message) {
                #expect(message.contains("denied by this agent's permission settings"))
            } catch {
                Issue.record("expected SubagentError.denied, got \(error)")
            }
        }
    }
}

private final class ChannelDeltaProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [AgentSubagentRunner.ChannelDelta] = []

    func record(_ delta: AgentSubagentRunner.ChannelDelta) {
        lock.lock()
        deltas.append(delta)
        lock.unlock()
    }

    func snapshot() -> [AgentSubagentRunner.ChannelDelta] {
        lock.lock()
        defer { lock.unlock() }
        return deltas
    }
}

private actor InterleavedReasoningStreamProbe {
    private var capturedRequests: [ChatCompletionRequest] = []

    func stream(
        for request: ChatCompletionRequest
    ) throws -> AsyncThrowingStream<String, Error> {
        capturedRequests.append(request)
        let step = capturedRequests.count

        return AsyncThrowingStream { continuation in
            if step == 1 {
                continuation.yield(
                    StreamingReasoningHint.encode("private reasoning before tool")
                )
                continuation.finish(
                    throwing: ServiceToolInvocation(
                        toolName: "lookup",
                        jsonArguments: "{}",
                        toolCallId: "call_lookup"
                    )
                )
            } else {
                continuation.yield(
                    StreamingReasoningHint.encode("private reasoning after tool")
                )
                continuation.yield("Visible final answer.")
                continuation.finish()
            }
        }
    }

    func requests() -> [ChatCompletionRequest] {
        capturedRequests
    }
}
