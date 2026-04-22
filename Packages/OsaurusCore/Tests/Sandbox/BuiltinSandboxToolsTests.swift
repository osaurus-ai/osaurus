import Foundation
import Testing

@testable import OsaurusCore

/// Extract the `result` dict from a `ToolEnvelope.success` JSON output.
/// The sandbox tool suite asserts success-path payloads field-by-field,
/// so flatten to the old shape locally rather than threading envelope
/// access through every assertion.
private func successPayload(_ raw: String) throws -> [String: Any] {
    try #require(ToolEnvelope.successPayload(raw) as? [String: Any])
}

/// Extract the failure envelope fields for assertion on the failure path.
private func failurePayload(_ raw: String) throws -> [String: Any] {
    let data = try #require(raw.data(using: .utf8))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite(.serialized)
struct BuiltinSandboxToolsTests {
    @Test @MainActor
    func sandboxPipInstall_bootstrapsPythonAndReturnsInstalledOnSuccess() async throws {
        let runner = MockSandboxToolCommandRunner(
            rootResults: [.init(stdout: "", stderr: "", exitCode: 0)],
            agentResults: [.init(stdout: "installed ok", stderr: "", exitCode: 0)]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_pip_install",
                argumentsJSON: #"{"packages":["flask","pytest"]}"#
            )
        }

        let payload = try successPayload(output)
        let installed = try #require(payload["installed"] as? [String])
        #expect(installed == ["flask", "pytest"])
        #expect(payload["requested"] == nil)
        #expect(payload["exit_code"] as? Int == 0)

        let calls = await runner.calls
        #expect(calls.count == 2)
        #expect(calls[0] == .root("test -x /usr/bin/python3"))
        guard case .agent(_, let command) = calls[1] else {
            Issue.record("Expected agent install call")
            return
        }
        #expect(command.contains("/usr/bin/python3 -m venv"))
        #expect(command.contains(".venv/bin/python3"))
        #expect(command.contains("-m pip install flask pytest"))
    }

    @Test @MainActor
    func sandboxPipInstall_returnsErrorWhenPythonMissing() async throws {
        let runner = MockSandboxToolCommandRunner(
            rootResults: [.init(stdout: "", stderr: "", exitCode: 1)],
            agentResults: []
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_pip_install",
                argumentsJSON: #"{"packages":["flask","pytest"]}"#
            )
        }

        #expect(ToolEnvelope.isError(output))
        let payload = try failurePayload(output)
        #expect(payload["kind"] as? String == "unavailable")
        #expect(payload["message"] as? String == "python3 is not installed in the sandbox image")

        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls[0] == .root("test -x /usr/bin/python3"))
    }

    @Test @MainActor
    func sandboxNpmInstall_returnsFailureEnvelopeOnBadExit() async throws {
        let runner = MockSandboxToolCommandRunner(
            rootResults: [.init(stdout: "", stderr: "", exitCode: 0)],
            agentResults: [.init(stdout: "", stderr: "npm: not found", exitCode: 127)]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_npm_install",
                argumentsJSON: #"{"packages":["vite"]}"#
            )
        }

        // install-family failures surface the combined output + exit code
        // in the failure envelope `message` so the model can diagnose.
        #expect(ToolEnvelope.isError(output))
        let payload = try failurePayload(output)
        #expect(payload["kind"] as? String == "execution_error")
        let message = payload["message"] as? String ?? ""
        #expect(message.contains("exit 127"))
        #expect(message.contains("npm: not found"))

        let calls = await runner.calls
        #expect(calls.count == 2)
        #expect(calls[0] == .root("test -x /usr/bin/node && test -x /usr/bin/npm"))
    }

    @Test @MainActor
    func sandboxRunScript_pythonUsesPythonInterpreter() async throws {
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [],
            execResults: [.init(stdout: "ok", stderr: "", exitCode: 0)]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_run_script",
                argumentsJSON: #"{"language":"python","script":"print('hi')"}"#
            )
        }

        let payload = try successPayload(output)
        #expect(payload["exit_code"] as? Int == 0)
        // run_script now emits stdout/stderr split (matching sandbox_exec)
        // plus a `combined` field for callers that prefer the merged form.
        #expect((payload["stdout"] as? String)?.contains("ok") == true)
        #expect(payload["stderr"] as? String == "")
        #expect((payload["combined"] as? String)?.contains("ok") == true)
        #expect(payload["language"] as? String == "python")

        let calls = await runner.calls
        guard case .exec(let user, let command, let env) = try #require(calls.first) else {
            Issue.record("Expected exec call")
            return
        }
        #expect(user == "agent-test-agent")
        #expect(command.contains("python3"))
        #expect(command.contains(".tmp/script_"))
        #expect(env["VIRTUAL_ENV"]?.contains(".venv") == true)
        #expect(env["PATH"]?.contains(".venv/bin") == true)
    }

    @Test @MainActor
    func sandboxExec_prefersAgentVenvOnPath() async throws {
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [],
            execResults: [.init(stdout: "", stderr: "sh: pytest: not found", exitCode: 127)]
        )

        _ = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_exec",
                argumentsJSON: #"{"command":"pytest test_app.py -v"}"#
            )
        }

        let calls = await runner.calls
        guard case .exec(let user, let command, let env) = try #require(calls.first) else {
            Issue.record("Expected exec call")
            return
        }
        #expect(user == "agent-test-agent")
        #expect(command == "pytest test_app.py -v")
        #expect(env["VIRTUAL_ENV"]?.contains(".venv") == true)
        #expect(env["PATH"]?.contains(".venv/bin") == true)
    }

    @Test @MainActor
    func sandboxReadFile_supportsTailAndMaxChars() async throws {
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [.init(stdout: "tail-output", stderr: "", exitCode: 0)]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_read_file",
                argumentsJSON: #"{"path":"build.log","tail_lines":20,"max_chars":1200}"#
            )
        }

        let payload = try successPayload(output)
        #expect(payload["content"] as? String == "tail-output")
        #expect(payload["tail_lines"] as? Int == 20)
        #expect(payload["max_chars"] as? Int == 1200)

        let calls = await runner.calls
        guard case .agent(_, let command) = try #require(calls.first) else {
            Issue.record("Expected agent read call")
            return
        }
        #expect(command.contains("tail -n 20"))
        #expect(command.contains("| head -c 1200"))
    }

    // MARK: - Screenshot bug regression

    /// The original bug: `sandbox_write_file` called with only `path`
    /// returned `{"error": "Invalid arguments"}` — the model had no way
    /// to tell which argument was missing. Now every per-step validator
    /// returns a structured envelope pointing at the failed field.
    @Test @MainActor
    func sandboxWriteFile_missingContentReportsFieldByName() async throws {
        let runner = MockSandboxToolCommandRunner(rootResults: [], agentResults: [])

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_write_file",
                argumentsJSON: #"{"path":"need-moar-compute/index.html"}"#
            )
        }

        #expect(ToolEnvelope.isError(output))
        let payload = try failurePayload(output)
        #expect(payload["kind"] as? String == "invalid_args")
        // Critical: the error names the missing field so the model can
        // retry correctly on the next turn.
        #expect(payload["field"] as? String == "content")
        let message = payload["message"] as? String ?? ""
        #expect(message.contains("content"))
    }

    @Test @MainActor
    func sandboxWriteFile_missingPathReportsFieldByName() async throws {
        let runner = MockSandboxToolCommandRunner(rootResults: [], agentResults: [])

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_write_file",
                argumentsJSON: #"{"content":"hello"}"#
            )
        }

        #expect(ToolEnvelope.isError(output))
        let payload = try failurePayload(output)
        #expect(payload["kind"] as? String == "invalid_args")
        #expect(payload["field"] as? String == "path")
    }

    /// The silent-cwd-fallback bug: `sandbox_exec` with a bad `cwd` used
    /// to run without `cd`, ending up in the wrong directory with no
    /// signal to the model. Now it returns an `invalid_args` envelope
    /// pointing at `cwd` with the sanitizer reason.
    @Test @MainActor
    func sandboxExec_badCwdReturnsInvalidArgsNotSilentFallback() async throws {
        let runner = MockSandboxToolCommandRunner(rootResults: [], agentResults: [])

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_exec",
                argumentsJSON: #"{"command":"ls","cwd":"../etc"}"#
            )
        }

        #expect(ToolEnvelope.isError(output))
        let payload = try failurePayload(output)
        #expect(payload["kind"] as? String == "invalid_args")
        #expect(payload["field"] as? String == "cwd")

        // The command must NOT have run (no silent fallback to agent home).
        let calls = await runner.calls
        #expect(calls.isEmpty, "no exec call should be made when cwd is rejected")
    }
}

private actor MockSandboxToolCommandRunner: SandboxToolCommandRunning {
    enum Call: Equatable {
        case exec(String?, String, [String: String])
        case root(String)
        case agent(String, String)
    }

    private(set) var calls: [Call] = []
    private var execResults: [ContainerExecResult]
    private var rootResults: [ContainerExecResult]
    private var agentResults: [ContainerExecResult]

    init(
        rootResults: [ContainerExecResult],
        agentResults: [ContainerExecResult],
        execResults: [ContainerExecResult] = []
    ) {
        self.rootResults = rootResults
        self.agentResults = agentResults
        self.execResults = execResults
    }

    func exec(
        user: String?,
        command: String,
        env: [String: String],
        cwd _: String?,
        timeout _: TimeInterval,
        streamToLogs _: Bool,
        logSource _: String?
    ) async throws -> ContainerExecResult {
        calls.append(.exec(user, command, env))
        return execResults.isEmpty ? .init(stdout: "", stderr: "", exitCode: 0) : execResults.removeFirst()
    }

    func execAsRoot(
        command: String,
        timeout _: TimeInterval,
        streamToLogs _: Bool,
        logSource _: String?
    ) async throws -> ContainerExecResult {
        calls.append(.root(command))
        return rootResults.isEmpty ? .init(stdout: "", stderr: "", exitCode: 0) : rootResults.removeFirst()
    }

    func execAsAgent(
        _ agentName: String,
        command: String,
        pluginName _: String?,
        env _: [String: String],
        timeout _: TimeInterval,
        streamToLogs _: Bool,
        logSource _: String?
    ) async throws -> ContainerExecResult {
        calls.append(.agent(agentName, command))
        return agentResults.isEmpty ? .init(stdout: "", stderr: "", exitCode: 0) : agentResults.removeFirst()
    }
}

@MainActor
private func withRegisteredSandboxTools<T>(
    runner: some SandboxToolCommandRunning,
    _ body: () async throws -> T
) async throws -> T {
    let agentId = "test-agent"
    let config = AutonomousExecConfig(enabled: true, maxCommandsPerTurn: 10, commandTimeout: 30, pluginCreate: true)
    await SandboxToolCommandRunnerRegistry.shared.setRunner(runner)
    ToolRegistry.shared.unregisterAllSandboxTools()
    BuiltinSandboxTools.register(agentId: agentId, agentName: agentId, config: config)

    do {
        let result = try await body()
        ToolRegistry.shared.unregisterAllSandboxTools()
        await SandboxToolCommandRunnerRegistry.shared.reset()
        return result
    } catch {
        ToolRegistry.shared.unregisterAllSandboxTools()
        await SandboxToolCommandRunnerRegistry.shared.reset()
        throw error
    }
}

private func parseJSON(_ string: String) throws -> [String: Any]? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
}
