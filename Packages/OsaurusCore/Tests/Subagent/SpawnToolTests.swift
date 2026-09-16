//
//  SpawnToolTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Model-free guardrail tests for `spawn_agent`, the one delegation tool.
//  The full nested loop needs a live model (covered by the AgentLoop eval
//  suite); these pin everything that must hold without one: the unified
//  recursion guard, argument validation (incl. `continue`), the
//  registry-timeout opt-out, and the per-agent reject-before-evict gates.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SpawnToolTests {

    private func capabilities(
        webSearch: Bool = false,
        knowledge: Bool = false,
        curator: Bool = false
    ) -> AgentCapabilities {
        AgentCapabilities(
            toolsEnabled: true,
            memoryEnabled: false,
            dbEnabled: false,
            renderChartEnabled: false,
            speakEnabled: false,
            searchMemoryEnabled: false,
            webSearchEnabled: webSearch,
            selfSchedulingEnabled: false,
            knowledgeEnabled: knowledge,
            knowledgeCuratorEnabled: curator
        )
    }

    @Test func childToolNamesFoldInCapabilityGatedBuiltins() {
        // A knowledge (non-curator) agent's spawned child carries the knowledge
        // read/annotate tools even with an EMPTY manual allowlist — they are
        // feature-gated builtins, not manual-list entries, so without this fold a
        // spawned knowledge agent would be silently tool-less.
        let knowledge = Set(
            TextSubagentKind.childToolNames(
                manual: [], capabilities: capabilities(knowledge: true)
            )
        )
        #expect(knowledge.contains("list_knowledge"))
        #expect(knowledge.contains("search_knowledge"))
        #expect(knowledge.contains("flag_knowledge_stale"))
        // Ticket bookkeeping follows the ordinary grant now that the curator
        // role is gone.
        #expect(knowledge.contains("update_knowledge_ticket"))

        // Fully capable workers: knowledge mutation rides along with the
        // grant (its approval card is still the consent gate).
        #expect(knowledge.contains("write_knowledge"))
        #expect(knowledge.contains("delete_knowledge"))

        // The curator flag is inert; it can no longer widen a child's tools.
        let curator = Set(
            TextSubagentKind.childToolNames(
                manual: [], capabilities: capabilities(knowledge: true, curator: true)
            )
        )
        #expect(curator == knowledge)

        // Web Search on rides into the child even when the seeded/manual
        // allowlist predates the capability and never listed the tools —
        // mirroring direct chat, where the toggle applies on top of the
        // allowlist. (Regression: a seeded allowlist without `web_search`
        // left the spawned helper unable to search despite the toggle.)
        let webSearch = Set(
            TextSubagentKind.childToolNames(
                manual: ["read_file"], capabilities: capabilities(webSearch: true)
            )
        )
        #expect(webSearch.contains("web_search"))
        #expect(webSearch.contains("search_and_extract"))
        #expect(webSearch.contains("read_file"))

        // All capability toggles off → the manual allowlist plus the
        // unconditional worker baseline (time + `share_artifact`, the
        // worker's only artifact-delivery path).
        let plain = Set(
            TextSubagentKind.childToolNames(
                manual: ["read_file"], capabilities: capabilities()
            )
        )
        #expect(plain == ["get_current_time", "read_file", "share_artifact"])
        #expect(!plain.contains("web_search"))

        // Spawn-capability tools and `clarify` are always dropped for children.
        let filtered = Set(
            TextSubagentKind.childToolNames(
                manual: ["read_file", "clarify", SubagentCapabilityRegistry.spawnAgentToolName],
                capabilities: capabilities()
            )
        )
        #expect(filtered == ["get_current_time", "read_file", "share_artifact"])
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

    }

    @Test func spawnAgentRejectsMissingArguments() async throws {
        let missingAgent = try await SpawnAgentTool().execute(argumentsJSON: #"{"input":"do a thing"}"#)
        #expect(ToolEnvelope.isError(missingAgent))
        #expect(missingAgent.contains("agent"))
        // The error teaches the alternative: `continue` stands in for `agent`.
        #expect(ToolEnvelope.failureMessage(missingAgent).contains("continue"))

        let missingInput = try await SpawnAgentTool().execute(argumentsJSON: #"{"agent":"helper"}"#)
        #expect(ToolEnvelope.isError(missingInput))
        #expect(missingInput.contains("input"))

        let malformed = try await SpawnAgentTool().execute(argumentsJSON: "not json")
        #expect(ToolEnvelope.isError(malformed))
    }

    @Test func spawnAgentContinueRequiresAKnownSession() async throws {
        // A malformed handle is an argument error.
        let malformed = try await SpawnAgentTool().execute(
            argumentsJSON: #"{"input":"next step","continue":"not-a-uuid"}"#
        )
        #expect(ToolEnvelope.isError(malformed))
        #expect(malformed.contains(#""field":"continue""#))

        // A well-formed handle that no delegated run produced is refused with
        // an actionable message (never silently starts a fresh worker).
        let foreign = try await SpawnAgentTool().execute(
            argumentsJSON:
                #"{"input":"next step","continue":"00000000-0000-4000-8000-0000000000AB"}"#
        )
        #expect(ToolEnvelope.isError(foreign))
        #expect(ToolEnvelope.failureMessage(foreign).contains("session"))
    }

    @Test func bypassesRegistryTimeout() {
        // The nested loop outlives the registry's per-tool wall clock; the
        // spawn tool must opt out so the host owns the deadline.
        #expect(SpawnAgentTool().bypassRegistryTimeout)
    }

    @Test func toolNamesMatchTheRegistry() {
        // `spawn_agent` is the ONE delegation tool (spawn_model / spawn_batch
        // were removed — several calls in one message are the fan-out).
        #expect(SpawnAgentTool().name == "spawn_agent")
        #expect(SubagentCapabilityRegistry.spawn.toolNames == ["spawn_agent"])
    }

    @Test func spawnAgentDescriptionStatesTheDelegatedToolBoundary() {
        let description = SpawnAgentTool().description
        // The child IS the target agent (a real chat session with that
        // agent's own tools and folder, inheriting the launcher's folder when
        // it has none); the story is short enough for small models.
        #expect(description.contains("chat session of that agent"))
        #expect(description.contains("its own tools and working folder"))
        #expect(description.contains("inherits yours if it has none"))
        #expect(description.contains("`session_id`"))
        #expect(!description.contains("cancellation-audited"))
        #expect(!description.contains("spawn_batch"))
        #expect(!description.contains("spawn_model"))
    }

    @Test func spawnSchemaUsesTheStandaloneInputContract() throws {
        guard case .object(let root)? = SpawnAgentTool().parameters,
            case .object(let properties)? = root["properties"],
            case .object(let input)? = properties["input"],
            case .string(let description)? = input["description"]
        else {
            Issue.record("Expected object tool schema with an `input` description")
            return
        }
        let expected = SpawnInputContract.schemaDescription
        #expect(description == expected)
        #expect(expected.contains("complete standalone task"))
        #expect(expected.contains("cannot see this chat"))
        #expect(expected.contains("required output format"))

        // `input` is the only required field: `agent` OR `continue` selects
        // the worker.
        if case .array(let required)? = root["required"] {
            #expect(required == [.string("input")])
        }
        #expect(properties["continue"] != nil)
        #expect(properties["agent"] != nil)
    }

    @Test func spawnAgentExposesOptionalBackgroundParameter() throws {
        guard case .object(let root)? = SpawnAgentTool().parameters,
            case .object(let properties)? = root["properties"],
            case .object(let background)? = properties["background"]
        else {
            Issue.record("Expected a `background` property on spawn_agent")
            return
        }
        // Optional: `background` must never join the required list.
        if case .array(let required)? = root["required"] {
            #expect(!required.contains(.string("background")))
        }
        #expect(background["type"] == .string("boolean"))
        #expect(
            background["description"]
                == .string(SpawnInputContract.backgroundParameterDescription)
        )
        #expect(
            SpawnInputContract.backgroundParameterDescription.contains("returns immediately")
        )
        #expect(
            SpawnInputContract.backgroundParameterDescription.contains("follow-up message")
        )
    }

    @Test func spawnInputDoesNotLexicallyRejectParentReferencePhrases() {
        let inputs = [
            (
                input: #"Translate the quoted phrase "previous message" into French."#,
                field: "input",
                tool: "spawn_agent"
            ),
            (
                input: #"Review this code: let label = "message above"."#,
                field: "input",
                tool: "spawn_agent"
            ),
            (
                input: "Translate '이전 메시지' into English.",
                field: "input",
                tool: "spawn_agent"
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
                    tool: "spawn_agent"
                ) == nil
            )
        }
    }

    @Test func spawnAgentRejectsBlankInputStructurally() async throws {
        let agent = try await SpawnAgentTool().execute(
            argumentsJSON: #"{"input":"   ","agent":"not-allowed"}"#
        )
        #expect(ToolEnvelope.isError(agent))
        #expect(ToolEnvelope.failureMessage(agent).contains("cannot be blank"))
        #expect(agent.contains(#""field":"input""#))
        #expect(!ToolEnvelope.failureMessage(agent).contains("not spawnable"))
    }

    @Test func agentKindShape() {
        let helperID = UUID(uuidString: "AAAAAAAA-1111-4111-8111-111111111111")!
        let kind = TextSubagentKind(agentID: helperID, input: "x")
        #expect(kind.capability.id == "spawn")
        #expect(kind.capability.toolNames == ["spawn_agent"])
        // spawn runs the chosen agent's model → it may resolve a DIFFERENT
        // local model and run the residency handoff (unlike the same-model
        // image / computer_use / sandbox kinds).
        #expect(kind.capability.modelSource == .agent)
        #expect(kind.feedTitle.contains(helperID.uuidString))
    }

    @Test func spawnUsagePrefersPositiveProviderThroughput() {
        let resolved = AgentSubagentRunner.resolvedTokensPerSecond(
            reported: 73.5,
            completionTokens: 42,
            elapsed: 2.0
        )
        #expect(resolved == 73.5)
    }

    @Test func spawnUsageMeasuresThroughputWhenProviderReportsZero() {
        let resolved = AgentSubagentRunner.resolvedTokensPerSecond(
            reported: 0,
            completionTokens: 5,
            elapsed: 0.25
        )
        #expect(resolved == 20)
    }

    @Test func spawnUsageDoesNotInventThroughputWithoutMeasurement() {
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
