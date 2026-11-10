//
//  ToolApprovalPresentationTests.swift
//  OsaurusCoreTests
//
//  What the approval sheet says: plain titles instead of tool names, the
//  workflow step's reason only inside a step, a short command preview with
//  the full command one click away, and "Enforced" rows only for
//  protections the call's routing and the sandbox configuration back.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ToolApprovalPresentationTests {

    private static let modelDescription = """
        Run a shell command inside the agent's **sandbox** VM. Use `background: true` for servers.

        Prefer `sandbox_read_file` for reading files.
        """

    private func make(
        _ toolName: String,
        _ arguments: String,
        description: String = Self.modelDescription,
        forModel: Bool = true,
        surface: ToolExecutionSurface? = .sandboxVM,
        reason: String? = nil,
        sandbox: ToolApprovalPresentation.SandboxFacts? = .init(cpus: 2, memoryGB: 4, network: .open)
    ) -> ToolApprovalPresentation {
        ToolApprovalPresentation.make(
            toolName: toolName, description: description, descriptionIsForModel: forModel,
            argumentsJSON: arguments, surface: surface, stepReason: reason, sandbox: sandbox)
    }

    // MARK: - Titles

    @Test
    func shellTitles_nameTheActionNotTheTool() {
        let cases: [(String, String)] = [
            ("python3 /workspace/runs/convert/main.py --in a.csv", "Run a Python script"),
            ("cd /workspace && python3 -c 'print(1)'", "Run Python code"),
            ("pip install pandas openpyxl", "Install Python packages"),
            ("python3 -m pip install -r requirements.txt", "Install Python packages"),
            ("npm install && node build.js", "Install Node packages"),
            ("node scripts/serve.js", "Run a Node script"),
            ("apk add ffmpeg", "Install system packages"),
            ("ls -la /workspace", "Run a shell command"),
        ]
        for (command, title) in cases {
            let json = try! String(
                decoding: JSONSerialization.data(withJSONObject: ["command": command]), as: UTF8.self)
            #expect(make("shell_run", json).title == title, "\(command)")
            #expect(make("sandbox_exec", json).title == title, "\(command)")
        }
    }

    @Test
    func curatedTitles_coverFileAndImageTools_andOthersAreHumanized() {
        #expect(make("file_write", #"{"path":"a.txt"}"#).title == "Write a file")
        #expect(make("image", #"{"prompt":"a fox"}"#).title == "Generate an image")
        #expect(make("image", #"{"prompt":"brighter","source_paths":["a.png"]}"#).title == "Edit an image")
        let uncurated = ToolDisplayName.approvalTitle(for: "linear_create_issue", arguments: nil)
        #expect(uncurated.curated == false)
        #expect(uncurated.title == "Linear create issue")
    }

    // MARK: - Summary

    @Test
    func modelDescription_isHiddenForCuratedTools_andShortenedForOthers() {
        #expect(make("shell_run", #"{"command":"ls"}"#).summary == nil)
        let mcp = make("linear_create_issue", #"{"title":"Bug"}"#, surface: .remoteServer, sandbox: nil)
        #expect(mcp.summary == "Run a shell command inside the agent's sandbox VM.")
        #expect(mcp.summary?.contains("**") == false)
        #expect(mcp.summary?.contains("`") == false)
    }

    @Test
    func userFacingDescription_isShownAsWritten() {
        let text = "This call costs about $0.04 on your Router account."
        #expect(make("image", "{}", description: text, forModel: false, surface: nil, sandbox: nil).summary == text)
    }

    // MARK: - Preview and details

    @Test
    func commandPreview_isOneShortLine_andTheSheetGetsTheFullCommand() {
        let command =
            "cd /workspace/runs/2026-11-08/convert-batch &&\n  python3 /workspace/runs/2026-11-08/convert-batch/main.py"
            + " --input /workspace/in/reports/q3.xlsx --format csv"
        let presentation = make("shell_run", try! jsonObject(["command": command]))
        let preview = presentation.preview ?? ""
        #expect(!preview.contains("\n"))
        #expect(preview.count <= 72)
        #expect(preview.hasPrefix("cd …/2026-11-08/convert-batch &&"))
        #expect(preview.hasSuffix("…"))
        #expect(presentation.fullDetail == command)
        #expect(presentation.isShell)
    }

    @Test
    func toolDetails_arePrettyJSONWithoutEscapedSlashes() {
        let presentation = make(
            "file_write", #"{"path":"\/Users\/me\/Documents\/notes\/today.md","content":"hi"}"#,
            surface: .nativeHost, sandbox: nil)
        #expect(presentation.preview == "…/notes/today.md")
        #expect(!presentation.isShell)
        let detail = presentation.fullDetail ?? ""
        #expect(!detail.contains(#"\/"#))
        #expect(detail.contains("/Users/me/Documents/notes/today.md"))
        #expect(make("notify", "{}", surface: nil, sandbox: nil).fullDetail == nil)
    }

    @Test
    func shortenedPath_keepsShortPathsAndURLs() {
        #expect(ToolApprovalPresentation.shortenedPath("main.py") == "main.py")
        #expect(ToolApprovalPresentation.shortenedPath("src/main.py") == "src/main.py")
        #expect(ToolApprovalPresentation.shortenedPath("https://pypi.org/simple/x") == "https://pypi.org/simple/x")
        #expect(ToolApprovalPresentation.shortenedPath("\"/a/b/c/d.txt\"") == "\"…/c/d.txt\"")
    }

    // MARK: - Reason

    @Test
    func reason_isTheStepReasonOnly() {
        #expect(make("shell_run", #"{"command":"ls"}"#).reason == nil)
        #expect(make("shell_run", #"{"command":"ls"}"#, reason: "  ").reason == nil)
        #expect(
            make("shell_run", #"{"command":"ls"}"#, reason: " Convert the report to CSV ").reason
                == "Convert the report to CSV")
    }

    @Test
    func workflowNode_reasonIsItsIntentElseItsName() {
        let withIntent = WorkflowNode(id: "a", name: "Convert", intent: "Turn the report into CSV", kind: nil)
        #expect(withIntent.approvalReason == "Turn the report into CSV")
        let nameOnly = WorkflowNode(id: "b", name: "Convert", intent: "  ", kind: nil)
        #expect(nameOnly.approvalReason == "Convert")
    }

    @Test
    func workflowStepBinding_carriesTheReasonToTheApprovalCall() async throws {
        let node = WorkflowNode(id: "step", name: "Convert", intent: "Turn the report into CSV", kind: nil)
        let context = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "W", node: node, input: .object([:]),
            bindings: BindingContext(input: .object([:])), model: nil, secretAccounts: [:],
            caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(), attempt: 1, timeout: 30)
        let seen = try await WorkflowExecutionContext.bind(context) { ChatExecutionContext.currentWorkflowStepReason }
        #expect(seen == "Turn the report into CSV")
        #expect(ChatExecutionContext.currentWorkflowStepReason == nil)
    }

    // MARK: - Guarantees

    @Test
    func sandboxGuarantees_comeFromTheRealConfiguration() {
        let rows = make("shell_run", #"{"command":"ls"}"#).guarantees
        #expect(rows.map(\.title) == ["Inside the sandbox only", "Up to 2 CPUs and 4 GB memory"])
        #expect(rows.allSatisfy { $0.kind == .enforced })

        let single = make(
            "shell_run", #"{"command":"ls"}"#, sandbox: .init(cpus: 1, memoryGB: 2, network: .open))
        #expect(single.guarantees.map(\.title).contains("Up to 1 CPU and 2 GB memory"))
    }

    @Test
    func networkGuarantee_onlyWhenThePolicyIsKnown() {
        func titles(_ network: ToolApprovalPresentation.SandboxFacts.Network) -> [String] {
            make("shell_run", #"{"command":"ls"}"#, sandbox: .init(cpus: 2, memoryGB: 2, network: network))
                .guarantees.map(\.title)
        }
        #expect(titles(.none).contains("No internet access"))
        #expect(titles(.limited).contains("Internet limited to approved sites"))
        #expect(!titles(.open).contains { $0.contains("nternet") })
        #expect(!titles(.unknown).contains { $0.contains("nternet") })
    }

    @Test
    func noSandboxFacts_meansNoResourceClaim() {
        let rows = make("shell_run", #"{"command":"ls"}"#, sandbox: nil).guarantees
        #expect(rows.map(\.title) == ["Inside the sandbox only"])
    }

    @Test
    func idleTimeout_isEnforcedOnlyWhenTheCallSetsIt_andNotInBackground() {
        let timed = make("shell_run", #"{"command":"make","timeout":45}"#).guarantees.map(\.title)
        #expect(timed.contains("Stopped after 45 seconds without output"))
        let background = make("shell_run", #"{"command":"make","timeout":45,"background":true}"#)
        #expect(!background.guarantees.contains { $0.icon == "clock" })
        #expect(!make("shell_run", #"{"command":"make"}"#).guarantees.contains { $0.icon == "clock" })
    }

    @Test
    func hostAndRemoteCalls_neverClaimEnforcement() {
        let host = make("file_write", #"{"path":"a.txt"}"#, surface: .nativeHost, sandbox: nil).guarantees
        #expect(host.map(\.kind) == [.caution])
        #expect(host.first?.title == "Runs on your Mac")

        let hostShell = make("shell_run", #"{"command":"ls"}"#, surface: .nativeHost, sandbox: nil)
        #expect(hostShell.guarantees.isEmpty)
        #expect(hostShell.risk?.findings.map(\.signal).contains(.changesMac) == true)

        let remote = make("linear_create_issue", "{}", surface: .remoteServer, sandbox: nil).guarantees
        #expect(remote.map(\.kind) == [.note])
        #expect(make("notify", "{}", surface: nil, sandbox: nil).guarantees.isEmpty)
    }

    @Test
    func networkOff_turnsADownloadIntoAWillFailNote() {
        let risk = make(
            "shell_run", #"{"command":"pip install pandas"}"#,
            sandbox: .init(cpus: 2, memoryGB: 2, network: .none)
        ).risk
        let download = risk?.findings.first { $0.signal == .downloads }
        #expect(download?.title == "Tries to download from the internet")
    }

    // MARK: - Who is waiting, lease, and facts

    @Test
    func chatCall_namesTheAgentAndTheReply() {
        let shell = make("shell_run", #"{"command":"ls"}"#)
        #expect(shell.subtitle == "The agent is waiting for your approval.")
        #expect(shell.leaseActionTitle == "For the Rest of This Reply")
    }

    @Test
    func workflowCall_namesTheStepAndTheRun() {
        let shell = make("shell_run", #"{"command":"ls"}"#, reason: "Convert the PDFs")
        #expect(shell.subtitle == "A workflow step is waiting for your approval.")
        #expect(shell.leaseActionTitle == "For the Rest of This Run")
    }

    @Test
    func facts_putWarningsFirst_thenProtections_thenTheCleanChecks() {
        let host = PermissionFact.facts(
            for: make("shell_run", #"{"command":"rm -rf build"}"#, surface: .nativeHost, sandbox: nil))
        #expect(host.map(\.title) == ["Deletes files", "Runs on your Mac", "No admin rights or downloads"])
        #expect(host.map(\.tone) == [.warning, .warning, .clean])

        let sandboxed = PermissionFact.facts(
            for: make(
                "shell_run", #"{"command":"ls"}"#,
                sandbox: .init(cpus: 2, memoryGB: 4, network: .none)))
        #expect(sandboxed.map(\.tone) == [.protection, .protection, .protection, .clean])
        #expect(sandboxed.first?.title == "Inside the sandbox only")
        #expect(sandboxed.last?.title == "No file deletion, admin rights, or downloads")
    }

    @Test
    func facts_forAnUnreadableCommand_neverClaimClean() {
        let facts = PermissionFact.facts(for: make("shell_run", #"{"command":"eval \"$X\""}"#))
        #expect(facts.contains { $0.title == "Couldn't fully check this command" })
        #expect(!facts.contains { $0.tone == .clean })
    }

    // MARK: - Workflow scopes

    private static let dinos = URL(fileURLWithPath: "/Users/me/Downloads/dinos")
    private static let workspace = URL(fileURLWithPath: "/Users/me/.osaurus/container/workspace/agents/wf-1/runs/r1")

    @Test
    func workflowFacts_nameEachFolderWithWhatTheRunMayDoThere() {
        let facts = ToolApprovalPresentation.WorkflowFacts.make(
            granted: [Self.dinos], writable: [Self.workspace, Self.dinos.appendingPathComponent("png")],
            workspace: Self.workspace, asksBeforeReplacing: true)
        #expect(facts.accessList == "dinos (read), dinos/png (write)")

        let unnarrowed = ToolApprovalPresentation.WorkflowFacts.make(
            granted: [Self.dinos], writable: nil, workspace: nil, asksBeforeReplacing: false)
        #expect(unnarrowed.accessList == "dinos (write)")
    }

    @Test
    func workflowFileTool_listsItsFoldersInsteadOfRunsOnYourMac() {
        let facts = ToolApprovalPresentation.WorkflowFacts.make(
            granted: [Self.dinos], writable: [Self.workspace, Self.dinos.appendingPathComponent("png")],
            workspace: Self.workspace, asksBeforeReplacing: true)
        let copy = ToolApprovalPresentation.make(
            toolName: "file_copy", description: "", descriptionIsForModel: true,
            argumentsJSON: #"{"source":"out/a.png","destination":"/Users/me/Downloads/dinos/png/a.png"}"#,
            surface: .nativeHost, stepReason: "Deliver", sandbox: nil, workflow: facts)
        #expect(
            copy.guarantees.map(\.title)
                == ["Access to dinos (read), dinos/png (write)", "Asks before replacing a file", "No file deletion"])
        #expect(copy.guarantees.map(\.kind) == [.enforced, .enforced, .note])
        #expect(!copy.guarantees.contains { $0.title == "Runs on your Mac" })

        let read = ToolApprovalPresentation.make(
            toolName: "file_read", description: "", descriptionIsForModel: true, argumentsJSON: #"{"path":"a.svg"}"#,
            surface: .nativeHost, stepReason: "Look", sandbox: nil,
            workflow: .init(places: [], asksBeforeReplacing: true))
        #expect(read.guarantees.map(\.title) == ["Only this run's workspace"])

        let script = ToolApprovalPresentation.make(
            toolName: "applescript", description: "", descriptionIsForModel: true, argumentsJSON: "{}",
            surface: .nativeHost, stepReason: "Script", sandbox: nil, workflow: facts)
        #expect(script.guarantees.map(\.title) == ["Runs on your Mac"])
    }

    @Test
    func workflowSandboxCall_saysItCannotSeeTheChosenFolders() {
        let shell = ToolApprovalPresentation.make(
            toolName: "shell_run", description: "", descriptionIsForModel: true, argumentsJSON: #"{"command":"ls"}"#,
            surface: .sandboxVM, stepReason: "Convert", sandbox: nil,
            workflow: .init(places: [.init(name: "dinos", writes: false)], asksBeforeReplacing: true))
        #expect(shell.guarantees.map(\.title) == ["Inside the sandbox only", "Can't see the folders you chose"])
        #expect(shell.guarantees.first?.detail == "It sees only the sandbox's own folders, not the rest of your Mac.")
    }

    @Test
    func riskReport_onlyForShellCommands() {
        #expect(make("shell_run", #"{"command":"ls"}"#).risk != nil)
        #expect(make("file_write", #"{"path":"a"}"#).risk == nil)
    }

    private func jsonObject(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
