//
//  InvalidArgsLoopDriverTests.swift
//  osaurusTests
//
//  Coverage for the consecutive-argument-rejection advisory: one tool
//  rejected with `invalid_args` twice in a row — with DIFFERENT arguments
//  each time, so no identical-signature breaker fires — gets a bounded
//  `[System Notice]` on the next build that quotes the validator message
//  verbatim. The loop never stops on it; the model either fixes the
//  arguments as stated or tells the user what is missing.
//
//  Reproduces the live Ornith-1.5-9B shape: `osaurus_config(apply)` rejected
//  for an unset env var, then rejected for an unexpected `set_api_key`
//  property, then re-issued in the first shape again while re-narrating the
//  same plan verbatim.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Envelope fixtures

private enum Fixture {
    static let envVarMessage =
        "token_ref: env var `OBSIDIAN_API_KEY` is not set (checked in the app process — "
        + "launchd apps do not inherit your shell profile)."

    static let unexpectedPropertyMessage =
        "Unexpected property `set_api_key`. Allowed: action, format, prune, save_as, sections, template, yaml"

    static func invalidArgs(tool: String, message: String, field: String? = nil) -> String {
        ToolEnvelope.failure(kind: .invalidArgs, message: message, field: field, tool: tool)
    }

    static func executionError(tool: String) -> String {
        ToolEnvelope.failure(
            kind: .executionError,
            message: "server returned 500",
            tool: tool,
            retryable: true
        )
    }

    static func success(tool: String) -> String {
        ToolEnvelope.success(tool: tool, text: "ok")
    }

    /// The phrase every argument-rejection notice carries.
    static let noticeMarker = "has rejected your arguments"
}

// MARK: - State-machine unit tests

@Suite(.serialized)
struct InvalidArgsRunStateTests {

    @Test func secondConsecutiveRejection_armsNoticeQuotingMessage() {
        let state = AgentTaskState()
        state.record(
            name: "osaurus_config",
            argsJSON: #"{"action":"apply","yaml":"a: 1"}"#,
            result: Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage)
        )
        #expect(state.nextStepBias() == nil, "one rejection is an honest miss — no nudge")

        state.record(
            name: "osaurus_config",
            argsJSON: #"{"action":"apply","set_api_key":"true"}"#,
            result: Fixture.invalidArgs(
                tool: "osaurus_config",
                message: Fixture.unexpectedPropertyMessage,
                field: "set_api_key"
            )
        )
        let bias = state.nextStepBias() ?? ""
        #expect(bias.contains(Fixture.noticeMarker))
        #expect(bias.contains("`osaurus_config`"))
        #expect(bias.contains("2 times in a row"))
        // The LAST validator message, verbatim.
        #expect(bias.contains("\"\(Fixture.unexpectedPropertyMessage)\""))
        // The allowed-property list is repeated when the message carries one.
        #expect(
            bias.contains(
                "Allowed properties for `osaurus_config`: action, format, prune, save_as, sections, template, yaml"
            )
        )
        #expect(bias.contains("The rejected field is `set_api_key`"))
        #expect(bias.contains("tell the user plainly what is missing"))
    }

    @Test func messageWithoutAllowedList_omitsAllowedLine() {
        let state = AgentTaskState()
        for _ in 0 ..< 2 {
            state.record(
                name: "osaurus_config",
                argsJSON: #"{"action":"apply"}"#,
                result: Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage)
            )
        }
        let bias = state.nextStepBias() ?? ""
        #expect(bias.contains(Fixture.noticeMarker))
        #expect(bias.contains("\"\(Fixture.envVarMessage)\""))
        #expect(!bias.contains("Allowed properties"))
    }

    @Test func thirdRejection_doesNotReArm() {
        let state = AgentTaskState()
        for n in 0 ..< 3 {
            state.record(
                name: "osaurus_config",
                argsJSON: #"{"action":"apply","n":\#(n)}"#,
                result: Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage)
            )
        }
        #expect(state.nextStepBias() == nil, "the notice is delivered once per tool per message")
    }

    @Test func rejectionsOnDifferentTools_doNotCombine() {
        let state = AgentTaskState()
        state.record(
            name: "osaurus_config",
            argsJSON: #"{"action":"apply"}"#,
            result: Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage)
        )
        state.record(
            name: "osaurus_inspect",
            argsJSON: #"{"section":"nope"}"#,
            result: Fixture.invalidArgs(tool: "osaurus_inspect", message: "Unknown section")
        )
        #expect(state.nextStepBias() == nil)
    }

    @Test func successForTheTool_resetsItsStreak() {
        let state = AgentTaskState()
        state.record(
            name: "osaurus_config",
            argsJSON: #"{"action":"apply"}"#,
            result: Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage)
        )
        state.record(
            name: "osaurus_config",
            argsJSON: #"{"action":"plan"}"#,
            result: Fixture.success(tool: "osaurus_config")
        )
        state.record(
            name: "osaurus_config",
            argsJSON: #"{"action":"apply","yaml":"b: 2"}"#,
            result: Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage)
        )
        #expect(state.nextStepBias() == nil, "success in between broke the streak")
    }

    @Test func interleavedOtherTool_doesNotLaunderTheStreak() {
        // The live shape: inspect/help detours between rejected applies.
        let state = AgentTaskState()
        state.record(
            name: "osaurus_config",
            argsJSON: #"{"action":"apply"}"#,
            result: Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage)
        )
        state.record(
            name: "osaurus_inspect",
            argsJSON: #"{}"#,
            result: Fixture.success(tool: "osaurus_inspect")
        )
        state.record(
            name: "osaurus_config",
            argsJSON: #"{"action":"apply","set_api_key":"true"}"#,
            result: Fixture.invalidArgs(
                tool: "osaurus_config",
                message: Fixture.unexpectedPropertyMessage
            )
        )
        #expect(state.nextStepBias()?.contains(Fixture.noticeMarker) == true)
    }

    @Test func executionError_isNotAnArgumentRejection() {
        let state = AgentTaskState()
        state.record(
            name: "http_request",
            argsJSON: #"{"url":"https://a"}"#,
            result: Fixture.executionError(tool: "http_request")
        )
        state.record(
            name: "http_request",
            argsJSON: #"{"url":"https://b"}"#,
            result: Fixture.executionError(tool: "http_request")
        )
        #expect(state.nextStepBias() == nil)
        // And a runtime failure breaks an invalid_args streak (it is not one).
        state.record(
            name: "http_request",
            argsJSON: #"{"url":1}"#,
            result: Fixture.invalidArgs(tool: "http_request", message: "url must be a string")
        )
        #expect(state.nextStepBias() == nil)
    }

    @Test func beginMessage_resetsStreakAndNoticeBudget() {
        let state = AgentTaskState()
        for n in 0 ..< 2 {
            state.record(
                name: "osaurus_config",
                argsJSON: #"{"n":\#(n)}"#,
                result: Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage)
            )
        }
        #expect(state.nextStepBias()?.contains(Fixture.noticeMarker) == true)
        state.beginMessage()
        state.record(
            name: "osaurus_config",
            argsJSON: #"{"n":9}"#,
            result: Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage)
        )
        #expect(state.nextStepBias() == nil, "streak restarts with the message")
        state.record(
            name: "osaurus_config",
            argsJSON: #"{"n":10}"#,
            result: Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage)
        )
        #expect(
            state.nextStepBias()?.contains(Fixture.noticeMarker) == true,
            "the per-tool notice budget is per message, not per session"
        )
    }

    @Test func biasDisabled_returnsNothing() {
        let state = AgentTaskState(biasEnabled: false)
        for n in 0 ..< 2 {
            state.record(
                name: "osaurus_config",
                argsJSON: #"{"n":\#(n)}"#,
                result: Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage)
            )
        }
        #expect(state.nextStepBias() == nil)
    }

    @Test func allowedPropertyList_parsesRegistryShape() {
        #expect(
            AgentTaskState.allowedPropertyList(in: Fixture.unexpectedPropertyMessage)
                == "action, format, prune, save_as, sections, template, yaml"
        )
        #expect(
            AgentTaskState.allowedPropertyList(
                in: "Unexpected property `x`. Allowed: a, b. Your previous call was malformed."
            ) == "a, b"
        )
        #expect(AgentTaskState.allowedPropertyList(in: Fixture.envVarMessage) == nil)
    }
}

// MARK: - Driver behavior tests

/// Scripted surface: model steps are consumed in order, and each tool
/// execution pops the next scripted result (default: a success envelope).
/// Results are keyed by CALL ORDER rather than tool name so a tool can fail,
/// succeed, then fail again within one run.
@MainActor
private final class InvalidArgsLoopSurface {
    var steps: [AgentLoopModelStep]
    var scriptedResults: [String]
    var builtNotices: [[String]] = []
    var executions: [(tool: String, args: String)] = []

    init(steps: [AgentLoopModelStep], results: [String]) {
        self.steps = steps
        self.scriptedResults = results
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
            executeTool: { inv, _ in
                self.executions.append((inv.toolName, inv.jsonArguments))
                guard !self.scriptedResults.isEmpty else {
                    return AgentLoopToolExecution(result: Fixture.success(tool: inv.toolName))
                }
                let result = self.scriptedResults.removeFirst()
                return AgentLoopToolExecution(
                    result: result,
                    isError: ToolEnvelope.isError(result)
                )
            }
        )
    }

    /// Per-build count of argument-rejection notices delivered.
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
struct InvalidArgsLoopDriverTests {

    private var policy: AgentLoopPolicy {
        AgentLoopPolicy(
            maxIterations: 8,
            stopOnToolRejection: false,
            dedupeNoticeEnabled: false
        )
    }

    private func configApply(_ args: String) -> ServiceToolInvocation {
        ServiceToolInvocation(toolName: "osaurus_config", jsonArguments: args)
    }

    private func inspect() -> ServiceToolInvocation {
        ServiceToolInvocation(toolName: "osaurus_inspect", jsonArguments: "{}")
    }

    /// (a) The reported shape: two consecutive `invalid_args` on the same
    /// tool with different arguments → exactly one notice, delivered on the
    /// build AFTER the second rejection, quoting that rejection's message.
    @Test
    func twoConsecutiveRejections_deliverOneNoticeQuotingTheMessage() async throws {
        let surface = InvalidArgsLoopSurface(
            steps: [
                .toolCalls([configApply(#"{"action":"apply","yaml":"mcp_servers: {}"}"#)]),
                .toolCalls([configApply(#"{"action":"apply","set_api_key":"true"}"#)]),
                .finalResponse,
            ],
            results: [
                Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage),
                Fixture.invalidArgs(
                    tool: "osaurus_config",
                    message: Fixture.unexpectedPropertyMessage,
                    field: "set_api_key"
                ),
            ]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        // Build #1: nothing. Build #2 (after the first rejection): nothing.
        // Build #3 (after the second): the one notice.
        #expect(surface.deliveredPerBuild() == [0, 0, 1])
        let notice = try #require(surface.deliveredNotices().first)
        #expect(notice.hasPrefix("[System Notice]"))
        #expect(notice.contains("\"\(Fixture.unexpectedPropertyMessage)\""))
        #expect(notice.contains("action, format, prune, save_as, sections, template, yaml"))
        // Both calls executed — advisory, never a block.
        #expect(surface.executions.count == 2)
    }

    /// (b) `invalid_args` on tool A then tool B → no notice.
    @Test
    func rejectionsOnTwoDifferentTools_noNotice() async throws {
        let surface = InvalidArgsLoopSurface(
            steps: [
                .toolCalls([configApply(#"{"action":"apply"}"#)]),
                .toolCalls([inspect()]),
                .finalResponse,
            ],
            results: [
                Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage),
                Fixture.invalidArgs(tool: "osaurus_inspect", message: "Unknown section"),
            ]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.deliveredNotices().isEmpty)
    }

    /// (c) `invalid_args`, success, `invalid_args` on the same tool → the
    /// success reset the streak, so no notice.
    @Test
    func rejectionSuccessRejection_noNotice() async throws {
        let surface = InvalidArgsLoopSurface(
            steps: [
                .toolCalls([configApply(#"{"action":"apply","yaml":"a: 1"}"#)]),
                .toolCalls([configApply(#"{"action":"plan","yaml":"a: 1"}"#)]),
                .toolCalls([configApply(#"{"action":"apply","yaml":"b: 2"}"#)]),
                .finalResponse,
            ],
            results: [
                Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage),
                Fixture.success(tool: "osaurus_config"),
                Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage),
            ]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(surface.deliveredNotices().isEmpty)
        #expect(surface.executions.count == 3)
    }

    /// (d) Three consecutive rejections → still exactly one notice, and it
    /// rides the build right after the SECOND rejection (bounded per tool
    /// per run, never a standing nag).
    @Test
    func threeConsecutiveRejections_stillOneNotice() async throws {
        let surface = InvalidArgsLoopSurface(
            steps: [
                .toolCalls([configApply(#"{"action":"apply","yaml":"a: 1"}"#)]),
                .toolCalls([configApply(#"{"action":"apply","set_api_key":"true"}"#)]),
                .toolCalls([configApply(#"{"action":"apply","yaml":"a: 1"}"#)]),
                .finalResponse,
            ],
            results: [
                Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage),
                Fixture.invalidArgs(
                    tool: "osaurus_config",
                    message: Fixture.unexpectedPropertyMessage
                ),
                Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage),
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
        // The third call still executed: advisory only.
        #expect(surface.executions.count == 3)
    }

    /// (e) The live shape end to end, with the inspect/help detour between
    /// rejections: the loop continues past the notice, the third call is
    /// still executed, and the run ends with an ordinary final response.
    @Test
    func liveShape_loopContinuesToFinalResponse() async throws {
        let surface = InvalidArgsLoopSurface(
            steps: [
                .toolCalls([inspect()]),
                .toolCalls([configApply(#"{"action":"apply","yaml":"mcp_servers: {}"}"#)]),
                .toolCalls([inspect()]),
                .toolCalls([configApply(#"{"action":"apply","set_api_key":"true"}"#)]),
                .toolCalls([configApply(#"{"action":"apply","yaml":"mcp_servers: {}"}"#)]),
                .finalResponse,
            ],
            results: [
                Fixture.success(tool: "osaurus_inspect"),
                Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage),
                Fixture.success(tool: "osaurus_inspect"),
                Fixture.invalidArgs(
                    tool: "osaurus_config",
                    message: Fixture.unexpectedPropertyMessage
                ),
                Fixture.invalidArgs(tool: "osaurus_config", message: Fixture.envVarMessage),
            ]
        )
        let result = try await AgentToolLoop.run(
            policy: policy,
            state: AgentTaskState(),
            hooks: surface.makeHooks()
        )
        #expect(result.exit == .finalResponse)
        #expect(result.iterations == 6)
        // The detour between the two rejected applies does not launder the
        // streak: the notice lands on the build after the second rejection.
        #expect(surface.deliveredPerBuild() == [0, 0, 0, 0, 1, 0])
        #expect(surface.executions.count == 5)
    }
}
