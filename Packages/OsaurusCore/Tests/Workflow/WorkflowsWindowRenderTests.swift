//
//  WorkflowsWindowRenderTests.swift
//  osaurusTests
//
//  Renders the Workflows window's surfaces (its home on each tab, New
//  Workflow, a workflow's page, a run's page, the Architect's guided start and draft
//  pane) seeded with runs that are going, waiting, failed, and started by
//  an automation, and fails if any render comes out blank. Set
//  `WORKFLOW_RENDER_DIR=/some/dir` to render every surface in light and
//  dark at 760, 1024, and 1440pt and at the largest text size, and write
//  each as a PNG for review; reference images are not kept in the repo.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct WorkflowsWindowRenderTests {
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private static let outputDir = ProcessInfo.processInfo.environment["WORKFLOW_RENDER_DIR"]
    private static var widths: [CGFloat] { outputDir == nil ? [1024] : [760, 1024, 1440] }

    private struct Look {
        let name: String
        let dark: Bool
        let fontScale: Double
    }

    private static var looks: [Look] {
        outputDir == nil
            ? [Look(name: "dark", dark: true, fontScale: 1)]
            : [
                Look(name: "light", dark: false, fontScale: 1),
                Look(name: "dark", dark: true, fontScale: 1),
                Look(name: "dark-largeText", dark: true, fontScale: ServerConfiguration.fontSizeMultiplierRange.upperBound),
            ]
    }

    /// Applies `look` app-wide (the Workflows window reads the app theme)
    /// and renders `view` in an offscreen window; returns the distinct
    /// colours a coarse grid of the bitmap holds.
    private func render<V: View>(_ name: String, width: CGFloat, height: CGFloat, look: Look, _ view: V)
        async throws -> Int
    {
        let manager = ThemeManager.shared
        manager.setAppearanceMode(look.dark ? .dark : .light, persist: false)
        manager.setDesignInspectionScale(look.fontScale)
        let theme = manager.currentTheme
        let root = view
            .frame(width: width, height: height)
            .background(theme.surface.canvas)
            .environment(\.theme, theme)
            .tint(theme.action.primary.default.background)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = KeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: look.dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        var colours = 0
        for attempt in 1...5 {
            try await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            colours = Self.distinctColours(rep)
            if colours > 8 || attempt == 5 {
                if let dir = Self.outputDir {
                    try rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(Int(width))-\(look.name).png"))
                }
                break
            }
        }
        return colours
    }

    private static func distinctColours(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<Int>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 12) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 12) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert(Int(c.redComponent * 31) << 10 | Int(c.greenComponent * 31) << 5 | Int(c.blueComponent * 31))
            }
        }
        return seen.count
    }

    /// The window's (empty) title bar over the page.
    private struct WindowFrame<Content: View>: View {
        @Environment(\.theme) private var theme
        let windowState: ChatWindowState
        let content: Content

        var body: some View {
            VStack(spacing: 0) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                ThemeHairlineDivider()
                content
            }
        }
    }

    // MARK: - Fixtures

    private static func noInput(_ steps: [String]) -> WorkflowDefinition {
        WorkflowDefinition(
            inputSchema: WF.object([:]), outputSchema: WF.object([:]),
            nodes: steps.enumerated().map { i, name in
                var node = WF.code("s\(i)")
                node.name = name
                return node
            },
            edges: zip(steps.indices, steps.indices.dropFirst()).map { WorkflowEdge(from: "s\($0)", to: "s\($1)") },
            output: .object([:]))
    }

    private static func run(
        _ workflow: InstalledWorkflow, _ status: WorkflowRunStatus, ago: TimeInterval, took: TimeInterval? = nil,
        caller: WorkflowCaller = WorkflowCaller(kind: .user)
    ) -> WorkflowRun {
        let ids = workflow.definition.nodes.map(\.id)
        var run = WorkflowRun(
            workflowID: workflow.id, workflowName: workflow.name, templateID: workflow.templateID,
            templateVersion: workflow.templateVersion, caller: caller, input: .object([:]), nodeIDs: ids)
        let start = Date().addingTimeInterval(-ago)
        run.status = status
        run.startedAt = start
        let reached: Int
        switch status {
        case .completed: reached = ids.count
        case .running, .awaitingUser: reached = max(1, ids.count / 2)
        default: reached = max(0, ids.count - 1)
        }
        for (i, id) in ids.enumerated() {
            run.update(id) {
                $0.startedAt = start.addingTimeInterval(Double(i) * 4)
                if i < reached {
                    $0.status = .done
                    $0.attempts = 1
                    $0.finishedAt = start.addingTimeInterval(Double(i) * 4 + 3)
                } else if i == reached {
                    switch status {
                    case .running:
                        $0.status = .running
                        $0.progress = WorkflowNodeProgress(fraction: 0.4, detail: "Reading 12 of 30 messages")
                    case .awaitingUser: $0.status = .awaitingUser
                    case .failed:
                        $0.status = .failed
                        $0.error = "The mail server refused the connection."
                    default: break
                    }
                }
            }
        }
        if status == .failed {
            run.error = WorkflowRunError(reason: "The mail server refused the connection.")
        }
        if let took { run.finishedAt = start.addingTimeInterval(took) }
        return run
    }

    private struct Seeded {
        let window: ChatWindowState
        let inbox: InstalledWorkflow
        let longName: InstalledWorkflow
        let runningRun: WorkflowRun
        let failedRun: WorkflowRun
        let draftSession: UUID
        let blankSession: UUID
    }

    /// A library someone has used for a while: a run going, one waiting on
    /// an answer, one an automation started, a failure, a long name, a
    /// published workflow, and two drafts.
    private static func seed() throws -> Seeded {
        let installed = InstalledWorkflowStore.shared
        let inbox = try installed.install(
            WF.template(noInput(["Fetch new mail", "Sort by sender", "Summarize threads", "Draft replies"]), name: "Inbox Sorter"),
            bindings: InstallBindings())
        let intake = try installed.install(WF.template(WF.intake(), name: "Client Intake"), bindings: InstallBindings())
        let digest = try installed.install(
            WF.template(noInput(["Collect headlines", "Rank by relevance", "Write the digest"]), name: "Morning Digest"),
            bindings: InstallBindings())
        let longName = try installed.install(
            WF.template(
                noInput(["Choose the visual direction", "Render both sides", "Export the print-ready PDF"]),
                name: "Quarterly Investor Update Deck With Charts From The Finance Spreadsheet"),
            bindings: InstallBindings())
        _ = try installed.install(WF.template(noInput(["Transcribe", "Summarize"]), name: "Meeting Notes"), bindings: InstallBindings())

        let store = WorkflowRunStore.shared
        let runningRun = run(inbox, .running, ago: 20)
        store.record(run(inbox, .completed, ago: 3600, took: 14))
        store.record(run(inbox, .completed, ago: 86_400, took: 18))
        store.record(runningRun)
        store.record(run(intake, .awaitingUser, ago: 90))
        let automation = WorkflowCaller(kind: .event, eventID: UUID(), eventName: "Every weekday at 8")
        store.record(run(digest, .running, ago: 8, caller: automation))
        store.record(run(digest, .completed, ago: 86_400, took: 41, caller: automation))
        let failedRun = run(longName, .failed, ago: 7200, took: 9)
        store.record(failedRun)

        var published = WorkflowRegistryRecord(
            templateID: digest.templateID, registryID: "reg-digest", slug: "morning-digest", version: 1,
            contentHash: "sha256:00", url: URL(string: "https://web.test/w/morning-digest")!,
            rawURL: URL(string: "https://registry.test/raw")!, deepLink: URL(string: "osaurus://templates-import")!,
            address: "0xabc", registry: WorkflowRegistryRecordStore.registryKey(WorkflowsRegistryAPIClient.defaultBaseURL),
            sharedAt: Date().addingTimeInterval(-86_400 * 3))
        published.registryLatestVersion = 1
        published.liveVersion = 1
        published.listed = true
        WorkflowRegistryRecordStore.shared.set(published)

        let drafts = WorkflowDraftStore.shared
        let draftSession = UUID()
        _ = drafts.create(
            sessionID: draftSession.uuidString,
            from: WF.template(noInput(["Watch the folder", "Rename by date", "Move to archive"]), name: "Receipt Filer"))
        let blankSession = UUID()
        _ = drafts.create(sessionID: blankSession.uuidString)

        let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
        return Seeded(
            window: window, inbox: inbox, longName: longName, runningRun: runningRun, failedRun: failedRun,
            draftSession: draftSession, blankSession: blankSession)
    }

    private static func tearDown(_ seeded: Seeded?) {
        seeded?.window.cleanup()
        if let digest = InstalledWorkflowStore.shared.workflows.first(where: { $0.name == "Morning Digest" }) {
            WorkflowRegistryRecordStore.shared.remove(templateID: digest.templateID)
        }
        WorkflowDraftStore.shared.resetForTesting()
        // The run database outlives the test root: open runs left in it
        // would read as abandoned to later tests.
        for workflow in InstalledWorkflowStore.shared.workflows {
            WorkflowRunStore.shared.deleteRuns(workflowID: workflow.id)
        }
        WorkflowRunStore.shared.resetForTesting()
        InstalledWorkflowStore.shared.resetForTesting()
        ThemeManager.shared.setDesignInspectionScale(1)
        ThemeManager.shared.setAppearanceMode(
            ServerConfigurationStore.load()?.appearanceMode ?? .system, persist: false)
        UserDefaults.standard.removeObject(forKey: ChatWindowState.workflowsTabDefaultsKey)
    }

    // MARK: - Renders

    private func renderEverywhere<V: View>(_ name: String, height: CGFloat = 900, _ view: () -> V) async throws {
        for look in Self.looks {
            for width in Self.widths {
                let colours = try await render(name, width: width, height: height, look: look, view())
                #expect(colours > 8, "\(name) rendered blank @\(Int(width)) \(look.name)")
            }
        }
    }

    @Test func firstRun_showsOnlyNewWorkflow() async throws {
        try await ChatHistoryTestStorage.run {
            InstalledWorkflowStore.shared.reload()
            WorkflowDraftStore.shared.resetForTesting()
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { Self.tearDown(nil); window.cleanup() }
            try await renderEverywhere("01-first-run") {
                WindowFrame(windowState: window, content: WorkflowsView(windowState: window))
            }
        }
    }

    @Test func workflowsTabsAndNewWorkflow_withLiveWaitingAutomatedAndFailedRuns() async throws {
        try await ChatHistoryTestStorage.run {
            InstalledWorkflowStore.shared.reload()
            let seeded = try Self.seed()
            defer { Self.tearDown(seeded) }
            let window = seeded.window

            window.showWorkflowsHome(tab: .all)
            try await renderEverywhere("02-workflows-all", height: 1100) {
                WindowFrame(
                    windowState: window,
                    content: WorkflowsView(windowState: window, expandedWorkflows: [seeded.inbox.id, seeded.longName.id]))
            }

            for tab in [ChatWindowState.WorkflowsTab.drafts, .published] {
                window.showWorkflowsHome(tab: tab)
                try await renderEverywhere("03-workflows-\(tab.rawValue)") {
                    WindowFrame(windowState: window, content: WorkflowsView(windowState: window))
                }
            }

            window.showNewWorkflow()
            #expect(window.workflowsPath == [.create])
            try await renderEverywhere("03-new-workflow") {
                WindowFrame(windowState: window, content: WorkflowsView(windowState: window))
            }

            window.showWorkflowsHome(tab: .all)
            window.pushWorkflowsPage(.workflow(seeded.inbox.id))
            try await renderEverywhere("04-workflow-page") {
                WindowFrame(windowState: window, content: WorkflowsView(windowState: window))
            }

            window.showWorkflowRun(workflowID: seeded.inbox.id, runID: seeded.runningRun.id, agentId: Agent.defaultId)
            try await renderEverywhere("05-run-page-running") {
                WindowFrame(windowState: window, content: WorkflowsView(windowState: window))
            }

            window.showWorkflowsHome()
            window.showWorkflowRun(workflowID: seeded.longName.id, runID: seeded.failedRun.id, agentId: Agent.defaultId)
            try await renderEverywhere("06-run-page-failed-long-name") {
                WindowFrame(windowState: window, content: WorkflowsView(windowState: window))
            }

            window.showWorkflowsHome()
            window.showWorkflowRun(workflowID: seeded.inbox.id, runID: nil, agentId: Agent.defaultId)
            try await renderEverywhere("07-run-page-new") {
                WindowFrame(windowState: window, content: WorkflowsView(windowState: window))
            }
        }
    }

    @Test func fiftyWorkflows_stayOneReadableList() async throws {
        try await ChatHistoryTestStorage.run {
            let installed = InstalledWorkflowStore.shared
            installed.reload()
            defer { Self.tearDown(nil) }
            for i in 1...52 {
                _ = try installed.install(
                    WF.template(Self.noInput(["Step one", "Step two"]), name: "Workflow number \(i)"),
                    bindings: InstallBindings())
            }
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            window.showWorkflowsHome(tab: .all)
            try await renderEverywhere("08-fifty-workflows") {
                WindowFrame(windowState: window, content: WorkflowsView(windowState: window))
            }
        }
    }

    @Test func architect_guidedStartEditStartAndDraftPane() async throws {
        try await ChatHistoryTestStorage.run {
            InstalledWorkflowStore.shared.reload()
            let seeded = try Self.seed()
            defer { Self.tearDown(seeded) }

            try await renderEverywhere("10-architect-start") {
                ArchitectChatEmptyState(
                    mode: .start, quickActions: AgentQuickAction.architectQuickActions, onPick: { _ in }, onBrowse: {})
            }
            try await renderEverywhere("11-architect-edit") {
                ArchitectChatEmptyState(
                    mode: .edit(workflowName: "Receipt Filer", stepCount: 3, isSaved: true),
                    quickActions: AgentQuickAction.architectEditQuickActions(workflowName: "Receipt Filer"),
                    onPick: { _ in })
            }
            for (name, session) in [("12-architect-pane-steps", seeded.draftSession), ("13-architect-pane-empty", seeded.blankSession)] {
                try await renderEverywhere(name) {
                    ArchitectSidebarPanel(sessionId: session)
                }
            }
        }
    }

    // MARK: - Forms

    /// Every kind of field a workflow asks for, as an Architect writes them.
    private static let businessCardInput = JSONValue.parse(
        #"""
        {"type": "object",
         "x-order": ["full_name", "job_title", "contact", "tagline", "size", "finish", "copies", "bleed"],
         "required": ["full_name", "job_title", "contact", "size", "copies"],
         "properties": {
           "full_name": {"type": "string", "title": "Full name",
                         "description": "Enter the name exactly as it should appear on the card."},
           "job_title": {"type": "string", "title": "Job title or role", "description": "Enter the person's title or role."},
           "contact": {"type": "string", "title": "Contact details",
                       "description": "Enter the phone, email, website, and address to include, one per line."},
           "tagline": {"type": "string", "title": "Tagline",
                       "description": "An optional slogan or short positioning statement."},
           "size": {"type": "string", "title": "Card size", "enum": ["Standard", "Square", "Mini"]},
           "finish": {"type": "string", "title": "Paper finish",
                      "enum": ["Matte", "Gloss", "Soft-touch laminate", "Uncoated recycled"],
                      "description": "Leave unset to let the printer choose."},
           "copies": {"type": "integer", "title": "Copies", "description": "How many to print."},
           "bleed": {"type": "boolean", "title": "Add bleed marks",
                     "description": "For printers that trim after cutting."}
         }}
        """#)!

    private static let businessCardPrefill = JSONValue.parse(
        #"""
        {"full_name": "Maya Chen", "job_title": "Landscape Architect",
         "contact": "maya@verdantstudio.com\n+1 555 0142\nverdantstudio.com", "size": "Standard", "copies": 250}
        """#)!.objectValue!

    private func renderLooks<V: View>(_ name: String, width: CGFloat, height: CGFloat, _ view: () -> V) async throws {
        for look in Self.looks {
            let colours = try await render(name, width: width, height: height, look: look, view())
            #expect(colours > 8, "\(name) rendered blank \(look.name)")
        }
    }

    @Test func forms_runSheetTestInputAndFollowUps() async throws {
        try await ChatHistoryTestStorage.run {
            let installed = InstalledWorkflowStore.shared
            installed.reload()
            defer { Self.tearDown(nil) }
            var definition = Self.noInput(["Lay out both sides", "Export the PDF"])
            definition.inputSchema = Self.businessCardInput
            let workflow = try installed.install(
                Template(
                    name: "Print-Ready Business Card Maker",
                    summary: "Designs a two-sided business card and exports a print-ready PDF with bleed.",
                    payload: .workflow(definition)),
                bindings: InstallBindings())
            let prefill = Self.businessCardPrefill

            try await renderLooks("14-run-sheet", width: 640, height: 1100) {
                WorkflowRunInputSheet(
                    workflow: workflow, windowAgent: Agent.defaultId, prefill: prefill,
                    onStarted: { _ in }, onSetUp: { _ in }, onClose: {})
            }

            var headshots = Self.noInput(["Retouch", "Render looks"])
            headshots.inputSchema = JSONValue.parse(
                #"""
                {"type": "object", "x-order": ["photo", "looks", "style"], "required": ["photo", "looks"],
                 "properties": {
                   "photo": {"type": "string", "format": "file", "title": "Your photo",
                             "description": "A clear, front-facing photo of yourself (selfie works)."},
                   "looks": {"type": "integer", "title": "Number of looks", "description": "How many headshots to make."},
                   "style": {"type": "string", "title": "Style", "enum": ["Corporate", "Creative", "Casual", "Startup", "Editorial"]}
                 }}
                """#)!
            headshots.examples = [
                WorkflowExample(name: "Corporate", input: .object(["photo": .string("/Users/maya/Pictures/selfie.jpg"), "looks": .number(3)])),
                WorkflowExample(name: "Creative", input: .object(["looks": .number(4)])),
            ]
            let headshotStudio = try installed.install(
                Template(
                    name: "LinkedIn Headshot Studio",
                    summary: "Turns one selfie into a set of polished LinkedIn headshots. Pick how many looks you want and a style; "
                        + "each look gets its own lighting, background and wardrobe, retouched for a natural finish, and exported "
                        + "at LinkedIn's recommended size with a matching banner.",
                    payload: .workflow(headshots)),
                bindings: InstallBindings())
            try await renderLooks("14b-run-sheet-file", width: 640, height: 900) {
                WorkflowRunInputSheet(
                    workflow: headshotStudio, windowAgent: Agent.defaultId, prefill: [:],
                    onStarted: { _ in }, onSetUp: { _ in }, onClose: {})
            }
            try await renderLooks("14c-run-sheet-file-chosen", width: 640, height: 900) {
                WorkflowRunInputSheet(
                    workflow: headshotStudio, windowAgent: Agent.defaultId,
                    prefill: headshots.examples[0].input.objectValue,
                    onStarted: { _ in }, onSetUp: { _ in }, onClose: {})
            }

            let fields = WorkflowFormFields.fields(fromInputSchema: Self.businessCardInput)
            #expect(fields.first { $0.key == "contact" }?.type == .longText)
            try await renderLooks("15-test-input", width: 460, height: 1000) {
                ScrollView {
                    WorkflowFormView(
                        fields: fields,
                        values: .constant(WorkflowFormFields.initialValues(fields, prefill: prefill)),
                        issues: ["job_title": "Required."])
                        .padding(16)
                }
            }

            var cardMaker = Self.noInput(["Lay out both sides", "Export the PDF"])
            cardMaker.nodes.insert(
                WorkflowNode(
                    id: "write", name: "Write greeting and art direction",
                    kind: .inference(InferenceSpec(modelSlot: "writer", instructions: "Write the card copy."))),
                at: 0)
            cardMaker.nodes.insert(
                WorkflowNode(
                    id: "plan", name: "Plan the layout",
                    kind: .inference(InferenceSpec(modelSlot: "layout", instructions: "Plan both sides."))),
                at: 1)
            cardMaker.modelSlots = [
                ModelRequirement(slot: "writer", preferred: "default"),
                ModelRequirement(slot: "layout", preferred: "OsaurusAI/Not-Downloaded-27B", needsToolUse: true),
            ]
            cardMaker.examples = [WorkflowExample(name: "Maya's cards", input: .object(prefill))]
            let template = WF.template(cardMaker, name: "Print-Ready Business Card Maker")
            let report = SetupChecker.check(template, bindings: InstallBindings(), subjectId: template.id)
            try await renderLooks("17-setup-models", width: 560, height: 720) {
                WorkflowModelsStep(
                    template: template, bindings: InstallBindings(),
                    items: report.items.filter { $0.kind == .model }, onlySlots: nil,
                    setModel: { _, _ in }, onLeave: { _ in })
                    .padding(24)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            try await renderLooks("18-setup-review", width: 560, height: 720) {
                WorkflowReviewStep(
                    subject: WorkflowSetupSubject(
                        mode: .install, template: template,
                        bindings: InstallBindings(models: ["layout": "OsaurusAI/Qwen3.8-27B-JANGH2"]),
                        name: template.name),
                    report: report, exampleToRun: .constant(nil), onRename: { _ in })
                    .padding(24)
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            try await renderLooks("16-follow-ups", width: 380, height: 360) {
                FollowUpSuggestionsBar(
                    suggestions: [
                        "What are CNN's top stories right now?",
                        "Can you show me the latest CNN politics news?",
                        "What are the newest CNN sports headlines?",
                        "Can you include summaries and direct links for each story?",
                    ],
                    animate: false, onSelect: { _ in }
                )
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}
