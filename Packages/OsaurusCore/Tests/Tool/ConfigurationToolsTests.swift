//
//  ConfigurationToolsTests.swift
//  OsaurusCoreTests
//
//  Per-tool gate contract for the consolidated configure surface:
//
//   * Every consolidated `osaurus_*` tool routes through
//     `ConfigurationToolBase.defaultAgentGateFailure` *before* parsing
//     arguments or dispatching on `action`. We assert this by calling each
//     tool without a `currentAgentId` binding — the response must be an
//     `unavailable` envelope regardless of how malformed the JSON is (and
//     regardless of which `action`, since the gate runs first).
//   * Calling from a non-default agent yields the same gate rejection
//     ("only available to the Default agent").
//
//  These tests deliberately avoid touching `AgentManager`,
//  `RemoteProviderManager`, `ModelManager`, etc. — the gate runs first so
//  the manager-side code is never reached when the caller is on the wrong
//  agent or has no agent context.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ConfigurationToolsGateContractTests {

    /// Run the tool with no `currentAgentId` binding (the most hostile
    /// invocation path — e.g. an HTTP / plugin tool call that somehow
    /// reached the configure surface).
    private func executeWithoutAgentContext(
        _ tool: any OsaurusTool,
        args: String = "{}"
    ) async throws -> String {
        try await tool.execute(argumentsJSON: args)
    }

    private func executeAsCustomAgent(
        _ tool: any OsaurusTool,
        args: String = "{}"
    ) async throws -> String {
        try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await tool.execute(argumentsJSON: args)
        }
    }

    /// Every consolidated configure tool, paired with a representative
    /// `action` to prove the gate fires before the action is even read.
    private func makeWriteTools() -> [any OsaurusTool] {
        [
            OsaurusProviderTool(),
            OsaurusModelTool(),
            OsaurusMCPTool(),
            OsaurusPluginTool(),
            OsaurusScheduleTool(),
            OsaurusAgentTool(),
        ]
    }

    // MARK: - Write tools: gate fires before argument / action parsing

    @Test
    func everyConsolidatedWrite_refusesWithoutAgentContext() async throws {
        for tool in makeWriteTools() {
            // A populated `action` proves the gate short-circuits before
            // dispatch — the response is the gate failure, not an action-
            // specific validation error.
            let result = try await executeWithoutAgentContext(
                tool,
                args: "{\"action\": \"add\"}"
            )
            #expect(ToolEnvelope.isError(result), "\(tool.name) should gate-fail without agent context")
            #expect(
                result.contains("chat session context"),
                "\(tool.name) gate message should name the missing session context; got \(result)"
            )
        }
    }

    @Test
    func everyConsolidatedWrite_refusesFromCustomAgent() async throws {
        for tool in makeWriteTools() {
            let result = try await executeAsCustomAgent(
                tool,
                args: "{\"action\": \"add\"}"
            )
            #expect(ToolEnvelope.isError(result), "\(tool.name) should gate-fail from a custom agent")
            #expect(
                result.contains("Default agent"),
                "\(tool.name) gate message should name the Default agent; got \(result)"
            )
        }
    }

    // MARK: - Read tools: same gate applies

    @Test
    func status_refusesWithoutAgentContext() async throws {
        let result = try await executeWithoutAgentContext(OsaurusStatusTool())
        #expect(ToolEnvelope.isError(result))
    }

    @Test
    func status_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(OsaurusStatusTool())
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"))
    }

    @Test
    func list_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(
            OsaurusListTool(),
            args: "{\"scope\": \"providers\"}"
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"))
    }

    @Test
    func describe_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(
            OsaurusDescribeTool(),
            args: "{\"scope\": \"providers\", \"id\": \"x\"}"
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"))
    }
}

/// Schema ergonomics surfaced by the Default-agent eval matrix: a small
/// model says "disable" / "Monday", so the consolidated tools must accept
/// those directly instead of forcing the `enable` + `enabled:false` idiom
/// or a 3-letter weekday code (either gap sends the model into a retry
/// loop it can't escape within its iteration budget).
@Suite
struct ConsolidatedActionSchemaTests {

    /// Pull the `action` property's JSON-Schema `enum` values off a tool's
    /// `parameters` so a test can assert which actions the model is offered.
    private func actionEnum(of tool: any OsaurusTool) -> [String] {
        guard case .object(let root)? = tool.parameters,
            case .object(let props)? = root["properties"],
            case .object(let action)? = props["action"],
            case .array(let values)? = action["enum"]
        else { return [] }
        return values.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    @Test
    func mcpTool_offersDisableAsFirstClassAction() {
        let actions = actionEnum(of: OsaurusMCPTool())
        #expect(actions.contains("enable"))
        #expect(actions.contains("disable"), "osaurus_mcp must expose a first-class `disable` action")
    }

    @Test
    func scheduleTool_offersDisableAsFirstClassAction() {
        let actions = actionEnum(of: OsaurusScheduleTool())
        #expect(actions.contains("enable"))
        #expect(actions.contains("disable"), "osaurus_schedule must expose a first-class `disable` action")
    }
}

/// Weekday parsing for `osaurus_schedule` create/update with
/// `frequency: weekly`. The model emits natural day text ("Monday"); the
/// parser normalizes to a 3-letter prefix so full names, abbreviations,
/// case, and plurals all resolve — only genuine non-weekdays are rejected.
@Suite
struct ScheduleWeeklyParsingTests {

    private func parseWeekday(_ value: String) -> ScheduleFrequency? {
        let outcome = ScheduleFrequencyParsing.parse(
            toolName: "osaurus_schedule",
            frequency: "weekly",
            value: value,
            timeOfDay: "09:30"
        )
        if case .parsed(let frequency) = outcome { return frequency }
        return nil
    }

    @Test
    func acceptsFullName() {
        #expect(parseWeekday("Monday") == .weekly(dayOfWeek: 2, hour: 9, minute: 30))
    }

    @Test
    func acceptsAbbreviation() {
        #expect(parseWeekday("MON") == .weekly(dayOfWeek: 2, hour: 9, minute: 30))
    }

    @Test
    func acceptsLowercaseAndPlural() {
        #expect(parseWeekday("mondays") == .weekly(dayOfWeek: 2, hour: 9, minute: 30))
        #expect(parseWeekday("sunday") == .weekly(dayOfWeek: 1, hour: 9, minute: 30))
        #expect(parseWeekday("Saturday") == .weekly(dayOfWeek: 7, hour: 9, minute: 30))
    }

    @Test
    func rejectsNonWeekday() {
        #expect(parseWeekday("someday") == nil)
        #expect(parseWeekday("xyz") == nil)
    }
}
