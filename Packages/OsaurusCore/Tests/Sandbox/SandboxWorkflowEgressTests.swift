//
//  SandboxWorkflowEgressTests.swift
//
//  A workflow step's network reaches only the hosts it declares, without
//  changing the pod's network for the agents beside it.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Sandbox workflow egress")
struct SandboxWorkflowEgressTests {

    @Test func proxyKeysOverrideTheCallersEnvironment() {
        let proxy = SandboxManager.proxyEnvironment(url: "http://tok:@192.168.64.1:3128")
        let merged = SandboxManager.mergedExecEnvironment(
            caller: ["https_proxy": "http://evil:1", "HTTP_PROXY": "", "PATH": "/x"], proxy: proxy)
        #expect(merged["https_proxy"] == "http://tok:@192.168.64.1:3128")
        #expect(merged["HTTP_PROXY"] == "http://tok:@192.168.64.1:3128")
        #expect(merged["PATH"] == "/x")
        // No proxy: the caller's env is untouched.
        #expect(SandboxManager.mergedExecEnvironment(caller: ["A": "1"], proxy: [:]) == ["A": "1"])
    }

    @Test func aStepWithNoProxyRunningGetsAnAddressNothingListensOn() async {
        let scoped = await SandboxManager.shared.egressProxyEnvironment(
            forLinuxUser: "agent-wf-\(UUID().uuidString.lowercased())", stepHosts: ["api.example.com"])
        #expect(scoped.env["https_proxy"] == "http://127.0.0.1:9")
        #expect(scoped.env["HTTP_PROXY"] == "http://127.0.0.1:9")
        #expect(scoped.stepToken == nil)

        // Outside a step, an unfiltered pod adds nothing.
        let plain = await SandboxManager.shared.egressProxyEnvironment(forLinuxUser: "agent-wf-x")
        #expect(plain.env.isEmpty)
    }

    @Test func credentialsAreScrubbedFromExecOutputAndBridgeLogs() {
        let token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_abcd"
        let result = ContainerExecResult(
            stdout: "https_proxy=http://\(token):@192.168.64.1:3128\n", stderr: "token \(token)", exitCode: 0,
            outputTruncated: true
        ).scrubbed(["OSAURUS_PROXY_TOKEN": token])
        #expect(!result.stdout.contains(token) && !result.stderr.contains(token))
        #expect(result.stdout.contains("[REDACTED:OSAURUS_PROXY_TOKEN]"))
        #expect(result.outputTruncated)

        let secrets = HostBridgeRequests.logScrubSecrets(agentId: UUID(), bridgeToken: token)
        #expect(SecretScrubber.scrub("env: \(token)", secrets: secrets) == "env: [REDACTED:OSAURUS_BRIDGE_TOKEN]")
    }

    @Test func seatbeltDropsTheNetworkForAStepWithNoHosts() {
        #expect(SandboxManager.seatbeltNetwork(.allowed, stepHosts: nil) == .allowed)
        #expect(SandboxManager.seatbeltNetwork(.allowed, stepHosts: []) == .denied)
        // Invalid patterns count as none.
        #expect(SandboxManager.seatbeltNetwork(.allowed, stepHosts: ["10.0.0.1"]) == .denied)
        #expect(SandboxManager.seatbeltNetwork(.allowed, stepHosts: ["api.example.com"]) == .allowed)
        #expect(SandboxManager.seatbeltNetwork(.denied, stepHosts: ["api.example.com"]) == .denied)
    }

    @MainActor
    @Test func workflowMembersStayOpenForPodComposition() {
        let member = OsaurusPaths.workflowSandboxAgentName(environmentID: UUID())
        #expect(SandboxManager.egressMode(forMember: member) == .open)
        #expect(SandboxEgressPolicy.podNetwork(for: [.open, SandboxManager.egressMode(forMember: member)]) == .nat)
    }

    @Test func pythonStepsBindTheirDeclaredHosts() async throws {
        let seen = HostsBox()
        let runtime = ToolNodeExecutor.Runtime(
            resolve: { name in
                ToolNodeExecutor.Resolved(
                    spec: Tool(type: "function", function: ToolFunction(name: name, description: name, parameters: nil)),
                    outputSchema: nil)
            },
            execute: { _, _, _ in
                await seen.append(SandboxStepScope.hosts)
                return ToolEnvelope.success(tool: "shell_run", result: ["exit_code": 1, "stdout": "", "stderr": "x"])
            })
        for hosts in [[], ["api.example.com"]] {
            let node = WorkflowNode(
                id: "py", name: "Py",
                kind: .code(CodeSpec(language: .python, source: "def run(input, ctx):\n    return {}\n", network: hosts)))
            guard case .code(let spec) = node.kind else { return }
            let context = WorkflowNodeContext(
                runID: UUID(), workflowID: UUID(), workflowName: "Py", node: node, input: .object([:]),
                bindings: BindingContext(input: .object([:]), outputs: [:]), model: nil, secretAccounts: [:],
                caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(), attempt: 1, timeout: 30)
            _ = try? await PythonCodeNodeExecutor.run(spec: spec, context: context, runtime: runtime)
        }
        #expect(await seen.values == [[], ["api.example.com"]])
        #expect(SandboxStepScope.hosts == nil)
    }

    // MARK: - Python limits and secrets

    @Test func pythonRunsUnderAMemoryCapAndAWallClock() {
        let command = PythonCodeNodeExecutor.guestCommand(main: "/w/main.py", timeoutSeconds: 12, memoryLimitMB: 512)
        #expect(command.contains("ulimit -v 524288"))
        #expect(command.contains("timeout -s KILL 12 python3 '/w/main.py'"))
        #expect(command.contains("alarm shift; exec @ARGV' 12 python3 '/w/main.py'"))
        #expect(PythonCodeNodeExecutor.killedByTimeLimit(exitCode: 137))
        #expect(PythonCodeNodeExecutor.killedByTimeLimit(exitCode: 142))
        #expect(!PythonCodeNodeExecutor.killedByTimeLimit(exitCode: 1))
    }

    @Test func pythonSecretsRideTheEnvironmentNotTheWorkspace() async throws {
        let source = """
            import os
            def run(input, ctx):
                return {"key": ctx.secrets.get("API_KEY"), "leaked": "OSAURUS_STEP_SECRETS" in os.environ}
            """
        let node = WorkflowNode(
            id: "py", name: "Py", kind: .code(CodeSpec(language: .python, source: source, secrets: ["API_KEY"])))
        guard case .code(let spec) = node.kind else { return }
        let workspace = WF.tempDir()
        let bundle = PythonCodeNodeExecutor.bundleDirectory(workspace: workspace, nodeID: "py", attempt: 1)
        let sawFile = HostsBox()
        let runtime = ToolNodeExecutor.Runtime(
            resolve: { name in
                ToolNodeExecutor.Resolved(
                    spec: Tool(type: "function", function: ToolFunction(name: name, description: name, parameters: nil)),
                    outputSchema: nil)
            },
            execute: { _, arguments, _ in
                let files = (try? FileManager.default.contentsOfDirectory(atPath: bundle.path)) ?? []
                await sawFile.append(files.sorted())
                let command = JSONValue.parse(arguments)?.objectValue?["command"]?.stringValue ?? ""
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                process.environment = ProcessInfo.processInfo.environment.merging(SandboxStepScope.environment) { _, s in s }
                let err = Pipe()
                process.standardError = err
                try process.run()
                process.waitUntilExit()
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return ToolEnvelope.success(
                    tool: "shell_run", result: ["exit_code": Int(process.terminationStatus), "stdout": "", "stderr": stderr])
            })
        let context = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "Py", node: node, input: .object([:]),
            bindings: BindingContext(input: .object([:]), outputs: [:]), model: nil, secretAccounts: [:],
            secrets: ["API_KEY": "sk-test-123456", "OTHER": "not-declared"], caller: WorkflowCaller(kind: .user),
            workspace: workspace, attempt: 1, timeout: 30)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
        let outcome = try await PythonCodeNodeExecutor.run(spec: spec, context: context, runtime: runtime)
        #expect(outcome.output.value(atPath: "key") == .string("sk-test-123456"))
        #expect(outcome.output.value(atPath: "leaked") == .bool(false))
        let files = await sawFile.values.first ?? nil
        #expect(files == ["ctx.json", "input.json", "main.py", "step.py"])
    }

    @Test func aPythonStepPastItsTimeLimitIsStopped() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
        let node = WorkflowNode(
            id: "py", name: "Py",
            kind: .code(
                CodeSpec(language: .python, source: "import time\ndef run(input, ctx):\n    time.sleep(5)\n", timeout: 1)))
        guard case .code(let spec) = node.kind else { return }
        let runtime = ToolNodeExecutor.Runtime(
            resolve: { name in
                ToolNodeExecutor.Resolved(
                    spec: Tool(type: "function", function: ToolFunction(name: name, description: name, parameters: nil)),
                    outputSchema: nil)
            },
            execute: { _, arguments, _ in
                let command = JSONValue.parse(arguments)?.objectValue?["command"]?.stringValue ?? ""
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                process.standardError = Pipe()
                try process.run()
                process.waitUntilExit()
                // The shell reports a signalled child as 128 + signal.
                let code =
                    process.terminationReason == .uncaughtSignal
                    ? 128 + Int(process.terminationStatus) : Int(process.terminationStatus)
                return ToolEnvelope.success(tool: "shell_run", result: ["exit_code": code, "stdout": "", "stderr": ""])
            })
        let context = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "Py", node: node, input: .object([:]),
            bindings: BindingContext(input: .object([:]), outputs: [:]), model: nil, secretAccounts: [:],
            caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(), attempt: 1, timeout: 30)
        let started = Date()
        do {
            _ = try await PythonCodeNodeExecutor.run(spec: spec, context: context, runtime: runtime)
            Issue.record("expected the time limit to stop the step")
        } catch let failure as RecordedNodeFailure {
            #expect(String(describing: failure.underlying).contains("1-second limit"))
        }
        #expect(Date().timeIntervalSince(started) < 4)
    }
}

private actor HostsBox {
    var values: [[String]?] = []
    func append(_ value: [String]?) { values.append(value) }
}
