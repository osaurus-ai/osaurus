//
//  WorkflowModelTests.swift
//  OsaurusCoreTests
//
//  The workflow payload: JSON shape and defaults, binding resolution,
//  schema validation with paths, graph validation, and requirement
//  derivation from the nodes.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowDefinitionCodingTests {

    @Test
    func templateRoundTripsWithHashAndKind() throws {
        let template = WF.template(WF.intake())
        #expect(template.kind == .workflow)
        #expect(template.hashIsValid)
        let parsed = try Template.parse(try template.jsonString())
        #expect(parsed.id == template.id)
        #expect(parsed.payload == template.payload)
        #expect(parsed.contentHash == template.contentHash)
        #expect(parsed.workflow?.nodes.map(\.id) == ["classify", "onboard", "lookup", "notify"])
    }

    @Test
    func dialogNodesDefaultToALongTimeout_othersToTwoMinutes() throws {
        let json = """
            {"id": "ask", "kind": "dialog", "dialog": {"title": "Client", "fields": [{"key": "email"}]}}
            """
        let dialog = try JSONDecoder().decode(WorkflowNode.self, from: Data(json.utf8))
        #expect(dialog.timeout == WorkflowNode.defaultDialogTimeout)
        let code = try JSONDecoder().decode(
            WorkflowNode.self,
            from: Data(#"{"id": "c", "kind": "code", "code": {"source": "async function run(i){}"}}"#.utf8))
        #expect(code.timeout == WorkflowNode.defaultTimeout)
    }

    @Test
    func unknownKindAndMode_areRejected() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WorkflowNode.self, from: Data(#"{"id": "x", "kind": "python"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                InferenceSpec.self, from: Data(#"{"model_slot": "a", "mode": "vibes"}"#.utf8))
        }
    }

    @Test
    func invalidWorkflowTemplate_failsToParse() throws {
        var def = WF.intake()
        def.edges.append(WorkflowEdge(from: "notify", to: "classify"))
        let json = try WF.template(def).jsonString()
        #expect(throws: TemplateError.self) { _ = try Template.parse(json) }
    }

    /// A graph of the original four step kinds with plain edges stays at
    /// format 1 so builds that predate format 2 keep importing it.
    @Test
    func templateWithOnlyFormatOneFeatures_staysFormatOne() throws {
        let template = WF.template(WF.intake())
        #expect(!WF.intake().usesPostV1Features)
        #expect(template.formatVersion == 1)
        let json = try template.jsonString()
        #expect(json.contains("\"format_version\" : 1"))
        #expect(try Template.parse(json).formatVersion == 1)
    }

    /// Each post-v1 feature on its own moves the template to format 2,
    /// and a build that only knows format 1 refuses it with the
    /// "update Osaurus" error instead of a parse failure.
    @Test
    func templateUsingFormatTwoFeatures_isWrittenAsFormatTwo() throws {
        var variants: [(String, WorkflowDefinition)] = []
        var http = WF.intake()
        http.nodes.append(
            WorkflowNode(
                id: "fetch", name: "Fetch", kind: .http(HTTPSpec(method: "GET", url: "https://api.example.com/x")),
                input: .object([:])))
        http.edges.append(WorkflowEdge(from: "notify", to: "fetch"))
        variants.append(("http step", http))
        var python = WF.intake()
        python.nodes[1].kind = .code(CodeSpec(language: .python, source: "def run(input, ctx):\n    return {}"))
        variants.append(("python step", python))
        var onError = WF.intake()
        onError.nodes[2].onError = .skip
        variants.append(("on_error", onError))
        var join = WF.intake()
        join.nodes[3].join = .all
        variants.append(("join", join))
        var errorEdge = WF.intake()
        errorEdge.nodes[1].onError = .continue
        errorEdge.edges[2] = WorkflowEdge(from: "onboard", to: "notify", on: .always)
        variants.append(("edge on", errorEdge))
        var op = WF.intake()
        op.edges[0] = WorkflowEdge(
            from: "classify", to: "onboard", when: WorkflowCondition(path: "choice", op: .contains, value: .string("new")))
        variants.append(("condition op", op))
        var group = WF.intake()
        group.edges[0] = WorkflowEdge(
            from: "classify", to: "onboard",
            when: .all([WorkflowCondition(path: "choice", value: .string("new"))]))
        variants.append(("condition group", group))

        for (label, def) in variants {
            #expect(def.usesPostV1Features, "\(label)")
            let template = WF.template(def)
            #expect(template.formatVersion == 2, "\(label)")
            let json = try template.jsonString()
            #expect(json.contains("\"format_version\" : 2"), "\(label)")
            #expect(try Template.parse(json).formatVersion == 2, "\(label)")
        }
    }

    @Test
    func sealingRecomputesTheFormatVersion_fromThePayload() {
        var template = WF.template(WF.intake())
        #expect(template.formatVersion == 1)
        var def = template.workflow!
        def.nodes[0].onError = .continue
        template.payload = .workflow(def)
        #expect(template.sealed().formatVersion == 2)
        // An agent template that bundles a format-2 workflow needs format 2 too.
        let agent = Template(
            name: "Agent", payload: .agent(AgentTemplatePayload(agent: AgentEntry(name: "A"), actions: nil, workflows: [])),
            bundled: [template.sealed()])
        #expect(agent.formatVersion == 2)
    }

    @Test
    func templateNewerThanThisBuild_isRefusedWithTheUpdateError() throws {
        var json = try WF.template(WF.intake()).jsonString()
        json = json.replacingOccurrences(of: "\"format_version\" : 1", with: "\"format_version\" : 6")
        #expect(throws: TemplateError.unsupportedVersion(6)) { _ = try Template.parse(json) }
    }

    /// Format 2 shipped without media steps and bypass, so a template using
    /// them is format 3: a format-2 build then shows "update Osaurus"
    /// instead of failing on an unknown step kind.
    @Test
    func templateUsingMediaOrBypass_isWrittenAsFormatThree() throws {
        var variants: [(String, WorkflowDefinition)] = []
        var media = WF.intake()
        media.nodes.append(WorkflowNode(id: "art", name: "Art", kind: .media(MediaSpec(prompt: "a fox"))))
        variants.append(("media step", media))
        var bypass = WF.intake()
        bypass.nodes[1].mode = .bypass
        variants.append(("bypassed step", bypass))
        var sweep = WF.intake()
        sweep.nodes.append(
            WorkflowNode(
                id: "sweep", name: "Sweep",
                kind: .map(
                    MapSpec(
                        items: "{{input.styles}}",
                        step: .object(["kind": .string("media"), "media": .object(["prompt": .string("{{item}}")])])))))
        variants.append(("media map body", sweep))

        for (label, def) in variants {
            #expect(def.usesFormat3Features, "\(label)")
            let template = WF.template(def)
            #expect(template.formatVersion == 3, "\(label)")
            let json = try template.jsonString()
            #expect(json.contains("\"format_version\" : 3"), "\(label)")
            #expect(try Template.parse(json).formatVersion == 3, "\(label)")
        }
        var plainMap = WF.intake()
        plainMap.nodes.append(
            WorkflowNode(
                id: "each", name: "Each",
                kind: .map(MapSpec(items: "{{input.list}}", step: .object(["kind": .string("wait")])))))
        #expect(WF.template(plainMap).formatVersion == 2)

        let agent = Template(
            name: "Agent", payload: .agent(AgentTemplatePayload(agent: AgentEntry(name: "A"), actions: nil, workflows: [])),
            bundled: [WF.template(media).sealed()])
        #expect(agent.formatVersion == 3)
    }

    @Test
    func decideSchema_isTheOptionEnum() {
        let schema = InferenceSpec.decideSchema(options: ["a", "b"])
        #expect(JSONSchemaValidator.validate(.object(["choice": .string("a")]), against: schema).isEmpty)
        #expect(!JSONSchemaValidator.validate(.object(["choice": .string("c")]), against: schema).isEmpty)
    }
}

struct BindingRendererTests {
    let ctx = BindingContext(
        input: .object(["client": .string("Acme"), "count": .number(3)]),
        outputs: [
            "classify": .object(["choice": .string("new"), "score": .number(0.5)]),
            "lookup": .null,
        ])

    @Test
    func singleReference_staysTyped() {
        #expect(BindingRenderer.renderValue("{{input.count}}", in: ctx) == .number(3))
        #expect(BindingRenderer.renderValue(" {{ nodes.classify.output }} ", in: ctx)
            == .object(["choice": .string("new"), "score": .number(0.5)]))
    }

    @Test
    func mixedText_interpolates() {
        #expect(
            BindingRenderer.renderValue("{{input.client}} is {{nodes.classify.output.choice}} ({{input.count}})", in: ctx)
                == .string("Acme is new (3)"))
    }

    @Test
    func skippedNodeAndMissingPath_bindAsNull() {
        #expect(BindingRenderer.renderValue("{{nodes.lookup.output.id}}", in: ctx) == .null)
        #expect(BindingRenderer.renderValue("{{nodes.never.output}}", in: ctx) == .null)
        #expect(BindingRenderer.renderText("id={{nodes.lookup.output.id}}", in: ctx) == "id=")
    }

    @Test
    func readableText_laysOutObjectsForPeople() {
        let plan: JSONValue = .object([
            "outline": .array([
                .object([
                    "heading": .string("More Than Repairs"),
                    "key_points": .array([.string("Neighbors meet"), .string("Skills spread")]),
                ]),
                .object(["heading": .string("Safety First"), "key_points": .array([])]),
            ]),
            "angle": .string("Community, not just fixing."),
            "notes": .null,
        ])
        let ctx = BindingContext(input: .object([:]), outputs: ["plan": plan])
        let text = BindingRenderer.renderReadableText("Proposed plan:\n\n{{nodes.plan.output}}", in: ctx)
        #expect(
            text == """
                Proposed plan:

                Angle
                Community, not just fixing.

                Outline
                • More Than Repairs
                  Key points
                    – Neighbors meet
                    – Skills spread
                • Safety First
                """)
        #expect(BindingRenderer.renderText("{{nodes.plan.output.angle}}", in: ctx) == "Community, not just fixing.")
        #expect(BindingRenderer.renderReadableText("{{input.missing}}x", in: ctx) == "x")
    }

    @Test
    func readableText_bulletsListsAndUntitledObjects() {
        let ctx = BindingContext(
            input: .object([
                "tags": .array([.string("a"), .string("b")]),
                "rows": .array([.object(["qty": .number(2), "sku": .string("X1")])]),
            ]))
        #expect(BindingRenderer.renderReadableText("{{input.tags}}", in: ctx) == "• a\n• b")
        #expect(BindingRenderer.renderReadableText("{{input.rows}}", in: ctx) == "• Qty: 2\n  Sku: X1")
    }

    @Test
    func objectBinding_assemblesNamedValues() {
        let value = BindingRenderer.render(.object(["who": "{{input.client}}", "n": "{{input.count}}"]), in: ctx)
        #expect(value == .object(["who": .string("Acme"), "n": .number(3)]))
    }

    @Test
    func objectBinding_passesLiteralsWithTheirType() throws {
        let binding = try JSONDecoder().decode(
            WorkflowBinding.self,
            from: Data(#"{"path": "{{input.client}}.md", "overwrite": true, "timeout": 25, "tag": null}"#.utf8))
        #expect(binding.references == ["input.client"])
        #expect(
            BindingRenderer.render(binding, in: ctx)
                == .object(["path": .string("Acme.md"), "overwrite": .bool(true), "timeout": .number(25), "tag": .null]))
        let strings = try JSONDecoder().decode(WorkflowBinding.self, from: Data(#"{"who": "{{input.client}}"}"#.utf8))
        #expect(strings == .object(["who": "{{input.client}}"]))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WorkflowBinding.self, from: Data(#"{"rows": [1, 2]}"#.utf8))
        }
    }

    @Test
    func referenceParsing() {
        #expect(BindingRenderer.parse(reference: "input") == .input(path: ""))
        #expect(BindingRenderer.parse(reference: "nodes.a.output.x.y") == .node(id: "a", path: "x.y"))
        #expect(BindingRenderer.parse(reference: "nodes.a.input") == nil)
        #expect(BindingRenderer.parse(reference: "secrets.KEY") == nil)
    }
}

struct JSONSchemaValidatorTests {

    @Test
    func nestedObjectsArraysEnumsAndRequired_reportPaths() {
        let schema = WF.object(
            [
                "client": WF.object(["email": WF.string, "tier": .object(["enum": .array([.string("a"), .string("b")])])], required: ["email"]),
                "tags": .object(["type": .string("array"), "items": WF.string]),
            ], required: ["client"])
        let bad: JSONValue = .object([
            "client": .object(["tier": .string("z")]),
            "tags": .array([.string("ok"), .number(1)]),
        ])
        let issues = JSONSchemaValidator.validate(bad, against: schema)
        let paths = Set(issues.map(\.path))
        #expect(paths.contains("$.client.email"))
        #expect(paths.contains("$.client.tier"))
        #expect(paths.contains("$.tags[1]"))
        #expect(JSONSchemaValidator.validate(.object([:]), against: schema).map(\.path) == ["$.client"])
    }

    @Test
    func nullAndTypeUnions() {
        let schema: JSONValue = .object(["type": .array([.string("string"), .string("null")])])
        #expect(JSONSchemaValidator.validate(.null, against: schema).isEmpty)
        #expect(JSONSchemaValidator.validate(.string("x"), against: schema).isEmpty)
        #expect(!JSONSchemaValidator.validate(.number(1), against: schema).isEmpty)
    }

    @Test
    func malformedSchemas_areReported() {
        #expect(!JSONSchemaValidator.schemaIssues(.object(["type": .string("strnig")])).isEmpty)
        #expect(!JSONSchemaValidator.schemaIssues(.object(["type": .string("object"), "properties": .array([])])).isEmpty)
        #expect(JSONSchemaValidator.schemaIssues(WF.object(["a": WF.string])).isEmpty)
    }
}

struct WorkflowValidatorTests {

    @Test
    func intakeIsClean() {
        #expect(WorkflowValidator.validate(WF.intake(), allowPlaceholders: false).isEmpty)
        #expect(WorkflowValidator.topologicalOrder(WF.intake()) == ["classify", "onboard", "lookup", "notify"])
    }

    @Test
    func cycle_isRejected() {
        var def = WF.intake()
        def.edges.append(WorkflowEdge(from: "notify", to: "classify"))
        #expect(WorkflowValidator.topologicalOrder(def) == nil)
        #expect(WorkflowValidator.validate(def, allowPlaceholders: false).contains { $0.message.contains("cycle") })
    }

    /// Review #17: the validator's bound is the executor's ceiling, so a
    /// value the executor would clamp is refused with the real limit.
    @Test
    func agenticMaxSteps_isBoundedByTheExecutorCeiling() {
        func issues(maxSteps: Int) -> [WorkflowIssue] {
            var def = WF.intake()
            def.nodes.append(
                WorkflowNode(
                    id: "research", name: "Research",
                    kind: .inference(
                        InferenceSpec(
                            modelSlot: "decision", instructions: "Look up {{input.client}}",
                            mode: .agentic(tools: [ToolRef(name: "web_search")], maxSteps: maxSteps))),
                    input: .object([:]), outputSchema: WF.object(["notes": WF.string])))
            return WorkflowValidator.validate(def, allowPlaceholders: false).filter { $0.message.contains("max_steps") }
        }
        #expect(issues(maxSteps: AgenticNodeExecutor.stepCeiling).isEmpty)
        #expect(issues(maxSteps: 1).isEmpty)
        let over = issues(maxSteps: AgenticNodeExecutor.stepCeiling + 1)
        #expect(over.count == 1)
        #expect(over.first?.message.contains("between 1 and \(AgenticNodeExecutor.stepCeiling)") == true)
        #expect(!issues(maxSteps: 0).isEmpty)
    }

    @Test
    func bindingToANonUpstreamNode_isRejected() {
        var def = WF.intake()
        def.nodes[2] = WF.code("lookup", input: .object(["w": "{{nodes.onboard.output.welcome}}"]))
        let issues = WorkflowValidator.validate(def, allowPlaceholders: false)
        #expect(issues.contains { $0.nodeID == "lookup" && $0.message.contains("not upstream") })
    }

    @Test
    func decideBranchOnUnknownOption_isRejected() {
        var def = WF.intake()
        def.edges[0].when = WorkflowCondition(path: "choice", value: .string("maybe"))
        #expect(WorkflowValidator.validate(def, allowPlaceholders: false).contains { $0.message.contains("maybe") })
    }

    @Test
    func duplicateIdsUnknownEdgesAndBadHosts() {
        var def = WF.intake()
        def.nodes.append(WF.code("notify"))
        def.edges.append(WorkflowEdge(from: "ghost", to: "notify"))
        def.nodes[1] = WorkflowNode(
            id: "onboard", name: "Onboard",
            kind: .code(CodeSpec(source: "async function run(i){}", network: ["https://api.example.com/v1"])))
        let messages = WorkflowValidator.validate(def, allowPlaceholders: false).map(\.message)
        #expect(messages.contains { $0.contains("duplicate node id") })
        #expect(messages.contains { $0.contains("unknown node `ghost`") })
        #expect(messages.contains { $0.contains("bare host name") })
    }

    @Test
    func agenticNodesCannotListWorkflowTools() {
        var def = WF.intake()
        func agentic(_ tools: [String]) -> WorkflowNode {
            WorkflowNode(
                id: "research", name: "Research",
                kind: .inference(
                    InferenceSpec(
                        modelSlot: "drafting", instructions: "Look it up",
                        mode: .agentic(tools: tools.map { ToolRef(name: $0) }, maxSteps: 3))),
                outputSchema: WF.object(["summary": WF.string]))
        }
        def.nodes.append(agentic(["crm_search"]))
        #expect(WorkflowValidator.validate(def, allowPlaceholders: false).isEmpty)

        def.nodes[def.nodes.count - 1] = agentic(["crm_search", "workflow_intake", "run_workflow", "architect_handoff"])
        let messages = WorkflowValidator.validate(def, allowPlaceholders: false).map(\.message)
        #expect(messages.filter { $0.contains("is a workflow tool") }.count == 3)
        #expect(!messages.contains { $0.contains("crm_search") })
    }

    @Test
    func placeholders_allowedInDraftsOnly() {
        var def = WF.intake()
        def.nodes.append(WorkflowNode(id: "later", name: "Later", intent: "Email the client", kind: nil))
        #expect(WorkflowValidator.validate(def, allowPlaceholders: true).isEmpty)
        #expect(!WorkflowValidator.validate(def, allowPlaceholders: false).isEmpty)
    }
}

struct WorkflowRequirementsDeriverTests {

    @Test
    func requirementsFollowTheNodes() {
        var def = WF.intake()
        def.nodes[1] = WorkflowNode(
            id: "onboard", name: "Onboard",
            kind: .code(
                CodeSpec(
                    source: "async function run(i, ctx){}", network: ["API.Clio.com"], secrets: ["CLIO_API_KEY"])),
            input: .object([:]), outputSchema: WF.object(["welcome": WF.string]))
        def.nodes.append(
            WorkflowNode(
                id: "research", name: "Research",
                kind: .inference(
                    InferenceSpec(
                        modelSlot: "drafting", instructions: "Look it up",
                        mode: .agentic(
                            tools: [ToolRef(name: "search", server: "Linear"), ToolRef(name: "x", plugin: "osaurus.web")],
                            maxSteps: 4)))))
        def.modelSlots = [ModelRequirement(slot: "decision", preferred: "anthropic/sonnet-5", locality: .cloudAllowed)]
        def.secrets = [SecretRequirement(key: "CLIO_API_KEY", label: "Clio API key")]

        let reqs = WorkflowRequirementsDeriver.derive(def)
        #expect(reqs.models.map(\.slot) == ["decision", "drafting"])
        #expect(reqs.models.first?.preferred == "anthropic/sonnet-5")
        #expect(reqs.models.last?.needsToolUse == true)
        #expect(reqs.secrets.map(\.label) == ["Clio API key"])
        #expect(reqs.network == ["api.clio.com"])
        #expect(reqs.mcpServers == ["Linear"])
        #expect(reqs.plugins == ["osaurus.web"])
    }

    @Test
    func declarationsAloneAddNothing() {
        var def = WF.intake()
        def.modelSlots.append(ModelRequirement(slot: "unused"))
        def.secrets.append(SecretRequirement(key: "UNUSED"))
        let reqs = WorkflowRequirementsDeriver.derive(def)
        #expect(!reqs.models.contains { $0.slot == "unused" })
        #expect(reqs.secrets.isEmpty)
    }

    @Test
    func templateRequirementsAreAlwaysDerived() throws {
        var template = WF.template(WF.intake())
        template.requirements = TemplateRequirements()
        let reparsed = try Template.parse(try template.jsonString())
        #expect(reparsed.requirements.models.map(\.slot) == ["decision"])
    }
}
