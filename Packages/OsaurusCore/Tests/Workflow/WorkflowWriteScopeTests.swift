//
//  WorkflowWriteScopeTests.swift
//  OsaurusCoreTests
//
//  A run's file tools save only where its definition says: the declared
//  subfolder of a picked folder, folders the person allowed saving in, and
//  the run's workspace. Replacing a file that already exists on this Mac
//  asks first, once per run or always.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowWriteScopeTests {

    /// `dinos/` with `a.svg` in it and an empty `dinos/png/`.
    private static func dinos() throws -> URL {
        let dinos = WF.tempDir().appendingPathComponent("dinos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dinos.appendingPathComponent("png"), withIntermediateDirectories: true)
        try Data("<svg/>".utf8).write(to: dinos.appendingPathComponent("a.svg"))
        return dinos
    }

    private static func inRun<T>(
        granted: [URL], writable: [URL]?, hooks: WorkflowHostFileHooks? = nil, _ body: () async throws -> T
    ) async rethrows -> T {
        try await ChatExecutionContext.$currentWorkflowRunId.withValue(UUID()) {
            try await ChatExecutionContext.$workflowGrantedPaths.withValue(granted) {
                try await ChatExecutionContext.$workflowWritableRoots.withValue(writable) {
                    try await ChatExecutionContext.$workflowHostFiles.withValue(hooks) { try await body() }
                }
            }
        }
    }

    @Test
    func writeIntent_staysInsideTheDeclaredSubfolder_whileReadsSeeTheWholeFolder() async throws {
        let dinos = try Self.dinos()
        let workspace = WF.tempDir()
        defer {
            try? FileManager.default.removeItem(at: dinos.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: workspace)
        }
        let png = dinos.appendingPathComponent("png")
        try await Self.inRun(granted: [dinos], writable: [workspace, png]) {
            let inside = try FolderToolHelpers.resolvePath(png.appendingPathComponent("a.png").path, rootPath: workspace, intent: .write)
            #expect(inside.lastPathComponent == "a.png")
            _ = try FolderToolHelpers.resolvePath(dinos.appendingPathComponent("a.svg").path, rootPath: workspace)
            _ = try FolderToolHelpers.resolvePath("out/a.png", rootPath: workspace, intent: .write)

            let target = dinos.appendingPathComponent("a.png").path
            do {
                _ = try FolderToolHelpers.resolvePath(target, rootPath: workspace, intent: .write)
                Issue.record("expected a write-scope error")
            } catch let error as FolderToolError {
                guard case .pathOutsideWorkflowWriteScope(_, let absolute, let writable) = error else {
                    Issue.record("unexpected \(error)")
                    return
                }
                #expect(absolute == URL(fileURLWithPath: target).standardized.path)
                #expect(writable.contains(png.standardized.path))
                let envelope = ToolEnvelope.fromError(error, tool: "file_write")
                #expect(ToolEnvelope.isError(envelope))
                #expect(WorkflowFolderGrant.requestedPath(in: envelope) == absolute)
                #expect(WorkflowFolderGrant.requestedAccess(in: envelope) == .write)
            }
        }
    }

    @Test
    func aReadOnlyFolder_refusesSaves_andAReadScopeErrorAsksToRead() async throws {
        let dinos = try Self.dinos()
        let workspace = WF.tempDir()
        let outside = WF.tempDir()
        defer {
            for url in [dinos.deletingLastPathComponent(), workspace, outside] { try? FileManager.default.removeItem(at: url) }
        }
        try await Self.inRun(granted: [dinos], writable: [workspace]) {
            #expect(throws: FolderToolError.self) {
                try FolderToolHelpers.resolvePath(
                    dinos.appendingPathComponent("png/a.png").path, rootPath: workspace, intent: .write)
            }
            do {
                _ = try FolderToolHelpers.resolvePath(outside.appendingPathComponent("x.txt").path, rootPath: workspace)
                Issue.record("expected an out-of-scope error")
            } catch let error as FolderToolError {
                #expect(WorkflowFolderGrant.requestedAccess(in: ToolEnvelope.fromError(error, tool: "file_read")) == .read)
            }
        }
    }

    @Test
    func aSymlinkInsideTheWritableFolder_cannotCarryASaveOutOfIt() async throws {
        let dinos = try Self.dinos()
        let workspace = WF.tempDir()
        defer {
            try? FileManager.default.removeItem(at: dinos.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: workspace)
        }
        let png = dinos.appendingPathComponent("png")
        try FileManager.default.createSymbolicLink(at: png.appendingPathComponent("up"), withDestinationURL: dinos)
        try await Self.inRun(granted: [dinos], writable: [workspace, png]) {
            #expect(throws: FolderToolError.self) {
                try FolderToolHelpers.resolvePath(
                    png.appendingPathComponent("up/a.png").path, rootPath: workspace, intent: .write)
            }
        }
    }

    @Test
    func outsideAWorkflowRun_writesAreNotNarrowed() throws {
        let dinos = try Self.dinos()
        defer { try? FileManager.default.removeItem(at: dinos.deletingLastPathComponent()) }
        try ChatExecutionContext.$currentWorkflowRunId.withValue(UUID()) {
            try ChatExecutionContext.$workflowGrantedPaths.withValue([dinos]) {
                _ = try FolderToolHelpers.resolvePath(
                    dinos.appendingPathComponent("a.png").path, rootPath: WF.tempDir(), intent: .write)
            }
        }
    }

    // MARK: - Replace gate through the real tools

    private actor Approvals {
        var asked: [String] = []
        var writes: [WorkflowHostWrite] = []
        func ask(_ file: URL) { asked.append(file.lastPathComponent) }
        func record(_ file: URL, _ replaced: Bool) { writes.append(WorkflowHostWrite(path: file.path, replaced: replaced)) }
    }

    private static func hooks(workspace: URL, approvals: Approvals, allow: Bool) -> WorkflowHostFileHooks {
        WorkflowHostFileHooks(
            workspace: workspace,
            approveReplace: { _, file in
                await approvals.ask(file)
                return allow
            },
            record: { file, replaced in await approvals.record(file, replaced) })
    }

    @Test
    func fileWrite_newFileIsRecorded_existingFileAsksFirst_andARefusalLeavesItAlone() async throws {
        let dinos = try Self.dinos()
        let workspace = WF.tempDir()
        defer {
            try? FileManager.default.removeItem(at: dinos.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: workspace)
        }
        let png = dinos.appendingPathComponent("png")
        let existing = png.appendingPathComponent("old.txt")
        try Data("keep".utf8).write(to: existing)
        let approvals = Approvals()
        let hooks = Self.hooks(workspace: workspace, approvals: approvals, allow: false)

        try await ChatExecutionContext.$currentFolderRoot.withValue(workspace) {
            try await Self.inRun(granted: [dinos], writable: [workspace, png], hooks: hooks) {
                let fresh = JSONValue.object([
                    "path": .string(png.appendingPathComponent("new.txt").path), "content": .string("hi"),
                ]).compactJSONString
                let created = try await FileWriteTool().execute(argumentsJSON: fresh)
                #expect(!ToolEnvelope.isError(created), Comment(rawValue: created))

                let scratch = JSONValue.object(["path": .string("scratch.txt"), "content": .string("x")]).compactJSONString
                _ = try await FileWriteTool().execute(argumentsJSON: scratch)

                let overwrite = JSONValue.object(["path": .string(existing.path), "content": .string("gone")]).compactJSONString
                do {
                    _ = try await FileWriteTool().execute(argumentsJSON: overwrite)
                    Issue.record("expected the replace to be refused")
                } catch let error as FolderToolError {
                    let envelope = ToolEnvelope.fromError(error, tool: "file_write")
                    #expect(WorkflowFolderGrant.isReplaceDenied(envelope))
                }
            }
        }
        #expect(await approvals.asked == ["old.txt"])
        #expect(await approvals.writes.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["new.txt"])
        #expect(await approvals.writes.first?.replaced == false)
        #expect(FileManager.default.contents(atPath: existing.path) == Data("keep".utf8))
    }

    @Test
    func fileCopy_overwritingAnApprovedFile_isRecordedAsReplaced() async throws {
        let dinos = try Self.dinos()
        let workspace = WF.tempDir()
        defer {
            try? FileManager.default.removeItem(at: dinos.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: workspace)
        }
        let png = dinos.appendingPathComponent("png")
        try Data("png".utf8).write(to: workspace.appendingPathComponent("a.png"))
        try Data("old".utf8).write(to: png.appendingPathComponent("a.png"))
        let approvals = Approvals()
        let hooks = Self.hooks(workspace: workspace, approvals: approvals, allow: true)
        let arguments = JSONValue.object([
            "source": .string("a.png"), "destination": .string(png.appendingPathComponent("a.png").path),
            "overwrite": .bool(true),
        ]).compactJSONString
        let result = try await ChatExecutionContext.$currentFolderRoot.withValue(workspace) {
            try await Self.inRun(granted: [dinos], writable: [workspace, png], hooks: hooks) {
                try await FileCopyTool().execute(argumentsJSON: arguments)
            }
        }
        #expect(!ToolEnvelope.isError(result), Comment(rawValue: result))
        #expect(await approvals.asked == ["a.png"])
        #expect(await approvals.writes.map(\.replaced) == [true])
        #expect(FileManager.default.contents(atPath: png.appendingPathComponent("a.png").path) == Data("png".utf8))
    }

    @Test
    func summaries_groupByFolder_andNameItUnderThePickedFolder() {
        let dinos = URL(fileURLWithPath: "/Users/me/Downloads/dinos")
        var writes = (1...12).map { WorkflowHostWrite(path: "/Users/me/Downloads/dinos/png/d\($0).png", replaced: false) }
        writes.append(WorkflowHostWrite(path: "/Users/me/Downloads/dinos/png/d1.png", replaced: true))
        writes.append(WorkflowHostWrite(path: "/Users/me/Downloads/dinos/notes.txt", replaced: true))
        let summaries = WorkflowHostWrite.summaries(writes, roots: [dinos])
        #expect(summaries.map(\.text) == ["Created 12 PNGs in dinos/png", "Replaced 1 TXT in dinos"])
        #expect(summaries.first?.files.count == 12)

        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "x", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .user), input: .object([:]), nodeIDs: [])
        run.hostWrites = [WorkflowHostWrite(path: "/tmp/a.png", replaced: false)]
        let decoded = try? JSONDecoder().decode(WorkflowRun.self, from: JSONEncoder().encode(run))
        #expect(decoded?.hostWrites == run.hostWrites)
    }

    // MARK: - Runner

    private static let folderInput: JSONValue = .object(["type": .string("string"), "format": .string("folder")])

    private static func deliverDefinition() -> WorkflowDefinition {
        var def = WorkflowDefinition(
            inputSchema: WF.object(["folder": folderInput], required: ["folder"]),
            nodes: [
                WorkflowNode(
                    id: "deliver", name: "Deliver", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_copy"))),
                    input: .object(["source": "a.png", "destination": "{{input.folder}}/png/a.png"]),
                    outputSchema: .object([:]))
            ])
        def.output = .object([:])
        return def
    }

    @Test
    func runner_bindsOnlyTheDeclaredTargetAndStandingSaveGrantsAsWritable() async throws {
        let dinos = try Self.dinos()
        let standing = WF.tempDir()
        let readOnly = WF.tempDir()
        defer {
            for url in [dinos.deletingLastPathComponent(), standing, readOnly] { try? FileManager.default.removeItem(at: url) }
        }
        var request = WorkflowRunner.Request(
            workflowID: UUID(), workflowName: "SVG to PNG", template: WF.template(Self.deliverDefinition()),
            caller: WorkflowCaller(kind: .test), input: .object(["folder": .string(dinos.path)]), workspace: WF.tempDir(),
            folderGrants: [standing.path])
        request.folderReadGrants = [readOnly.path]
        let seen = ScopeBox<WorkflowNodeContext>()
        let run = await WorkflowRunner(
            request: request,
            executor: ClosureExecutor { context, _ in
                await seen.set(context)
                return WorkflowNodeOutcome(output: .object([:]))
            }
        ).execute()
        #expect(run.status == .completed, Comment(rawValue: String(describing: run.error)))
        let context = try #require(await seen.value)
        let granted = context.grantedPaths.map(\.standardized.path)
        #expect(granted.contains(dinos.standardized.path))
        #expect(granted.contains(readOnly.standardized.path))
        let writable = (context.writableRoots ?? []).map(\.standardized.path)
        #expect(writable.contains(dinos.appendingPathComponent("png/a.png").standardized.path))
        #expect(!writable.contains(dinos.appendingPathComponent("png").standardized.path))
        #expect(writable.contains(standing.standardized.path))
        #expect(!writable.contains(dinos.standardized.path))
        #expect(!writable.contains(readOnly.standardized.path))
        #expect(context.hostFiles != nil)
    }

    @Test
    func runner_headlessCaller_refusesReplacesWithoutACard() async throws {
        let folder = WF.tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = WorkflowRunner.Request(
            workflowID: UUID(), workflowName: "SVG to PNG", template: WF.template(Self.deliverDefinition()),
            caller: WorkflowCaller(kind: .agent, isExternalSurface: true), input: .object(["folder": .string(folder.path)]),
            workspace: WF.tempDir())
        let answer = ScopeBox<Bool>()
        _ = await WorkflowRunner(
            request: request,
            executor: ClosureExecutor { context, _ in
                let hooks = try #require(context.hostFiles)
                await answer.set(try await hooks.approveReplace(folder, folder.appendingPathComponent("a.png")))
                return WorkflowNodeOutcome(output: .object([:]))
            }
        ).execute()
        #expect(await answer.value == false)
    }

    @Test
    func toolNode_replaceDenied_failsAsReplaceDenied() async {
        let spec = ToolNodeSpec(tool: ToolRef(name: "file_copy"))
        let node = WorkflowNode(id: "deliver", name: "Deliver", kind: .tool(spec), input: .object([:]))
        let context = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "SVG to PNG", node: node, input: .object([:]),
            bindings: BindingContext(input: .object([:])), model: nil, secretAccounts: [:],
            caller: WorkflowCaller(kind: .test), workspace: WF.tempDir(), requestFolderGrant: nil, attempt: 1, timeout: 60)
        let runtime = ToolNodeExecutor.Runtime(
            resolve: { name in
                ToolNodeExecutor.Resolved(
                    spec: Tool(type: "function", function: ToolFunction(name: name, description: name, parameters: nil)),
                    outputSchema: nil)
            },
            execute: { name, _, _ in
                ToolEnvelope.fromError(FolderToolError.replaceDenied(path: "/tmp/dinos/png/a.png", folder: "/tmp/dinos/png"), tool: name)
            })
        do {
            _ = try await ToolNodeExecutor.run(spec: spec, context: context, runtime: runtime)
            Issue.record("expected the step to fail")
        } catch let recorded as RecordedNodeFailure {
            guard case WorkflowNodeError.toolFailed(_, let kind, _, let retryable)? = recorded.underlying as? WorkflowNodeError
            else {
                Issue.record("unexpected \(recorded.underlying)")
                return
            }
            #expect(kind == "replace_denied")
            #expect(!retryable)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

/// The replace card: shown once per folder, "Always allow" persists, and
/// the run's result summary lists what was replaced.
extension DialogSharedQueueTests {
struct WorkflowReplaceCardTests {

    @Test
    func alwaysAllow_persists_andLaterReplacesInTheFolderDoNotAskAgain() async throws {
        await MainActor.run { DialogCoordinator.shared.resetForTesting() }
        let folder = WF.tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let persisted = ScopeBox<[String]>()
        var def = WorkflowDefinition(
            inputSchema: WF.object([:]),
            nodes: [
                WorkflowNode(
                    id: "deliver", name: "Deliver", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_copy"))),
                    input: .object(["destination": folder.appendingPathComponent("a.png").path]),
                    outputSchema: .object([:]))
            ])
        def.output = .object([:])
        var request = WorkflowRunner.Request(
            workflowID: UUID(), workflowName: "SVG to PNG", template: WF.template(def),
            caller: WorkflowCaller(kind: .test), input: .object([:]), workspace: WF.tempDir())
        request.persistReplaceGrant = { path in await persisted.append(path) }
        let answers = ScopeBox<[Bool]>()
        let runner = WorkflowRunner(
            request: request,
            executor: ClosureExecutor { context, _ in
                let hooks = try #require(context.hostFiles)
                await answers.append(try await hooks.approveReplace(folder, folder.appendingPathComponent("a.png")))
                await answers.append(try await hooks.approveReplace(folder, folder.appendingPathComponent("b.png")))
                await hooks.record(folder.appendingPathComponent("a.png"), true)
                await hooks.record(folder.appendingPathComponent("b.png"), true)
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
        #expect(shown.nodeID == "deliver#replace-grant")
        let answered = await MainActor.run {
            DialogCoordinator.shared.answer(
                shown.id,
                values: [WorkflowFolderGrantCoordinator.decisionKey: .string(WorkflowFolderGrantDecision.allowAlways.label)])
        }
        #expect((try? answered.get()) != nil)

        let run = await running.value
        #expect(run.status == .completed, Comment(rawValue: String(describing: run.error)))
        #expect(await answers.value == [true, true])
        #expect(await persisted.value == [folder.standardized.path])
        #expect(run.hostWrites.map(\.replaced) == [true, true])
        #expect(await MainActor.run { DialogCoordinator.shared.pending.isEmpty })
        await MainActor.run { DialogCoordinator.shared.resetForTesting() }
    }
}
}

private actor ScopeBox<Value: Sendable> {
    var value: Value?
    func set(_ value: Value) { self.value = value }
}

extension ScopeBox {
    func append<Element: Sendable>(_ element: Element) where Value == [Element] {
        value = (value ?? []) + [element]
    }
}
