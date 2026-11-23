//
//  BundledTeamReferenceTests.swift
//  OsaurusCoreTests
//
//  Every bundled workflow and prepared ask names its teammate by the fixed
//  template UUID, never by name, so a renamed teammate keeps working and a
//  person's own agent that takes the old name never inherits the step.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Bundled teammate references")
@MainActor
struct BundledTeamReferenceTests {

    /// Every workflow file in `Resources/Team`, read from the source tree so
    /// a new file is checked without being added to a list here.
    static func bundledWorkflowResources() throws -> [(name: String, template: Template)] {
        let team = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Team", isDirectory: true)
        let urls = try FileManager.default.contentsOfDirectory(at: team, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try Set(urls.map { $0.deletingPathExtension().lastPathComponent })
            .filter { $0.hasPrefix("default-workflow-") || $0.hasPrefix("prepared-") }
            .sorted()
            .map { name in (name, try #require(TeamSeeder.loadBundled(name), "\(name)")) }
    }

    /// Tool steps, including the body of a `map` step (Research Brief reads
    /// each page in one).
    static func toolSteps(_ template: Template) -> [(node: WorkflowNode, spec: ToolNodeSpec)] {
        func steps(_ node: WorkflowNode) -> [(node: WorkflowNode, spec: ToolNodeSpec)] {
            switch node.kind {
            case .tool(let spec): return [(node, spec)]
            case .map(let spec): return steps(spec.body(parentID: node.id))
            default: return []
            }
        }
        return (template.workflow?.nodes ?? []).flatMap(steps)
    }

    @Test
    func everyBundledToolStep_namesAKnownTeammateByUUID_thatHasTheApp() throws {
        let resources = try Self.bundledWorkflowResources()
        let catalogued =
            TeamSeeder.defaultWorkflowResourceNames + PreparedAskCatalog.resourceNames
            + PreparedAskCatalog.writeResourceNames
        #expect(Set(resources.map(\.name)) == Set(catalogued), "every bundled workflow file is installed or prepared")
        for (name, template) in resources {
            let steps = Self.toolSteps(template)
            #expect(!steps.isEmpty, "\(name)")
            for (node, spec) in steps {
                let reference = try #require(spec.tool.agent, "\(name)/\(node.id) names no teammate")
                let teammate = try #require(
                    UUID(uuidString: reference).flatMap(Teammate.teammate(forTemplateID:)),
                    "\(name)/\(node.id): \(reference) is not a teammate UUID"
                )
                if let app = AppleApp.app(forTool: spec.tool.name) {
                    let apps = try #require(TeamSeeder.template(for: teammate)).agent.capabilities?.appleApps ?? []
                    #expect(apps.contains(app.rawValue), "\(name): \(teammate) lacks \(app)")
                }
            }
        }
    }

    private actor Calls {
        var agents: [UUID?] = []
        func record(_ id: UUID?) { agents.append(id) }
    }

    /// Each teammate renamed, and an agent of the person's own holding each
    /// teammate's old name: every step still runs as the teammate.
    @Test
    func afterARename_everyBundledStep_stillRunsAsItsTeammate() async throws {
        var agents: [Agent] = []
        var teammateIds: [Teammate: UUID] = [:]
        for teammate in Teammate.allCases {
            var renamed = Agent(name: "My \(teammate.rawValue)", systemPrompt: "")
            renamed.sourceTemplateID = teammate.templateID
            teammateIds[teammate] = renamed.id
            agents.append(renamed)
            agents.append(Agent(name: teammate.rawValue.capitalized, systemPrompt: "Someone else's"))
        }
        let roster = agents
        let calls = Calls()
        let runtime = ToolNodeExecutor.Runtime(
            resolve: { name in
                ToolNodeExecutor.Resolved(
                    spec: Tool(
                        type: "function",
                        function: ToolFunction(name: name, description: name, parameters: nil)
                    ),
                    outputSchema: nil
                )
            },
            execute: { name, _, _ in
                await calls.record(ChatExecutionContext.currentAgentId)
                return ToolEnvelope.success(tool: name, result: ["ok": true])
            },
            resolveAgent: { reference in
                WorkflowStepAgent.resolve(reference, in: roster).map {
                    WorkflowStepAgent.Match(id: $0.id, name: $0.name, enabledAppleApps: Set(AppleApp.allCases))
                }
            }
        )

        var expected: [UUID?] = []
        for (name, template) in try Self.bundledWorkflowResources() {
            for (node, spec) in Self.toolSteps(template) {
                let teammate = try #require(
                    spec.tool.agent.flatMap(UUID.init(uuidString:)).flatMap(Teammate.teammate(forTemplateID:)),
                    "\(name)"
                )
                expected.append(teammateIds[teammate])
                let context = WorkflowNodeContext(
                    runID: UUID(),
                    workflowID: template.id,
                    workflowName: template.name,
                    node: node,
                    input: .object([:]),
                    bindings: BindingContext(input: .object([:])),
                    model: nil,
                    secretAccounts: [:],
                    caller: WorkflowCaller(kind: .user),
                    workspace: WF.tempDir(),
                    attempt: 1,
                    timeout: 60
                )
                let outcome = try await ToolNodeExecutor.run(spec: spec, context: context, runtime: runtime)
                #expect(outcome.output.objectValue?["ok"] == .bool(true), "\(name)/\(node.id)")
            }
        }
        #expect(!expected.isEmpty)
        #expect(await calls.agents == expected)
    }
}
