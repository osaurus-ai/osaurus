//
//  ToolOutputSchemaCoverageTests.swift
//  OsaurusCoreTests
//
//  Every built-in a workflow step may call publishes an output schema, so
//  the Architect binds the fields the tool really returns instead of
//  guessing. Plugin and MCP tools publish their own.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct ToolOutputSchemaCoverageTests {

    @Test
    func everyBuiltinWorkflowToolPublishesAnOutputSchema() async throws {
        // The sandbox suites share the registry's sandbox tools; hold their
        // lock so registering and removing them here cannot race a test.
        let schemas: [String: JSONValue?] = await SandboxTestLock.shared.run {
            let registry = ToolRegistry.shared
            ConfigurationDomainBootstrap.registerBuiltIns()
            BuiltinSandboxTools.register(
                agentId: UUID().uuidString, agentName: "schema-coverage",
                config: AutonomousExecConfig(enabled: true, maxCommandsPerTurn: 100, pluginCreate: true))
            defer { registry.unregisterAllBuiltinSandboxTools() }
            let builtins = WorkflowToolCatalog.entries().filter { $0.group == nil }
            return Dictionary(builtins.map { ($0.name, $0.outputSchema) }, uniquingKeysWith: { first, _ in first })
        }
        #expect(schemas.keys.contains("sandbox_exec"), "sandbox tools are in the catalog")
        #expect(schemas.keys.contains("osaurus_config"), "configurator tools are in the catalog")
        let missing = schemas.filter { $0.value == nil }.keys.sorted()
        #expect(missing.isEmpty, "no output schema: \(missing.joined(separator: ", "))")

        for (name, schema) in schemas {
            guard let schema else { continue }
            #expect(schema.objectValue?["type"]?.stringValue == "object", "\(name): result is an object")
            #expect(
                schema.value(atPath: "additionalProperties") != .bool(false),
                "\(name): an output schema must not forbid fields a result adds")
        }
    }

    @Test
    func appleSchemaTableMatchesTheAppleToolNames() {
        let declared = AppleApp.allCases.reduce(into: Set<String>()) { $0.formUnion($1.toolNames) }
        #expect(Set(AppleToolOutputSchemas.byTool.keys) == declared)
    }
}
