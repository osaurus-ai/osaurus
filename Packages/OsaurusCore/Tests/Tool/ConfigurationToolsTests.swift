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

    // MARK: - Write tool: gate fires before argument / action parsing

    @Test
    func configWrite_refusesWithoutAgentContext() async throws {
        // A populated `action` proves the gate short-circuits before
        // dispatch — the response is the gate failure, not an action-
        // specific validation error.
        let result = try await executeWithoutAgentContext(
            OsaurusConfigTool(),
            args: "{\"action\": \"apply\"}"
        )
        #expect(ToolEnvelope.isError(result), "osaurus_config should gate-fail without agent context")
        #expect(
            result.contains("chat session context"),
            "osaurus_config gate message should name the missing session context; got \(result)"
        )
    }

    @Test
    func configWrite_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(
            OsaurusConfigTool(),
            args: "{\"action\": \"apply\"}"
        )
        #expect(ToolEnvelope.isError(result), "osaurus_config should gate-fail from a custom agent")
        #expect(
            result.contains("Default agent"),
            "osaurus_config gate message should name the Default agent; got \(result)"
        )
    }

    // MARK: - Read tool: same gate applies

    @Test
    func inspect_refusesWithoutAgentContext() async throws {
        let result = try await executeWithoutAgentContext(
            OsaurusInspectTool(),
            args: "{\"action\": \"status\"}"
        )
        #expect(ToolEnvelope.isError(result))
    }

    @Test
    func inspect_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(
            OsaurusInspectTool(),
            args: "{\"action\": \"status\"}"
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"))
    }

    @Test
    func inspectList_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(
            OsaurusInspectTool(),
            args: "{\"action\": \"list\", \"scope\": \"providers\"}"
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"))
    }

    @Test
    func inspectDescribe_refusesFromCustomAgent() async throws {
        let result = try await executeAsCustomAgent(
            OsaurusInspectTool(),
            args: "{\"action\": \"describe\", \"scope\": \"providers\", \"id\": \"x\"}"
        )
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("Default agent"))
    }
}

/// Pins the `osaurus_config` action surface — the whole configure write
/// contract for the Default agent. Removing an action silently downgrades
/// the agent's configuration ability.
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
    func configTool_offersTheFullDeclarativeSurface() {
        let actions = actionEnum(of: OsaurusConfigTool())
        #expect(Set(actions) == ["schema", "export", "plan", "apply", "templates"])
    }

    @Test
    func inspectTool_offersTheThreeReadDepths() {
        let actions = actionEnum(of: OsaurusInspectTool())
        #expect(Set(actions) == ["status", "list", "describe"])
    }
}

/// Pins the read-scope surface of `osaurus_inspect`. These scopes are a
/// product contract: the configuration agent can only answer "what
/// skills/watchers/themes/… do I have?" from live state when the scope is
/// offered in the schema enum — prompt compaction strips description prose
/// but KEEPS enums, so this list is the only roster a compact-schema model
/// ever sees (removing it regressed scope-less/junk-arg calls immediately).
/// The enum ALSO carries the settings document sections: those execute as
/// a teaching failure that redirects to osaurus_config export/apply
/// (`unknownScopeFailure`) instead of a generic schema rejection.
@Suite
struct ConfigurationReadScopeTests {

    private func scopeEnum(of tool: any OsaurusTool) -> Set<String> {
        guard case .object(let root)? = tool.parameters,
            case .object(let props)? = root["properties"],
            case .object(let scope)? = props["scope"],
            case .array(let values)? = scope["enum"]
        else { return [] }
        return Set(values.compactMap { if case .string(let s) = $0 { return s } else { return nil } })
    }

    private static let expectedScopes: Set<String> = [
        "agents", "models", "providers", "mcp", "plugins", "schedules",
        "skills", "watchers", "knowledge", "themes", "commands", "channels",
        "search",
    ]

    /// Document sections (export/apply redirect) plus the removed
    /// `server`/`chat`/`app` names (Settings-UI-only teach). Both stay in
    /// the enum so the SchemaValidator lets them through to
    /// `unknownScopeFailure` instead of a generic rejection.
    private static let settingsSections: Set<String> = [
        "server", "chat", "app", "memory", "default_agent", "active_agent",
        "tools", "delegation",
    ]

    @Test
    func inspectTool_offersEveryReadScope() {
        let offered = scopeEnum(of: OsaurusInspectTool())
        #expect(offered.isSuperset(of: Self.expectedScopes))
        #expect(
            OsaurusInspectTool.knownReadScopes
                == Self.expectedScopes.union(["mcp_providers"]))
    }

    @Test
    func inspectTool_scopeEnumCarriesSettingsSectionsForTheRedirect() {
        let offered = scopeEnum(of: OsaurusInspectTool())
        #expect(offered.isSuperset(of: Self.settingsSections))
    }

    @Test
    func entitySectionNames_resolveAsScopeAliases() {
        #expect(OsaurusInspectTool.canonicalScope("mcp_servers") == "mcp")
        #expect(OsaurusInspectTool.canonicalScope("knowledge_collections") == "knowledge")
        #expect(OsaurusInspectTool.canonicalScope("search_providers") == "search")
        #expect(OsaurusInspectTool.canonicalScope("agents") == "agents")
    }

    @Test
    func unknownScope_documentSection_redirectsToExportApply() {
        // The bare failure text still teaches the export/apply pair (it is
        // what a caller sees when the section read itself cannot run).
        let envelope = OsaurusInspectTool.unknownScopeFailure(scope: "memory", tool: "osaurus_inspect")
        #expect(envelope.contains("DOCUMENT SECTION"))
        #expect(envelope.contains("export"))
        #expect(envelope.contains("apply"))
        #expect(envelope.contains("memory"))
    }


    /// The exact rejected calls from the build #13 loop, through the real
    /// `execute` dispatch (not the helper): a junk scope still teaches, and
    /// the scope that rejection offers now reads instead of contradicting it.
    @Test
    func originalLoopArguments_throughDispatch() async throws {
        let tool = OsaurusInspectTool()
        // Configuration tools run only under the Default agent's context.
        try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            let junk = try await tool.execute(
                argumentsJSON: #"{"action":"describe","id":"00000000-0000-0000-0000-000000000001","scope":"user_profile"}"#)
            #expect(!ToolEnvelope.isSuccess(junk))
            #expect(junk.contains("scope"))

            let section = try await tool.execute(
                argumentsJSON: #"{"action":"describe","id":"00000000-0000-0000-0000-000000000001","scope":"default_agent"}"#)
            #expect(ToolEnvelope.isSuccess(section), Comment(rawValue: String(section.prefix(240))))
            let payload = try #require(ToolEnvelope.successPayload(section) as? [String: Any])
            #expect(payload["kind"] as? String == "document_section")
            #expect((payload["yaml"] as? String)?.contains("default_agent") == true)

            let listed = try await tool.execute(argumentsJSON: #"{"action":"list","scope":"memory"}"#)
            #expect(ToolEnvelope.isSuccess(listed), Comment(rawValue: String(listed.prefix(240))))
        }
    }

    /// The scope enum advertises the document sections; naming one must read
    /// it, not bounce between "must be one of … default_agent …" and "not an
    /// inspect scope" (the 29-call loop on build #13).
    @Test
    func documentSectionScope_readsTheSection() async throws {
        for scope in ["default_agent", "memory", "tools"] {
            let envelope = try #require(
                await OsaurusInspectTool.documentSectionRead(scope: scope, tool: "osaurus_inspect"),
                "\(scope) must resolve to a section read")
            #expect(ToolEnvelope.isSuccess(envelope), "\(scope): \(envelope.prefix(200))")
            let payload = try #require(ToolEnvelope.successPayload(envelope) as? [String: Any])
            #expect(payload["kind"] as? String == "document_section")
            #expect(payload["scope"] as? String == scope)
            #expect((payload["yaml"] as? String)?.contains(scope) == true)
        }
        // Not a section: no read, the caller falls through to the failure.
        #expect(await OsaurusInspectTool.documentSectionRead(scope: "user_profile", tool: "osaurus_inspect") == nil)
        for removed in ["server", "chat", "app"] {
            #expect(await OsaurusInspectTool.documentSectionRead(scope: removed, tool: "osaurus_inspect") == nil)
        }
    }

    @Test
    func unknownScope_removedSection_teachesSettingsUIOnly() {
        // Scope reduction 2: the removed section names must get the honest
        // "Settings UI only" answer, not the export redirect.
        for scope in ["server", "chat", "app"] {
            let envelope = OsaurusInspectTool.unknownScopeFailure(scope: scope, tool: "osaurus_inspect")
            #expect(envelope.contains("Settings UI"), "no redirect for `\(scope)`")
            #expect(!envelope.contains("DOCUMENT SECTION"))
            #expect(!envelope.contains("export"))
        }
    }

    @Test
    func unknownScope_nonSection_listsValidScopes() {
        let envelope = OsaurusInspectTool.unknownScopeFailure(scope: "bogus", tool: "osaurus_inspect")
        #expect(envelope.contains("Unknown scope"))
        #expect(envelope.contains("agents"))
        #expect(!envelope.contains("DOCUMENT SECTION"))
    }

    @Test
    func describeFoundation_teachesTheBuiltInModelValue() async throws {
        // "foundation" is a model VALUE (Apple's built-in on-device model),
        // not an installed model entry; verifying it against the installed
        // list comes back empty and models refuse a valid setting.
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusInspectTool().execute(
                argumentsJSON:
                    "{\"action\": \"describe\", \"scope\": \"models\", \"id\": \"foundation\"}"
            )
        }
        #expect(result.contains("Apple Foundation"), "missing foundation teach: \(result)")
        #expect(result.contains("default_agent.model"))
    }
}

/// Weekday parsing for `schedules` entries with `frequency: weekly`. The
/// model emits natural day text ("Monday"); the parser normalizes to a
/// 3-letter prefix so full names, abbreviations, case, and plurals all
/// resolve — only genuine non-weekdays are rejected.
@Suite
struct ScheduleWeeklyParsingTests {

    private func parseWeekday(_ value: String) -> ScheduleFrequency? {
        let outcome = ConfigScheduleFrequency.parse(
            frequency: "weekly",
            value: value,
            timeOfDay: "09:30"
        )
        if case .success(let frequency) = outcome { return frequency }
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
