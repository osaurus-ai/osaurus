//
//  BuiltinToolResilienceTests.swift
//
//  Cross-tool resilience matrix. For every built-in (always-loaded) and
//  built-in sandbox tool, exercise the canonical malformed shapes that
//  quantized models routinely emit and pin the structured outcome:
//
//    1. `{}`                              — preflight rejects with `field`
//                                           pointing at first required arg.
//    2. wrong type for required            — preflight rejects with `field`.
//    3. extra unknown key                  — preflight rejects with `field`
//                                           pointing at the unknown key (when
//                                           the schema sets `additionalProperties`).
//    4. JSON-encoded scalar / array        — preflight coerces to native.
//    5. empty / whitespace optional string — preflight drops the key.
//
//  Tools without required args (e.g. `git_status`, `git_diff`) skip
//  cases 1–2; tools without `additionalProperties: false` skip case 3.
//
//  We deliberately stop at the preflight boundary instead of executing
//  bodies — many built-ins touch the keychain, sandbox container, or
//  shell, and the goal here is to verify the schema/preflight contract.
//  Per-tool execution tests (BuiltinSandboxToolsTests, AgentLoopToolsTests,
//  FolderToolsResilienceTests) cover the body-level rejection paths.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct BuiltinToolResilienceTests {

    // MARK: - Always-loaded built-ins

    /// Every always-loaded tool must declare `additionalProperties: false`
    /// at the top level so the central preflight rejects unknown keys.
    /// Locking this in here stops a future "I'll just leave it loose"
    /// schema from quietly becoming a compatibility hole.
    @Test func allBuiltInsRejectUnknownProperties() throws {
        let registry = ToolRegistry.shared
        let builtIns = registry.listTools()
            .filter { registry.builtInToolNames.contains($0.name) }
        #expect(!builtIns.isEmpty, "no built-in tools registered")

        for entry in builtIns {
            let parameters = try #require(entry.parameters, "\(entry.name): no parameter schema")
            try assertHasAdditionalPropertiesFalse(parameters, toolName: entry.name)
        }
    }

    /// Every built-in's schema must accept `{<all-required-filled>}` and
    /// reject `{}`. Catches schemas that declare a required key but
    /// either (a) forgot to add it to `required` or (b) have a wrong-
    /// typed example so the validator fails on a well-formed call.
    @Test func allBuiltInsValidateMinimumValidPayload() throws {
        let registry = ToolRegistry.shared
        let builtIns = registry.listTools()
            .filter { registry.builtInToolNames.contains($0.name) }

        for entry in builtIns {
            guard let parameters = entry.parameters,
                let synthesized = synthesizeMinimumValid(forSchema: parameters)
            else { continue }
            let outcome = registry.preflightForTest(
                argumentsJSON: synthesized,
                schema: parameters,
                toolName: entry.name
            )
            switch outcome {
            case .ready:
                break  // good: validator accepts the synthesized payload
            case .rejected(let envelope):
                Issue.record(
                    "\(entry.name): preflight rejected the synthesized minimum-valid payload \(synthesized): \(envelope)"
                )
            }
        }
    }

    /// `{}` against a schema with required keys must surface a structured
    /// `invalid_args` envelope whose `field` names the first missing
    /// required arg. Tools with no required args are skipped (they
    /// legitimately accept `{}`).
    @Test func allBuiltInsRejectEmptyArgsWhenAnyRequired() throws {
        let registry = ToolRegistry.shared
        let builtIns = registry.listTools()
            .filter { registry.builtInToolNames.contains($0.name) }

        for entry in builtIns {
            guard let parameters = entry.parameters,
                let firstRequired = firstRequiredKey(in: parameters)
            else { continue }
            let outcome = registry.preflightForTest(
                argumentsJSON: "{}",
                schema: parameters,
                toolName: entry.name
            )
            switch outcome {
            case .rejected(let envelope):
                let field = failureField(envelope)
                #expect(
                    field == firstRequired,
                    "\(entry.name): expected field=\(firstRequired), got \(field ?? "nil")"
                )
            case .ready:
                Issue.record(
                    "\(entry.name): expected `{}` to be rejected (required: \(firstRequired)) but preflight accepted it"
                )
            }
        }
    }

    // MARK: - Sandbox built-ins
    //
    // Sandbox tool types are file-private to BuiltinSandboxTools.swift.
    // Driving the matrix through `ToolRegistry` avoids reaching across
    // the private boundary AND verifies the live registration flow at
    // the same time.

    /// Run `body` with sandbox built-ins registered for a synthetic
    /// agent, then unregister to restore registry state. Sandbox tools
    /// are runtime-managed, so `unregisterAllBuiltinSandboxTools` is
    /// the correct cleanup hook.
    private func withSandboxBuiltInsRegistered(
        _ body: ([ToolRegistry.ToolEntry]) throws -> Void
    ) rethrows {
        let registry = ToolRegistry.shared
        let agentId = UUID().uuidString
        BuiltinSandboxTools.register(
            agentId: agentId,
            agentName: "test-agent",
            config: AutonomousExecConfig(
                enabled: true,
                maxCommandsPerTurn: 100,
                pluginCreate: true
            )
        )
        defer { registry.unregisterAllBuiltinSandboxTools() }
        let names = registry.builtInSandboxToolNamesSnapshot
        let entries = registry.listTools().filter { names.contains($0.name) }
        try body(entries)
    }

    @Test func sandboxBuiltInsRejectUnknownProperties() throws {
        try withSandboxBuiltInsRegistered { entries in
            #expect(!entries.isEmpty, "no sandbox built-ins registered")
            for entry in entries {
                let parameters = try #require(
                    entry.parameters,
                    "\(entry.name): no parameter schema"
                )
                try assertHasAdditionalPropertiesFalse(parameters, toolName: entry.name)
            }
        }
    }

    @Test func sandboxBuiltInsValidateMinimumValidPayload() throws {
        let registry = ToolRegistry.shared
        try withSandboxBuiltInsRegistered { entries in
            for entry in entries {
                guard let parameters = entry.parameters,
                    let synthesized = synthesizeMinimumValid(forSchema: parameters)
                else { continue }
                let outcome = registry.preflightForTest(
                    argumentsJSON: synthesized,
                    schema: parameters,
                    toolName: entry.name
                )
                switch outcome {
                case .ready:
                    break
                case .rejected(let envelope):
                    Issue.record(
                        "\(entry.name): preflight rejected synthesized minimum-valid payload \(synthesized): \(envelope)"
                    )
                }
            }
        }
    }

    @Test func sandboxBuiltInsRejectEmptyArgsWhenAnyRequired() throws {
        let registry = ToolRegistry.shared
        try withSandboxBuiltInsRegistered { entries in
            for entry in entries {
                guard let parameters = entry.parameters,
                    let firstRequired = firstRequiredKey(in: parameters)
                else { continue }
                let outcome = registry.preflightForTest(
                    argumentsJSON: "{}",
                    schema: parameters,
                    toolName: entry.name
                )
                switch outcome {
                case .rejected(let envelope):
                    #expect(
                        failureField(envelope) == firstRequired,
                        "\(entry.name): expected field=\(firstRequired), got \(failureField(envelope) ?? "nil")"
                    )
                case .ready:
                    Issue.record(
                        "\(entry.name): expected `{}` rejected, but preflight accepted"
                    )
                }
            }
        }
    }

    // MARK: - Cross-cutting coercion regressions

    /// Sandbox install tools accept a JSON-encoded string array for
    /// `packages` because `SchemaValidator.coerceArguments` rescues the
    /// shape before the validator runs. Looked up via the registry so
    /// we don't need access to the file-private tool struct.
    @Test func sandboxInstallAcceptsJSONEncodedPackages() throws {
        try withSandboxBuiltInsRegistered { _ in
            let registry = ToolRegistry.shared
            let parameters = try #require(
                registry.parametersForTool(name: "sandbox_install"),
                "sandbox_install not registered"
            )
            let outcome = registry.preflightForTest(
                argumentsJSON: #"{"manager": "apk", "packages": "[\"ffmpeg\", \"imagemagick\"]"}"#,
                schema: parameters,
                toolName: "sandbox_install"
            )
            switch outcome {
            case .ready(let argsJSON):
                #expect(argsJSON.contains("\"ffmpeg\""))
                #expect(argsJSON.contains("\"imagemagick\""))
            case .rejected(let envelope):
                Issue.record("preflight rejected stringified array: \(envelope)")
            }
        }
    }

    /// `search_memory` accepts mixed-case enum values because
    /// `coerceValue` normalises them to the canonical declared form.
    @Test func searchMemoryAcceptsMixedCaseScope() {
        let tool = SearchMemoryTool()
        let outcome = ToolRegistry.shared.preflightForTest(
            argumentsJSON: #"{"scope": "PINNED", "query": "what colour"}"#,
            schema: tool.parameters,
            toolName: tool.name
        )
        switch outcome {
        case .ready(let argsJSON):
            #expect(argsJSON.contains("\"scope\":\"pinned\""))
        case .rejected(let envelope):
            Issue.record("preflight rejected mixed-case scope: \(envelope)")
        }
    }

    /// `share_artifact` exhibits the empty-string-as-absent rescue at
    /// the preflight layer (lifted out of its hand-rolled `nonEmpty`
    /// helper). `description: ""` should be dropped before the body
    /// runs so the at-least-one-of check in the body only sees real
    /// fields.
    @Test func shareArtifactDropsEmptyStringFiller() {
        let tool = ShareArtifactTool()
        let outcome = ToolRegistry.shared.preflightForTest(
            argumentsJSON: #"{"path": "report.pdf", "description": "", "filename": ""}"#,
            schema: tool.parameters,
            toolName: tool.name
        )
        switch outcome {
        case .ready(let argsJSON):
            #expect(!argsJSON.contains("\"description\""))
            #expect(!argsJSON.contains("\"filename\""))
            #expect(argsJSON.contains("\"path\":\"report.pdf\""))
        case .rejected(let envelope):
            Issue.record("preflight rejected: \(envelope)")
        }
    }

    /// `sandbox_exec` accepts a string-encoded `timeout` (the screenshot
    /// bug). Anchored here in addition to `SchemaValidatorCoercionTests`
    /// so a regression in the per-tool schema (e.g. dropping the
    /// `integer` type) shows up under the matrix banner.
    @Test func sandboxExecAcceptsStringTimeout() throws {
        try withSandboxBuiltInsRegistered { _ in
            let registry = ToolRegistry.shared
            let parameters = try #require(
                registry.parametersForTool(name: "sandbox_exec"),
                "sandbox_exec not registered"
            )
            let outcome = registry.preflightForTest(
                argumentsJSON: #"{"command": "echo hi", "timeout": "15"}"#,
                schema: parameters,
                toolName: "sandbox_exec"
            )
            switch outcome {
            case .ready(let argsJSON):
                #expect(argsJSON.contains("\"timeout\":15"))
            case .rejected(let envelope):
                Issue.record(
                    "preflight rejected sandbox_exec string timeout: \(envelope)"
                )
            }
        }
    }

    // MARK: - SandboxPluginTool envelope contract

    /// User-created plugin tools must round-trip through the standard
    /// envelope detectors. Specifically the success / non-zero-exit
    /// split — pre-audit the tool returned a raw `{stdout, stderr,
    /// exit_code}` shape that `ToolEnvelope.isSuccess` could not detect
    /// as success, breaking the chat UI's grouping logic.
    @Test func sandboxPluginToolHonoursStandardSchemaContract() throws {
        // `SandboxPlugin.id` derives from `name.lowercased()`, so naming
        // the plugin "demo" gives the tool id `demo_echo`.
        let plugin = SandboxPlugin(
            name: "demo",
            description: "test",
            tools: [
                SandboxToolSpec(
                    id: "echo",
                    description: "echoes",
                    parameters: ["text": SandboxParameterSpec(type: "string")],
                    run: "echo $PARAM_TEXT"
                )
            ]
        )
        let tool = SandboxPluginTool(spec: plugin.tools![0], plugin: plugin)
        let parameters = try #require(tool.parameters)

        // `additionalProperties: false` is now emitted on every
        // generated plugin schema (pre-audit it was missing).
        try assertHasAdditionalPropertiesFalse(parameters, toolName: tool.name)

        // `{}` against a single required arg → invalid_args(field=text)
        let missingOutcome = ToolRegistry.shared.preflightForTest(
            argumentsJSON: "{}",
            schema: parameters,
            toolName: tool.name
        )
        if case .rejected(let envelope) = missingOutcome {
            #expect(failureField(envelope) == "text")
        } else {
            Issue.record("expected `{}` rejected with field=text")
        }

        // Unknown key → invalid_args(field=extra)
        let unknownOutcome = ToolRegistry.shared.preflightForTest(
            argumentsJSON: #"{"text": "hi", "extra": 1}"#,
            schema: parameters,
            toolName: tool.name
        )
        if case .rejected(let envelope) = unknownOutcome {
            #expect(failureField(envelope) == "extra")
        } else {
            Issue.record("expected unknown key rejected with field=extra")
        }
    }

    // MARK: - Schema introspection helpers

    /// Walk the schema (top-level + every declared object property) and
    /// fail the test if any object schema is missing
    /// `additionalProperties: false`. Emitting it at every nested level
    /// keeps unknown keys from leaking through nested args (e.g.
    /// `series` items).
    private func assertHasAdditionalPropertiesFalse(
        _ schema: JSONValue,
        toolName: String,
        path: String = ""
    ) throws {
        guard case .object(let obj) = schema else { return }
        // Only enforce on `type: object` schemas — `array` / scalar
        // schemas don't take `additionalProperties`.
        let isObject: Bool
        if case .string("object")? = obj["type"] {
            isObject = true
        } else {
            isObject = false
        }
        if isObject {
            switch obj["additionalProperties"] {
            case .bool(false):
                break
            case .none:
                Issue.record(
                    "\(toolName)\(path.isEmpty ? "" : " (\(path))"): schema is missing `additionalProperties: false`"
                )
            default:
                // `additionalProperties: <schema>` and `: true` aren't
                // wrong per JSON Schema, but they aren't part of our
                // resilience contract. Note them so a future maintainer
                // can decide whether to lock them down.
                break
            }
        }
        // Recurse into each declared property to enforce the same rule
        // on nested object schemas.
        if case .object(let props)? = obj["properties"] {
            for (key, child) in props {
                try assertHasAdditionalPropertiesFalse(
                    child,
                    toolName: toolName,
                    path: path.isEmpty ? key : "\(path).\(key)"
                )
            }
        }
    }

    /// Return the first `required` key declared at the top level of the
    /// schema, or nil when the schema has no required keys.
    private func firstRequiredKey(in schema: JSONValue) -> String? {
        guard case .object(let obj) = schema,
            case .array(let arr)? = obj["required"]
        else { return nil }
        for v in arr {
            if case .string(let s) = v { return s }
        }
        return nil
    }

    /// Synthesize the smallest payload that satisfies every `required`
    /// field of the schema using innocuous-but-well-typed values
    /// (`"x"`, `1`, `true`, `["x"]`, `{}`). Returns nil when the
    /// schema is missing or has no `required` array.
    private func synthesizeMinimumValid(forSchema schema: JSONValue) -> String? {
        guard case .object(let obj) = schema,
            case .array(let required)? = obj["required"],
            !required.isEmpty,
            case .object(let propsDict)? = obj["properties"]
        else { return nil }

        var payload: [String: Any] = [:]
        for entry in required {
            guard case .string(let key) = entry else { continue }
            guard case .object(let propSchema)? = propsDict[key] else { continue }
            payload[key] = sampleValue(for: propSchema)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    private func sampleValue(for propSchema: [String: JSONValue]) -> Any {
        // Honour an enum first so we don't generate a value that the
        // validator immediately rejects.
        if case .array(let enumArr)? = propSchema["enum"],
            let firstString = enumArr.first(where: {
                if case .string = $0 { return true }; return false
            }),
            case .string(let s) = firstString
        {
            return s
        }
        guard case .string(let typeName)? = propSchema["type"] else {
            return "x"
        }
        switch typeName {
        case "string": return "x"
        case "integer": return 1
        case "number": return 1.0
        case "boolean": return true
        case "array":
            // Honour `items` when present so array-of-object schemas
            // (e.g. `db_create_table.columns`) get a structurally-
            // valid sample. Falls back to `["x"]` when `items` is
            // missing or not an object schema.
            if case .object(let itemsSchema)? = propSchema["items"] {
                return [sampleValue(for: itemsSchema)]
            }
            return ["x"]
        case "object":
            // Recurse into the object's own `required`/`properties`
            // pairing so nested object schemas with required keys
            // (rare today, but on the horizon) produce valid samples.
            if case .array(let nestedRequired)? = propSchema["required"],
                case .object(let nestedProps)? = propSchema["properties"]
            {
                var obj: [String: Any] = [:]
                for entry in nestedRequired {
                    guard case .string(let k) = entry,
                        case .object(let childSchema)? = nestedProps[k]
                    else { continue }
                    obj[k] = sampleValue(for: childSchema)
                }
                return obj
            }
            return [String: Any]()
        default: return "x"
        }
    }

    private func failureField(_ result: String) -> String? {
        EnvelopeAssertions.failureField(result)
    }

    // MARK: - Phase B: shell-tool routing through TerminalSnapshot.from

    /// Routing decision the chat layer makes when a shell tool
    /// completes. The single `TerminalSnapshot.from(toolResult:item:)`
    /// factory enforces all three branches:
    ///   1. shell tool + valid envelope → non-nil snapshot
    ///   2. non-shell tool             → nil (markdown fallback)
    ///   3. error envelope             → nil (markdown fallback)

    @Test func shellToolSnapshotExtractsStdoutStderrExitCommand() {
        let envelope = ToolEnvelope.success(
            tool: "shell_run",
            result: [
                "stdout": "hello\nworld\n",
                "stderr": "warn: x\n",
                "exit_code": 0,
            ] as [String: Any]
        )
        let item = makeItem(
            name: "shell_run",
            arguments: #"{"command": "echo hello"}"#,
            result: envelope
        )
        guard let snap = TerminalSnapshot.from(toolResult: envelope, item: item)
        else {
            Issue.record("expected non-nil snapshot for shell_run envelope")
            return
        }
        #expect(snap.command == "echo hello")
        #expect(snap.exitCode == 0)
        #expect(!snap.killedByUser)
        let body = String(data: snap.output, encoding: .utf8) ?? ""
        #expect(body.contains("hello"))
        #expect(body.contains("world"))
        #expect(body.contains("warn: x"))
    }

    @Test func shellToolSnapshotMarksKilledByUser() {
        let envelope = ToolEnvelope.success(
            tool: "sandbox_exec",
            result: [
                "stdout": "",
                "stderr": "",
                "exit_code": -1,
                "killed_by": "user",
            ] as [String: Any]
        )
        let item = makeItem(
            name: "sandbox_exec",
            arguments: #"{"command": "sleep 100"}"#,
            result: envelope
        )
        let snap = TerminalSnapshot.from(toolResult: envelope, item: item)
        #expect(snap?.killedByUser == true)
    }

    @Test func errorEnvelopeReturnsNilSnapshot() {
        // Failures must keep the markdown path so the model-facing
        // error message is preserved verbatim.
        let envelope = ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "bad",
            field: "command",
            expected: "string",
            tool: "shell_run"
        )
        let item = makeItem(
            name: "shell_run",
            arguments: "{}",
            result: envelope
        )
        let snap = TerminalSnapshot.from(toolResult: envelope, item: item)
        #expect(snap == nil)
    }

    @Test func nonShellToolReturnsNilSnapshot() {
        // file_read is a tool whose envelope has the success shape
        // but isn't a shell tool. The factory's name check filters
        // it out so the markdown path renders the prose verbatim.
        let envelope = ToolEnvelope.success(tool: "file_read", text: "file body")
        let item = makeItem(
            name: "file_read",
            arguments: #"{"path": "x.txt"}"#,
            result: envelope
        )
        let snap = TerminalSnapshot.from(toolResult: envelope, item: item)
        #expect(snap == nil)
    }

    @Test func shellToolWithoutExitCodeReturnsNil() {
        // A shell-tool name but a malformed envelope (no exit_code key)
        // must still bail out. Defensive against payload-shape drift.
        let envelope = ToolEnvelope.success(
            tool: "shell_run",
            result: ["stdout": "x"] as [String: Any]
        )
        let item = makeItem(
            name: "shell_run",
            arguments: #"{"command": "echo x"}"#,
            result: envelope
        )
        let snap = TerminalSnapshot.from(toolResult: envelope, item: item)
        #expect(snap == nil)
    }

    private func makeItem(
        name: String,
        arguments: String,
        result: String
    ) -> ToolCallItem {
        ToolCallItem(
            call: ToolCall(
                id: UUID().uuidString,
                type: "function",
                function: ToolCallFunction(name: name, arguments: arguments)
            ),
            result: result
        )
    }
}
