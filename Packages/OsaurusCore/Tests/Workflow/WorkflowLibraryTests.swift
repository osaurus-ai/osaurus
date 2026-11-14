//
//  WorkflowLibraryTests.swift
//  OsaurusCoreTests
//
//  The Workflows library: version diffs, what an update asks about, which
//  wizard steps each mode shows, parked setup routing, and workflow tabs
//  (open, reuse, layout v2 round trip, restore).
//

import Foundation
import Testing

@testable import OsaurusCore

struct TemplateDiffTests {

    private func requirements(
        models: [ModelRequirement] = [], secrets: [String] = [], mcp: [String] = [], plugins: [String] = [],
        permissions: [String] = [], network: [String] = []
    ) -> TemplateRequirements {
        TemplateRequirements(
            models: models, secrets: secrets.map { SecretRequirement(key: $0) }, mcpServers: mcp, plugins: plugins,
            permissions: permissions, network: network)
    }

    @Test
    func newRequirementsListOnlyWhatTheOldVersionDidNotAskFor() {
        let old = requirements(
            models: [ModelRequirement(slot: "decision"), ModelRequirement(slot: "writer")],
            secrets: ["CLIO_KEY"], mcp: ["clio"], plugins: ["mail"], network: ["api.clio.com"])
        let new = requirements(
            models: [
                ModelRequirement(slot: "decision"),
                ModelRequirement(slot: "writer", strictness: .always),
                ModelRequirement(slot: "summary"),
            ],
            secrets: ["CLIO_KEY", "SLACK_TOKEN"], mcp: ["clio", "drive"], plugins: [],
            permissions: ["calendar"], network: ["api.clio.com", "slack.com"])

        let diff = TemplateDiff.newRequirements(from: old, to: new)
        #expect(diff.slots == ["writer", "summary"])
        #expect(diff.secrets == ["SLACK_TOKEN"])
        #expect(diff.mcpServers == ["drive"])
        #expect(diff.plugins.isEmpty, "a removed plugin is not asked about")
        #expect(diff.permissions == ["calendar"])
        #expect(diff.network == ["slack.com"])
        #expect(!diff.isEmpty)
        #expect(TemplateDiff.newRequirements(from: old, to: old).isEmpty)
    }

    @Test
    func newRequirementsMatchSetupItemsByKindAndValue() {
        var diff = TemplateDiff.NewRequirements()
        diff.secrets = ["SLACK_TOKEN"]
        diff.slots = ["summary"]
        let item = { (kind: TemplateRequirement.Kind, value: String) in
            SetupItem(kind: kind, severity: .blocking, title: value, detail: "", value: value)
        }
        #expect(diff.contains(item(.secret, "SLACK_TOKEN")))
        #expect(!diff.contains(item(.secret, "CLIO_KEY")))
        #expect(diff.contains(item(.model, "summary")))
        #expect(!diff.contains(item(.model, "decision")))
        #expect(!diff.contains(item(.mcpServer, "clio")))
    }

    @Test
    func changesCoverIdentityGraphAndRequirements() {
        let v1 = WF.template(WF.intake())
        var def = WF.intake()
        def.nodes.append(WF.code("archive"))
        var v2 = Template(id: v1.id, version: 2, name: "Client Intake v2", summary: v1.summary, payload: .workflow(def))
        v2.requirements.secrets.append(SecretRequirement(key: "ARCHIVE_KEY"))

        let changes = TemplateDiff.changes(from: v1, to: v2)
        #expect(changes.contains { $0.subject == "name" && $0.kind == .changed })
        #expect(changes.contains { $0.kind == .added && $0.subject.contains("archive") })
        #expect(changes.contains { $0.kind == .added && $0.subject == "secret ARCHIVE_KEY" })
        #expect(TemplateDiff.changes(from: v1, to: v1).isEmpty)
    }
}

struct WorkflowSetupStepsTests {

    private func template() -> Template {
        var t = WF.template(WF.intake())
        t.requirements = TemplateRequirements(
            models: [ModelRequirement(slot: "decision")], secrets: [SecretRequirement(key: "CLIO_KEY")],
            mcpServers: ["clio"], permissions: ["calendar"])
        return t
    }

    private func subject(_ mode: WorkflowSetupSubject.Mode, _ template: Template) -> WorkflowSetupSubject {
        WorkflowSetupSubject(mode: mode, template: template, bindings: InstallBindings(), name: template.name)
    }

    private func blocking(_ kind: TemplateRequirement.Kind, _ value: String) -> SetupItem {
        SetupItem(kind: kind, severity: .blocking, title: value, detail: "", value: value)
    }

    @Test
    func installShowsEveryRequirementStep() {
        let t = template()
        let steps = WorkflowSetupWizardView.steps(
            for: subject(.install, t), report: SetupReport(subjectId: t.id, items: []), newRequirements: nil)
        #expect(steps == [.models, .secrets, .tools, .permissions, .review])
    }

    @Test
    func updateAsksOnlyAboutNewOrBlockingRequirements() {
        let t = template()
        let s = subject(.update(UUID()), t)
        let clean = SetupReport(subjectId: t.id, items: [])

        #expect(
            WorkflowSetupWizardView.steps(for: s, report: clean, newRequirements: TemplateDiff.NewRequirements())
                == [.review], "nothing new and nothing broken: straight to review")

        var newSecret = TemplateDiff.NewRequirements()
        newSecret.secrets = ["CLIO_KEY"]
        #expect(WorkflowSetupWizardView.steps(for: s, report: clean, newRequirements: newSecret) == [.secrets, .review])

        let brokenModel = SetupReport(subjectId: t.id, items: [blocking(.model, "decision")])
        #expect(
            WorkflowSetupWizardView.steps(for: s, report: brokenModel, newRequirements: TemplateDiff.NewRequirements())
                == [.models, .review], "a binding that no longer resolves is asked about again")
    }

    @Test
    func savedAnswersStepOnlyForInstalledWorkflowsWithRememberedFields() {
        var def = WorkflowDefinition()
        def.nodes = [
            WorkflowNode(
                id: "ask", name: "Ask",
                kind: .dialog(
                    DialogSpec(title: "Who", fields: [DialogField(key: "firm", label: "Firm", persistence: .remember)])))
        ]
        let t = Template(name: "Ask", payload: .workflow(def))
        let report = SetupReport(subjectId: t.id, items: [])
        #expect(!WorkflowSetupWizardView.steps(for: subject(.install, t), report: report, newRequirements: nil).contains(.answers))
        #expect(WorkflowSetupWizardView.steps(for: subject(.setup(UUID()), t), report: report, newRequirements: nil).contains(.answers))
    }

    @Test
    func parkedWorkflowSetupRoutesToTheWorkflowsTab() {
        let t = template()
        let parked = PendingSetupSubject.workflow(subject(.install, t))
        #expect(parked.tab == .workflows)
    }
}

@MainActor
struct WorkflowPresentationTests {
    @Test
    func requirementChips_sayWhereModelsRunAndCountCodeAndSecrets() {
        var def = WF.intake()
        def.nodes.append(
            WorkflowNode(
                id: "post", name: "Post",
                kind: .code(CodeSpec(source: "async function run() { return {} }", secrets: ["A", "B"])),
                input: .object([:])))
        def.modelSlots = [ModelRequirement(slot: "decision", locality: .localOnly)]
        let local = WorkflowRequirementChips.items(for: WF.template(def)).map(\.text)
        #expect(local == ["Local only", "4 code", "2 secrets"])

        def.modelSlots = []
        #expect(WorkflowRequirementChips.items(for: WF.template(def)).first?.text == "Cloud")
        #expect(WorkflowRequirementChips.items(for: WF.template(WorkflowDefinition())).isEmpty)
    }

    @Test
    func cardFacts_readStepsWhereItRunsAndWhatToEnter() {
        var def = WF.intake()
        def.nodes.append(
            WorkflowNode(
                id: "post", name: "Post",
                kind: .code(CodeSpec(source: "async function run() { return {} }", secrets: ["A", "B"])),
                input: .object([:])))
        def.modelSlots = [ModelRequirement(slot: "decision", locality: .localOnly)]
        #expect(
            WorkflowCardFacts.template(WF.template(def))
                == ["\(def.nodes.count) steps", "Runs on this Mac", "2 secrets to enter"])

        let single = WorkflowDefinition(nodes: [WorkflowNode(id: "a", name: "A", intent: "Do A", kind: nil)])
        #expect(WorkflowCardFacts.template(WF.template(single)) == ["1 step"])
        #expect(WorkflowCardFacts.agents(0) == "Not on an agent yet")
        #expect(WorkflowCardFacts.agents(1) == "On 1 agent")
        #expect(WorkflowCardFacts.agents(3) == "On 3 agents")
    }

    @Test
    func output_isLaidOutBySchema_requiredFirst() throws {
        let schema = JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "summary": .object(["type": .string("string"), "title": .string("Summary")]),
                "next_step": WF.string,
                "tags": .object(["type": .string("array")]),
                "score": WF.number,
                "raw": .object(["type": .string("object")]),
            ]),
            "required": .array([.string("summary")]),
        ])
        let output = JSONValue.object([
            "summary": .string("All good"), "next_step": .string("Call"), "tags": .array([.string("a"), .string("b")]),
            "score": .number(3), "raw": .object(["k": .bool(true)]), "extra": .bool(false),
        ])
        let fields = try #require(WorkflowOutputLayout.fields(output, schema: schema))
        #expect(fields.map(\.key) == ["summary", "next_step", "raw", "score", "tags", "extra"])
        #expect(fields[0].label == "Summary")
        #expect(fields[1].label == "Next step")
        #expect(fields.first { $0.key == "tags" }?.text == "• a\n• b")
        #expect(fields.first { $0.key == "score" }?.text == "3")
        #expect(fields.first { $0.key == "raw" }?.isStructured == true)
        #expect(fields.first { $0.key == "extra" }?.text == "No")

        #expect(WorkflowOutputLayout.fields(.string("x"), schema: schema) == nil)
        #expect(WorkflowOutputLayout.fields(output, schema: .object(["type": .string("object")])) == nil)
    }
}

@Suite(.serialized)
@MainActor
struct WorkflowTabTests {

    @Test
    func layoutEntryRoundTripsWorkflowFields_andReadsV1ChatEntries() throws {
        let workflowID = UUID()
        let runID = UUID()
        let agentId = UUID()
        let record = ChatTabLayoutRecord(
            tabs: [
                .init(sessionId: UUID(), lastActivatedAt: Date(timeIntervalSince1970: 1)),
                .init(
                    sessionId: nil, lastActivatedAt: Date(timeIntervalSince1970: 2), workflowID: workflowID,
                    runID: runID, agentId: agentId),
            ],
            activeSessionId: nil, savedAt: Date(timeIntervalSince1970: 3))
        let decoded = try JSONDecoder().decode(ChatTabLayoutRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)

        let sessionId = UUID()
        let v1 = #"{"sessionId":"\#(sessionId.uuidString)","lastActivatedAt":0}"#
        let entry = try JSONDecoder().decode(ChatTabLayoutRecord.Tab.self, from: Data(v1.utf8))
        #expect(entry.sessionId == sessionId)
        #expect(entry.workflowID == nil)
    }

    @Test
    func storeFallsBackToTheV1Key_andDropsItOnSave() throws {
        let suite = "WorkflowTabTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = UUID()
        let record = ChatTabLayoutRecord(
            tabs: [.init(sessionId: UUID(), lastActivatedAt: Date(timeIntervalSince1970: 1))], activeSessionId: nil,
            savedAt: Date(timeIntervalSince1970: 2))
        defaults.set(
            try JSONEncoder().encode(ChatTabLayout(windows: [window: record])),
            forKey: ChatTabLayoutStore.legacyDefaultsKey)

        let store = ChatTabLayoutStore(defaults: defaults)
        #expect(store.load().windows[window] == record)
        store.save(store.load())
        #expect(defaults.data(forKey: ChatTabLayoutStore.legacyDefaultsKey) == nil)
        #expect(defaults.data(forKey: ChatTabLayoutStore.defaultsKey) != nil)
    }

    @Test
    func openingAWorkflowRunShowsItInTheWorkflowsWindow_notATab() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let workflowID = UUID()
            let runID = UUID()
            let tabs = window.tabs.count

            window.openWorkflowTab(workflowID: workflowID)
            #expect(window.tabs.count == tabs, "a workflow never opens a tab")
            #expect(window.mainSurface == .workflows && window.showsWorkflowLibrary)
            #expect(window.workflowsPath == [.run(workflowID: workflowID, runID: nil, agentId: Agent.defaultId)])

            window.openWorkflowTab(workflowID: workflowID, runID: runID)
            #expect(
                window.workflowsPath == [.run(workflowID: workflowID, runID: runID, agentId: Agent.defaultId)],
                "a run of the workflow on screen replaces it rather than stacking")

            let record = window.tabLayoutSnapshot()
            #expect(record.tabs.allSatisfy { $0.workflowID == nil }, "the snapshot records no workflow tabs")
        }
    }

    @Test
    func aRunOpenedFromAWorkflowsPage_stacksOnIt_andBackReturns() async throws {
        try await ChatHistoryTestStorage.run {
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let workflowID = UUID()
            let runID = UUID()

            window.showWorkflowsHome()
            #expect(window.workflowsPath.isEmpty)
            window.pushWorkflowsPage(.workflow(workflowID))
            window.showWorkflowRun(workflowID: workflowID, runID: runID)
            #expect(
                window.workflowsPath == [
                    .workflow(workflowID), .run(workflowID: workflowID, runID: runID, agentId: Agent.defaultId),
                ])
            window.popWorkflowsPage()
            #expect(window.workflowsPath == [.workflow(workflowID)])

            window.showMainSurface(.chat)
            #expect(window.mainSurface == .chat)
            let other = UUID()
            window.openWorkflowTab(workflowID: other)
            #expect(
                window.workflowsPath == [.run(workflowID: other, runID: nil, agentId: Agent.defaultId)],
                "from a chat, a run opens on its own with the window's home behind it")
            window.showWorkflowsHome()
            #expect(window.workflowsPath.isEmpty)
        }
    }

    @Test
    func restoreSkipsWorkflowTabsAnEarlierVersionSaved() async throws {
        try await ChatHistoryTestStorage.run {
            let store = InstalledWorkflowStore.shared
            store.reload()
            defer { store.resetForTesting() }
            let installed = try store.install(WF.template(WF.intake()), bindings: InstallBindings())
            let chat = ChatSessionData(
                id: UUID(), title: "Chat", turns: [ChatTurnData(role: .user, content: "hi")], agentId: Agent.defaultId)
            ChatSessionStore.save(chat)

            let record = ChatTabLayoutRecord(
                tabs: [
                    .init(
                        sessionId: nil, lastActivatedAt: Date(timeIntervalSince1970: 1), workflowID: installed.id,
                        agentId: Agent.defaultId),
                    .init(sessionId: nil, lastActivatedAt: Date(timeIntervalSince1970: 2), workflowID: UUID()),
                    .init(sessionId: chat.id, lastActivatedAt: Date(timeIntervalSince1970: 3)),
                ],
                activeSessionId: chat.id, savedAt: Date())

            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            #expect(window.restoreTabs(from: record) == 1, "only the chat comes back as a tab")
            #expect(window.tabs.allSatisfy { $0.workflowID == nil })
            #expect(window.tabs.last?.session.sessionId == chat.id)
        }
    }
}

@MainActor
struct WorkflowListTests {
    @Test
    func theList_showsTheAgentsWorkflowsWithStatus_andOnlyStartersNotYetAdded() {
        let added = WF.template(WF.intake(), name: "Client Intake")
        let starter = WF.template(WF.intake(), name: "Inbox Sorter")
        let ready = InstalledWorkflow(template: added, bindings: InstallBindings())
        var blocked = InstalledWorkflow(template: WF.template(WF.intake(), name: "Lead Router"), bindings: InstallBindings())
        blocked.needsSetup = true
        let other = InstalledWorkflow(template: WF.template(WF.intake(), name: "Not Mine"), bindings: InstallBindings())
        let model = WorkflowListModel.make(
            agentWorkflows: [ready, blocked], installed: [ready, blocked, other], builtIn: [added, starter], query: "",
            needsSetup: \.needsSetup, isRunning: { _ in false })
        #expect(model.mine.map(\.name) == ["Client Intake", "Lead Router"])
        #expect(model.mine.map(\.status) == ["Test workflow", "Needs setup"])
        #expect(model.others.map(\.name) == ["Not Mine"])
        #expect(model.starters.map(\.name) == ["Inbox Sorter"])

        let running = WorkflowListModel.make(
            agentWorkflows: [ready], installed: [ready], builtIn: [], query: "", needsSetup: { _ in false },
            isRunning: { $0 == ready.id })
        #expect(running.mine.first?.status == "Running…")

        let searched = WorkflowListModel.make(
            agentWorkflows: [ready, blocked], installed: [ready, blocked], builtIn: [added, starter], query: "lead",
            needsSetup: \.needsSetup, isRunning: { _ in false })
        #expect(searched.mine.map(\.name) == ["Lead Router"])
        #expect(searched.starters.isEmpty)
    }

    @Test
    func summary_saysWhatYouFillInAndGet_inRunOrder() {
        var def = WF.intake()
        def.inputSchema = .object([
            "type": .string("object"),
            "properties": .object([
                "client": .object(["type": .string("string"), "title": .string("Client name")]),
                "notes": WF.string,
            ]),
            "required": .array([.string("client")]),
            "x-order": .array([.string("client"), .string("notes")]),
        ])
        #expect(WorkflowSummary.sentence(def) == "You fill in Client name and Notes · 4 steps · You get Category, Record, and Welcome")
        let steps = WorkflowSummary.steps(def)
        #expect(steps.first?.name == "Classify")
        #expect(steps.first?.kind == "Picks a path")
        #expect(steps.first?.icon == "arrow.triangle.branch")
        #expect(steps.last?.id == "notify")
    }

    @Test
    func stepIcons_followWhatEachStepDoes() {
        func node(_ kind: NodeKind?) -> WorkflowNode { WorkflowNode(id: "n", name: "N", kind: kind) }
        #expect(WorkflowSummary.icon(node(.dialog(DialogSpec(title: "Ask", fields: [])))) == "questionmark.bubble")
        #expect(WorkflowSummary.icon(node(nil)) == "circle.dashed")
        let icons = Set(WF.intake().nodes.map(WorkflowSummary.icon))
        #expect(!icons.contains("circle.dashed"), "every step in a real workflow gets a kind-specific icon")
    }

    @Test
    func aStarterThatNeedsNothing_addsWithoutTheWizard() throws {
        var def = WF.intake()
        def.nodes = [
            WorkflowNode(
                id: "ask", name: "Ask",
                kind: .dialog(DialogSpec(title: "Anything else?", fields: [DialogField(key: "note", label: "Note", type: .text)])))
        ]
        def.edges = []
        def.output = .object([:])
        def.outputSchema = WF.object([:])
        let template = WF.template(def, name: "Starter \(UUID().uuidString.prefix(6))")
        #expect(WorkflowStarterPreviewSheet.blockers(template).isEmpty)
        let installed = try #require(try WorkflowStarterPreviewSheet.addDirectly(template))
        defer { InstalledWorkflowStore.shared.delete(id: installed.id) }
        #expect(installed.templateID == template.id)

        var secret = def
        secret.nodes = [
            WorkflowNode(
                id: "post", name: "Post",
                kind: .code(CodeSpec(source: "async function run() { return {} }", secrets: ["WF_STARTER_KEY"])),
                input: .object([:]))
        ]
        let needsKey = WF.template(secret, name: "Starter \(UUID().uuidString.prefix(6))")
        #expect(!WorkflowStarterPreviewSheet.blockers(needsKey).isEmpty)
        #expect(try WorkflowStarterPreviewSheet.addDirectly(needsKey) == nil)
    }
}

@MainActor
struct WorkflowFormOrderTests {
    private static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["tone": WF.string, "topic": WF.string, "audience": WF.string, "platform": WF.string]),
        "required": .array([.string("topic"), .string("platform")]),
    ])

    @Test
    func setSchemas_stampsXOrder_requiredFirstThenTheRest() throws {
        let result = try WorkflowDraftPatcher.apply([.setSchemas(input: Self.schema, output: nil)], to: WorkflowDefinition())
        let order = result.definition.inputSchema.objectValue?["x-order"]?.arrayStrings
        #expect(order == ["topic", "platform", "audience", "tone"])

        var designed = Self.schema.objectValue!
        designed["x-order"] = .array([.string("tone"), .string("ghost")])
        let kept = try WorkflowDraftPatcher.apply([.setSchemas(input: .object(designed), output: nil)], to: WorkflowDefinition())
        #expect(kept.definition.inputSchema.objectValue?["x-order"]?.arrayStrings == ["tone", "topic", "platform", "audience"])
    }

    @Test
    func theForm_ordersFieldsByXOrderThenRequired_evenWithoutStamping() {
        #expect(WorkflowFormFields.fields(fromInputSchema: Self.schema).map(\.key) == ["topic", "platform", "audience", "tone"])
    }

    @Test
    func copyAll_isEveryFieldUnderItsTitle_andProgressSpeaksPlainly() {
        let schema = JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "post": .object(["type": .string("string"), "title": .string("Post")]),
                "hashtags": .object(["type": .string("array"), "title": .string("Hashtags")]),
            ]),
            "required": .array([.string("post"), .string("hashtags")]),
        ])
        let output = JSONValue.object(["post": .string("Hello"), "hashtags": .array([.string("#a"), .string("#b")])])
        #expect(WorkflowResultCard.plainText(output, schema: schema) == "Post\nHello\n\nHashtags\n• #a\n• #b")
        #expect(WorkflowResultCard.plainText(.string("raw"), schema: schema) == "\"raw\"")
        #expect(WorkflowRunView.stateText(.running) == "working…")
        #expect(WorkflowRunView.stateText(nil) == "waiting")
        #expect(WorkflowRunTabView.statusText(.failed) == "It didn't finish")
    }
}
