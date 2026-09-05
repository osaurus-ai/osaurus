//
//  ToolNotFoundLoopDriverTests.swift
//  osaurusTests
//
//  Coverage for the consecutive `tool_not_found` advisory: one tool name
//  refused twice in a row by the request scope gets a bounded
//  `[System Notice]` on the next build that restates the refusal and lists
//  the tools the request IS authorized to run. The loop never stops on it
//  and the refused call is still executed (and still refused) — the notice
//  is advisory, not a block.
//
//  Also covers the hallucinated-punctuation fold: `osaurus_help!!` becomes
//  `osaurus_help` before execution when — and only when — the canonical
//  name is in scope.
//
//  Reproduces the live Raptor shape (0.24.6, Orchestrator chip): `osaurus_help`
//  refused with `tool_not_found` three times, then `osaurus_help!!`,
//  `osaurus_help!`, then a bare `!` as the reply.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Fixtures

private enum Fixture {
    static let scope: Set<String> = [
        "osaurus_inspect", "osaurus_config", "web_search", "todo", "complete",
    ]

    static func toolNotFound(tool: String) -> String {
        ToolEnvelope.failure(
            kind: .toolNotFound,
            message: "\(tool) is not available in this conversation.",
            tool: tool,
            retryable: false
        )
    }

    static func invalidArgs(tool: String) -> String {
        ToolEnvelope.failure(kind: .invalidArgs, message: "bad args", tool: tool)
    }

    static func success(tool: String) -> String {
        ToolEnvelope.success(tool: tool, text: "ok")
    }

    /// The phrase every not-available notice carries.
    static let noticeMarker = "calling it again will fail identically"

    static var sortedScopeList: String {
        scope.sorted().joined(separator: ", ")
    }
}

// MARK: - State-machine unit tests

@Suite(.serialized)
struct ToolNotFoundRunStateTests {

    private func makeState() -> AgentTaskState {
        let state = AgentTaskState()
        state.authorizedToolNamesProvider = { Fixture.scope }
        return state
    }

    @Test func secondConsecutiveRefusal_armsNoticeListingScope() {
        let state = makeState()
        state.record(
            name: "osaurus_help",
            argsJSON: #"{"action":"topics"}"#,
            result: Fixture.toolNotFound(tool: "osaurus_help")
        )
        #expect(state.nextStepBias() == nil, "one refusal is explained by the envelope itself")

        state.record(
            name: "osaurus_help",
            argsJSON: #"{"action":"read","topic":"x"}"#,
            result: Fixture.toolNotFound(tool: "osaurus_help")
        )
        let bias = state.nextStepBias() ?? ""
        #expect(bias.contains(Fixture.noticeMarker))
        #expect(bias.hasPrefix("`osaurus_help` is not available in this conversation"))
        #expect(bias.contains("The tools you have are exactly: \(Fixture.sortedScopeList)."))
        #expect(bias.contains("Answer the user with those or without a tool."))
    }

    @Test func thirdRefusal_doesNotReArm() {
        // Varying arguments so the older identical-args nudge (3 exact
        // repeats) stays out of the picture and only this breaker is read.
        let state = makeState()
        for n in 0 ..< 3 {
            state.record(
                name: "osaurus_help",
                argsJSON: #"{"n":\#(n)}"#,
                result: Fixture.toolNotFound(tool: "osaurus_help")
            )
        }
        #expect(state.nextStepBias() == nil, "delivered once per tool per message")
    }

    @Test func refusalsOnDifferentTools_doNotCombine() {
        let state = makeState()
        state.record(name: "osaurus_help", argsJSON: "{}", result: Fixture.toolNotFound(tool: "osaurus_help"))
        state.record(name: "web_fetch", argsJSON: "{}", result: Fixture.toolNotFound(tool: "web_fetch"))
        #expect(state.nextStepBias() == nil)
    }

    @Test func punctuationVariants_countAsOneStreak() {
        // The live tail: `osaurus_help!!` then `osaurus_help!` while the
        // canonical name is NOT in scope — both still refused, and they
        // fold onto one streak so the notice fires on the second.
        let state = makeState()
        state.record(name: "osaurus_help!!", argsJSON: "{}", result: Fixture.toolNotFound(tool: "osaurus_help!!"))
        #expect(state.nextStepBias() == nil)
        state.record(name: "osaurus_help!", argsJSON: "{}", result: Fixture.toolNotFound(tool: "osaurus_help!"))
        let bias = state.nextStepBias() ?? ""
        #expect(bias.hasPrefix("`osaurus_help` is not available"), "named by the canonical form")
    }

    @Test func otherResultForTheTool_resetsItsStreak() {
        let state = makeState()
        state.record(name: "osaurus_help", argsJSON: #"{"n":1}"#, result: Fixture.toolNotFound(tool: "osaurus_help"))
        state.record(name: "osaurus_help", argsJSON: #"{"n":2}"#, result: Fixture.invalidArgs(tool: "osaurus_help"))
        state.record(name: "osaurus_help", argsJSON: #"{"n":3}"#, result: Fixture.toolNotFound(tool: "osaurus_help"))
        #expect(state.nextStepBias() == nil, "a different failure kind broke the streak")
    }

    @Test func noProvider_noticeOmitsTheList() {
        let state = AgentTaskState()
        for _ in 0 ..< 2 {
            state.record(name: "ghost", argsJSON: "{}", result: Fixture.toolNotFound(tool: "ghost"))
        }
        let bias = state.nextStepBias() ?? ""
        #expect(bias.contains(Fixture.noticeMarker))
        #expect(bias.contains("the ones in your tool schema"))
        #expect(!bias.contains("exactly:"))
    }

    @Test func beginMessage_resetsStreakAndNoticeBudget() {
        let state = makeState()
        for _ in 0 ..< 2 {
            state.record(name: "ghost", argsJSON: "{}", result: Fixture.toolNotFound(tool: "ghost"))
        }
        #expect(state.nextStepBias()?.contains(Fixture.noticeMarker) == true)
        state.beginMessage()
        state.record(name: "ghost", argsJSON: "{}", result: Fixture.toolNotFound(tool: "ghost"))
        #expect(state.nextStepBias() == nil, "streak restarts with the message")
        state.record(name: "ghost", argsJSON: "{}", result: Fixture.toolNotFound(tool: "ghost"))
        #expect(state.nextStepBias()?.contains(Fixture.noticeMarker) == true)
    }

    @Test func biasDisabled_returnsNothing() {
        let state = AgentTaskState(biasEnabled: false)
        state.authorizedToolNamesProvider = { Fixture.scope }
        for _ in 0 ..< 2 {
            state.record(name: "ghost", argsJSON: "{}", result: Fixture.toolNotFound(tool: "ghost"))
        }
        #expect(state.nextStepBias() == nil)
    }

    @Test func canonicalToolName_stripsEdgePunctuationOnly() {
        #expect(AgentTaskState.canonicalToolName("osaurus_help!!") == "osaurus_help")
        #expect(AgentTaskState.canonicalToolName("osaurus_help!") == "osaurus_help")
        #expect(AgentTaskState.canonicalToolName("`osaurus_help`") == "osaurus_help")
        #expect(AgentTaskState.canonicalToolName("\"osaurus_help\".") == "osaurus_help")
        #expect(AgentTaskState.canonicalToolName(" osaurus_help ") == "osaurus_help")
        // Interior characters are legitimate and untouched.
        #expect(AgentTaskState.canonicalToolName("server.tool") == "server.tool")
        #expect(AgentTaskState.canonicalToolName("tool/osaurus_help") == "tool/osaurus_help")
        #expect(AgentTaskState.canonicalToolName("a-b_c") == "a-b_c")
        // Already canonical → identity; all-punctuation → unchanged.
        #expect(AgentTaskState.canonicalToolName("osaurus_help") == "osaurus_help")
        #expect(AgentTaskState.canonicalToolName("!!!") == "!!!")
    }

    @Test func canonicalizedInvocations_foldsOnlyWhenCanonicalIsAuthorized() {
        let calls = [
            ServiceToolInvocation(toolName: "osaurus_help!!", jsonArguments: "{}", toolCallId: "c1"),
            ServiceToolInvocation(toolName: "web_fetch!", jsonArguments: "{}", toolCallId: "c2"),
            ServiceToolInvocation(toolName: "web_search", jsonArguments: "{}", toolCallId: "c3"),
        ]
        let folded = AgentToolLoop.canonicalizedInvocations(
            calls,
            authorizedToolNames: ["osaurus_help", "web_search"]
        )
        #expect(folded.map(\.toolName) == ["osaurus_help", "web_fetch!", "web_search"])
        #expect(folded.map(\.toolCallId) == ["c1", "c2", "c3"], "call ids survive the fold")
        // No scope published → nothing is touched.
        #expect(
            AgentToolLoop.canonicalizedInvocations(calls, authorizedToolNames: nil).map(\.toolName)
                == ["osaurus_help!!", "web_fetch!", "web_search"]
        )
    }
}

// MARK: - Driver behavior tests

/// Scripted surface (see `InvalidArgsLoopDriverTests`): model steps are
/// consumed in order; each execution pops the next scripted result, and a
/// tool outside `scope` is refused with the registry's `tool_not_found`
/// envelope when no result is scripted for it.
@MainActor
private final class ToolNotFoundLoopSurface {
    var steps: [AgentLoopModelStep]
    var scriptedResults: [String]
    var builtNotices: [[String]] = []
    var executions: [(tool: String, args: String)] = []
    let scope: ToolExecutionScope

    init(steps: [AgentLoopModelStep], results: [String] = [], scope: Set<String> = Fixture.scope) {
        self.steps = steps
        self.scriptedResults = results
        self.scope = ToolExecutionScope(exposed: [])
        self.scope.activate(Array(scope))
    }

    private func pop(for inv: ServiceToolInvocation) -> AgentLoopToolExecution {
        executions.append((inv.toolName, inv.jsonArguments))
        if !scriptedResults.isEmpty {
            let result = scriptedResults.removeFirst()
            return AgentLoopToolExecution(result: result, isError: ToolEnvelope.isError(result))
        }
        // Mirror `ToolRegistry.execute`'s scope refusal for anything the
        // request never exposed.
        guard scope.permits(inv.toolName) else {
            let refused = Fixture.toolNotFound(tool: inv.toolName)
            return AgentLoopToolExecution(result: refused, isError: true)
        }
        return AgentLoopToolExecution(result: Fixture.success(tool: inv.toolName))
    }

    func makeHooks() -> AgentLoopHooks {
        AgentLoopHooks(
            buildMessages: { notices in
                self.builtNotices.append(notices)
                return AgentLoopIterationInput(
                    messages: [ChatMessage(role: "user", content: "task")]
                )
            },
            modelStep: { _, _ in
                guard !self.steps.isEmpty else { return .finalResponse }
                return self.steps.removeFirst()
            },
            executeTool: { inv, _ in self.pop(for: inv) },
            authorizedToolNames: { self.scope.authorizedNames }
        )
    }

    func deliveredPerBuild() -> [Int] {
        builtNotices.map { notices in
            notices.filter { $0.contains(Fixture.noticeMarker) }.count
        }
    }

    func deliveredNotices() -> [String] {
        builtNotices.flatMap { $0 }.filter { $0.contains(Fixture.noticeMarker) }
    }
}

@MainActor
struct ToolNotFoundLoopDriverTests {

    /// Chat semantics: `stopOnToolRejection` is ON, exactly as the live
    /// surface runs — `tool_not_found` must not end the run, or the notice
    /// could never be delivered there.
    private var policy: AgentLoopPolicy {
        AgentLoopPolicy(
            maxIterations: 8,
            stopOnToolRejection: true,
            dedupeNoticeEnabled: false
        )
    }

    private func help(_ name: String = "osaurus_help", _ args: String = #"{"action":"topics"}"#)
        -> ServiceToolInvocation
    {
        ServiceToolInvocation(toolName: name, jsonArguments: args)
    }

    /// (a) Two `tool_not_found` for X → exactly one notice, on the build
    /// after the second refusal, listing the authorized names.
    @Test
    func twoRefusals_deliverOneNoticeListingTheScope() async throws {
        let surface = ToolNotFoundLoopSurface(
            steps: [
                .toolCalls([help("osaurus_help", #"{"action":"topics"}"#)]),
                .toolCalls([help("osaurus_help", #"{"action":"read","topic":"agents"}"#)]),
                .finalResponse,
            ]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.deliveredPerBuild() == [0, 0, 1])
        let notice = try #require(surface.deliveredNotices().first)
        #expect(notice.hasPrefix("[System Notice] `osaurus_help` is not available in this conversation"))
        #expect(notice.contains("The tools you have are exactly: \(Fixture.sortedScopeList)."))
        #expect(notice.contains("Answer the user with those or without a tool."))
        // Both calls reached the executor — advisory, never a block.
        #expect(surface.executions.map(\.tool) == ["osaurus_help", "osaurus_help"])
    }

    /// (b) X refused, then Y refused → no notice.
    @Test
    func refusalsOnTwoDifferentTools_noNotice() async throws {
        let surface = ToolNotFoundLoopSurface(
            steps: [
                .toolCalls([help("osaurus_help")]),
                .toolCalls([help("web_fetch", #"{"url":"https://a"}"#)]),
                .finalResponse,
            ]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.deliveredNotices().isEmpty)
        #expect(surface.executions.count == 2)
    }

    /// (c) Three refusals → still exactly one notice (bounded per tool per
    /// message), and the third call still executes.
    @Test
    func threeRefusals_stillOneNotice() async throws {
        let surface = ToolNotFoundLoopSurface(
            steps: [
                .toolCalls([help()]),
                .toolCalls([help()]),
                .toolCalls([help()]),
                .finalResponse,
            ]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.deliveredPerBuild() == [0, 0, 1, 0])
        #expect(surface.deliveredNotices().count == 1)
        #expect(surface.executions.count == 3)
    }

    /// (d) `osaurus_help!!` resolves to `osaurus_help` when the canonical
    /// name is in scope: the executor receives the canonical name, the call
    /// succeeds, and no notice is staged. A decorated name whose canonical
    /// form is NOT in scope stays as emitted and is refused.
    @Test
    func decoratedName_resolvesToCanonicalWhenInScope() async throws {
        let surface = ToolNotFoundLoopSurface(
            steps: [
                .toolCalls([help("osaurus_help!!")]),
                .toolCalls([help("web_fetch!!")]),
                .finalResponse,
            ],
            scope: Fixture.scope.union(["osaurus_help"])
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.executions.map(\.tool) == ["osaurus_help", "web_fetch!!"])
        #expect(surface.deliveredNotices().isEmpty)
    }

    /// (e) The live shape end to end: three refused `osaurus_help`, then the
    /// decorated variants (still out of scope), then a final response. One
    /// notice after the second refusal; the loop runs to `.finalResponse`.
    @Test
    func liveShape_loopContinuesToFinalResponse() async throws {
        let surface = ToolNotFoundLoopSurface(
            steps: [
                .toolCalls([help()]),
                .toolCalls([help()]),
                .toolCalls([help()]),
                .toolCalls([help("osaurus_help!!")]),
                .toolCalls([help("osaurus_help!")]),
                .finalResponse,
            ]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(result.iterations == 6)
        #expect(surface.deliveredPerBuild() == [0, 0, 1, 0, 0, 0])
        // Out-of-scope decorations are NOT folded — they reach the executor
        // as emitted and are refused like the canonical name was.
        #expect(
            surface.executions.map(\.tool)
                == ["osaurus_help", "osaurus_help", "osaurus_help", "osaurus_help!!", "osaurus_help!"]
        )
    }

    /// The fix for the live case in loop terms: once the scope carries
    /// `osaurus_help` (the agent-switch re-freeze), the same model behaviour
    /// simply works — no refusals, no notice.
    @Test
    func scopeCarriesTheTool_noRefusalNoNotice() async throws {
        let surface = ToolNotFoundLoopSurface(
            steps: [.toolCalls([help()]), .finalResponse],
            scope: Fixture.scope.union(["osaurus_help"])
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.deliveredNotices().isEmpty)
        #expect(surface.executions.map(\.tool) == ["osaurus_help"])
    }
}
