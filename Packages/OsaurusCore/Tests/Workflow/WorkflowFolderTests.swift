//
//  WorkflowFolderTests.swift
//  OsaurusCoreTests
//
//  Declared folders: the model and its JSON (omitted when none), the
//  `declare_folder` op, the `{{folders.<key>}}` binding and the
//  validator's rules, requirements and setup items, the paths a run's file
//  tools may use, the out-of-scope error, `file_copy` to a host folder
//  with a sandbox attached, and the run-time "allow this folder" card.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowFolderTests {

    private static let invoices = FolderRequirement(
        key: "invoices", label: "Invoices folder", help: "Where PDFs are saved", access: .write,
        hint: PathHint(path: "~/Documents/Invoices"))

    private static func saveStep(destination: String = "{{folders.invoices}}/invoice.pdf") -> WorkflowNode {
        WorkflowNode(
            id: "save", name: "Save PDF", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_copy"))),
            input: .object(["source": "invoice.pdf", "destination": destination]), outputSchema: .object([:]))
    }

    private static func definition(
        folders: [FolderRequirement] = [invoices], step: WorkflowNode = saveStep()
    ) -> WorkflowDefinition {
        var def = WorkflowDefinition(
            inputSchema: WF.object([:]), nodes: [step], output: .object(["saved": "{{nodes.save.output.destination}}"]))
        def.folders = folders
        return def
    }

    // MARK: - Model and JSON

    @Test
    func folder_roundTripsThroughJSON_andIsOmittedWhenNone() throws {
        let def = Self.definition()
        let data = try JSONEncoder().encode(def)
        let json = try #require(JSONValue.parse(String(decoding: data, as: UTF8.self))?.objectValue)
        guard case .array(let folders)? = json["folders"] else {
            Issue.record("expected a folders array")
            return
        }
        #expect(folders.first?.objectValue?["key"] == .string("invoices"))
        #expect(folders.first?.objectValue?["access"] == .string("write"))
        #expect(try JSONDecoder().decode(WorkflowDefinition.self, from: data).folders == [Self.invoices])

        let plainDef = try #require(
            JSONValue.parse(String(decoding: try JSONEncoder().encode(WF.intake()), as: UTF8.self))?.objectValue)
        #expect(plainDef["folders"] == nil)
        let plainReqs = try #require(
            JSONValue.parse(String(decoding: try JSONEncoder().encode(TemplateRequirements()), as: UTF8.self))?
                .objectValue)
        #expect(plainReqs["folders"] == nil)
        let plainBindings = try #require(
            JSONValue.parse(String(decoding: try JSONEncoder().encode(InstallBindings()), as: UTF8.self))?.objectValue)
        #expect(plainBindings["folders"] == nil)
        #expect(plainBindings["folder_grants"] == nil)

        let bindings = InstallBindings(folders: ["invoices": "/tmp/inv"], folderGrants: ["/tmp/other"])
        let decoded = try JSONDecoder().decode(InstallBindings.self, from: JSONEncoder().encode(bindings))
        #expect(decoded == bindings)
    }

    @Test
    func folder_keysMustBeBindingSafe() {
        #expect(FolderRequirement.isValidKey("save_to"))
        #expect(!FolderRequirement.isValidKey("1st"))
        #expect(!FolderRequirement.isValidKey("my-folder"))
        #expect(!FolderRequirement(key: "a.b", label: "X").issues.isEmpty)
        #expect(!FolderRequirement(key: "ok", label: " ").issues.isEmpty)
    }

    // MARK: - declare_folder

    @Test
    func declareFolder_parsesUpsertsAndRemoves() throws {
        let op = try WorkflowDraftOp.parse(
            .object([
                "op": .string("declare_folder"), "key": .string("invoices"), "label": .string("Invoices folder"),
                "access": .string("read"), "hint": .string("~/Documents/Invoices"),
            ]))
        guard case .declareFolder(let folder) = op else {
            Issue.record("expected declareFolder, got \(op)")
            return
        }
        #expect(folder.access == .read)
        #expect(folder.hint?.path == "~/Documents/Invoices")

        var def = WorkflowDefinition()
        def = try WorkflowDraftPatcher.apply([op], to: def).definition
        #expect(def.folders.map(\.key) == ["invoices"])
        var renamed = folder
        renamed.label = "Invoices"
        def = try WorkflowDraftPatcher.apply([.declareFolder(renamed)], to: def).definition
        #expect(def.folders.count == 1)
        #expect(def.folders.first?.label == "Invoices")

        let remove = try WorkflowDraftOp.parse(
            .object(["op": .string("declare_folder"), "key": .string("invoices"), "remove": .bool(true)]))
        #expect(remove == .removeFolder(key: "invoices"))
        def = try WorkflowDraftPatcher.apply([remove], to: def).definition
        #expect(def.folders.isEmpty)
        #expect(throws: WorkflowDraftPatcher.Failure.self) { try WorkflowDraftPatcher.apply([remove], to: def) }

        #expect(throws: WorkflowDraftOp.ParseError.self) {
            try WorkflowDraftOp.parse(.object(["op": .string("declare_folder"), "key": .string("bad-key"), "label": .string("X")]))
        }
        #expect(throws: WorkflowDraftOp.ParseError.self) {
            try WorkflowDraftOp.parse(
                .object([
                    "op": .string("declare_folder"), "key": .string("out"), "label": .string("X"),
                    "access": .string("everything"),
                ]))
        }
    }

    // MARK: - Binding and validator

    @Test
    func foldersBinding_rendersTheBoundFolder() {
        let ctx = BindingContext(input: .object([:]), folders: BindingContext.foldersValue(["out": "/tmp/out"]))
        #expect(BindingRenderer.parse(reference: "folders.out") == .folder(key: "out"))
        #expect(BindingRenderer.render(.template("{{folders.out}}/a.pdf"), in: ctx) == .string("/tmp/out/a.pdf"))
        #expect(BindingRenderer.render(.template("{{folders.missing}}"), in: ctx) == .null)
    }

    @Test
    func validator_requiresDeclaredFolders_andFlagsPathsFromThisMac() {
        #expect(WorkflowValidator.validate(Self.definition(), allowPlaceholders: false).isEmpty)

        let undeclared = WorkflowValidator.validate(Self.definition(folders: []), allowPlaceholders: false)
        #expect(undeclared.contains { $0.message.contains("folder `invoices`, which is not declared") })

        for literal in ["/Users/tpae/Desktop/Invoice.pdf", "~/Desktop/Invoice.pdf"] {
            let issues = WorkflowValidator.validate(
                Self.definition(folders: [], step: Self.saveStep(destination: literal)), allowPlaceholders: false)
            #expect(issues.contains { $0.nodeID == "save" && $0.message.contains("declare_folder") })
        }
        let relative = WorkflowValidator.validate(
            Self.definition(folders: [], step: Self.saveStep(destination: "out.pdf")), allowPlaceholders: false)
        #expect(relative.isEmpty)

        let duplicate = WorkflowValidator.validate(
            Self.definition(folders: [Self.invoices, Self.invoices]), allowPlaceholders: false)
        #expect(duplicate.contains { $0.message.contains("more than once") })
    }

    // MARK: - Requirements and setup

    @Test
    func requirements_carryFolders_mergeByKey_andDiffNewOnes() {
        let reqs = WorkflowRequirementsDeriver.derive(Self.definition())
        #expect(reqs.folders == [Self.invoices])
        #expect(reqs.items.contains { $0.kind == .folder && $0.id == "folder:invoices" })

        let other = TemplateRequirements(folders: [FolderRequirement(key: "downloads", label: "Downloads")])
        #expect(reqs.merged(with: other).folders.map(\.key) == ["invoices", "downloads"])
        #expect(reqs.merged(with: reqs).folders.count == 1)

        let diff = TemplateDiff.newRequirements(from: reqs, to: reqs.merged(with: other))
        #expect(diff.folders == ["downloads"])
        #expect(diff.contains(SetupItem(kind: .folder, severity: .blocking, title: "D", detail: "", value: "downloads")))
        #expect(!diff.contains(SetupItem(kind: .folder, severity: .blocking, title: "I", detail: "", value: "invoices")))
    }

    @Test
    func setup_blocksOnUnboundOrMissingFolders() {
        var env = SetupChecker.Environment(
            registeredToolNames: ["file_copy"],
            modelCatalog: ConfigModelReference.Catalog(localModelIds: [], providers: []),
            isPermissionGranted: { _ in true }, bookmarkResolves: { _ in true },
            knowledgeCollectionExists: { _ in true })
        env.folderExists = { $0 == "/tmp/invoices" }
        let template = WF.template(Self.definition())

        let unbound = SetupChecker.check(template, bindings: InstallBindings(), subjectId: UUID(), environment: env)
        #expect(unbound.blocking.map(\.kind) == [.folder])
        #expect(unbound.blocking.first?.value == "invoices")
        #expect(unbound.blocking.first?.detail.contains("~/Documents/Invoices") == true)

        let gone = SetupChecker.check(
            template, bindings: InstallBindings(folders: ["invoices": "/tmp/nowhere"]), subjectId: UUID(),
            environment: env)
        #expect(gone.blocking.map(\.kind) == [.folder])

        let bound = SetupChecker.check(
            template, bindings: InstallBindings(folders: ["invoices": "/tmp/invoices"]), subjectId: UUID(),
            environment: env)
        #expect(bound.isClean)
    }

    // MARK: - Run-time scopes

    @Test
    func runner_grantsBoundFoldersAndStandingGrants_andBindsFolderKeys() async {
        let bound = WF.tempDir()
        let standing = WF.tempDir()
        defer {
            try? FileManager.default.removeItem(at: bound)
            try? FileManager.default.removeItem(at: standing)
        }
        let request = WorkflowRunner.Request(
            workflowID: UUID(), workflowName: "Invoices", template: WF.template(Self.definition()),
            caller: WorkflowCaller(kind: .test), input: .object([:]), workspace: WF.tempDir(),
            boundFolders: ["invoices": bound.path], folderGrants: [standing.path])
        let seen = FolderContextBox()
        let run = await WorkflowRunner(
            request: request,
            executor: ClosureExecutor { context, _ in
                await seen.set(context)
                return WorkflowNodeOutcome(output: .object(["destination": .string("x")]))
            }
        ).execute()
        #expect(run.status == .completed, Comment(rawValue: String(describing: run.error)))
        let context = await seen.value
        let paths = context?.grantedPaths.map(\.standardized.path) ?? []
        #expect(paths.contains(bound.standardized.path))
        #expect(paths.contains(standing.standardized.path))
        #expect(context?.bindings.folders.objectValue?["invoices"] == .string(bound.path))
        #expect(context?.input.objectValue?["destination"] == .string(bound.path + "/invoice.pdf"))
        #expect(context?.requestFolderGrant != nil)
    }

    @Test
    func runner_headlessCallers_getNoFolderCard() async {
        let request = WorkflowRunner.Request(
            workflowID: UUID(), workflowName: "Invoices", template: WF.template(Self.definition()),
            caller: WorkflowCaller(kind: .agent, isExternalSurface: true), input: .object([:]), workspace: WF.tempDir(),
            boundFolders: ["invoices": "/tmp"])
        let seen = FolderContextBox()
        _ = await WorkflowRunner(
            request: request,
            executor: ClosureExecutor { context, _ in
                await seen.set(context)
                return WorkflowNodeOutcome(output: .object([:]))
            }
        ).execute()
        #expect(await seen.value?.requestFolderGrant == nil)
        #expect(!WorkflowFolderGrantCoordinator.canAsk(WorkflowCaller(kind: .agent, isUnattendedDispatch: true)))
        #expect(WorkflowFolderGrantCoordinator.canAsk(WorkflowCaller(kind: .test)))
    }

    @Test
    func resolvePath_inAWorkflowRun_namesTheScopesAndTheFolderToAllow() throws {
        let root = WF.tempDir()
        let granted = WF.tempDir()
        let outside = WF.tempDir()
        defer {
            for url in [root, granted, outside] { try? FileManager.default.removeItem(at: url) }
        }
        let target = outside.appendingPathComponent("Invoice.pdf").path
        try ChatExecutionContext.$currentWorkflowRunId.withValue(UUID()) {
            try ChatExecutionContext.$workflowGrantedPaths.withValue([granted]) {
                do {
                    _ = try FolderToolHelpers.resolvePath(target, rootPath: root)
                    Issue.record("expected an out-of-scope error")
                } catch let error as FolderToolError {
                    guard case .pathOutsideWorkflowScopes(_, let absolute, let allowed) = error else {
                        Issue.record("unexpected \(error)")
                        return
                    }
                    #expect(absolute == URL(fileURLWithPath: target).standardized.path)
                    #expect(allowed.contains(root.standardized.path))
                    #expect(allowed.contains(granted.standardized.path))
                    let envelope = ToolEnvelope.fromError(error, tool: "file_copy")
                    #expect(WorkflowFolderGrant.requestedPath(in: envelope) == absolute)
                    #expect(ToolEnvelope.isError(envelope))
                }
            }
        }
        // Outside a workflow run the old error stays.
        #expect(throws: FolderToolError.self) { try FolderToolHelpers.resolvePath(target, rootPath: root) }
    }

    @Test
    func fileCopy_withASandboxAttached_copiesIntoAGrantedHostFolder() async throws {
        let root = WF.tempDir()
        let granted = WF.tempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: granted)
        }
        try Data("pdf".utf8).write(to: root.appendingPathComponent("invoice.pdf"))
        let destination = granted.appendingPathComponent("Invoice-INV-1001.pdf")
        let arguments = JSONValue.object([
            "source": .string("invoice.pdf"), "destination": .string(destination.path),
        ]).compactJSONString
        let bridge = SandboxReadBridge(agentName: "wf-test", home: "/workspace/agents/wf-test")
        let result = try await ChatExecutionContext.$sandboxReadBridge.withValue(bridge) {
            try await ChatExecutionContext.$currentFolderRoot.withValue(root) {
                try await ChatExecutionContext.$currentWorkflowRunId.withValue(UUID()) {
                    try await ChatExecutionContext.$workflowGrantedPaths.withValue([granted]) {
                        try await FileCopyTool().execute(argumentsJSON: arguments)
                    }
                }
            }
        }
        #expect(!ToolEnvelope.isError(result), Comment(rawValue: result))
        #expect(FileManager.default.contents(atPath: destination.path) == Data("pdf".utf8))
    }

    // MARK: - Allow card

    private actor CallLog {
        var grantedPaths: [[String]] = []
        func record(_ paths: [String]) { grantedPaths.append(paths) }
        var count: Int { grantedPaths.count }
    }

    private static func toolContext(
        grant: WorkflowFolderGrantRequest?
    ) -> (ToolNodeSpec, WorkflowNodeContext) {
        let spec = ToolNodeSpec(tool: ToolRef(name: "file_copy"))
        let node = saveStep(destination: "/Users/someone/Desktop/Invoice.pdf")
        let input = JSONValue.object([
            "source": .string("invoice.pdf"), "destination": .string("/Users/someone/Desktop/Invoice.pdf"),
        ])
        let context = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "Invoices", node: node, input: input,
            bindings: BindingContext(input: input), model: nil, secretAccounts: [:],
            caller: WorkflowCaller(kind: .test), workspace: WF.tempDir(), requestFolderGrant: grant, attempt: 1,
            timeout: 60)
        return (spec, context)
    }

    private static func runtime(log: CallLog) -> ToolNodeExecutor.Runtime {
        ToolNodeExecutor.Runtime(
            resolve: { name in
                ToolNodeExecutor.Resolved(
                    spec: Tool(type: "function", function: ToolFunction(name: name, description: name, parameters: nil)),
                    outputSchema: nil)
            },
            execute: { name, _, _ in
                let paths = (ChatExecutionContext.workflowGrantedPaths ?? []).map(\.path)
                await log.record(paths)
                if paths.contains("/Users/someone/Desktop") {
                    return ToolEnvelope.success(tool: name, result: ["destination": "/Users/someone/Desktop/Invoice.pdf"])
                }
                return ToolEnvelope.fromError(
                    FolderToolError.pathOutsideWorkflowScopes(
                        path: "/Users/someone/Desktop/Invoice.pdf",
                        absolutePath: "/Users/someone/Desktop/Invoice.pdf", allowed: ["/tmp/run"]),
                    tool: name)
            })
    }

    @Test
    func toolNode_allowedFolder_runsTheCallOnceMore() async throws {
        let log = CallLog()
        let (spec, context) = Self.toolContext { path, access in
            #expect(path == "/Users/someone/Desktop/Invoice.pdf")
            #expect(access == .read)
            return .allowOnce
        }
        let outcome = try await ToolNodeExecutor.run(spec: spec, context: context, runtime: Self.runtime(log: log))
        #expect(await log.count == 2)
        #expect(outcome.toolCallRecords.map(\.isError) == [true, false])
        #expect(outcome.output.objectValue?["destination"] == .string("/Users/someone/Desktop/Invoice.pdf"))
    }

    @Test
    func toolNode_deniedFolder_failsAsFolderDenied() async {
        let log = CallLog()
        let (spec, context) = Self.toolContext { _, _ in .deny }
        do {
            _ = try await ToolNodeExecutor.run(spec: spec, context: context, runtime: Self.runtime(log: log))
            Issue.record("expected the step to fail")
        } catch let recorded as RecordedNodeFailure {
            guard case WorkflowNodeError.toolFailed(_, let kind, _, let retryable)? = recorded.underlying as? WorkflowNodeError
            else {
                Issue.record("unexpected \(recorded.underlying)")
                return
            }
            #expect(kind == "folder_denied")
            #expect(!retryable)
            #expect(recorded.toolCallRecords.count == 1)
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(await log.count == 1)
    }

    @Test
    func toolNode_withoutACard_failsWithTheScopesMessage() async {
        let log = CallLog()
        let (spec, context) = Self.toolContext(grant: nil)
        do {
            _ = try await ToolNodeExecutor.run(spec: spec, context: context, runtime: Self.runtime(log: log))
            Issue.record("expected the step to fail")
        } catch let recorded as RecordedNodeFailure {
            guard case WorkflowNodeError.toolFailed(_, let kind, let message, _)? = recorded.underlying as? WorkflowNodeError
            else {
                Issue.record("unexpected \(recorded.underlying)")
                return
            }
            #expect(kind == "rejected")
            #expect(message.contains("outside the folders this workflow may use"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(await log.count == 1)
    }

    @Test
    func grantDecision_readsLabelsAndRawValues() {
        #expect(WorkflowFolderGrantDecision(answer: .string("allow_always")) == .allowAlways)
        #expect(WorkflowFolderGrantDecision(answer: .string(WorkflowFolderGrantDecision.allowOnce.label)) == .allowOnce)
        #expect(WorkflowFolderGrantDecision(answer: .string("nope")) == nil)
        #expect(FolderRequirement.grantRoot(for: "/tmp/does-not-exist/a.pdf").path == "/tmp/does-not-exist")
    }
}

/// The runner's card: "Always allow" persists through the request, and the
/// folder is granted to later attempts of the run.
extension DialogSharedQueueTests {
struct WorkflowFolderGrantCardTests {

    @Test
    func alwaysAllow_persistsTheFolder_andGrantsIt() async throws {
        await MainActor.run { DialogCoordinator.shared.resetForTesting() }
        let folder = WF.tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("Invoice.pdf").path
        let persisted = PersistedPaths()
        var def = WorkflowDefinition(
            inputSchema: WF.object([:]),
            nodes: [
                WorkflowNode(
                    id: "save", name: "Save PDF", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_copy"))),
                    input: .object(["destination": target]), outputSchema: .object([:]))
            ])
        def.output = .object([:])
        let request = WorkflowRunner.Request(
            workflowID: UUID(), workflowName: "Invoices", template: WF.template(def),
            caller: WorkflowCaller(kind: .test), input: .object([:]), workspace: WF.tempDir(),
            persistFolderGrant: { path, _ in await persisted.add(path) })
        let runner = WorkflowRunner(
            request: request,
            executor: ClosureExecutor { context, _ in
                let ask = try #require(context.requestFolderGrant)
                let decision = try await ask(target, .write)
                #expect(decision == .allowAlways)
                return WorkflowNodeOutcome(output: .object([:]))
            })
        let running = Task { await runner.execute() }

        var dialog: PendingDialog?
        for _ in 0 ..< 2000 {
            dialog = await MainActor.run { DialogCoordinator.shared.pending.first }
            if dialog != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let shown = try #require(dialog)
        #expect(shown.nodeID == "save#folder-grant")
        #expect(shown.fields.map(\.key) == [WorkflowFolderGrantCoordinator.decisionKey])
        let answered = await MainActor.run {
            DialogCoordinator.shared.answer(
                shown.id, values: [WorkflowFolderGrantCoordinator.decisionKey: .string(WorkflowFolderGrantDecision.allowAlways.label)])
        }
        #expect((try? answered.get()) != nil)

        let run = await running.value
        #expect(run.status == .completed, Comment(rawValue: String(describing: run.error)))
        #expect(await persisted.paths == [folder.standardized.path])
        #expect(run.node("save")?.logs.contains { $0.contains(folder.standardized.path) } == true)
        await MainActor.run { DialogCoordinator.shared.resetForTesting() }
    }
}
}

private actor FolderContextBox {
    var value: WorkflowNodeContext?
    func set(_ context: WorkflowNodeContext) { value = context }
}

private actor PersistedPaths {
    var paths: [String] = []
    func add(_ path: String) { paths.append(path) }
}
