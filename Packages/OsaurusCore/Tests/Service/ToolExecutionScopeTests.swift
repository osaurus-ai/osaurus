// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

/// Tools fired in the app while the tools toggle was visibly **off**.
///
/// Exposure and execution were never bound to each other. The prompt decided which tools the model
/// was *told* about, but nothing stopped it from naming one it had never been shown: the parser
/// records any name once at least one schema is present, and `ToolRegistry` executed it, because
/// the registry believed access control had already happened upstream. It had not. A sandbox /
/// plugin / MCP tool deliberately withheld from an agent would run if the model simply guessed its
/// name.
///
/// The scope has to grow when `capabilities` or `sandbox_plugin_register` activates a tool. It grows
/// both execution authorization and the next iteration's model-visible schema so constrained
/// decoders can emit the loaded name. These tests pin both halves: the hole is closed, AND
/// capability loading still works.
@Suite("A request may only execute what it exposed")
struct ToolExecutionScopeTests {

    private func spec(_ name: String) -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(name: name, description: "test tool \(name)", parameters: nil)
        )
    }

    @Test("A tool that was exposed is permitted")
    func exposedToolIsPermitted() {
        let scope = ToolExecutionScope(exposed: [spec("get_current_time"), spec("file_read")])
        #expect(scope.permits("get_current_time"))
        #expect(scope.permits("file_read"))
    }

    @Test("A tool that was never exposed is refused, however plausible its name")
    func unexposedToolIsRefused() {
        // The exact live failure: the request exposes a benign tool, a sandbox tool is registered
        // process-wide but withheld from this agent, and the model names it anyway.
        let scope = ToolExecutionScope(exposed: [spec("get_current_time")])

        #expect(!scope.permits("sandbox_exec"))
        #expect(!scope.permits("shell_run"))
        #expect(!scope.permits("file_write"))
    }

    @Test("An empty exposure permits nothing — it is not the same as 'no allowlist'")
    func emptyExposurePermitsNothing() {
        // Tools OFF. Conflating "this request exposed nothing" with "no allowlist was published"
        // is exactly how an unexposed tool got through.
        let scope = ToolExecutionScope(exposed: [])
        #expect(!scope.permits("get_current_time"))
        #expect(!scope.permits("sandbox_exec"))
        #expect(scope.authorizedNames.isEmpty)
    }

    @Test("capabilities_load can still make a tool callable mid-run")
    func capabilityLoadGrowsTheScope() {
        let scope = ToolExecutionScope(exposed: [spec("capabilities_load")])
        #expect(!scope.permits("web_search"))

        scope.activate(["web_search", "web_fetch"])

        #expect(scope.permits("web_search"))
        #expect(scope.permits("web_fetch"))
        // …and activating one tool must not fling the doors open for everything else.
        #expect(!scope.permits("sandbox_exec"))
    }

    @Test("Loaded schemas join the next iteration without duplicates")
    func loadedSchemasJoinModelVisibleSpecs() {
        let gateway = spec("capabilities")
        let getEvents = spec("get_events")
        let scope = ToolExecutionScope(exposed: [gateway])

        scope.activate([getEvents, gateway])

        #expect(scope.permits("get_events"))
        #expect(scope.modelVisibleSpecs.map(\.function.name) == ["capabilities", "get_events"])
    }

    @Test("Activation is additive and never revokes the original grant")
    func activationIsAdditive() {
        let scope = ToolExecutionScope(exposed: [spec("get_current_time")])
        scope.activate(["web_search"])
        #expect(scope.permits("get_current_time"))
        #expect(scope.permits("web_search"))
    }
}

/// The check has to sit in the right place, or the model routes around it.
@Suite("The allowlist is enforced where it cannot be bypassed")
struct ToolExecutionScopeWiringTests {
    private static func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Service/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusCore/
        return try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("The check runs AFTER the tool/ prefix is normalized away")
    func checkRunsAfterNameNormalization() throws {
        let src = try Self.source("Tools/ToolRegistry.swift")

        guard
            let execute = src.range(
                of: "func execute(\n        name rawName: String,"
            )
        else {
            Issue.record("could not locate ToolRegistry.execute")
            return
        }
        let executeBody = src[execute.lowerBound...]
        guard
            let normalization = executeBody.range(
                of: "let name = resolvedRegisteredName(for: rawName)"
            ),
            let check = executeBody.range(of: "ChatExecutionContext.toolExecutionScope")
        else {
            Issue.record("could not locate the normalization or the exposure check")
            return
        }

        // Checking the RAW name would let the model bypass the whole allowlist by prefixing a
        // name it was never given: `tool/sandbox_exec` normalizes to `sandbox_exec` afterwards.
        #expect(
            normalization.lowerBound < check.lowerBound,
            "the allowlist must be checked on the NORMALIZED name, or `tool/` walks straight past it"
        )
    }

    @Test("The chat loop publishes a scope, so the guard is actually reached")
    func chatLoopPublishesTheScope() throws {
        // A guard the system never reaches is not a guard. We have shipped that twice.
        let src = try Self.source("Views/Chat/ChatView.swift")
        #expect(src.contains("let toolScope = ToolExecutionScope(exposed: toolSpecs)"))
        #expect(src.contains("$toolExecutionScope"))
        // …and both authorization and the next request schema must grow.
        #expect(src.contains("toolScope.activate(newTools)"))
        #expect(src.contains("let iterationToolSpecs = toolScope.modelVisibleSpecs"))
    }
}
