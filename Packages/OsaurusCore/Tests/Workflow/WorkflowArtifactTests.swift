//
//  WorkflowArtifactTests.swift
//  OsaurusCoreTests
//
//  Files a run hands the person: the run record's JSON, path resolution
//  inside the run's folders (sandbox home included), `share_artifact` in
//  tool and agentic steps, the output's `format: "file"` fields, the
//  runner collecting both, the copy into a calling chat, and what the
//  calling model and the Architect are told.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowArtifactTests {

    private static func remove(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private static func scope(root: URL, workspace: URL, granted: [URL] = []) -> WorkflowFileScope {
        WorkflowFileScope(folderRoot: root, workspace: workspace, granted: granted)
    }

    private static func shareResult(_ arguments: String) async throws -> String {
        try await ShareArtifactTool().execute(argumentsJSON: arguments)
    }

    // MARK: - Run record

    @Test
    func run_artifactsRoundTrip_andOldRecordsDecodeWithout() throws {
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "Invoices", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .user), input: .object([:]), nodeIDs: ["save"])
        let plain = try JSONEncoder().encode(run)
        #expect(JSONValue.parse(String(decoding: plain, as: UTF8.self))?.objectValue?["artifacts"] == nil)
        #expect(try JSONDecoder().decode(WorkflowRun.self, from: plain).artifacts.isEmpty)

        run.artifacts = [
            WorkflowArtifact(
                id: "output:pdf", source: .output, field: "pdf", filename: "Invoice.pdf", path: "/tmp/Invoice.pdf",
                fileSize: 3)
        ]
        let decoded = try JSONDecoder().decode(WorkflowRun.self, from: try JSONEncoder().encode(run))
        #expect(decoded == run)
        #expect(decoded.artifacts.first?.mimeType == "application/pdf")
    }

    // MARK: - Scope

    @Test
    func scope_resolvesInsideTheRunsFolders_andRefusesTheRest() throws {
        let root = WF.tempDir()
        let workspace = WF.tempDir()
        let granted = WF.tempDir()
        let outside = WF.tempDir()
        defer { Self.remove(root, workspace, granted, outside) }
        for (dir, name) in [(root, "a.txt"), (workspace, "b.txt"), (granted, "c.txt"), (outside, "d.txt")] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        let scope = Self.scope(root: root, workspace: workspace, granted: [granted])
        func resolved(_ path: String) -> String? { try? scope.resolve(path).get().lastPathComponent }

        #expect(resolved("a.txt") == "a.txt")
        #expect(resolved("b.txt") == "b.txt")
        #expect(resolved(granted.appendingPathComponent("c.txt").path) == "c.txt")
        #expect(scope.resolve(outside.appendingPathComponent("d.txt").path) == .failure(.outside(
            outside.appendingPathComponent("d.txt").standardized.path)))
        guard case .failure(.outside) = scope.resolve("../\(outside.lastPathComponent)/d.txt") else {
            Issue.record("a relative escape must be refused")
            return
        }
        guard case .failure(.notFound) = scope.resolve("missing.txt") else {
            Issue.record("a missing file inside the scope is not found")
            return
        }
    }

    @Test
    func scope_mapsTheSandboxRunWorkspaceToItsHostShare() throws {
        let workspace = WF.tempDir()
        defer { Self.remove(workspace) }
        try Data("mp4".utf8).write(to: workspace.appendingPathComponent("clip.mp4"))
        let inVM = "/workspace/agents/wf-test/runs/r1"
        let sandbox = WorkflowSandboxContext(
            environmentID: UUID(), bridge: SandboxReadBridge(agentName: "wf-test", home: "/workspace/agents/wf-test"),
            inVMWorkingDirectory: inVM)
        let scope = WorkflowFileScope(folderRoot: workspace, workspace: workspace, granted: [], sandbox: sandbox)
        let url = try scope.resolve(inVM + "/clip.mp4").get()
        #expect(url.lastPathComponent == "clip.mp4")
        #expect(FileManager.default.contents(atPath: url.path) == Data("mp4".utf8))
    }

    // MARK: - share_artifact

    @Test
    func share_inlineContent_isSavedIntoTheRunsFiles() async throws {
        let workspace = WF.tempDir()
        let store = WF.tempDir()
        defer { Self.remove(workspace, store) }
        let raw = try await Self.shareResult(
            ##"{"content": "# Summary\nAll paid.", "filename": "summary.md", "description": "Run summary"}"##)
        let shared = WorkflowArtifactCollector.share(
            raw, nodeID: "write", scope: Self.scope(root: workspace, workspace: workspace), into: store)
        let artifact = try #require(shared.artifact)
        #expect(artifact.source == .shared)
        #expect(artifact.nodeID == "write")
        #expect(artifact.filename == "summary.md")
        #expect(artifact.mimeType == "text/markdown")
        #expect(artifact.description == "Run summary")
        let saved = String(decoding: FileManager.default.contents(atPath: artifact.path) ?? Data(), as: UTF8.self)
        #expect(saved.trimmingCharacters(in: .newlines) == "# Summary\nAll paid.")
        #expect(!ToolEnvelope.isError(shared.modelResult))
        #expect(!shared.modelResult.contains("SHARED_ARTIFACT"))

        let again = WorkflowArtifactCollector.share(
            raw, nodeID: "write", scope: Self.scope(root: workspace, workspace: workspace), into: store)
        #expect(again.artifact?.filename == "summary 2.md")
    }

    @Test
    func share_path_copiesAFileFromTheWorkspace_andRefusesOneOutside() async throws {
        let workspace = WF.tempDir()
        let outside = WF.tempDir()
        let store = WF.tempDir()
        defer { Self.remove(workspace, outside, store) }
        try Data("pdf".utf8).write(to: workspace.appendingPathComponent("Invoice.pdf"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("notes.txt"))
        let scope = Self.scope(root: workspace, workspace: workspace)

        let copied = WorkflowArtifactCollector.share(
            try await Self.shareResult(#"{"path": "Invoice.pdf"}"#), nodeID: "save", scope: scope, into: store)
        let artifact = try #require(copied.artifact)
        #expect(artifact.path.hasPrefix(SharedArtifact.canonicalizedURL(store).path) || artifact.path.hasPrefix(store.path))
        #expect(artifact.fileSize == 3)
        #expect(FileManager.default.contents(atPath: artifact.path) == Data("pdf".utf8))

        let refused = WorkflowArtifactCollector.share(
            try await Self.shareResult(
                JSONValue.object(["path": .string(outside.appendingPathComponent("notes.txt").path)]).compactJSONString),
            nodeID: "save", scope: scope, into: store)
        #expect(refused.artifact == nil)
        #expect(ToolEnvelope.isError(refused.modelResult))
        #expect(refused.modelResult.contains("outside the folders this workflow may use"))

        let plain = ToolEnvelope.success(tool: "share_artifact", text: "no markers")
        #expect(WorkflowArtifactCollector.share(plain, nodeID: "save", scope: scope, into: store).modelResult == plain)
    }

    @Test
    func toolStep_shareArtifact_addsTheFile_andOutputsItsPath() async throws {
        try await StoragePathsTestLock.shared.run {
            let workspace = WF.tempDir()
            defer { Self.remove(workspace) }
            try Data("pdf".utf8).write(to: workspace.appendingPathComponent("Invoice.pdf"))
            let input: JSONValue = .object(["path": .string("Invoice.pdf")])
            let node = WorkflowNode(
                id: "share", name: "Share", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "share_artifact"))),
                input: .object(["path": "Invoice.pdf"]), outputSchema: .object([:]))
            let context = WorkflowNodeContext(
                runID: UUID(), workflowID: UUID(), workflowName: "Invoices", node: node, input: input,
                bindings: BindingContext(input: input), model: nil, secretAccounts: [:],
                caller: WorkflowCaller(kind: .user), workspace: workspace, attempt: 1, timeout: 60)
            let runtime = ToolNodeExecutor.Runtime(
                resolve: { name in
                    ToolNodeExecutor.Resolved(
                        spec: Tool(type: "function", function: ToolFunction(name: name, description: name, parameters: nil)),
                        outputSchema: nil)
                },
                execute: { _, arguments, _ in try await ShareArtifactTool().execute(argumentsJSON: arguments) })
            let outcome = try await ToolNodeExecutor.run(
                spec: ToolNodeSpec(tool: ToolRef(name: "share_artifact")), context: context, runtime: runtime)
            defer { Self.remove(OsaurusPaths.workflowRunArtifacts(workflowID: context.workflowID, runID: context.runID)) }

            let artifact = try #require(outcome.artifacts.first)
            #expect(artifact.filename == "Invoice.pdf")
            #expect(outcome.output.objectValue?["path"] == .string(artifact.path))
            #expect(outcome.toolCallRecords.first?.resultPreview?.contains("SHARED_ARTIFACT") == false)
        }
    }

    @Test
    func agenticStep_shareArtifact_addsTheFile_andTheModelSeesAConfirmation() async throws {
        try await StoragePathsTestLock.shared.run {
            actor Prompt {
                var text = ""
                func set(_ value: String) { text = value }
            }
            let prompt = Prompt()
            let spec = InferenceSpec(
                modelSlot: "main", instructions: "Write a report.",
                mode: .agentic(tools: [ToolRef(name: "share_artifact")], maxSteps: 3))
            let node = WorkflowNode(
                id: "report", name: "Report", kind: .inference(spec), input: .object([:]),
                outputSchema: WF.object(["summary": WF.string], required: ["summary"]))
            let context = WorkflowNodeContext(
                runID: UUID(), workflowID: UUID(), workflowName: "Reports", node: node, input: .object([:]),
                bindings: BindingContext(input: .object([:])), model: "openai/gpt-test", secretAccounts: [:],
                caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(), attempt: 1, timeout: 60)
            defer { Self.remove(OsaurusPaths.workflowRunArtifacts(workflowID: context.workflowID, runID: context.runID)) }
            let share = ToolCall(
                id: "c1", type: "function",
                function: ToolCallFunction(name: "share_artifact", arguments: #"{"content": "Done.", "filename": "report.txt"}"#))
            let runtime = AgenticNodeExecutor.Runtime(
                step: { _, messages, _ in
                    messages.contains { $0.role == "tool" } ? .init(text: "Shared.", calls: []) : .init(text: nil, calls: [share])
                },
                execute: { _, arguments, _ in (try? await ShareArtifactTool().execute(argumentsJSON: arguments)) ?? "" },
                finish: { _, text, _, _, _ in
                    await prompt.set(text)
                    return #"{"summary": "Report shared."}"#
                },
                specs: { names in
                    names.map { Tool(type: "function", function: ToolFunction(name: $0, description: $0, parameters: nil)) }
                })
            let outcome = try await AgenticNodeExecutor.run(
                spec: spec, tools: [ToolRef(name: "share_artifact")], maxSteps: 3, context: context, runtime: runtime)
            #expect(outcome.artifacts.map(\.filename) == ["report.txt"])
            let finalPrompt = await prompt.text
            #expect(finalPrompt.contains("is in this run's files"))
            #expect(!finalPrompt.contains("SHARED_ARTIFACT"))
        }
    }

    // MARK: - Output file fields

    @Test
    func outputFiles_readStringAndArrayFields_andKeepProblems() throws {
        let workspace = WF.tempDir()
        let outside = WF.tempDir()
        defer { Self.remove(workspace, outside) }
        try Data("a".utf8).write(to: workspace.appendingPathComponent("a.pdf"))
        try Data("b".utf8).write(to: workspace.appendingPathComponent("b.png"))
        let file: JSONValue = .object(["type": .string("string"), "format": .string("file")])
        let schema = WF.object(
            [
                "report": file, "images": .object(["type": .string("array"), "items": file]), "note": WF.string,
                "leak": file, "gone": file,
            ], required: ["report"])
        #expect(WorkflowArtifactCollector.fileFields(of: schema) == ["report", "gone", "images", "leak"])

        let output: JSONValue = .object([
            "report": .string("a.pdf"), "images": .array([.string("b.png")]), "note": .string("hi"),
            "leak": .string(outside.appendingPathComponent("x.txt").path), "gone": .string("missing.pdf"),
        ])
        let files = WorkflowArtifactCollector.outputFiles(
            output, schema: schema, scope: Self.scope(root: workspace, workspace: workspace))
        #expect(files.map(\.id) == ["output:report", "output:gone", "output:images", "output:leak"])
        #expect(files[0].isAvailable && files[0].fileSize == 1)
        #expect(files[1].problem?.contains("No file at") == true)
        #expect(files[2].filename == "b.png" && files[2].isAvailable)
        #expect(files[3].problem?.contains("outside the folders") == true)
    }

    @Test
    func runner_collectsSharedFilesThenOutputFiles() async throws {
        let workspace = WF.tempDir()
        defer { Self.remove(workspace) }
        let file: JSONValue = .object(["type": .string("string"), "format": .string("file")])
        let def = WorkflowDefinition(
            inputSchema: WF.object([:]), outputSchema: WF.object(["report": file], required: ["report"]),
            nodes: [
                WorkflowNode(
                    id: "make", name: "Make", kind: .code(CodeSpec(source: "async function run() { return {} }")),
                    input: .object([:]), outputSchema: .object([:]))
            ],
            output: .object(["report": "{{nodes.make.output.path}}"]))
        let request = WorkflowRunner.Request(
            workflowID: UUID(), workflowName: "Reports", template: WF.template(def),
            caller: WorkflowCaller(kind: .user), input: .object([:]), workspace: workspace)
        let runner = WorkflowRunner(
            request: request,
            executor: ClosureExecutor { context, _ in
                try Data("pdf".utf8).write(to: context.workspace.appendingPathComponent("report.pdf"))
                let shared = WorkflowArtifact(
                    source: .shared, nodeID: "make", filename: "notes.md", path: "/tmp/notes.md", fileSize: 1)
                return WorkflowNodeOutcome(output: .object(["path": .string("report.pdf")]), artifacts: [shared])
            })
        let run = await runner.execute()
        #expect(run.status == .completed, Comment(rawValue: String(describing: run.error)))
        #expect(run.artifacts.map(\.filename) == ["notes.md", "report.pdf"])
        #expect(run.artifacts.last?.source == .output)
        #expect(run.artifacts.last?.isAvailable == true)

        let summary = WorkflowTestTool.summary(run)
        let files = try #require(summary["files"] as? [[String: Any]])
        #expect(files.map { $0["filename"] as? String } == ["notes.md", "report.pdf"])
        #expect(files.last?["field"] as? String == "report")
    }

    // MARK: - Calling chat

    private static func finishedRun(caller: WorkflowCaller, file: URL) -> WorkflowRun {
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "Invoices", templateID: UUID(), templateVersion: 1, caller: caller,
            input: .object([:]), nodeIDs: [])
        run.status = .completed
        run.output = .object(["pdf": .string(file.path)])
        run.artifacts = [
            WorkflowArtifact(
                id: "output:pdf", source: .output, field: "pdf", filename: file.lastPathComponent, path: file.path,
                fileSize: 3),
            WorkflowArtifact(id: "output:gone", source: .output, filename: "gone.pdf", path: "", problem: "No file"),
        ]
        return run
    }

    @Test
    func forwarder_copiesTheFilesIntoTheCallingChat_andTellsTheModel() async throws {
        try await StoragePathsTestLock.shared.run {
            let folder = WF.tempDir()
            defer { Self.remove(folder) }
            let file = folder.appendingPathComponent("Invoice.pdf")
            try Data("pdf".utf8).write(to: file)
            let sessionID = UUID().uuidString
            defer {
                SpawnArtifactCollector.discard(sessionId: sessionID)
                Self.remove(OsaurusPaths.contextArtifactsDir(contextId: sessionID))
            }
            let run = Self.finishedRun(caller: WorkflowCaller(kind: .agent, sessionID: sessionID), file: file)
            #expect(WorkflowArtifactForwarder.forwardable(run).map(\.filename) == ["Invoice.pdf"])

            WorkflowArtifactForwarder.forward(run)
            let attached = SpawnArtifactCollector.drain(sessionId: sessionID)
            #expect(attached.map(\.filename) == ["Invoice.pdf"])
            #expect(attached.first?.description == "Invoices")
            #expect(attached.first.map { FileManager.default.contents(atPath: $0.hostPath) } == Data("pdf".utf8))

            let result = WorkflowCallResult(run: run)
            #expect(result.filesShown == ["Invoice.pdf"])
            let envelope = WorkflowToolCall.envelope(result, workflow: "Invoices", tool: "workflow_invoices")
            #expect(envelope.contains("already sees Invoice.pdf"))
        }
    }

    @Test
    func forwarder_skipsTabsTestsAndOutsideCallers() throws {
        let file = URL(fileURLWithPath: "/tmp/Invoice.pdf")
        for caller in [
            WorkflowCaller(kind: .user),
            WorkflowCaller(kind: .test, sessionID: "architect"),
            WorkflowCaller(kind: .agent, sessionID: "http", isExternalSurface: true),
            WorkflowCaller(kind: .orchestrator),
        ] {
            let run = Self.finishedRun(caller: caller, file: file)
            #expect(WorkflowArtifactForwarder.forwardable(run).isEmpty, "\(caller.kind)")
            #expect(WorkflowCallResult(run: run).filesShown == nil)
        }
        var parked = Self.finishedRun(caller: WorkflowCaller(kind: .agent, sessionID: "chat"), file: file)
        parked.status = .awaitingUser
        #expect(WorkflowArtifactForwarder.forwardable(parked).isEmpty)
    }
}
