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
        // First-attempt success — no recovery retry happened.
        #expect(payload["retried"] == nil)

        let calls = await runner.calls
        #expect(calls.count == 2)
        #expect(calls[0] == .root("test -x /usr/bin/python3"))
        guard case .agent(_, let command) = calls[1] else {
            Issue.record("Expected agent install call")
            return
        }
        #expect(command.contains("/usr/bin/python3 -m venv"))
        #expect(command.contains(".venv/bin/python3"))
        #expect(command.contains("-m pip install"))
        // Hardening flags: silence pip's version warning and refuse to
        // block on a credential prompt for private indexes.
        #expect(command.contains("--disable-pip-version-check"))
        #expect(command.contains("--no-input"))
        #expect(command.contains("flask pytest"))
    }

    @Test @MainActor
    func sandboxPipInstall_recoversFromOSError() async throws {
        // First attempt fails with an OSError (recoverable). The harness
        // runs `pip cache purge` and retries. Second attempt succeeds.
        // Result envelope carries `retried: true`.
        let runner = MockSandboxToolCommandRunner(
            rootResults: [.init(stdout: "", stderr: "", exitCode: 0)],
            agentResults: [
                // Attempt 1 — fails with the recoverable OSError signature.
                .init(
                    stdout: "",
                    stderr: "ERROR: Could not install packages due to an OSError: [Errno 28] No space left on device",
                    exitCode: 1
                ),
                // Cleanup — pip cache purge returns success.
                .init(stdout: "", stderr: "", exitCode: 0),
                // Attempt 2 — succeeds after cleanup.
                .init(stdout: "Successfully installed flask-3.0.0", stderr: "", exitCode: 0),
            ]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_pip_install",
                argumentsJSON: #"{"packages":["flask"]}"#
            )
        }

        let payload = try successPayload(output)
        #expect(payload["retried"] as? Bool == true)
        #expect(payload["exit_code"] as? Int == 0)

        let calls = await runner.calls
        #expect(calls.count == 4, "expected: root probe + install + cache purge + retry")
        // Cleanup call is the third one (index 2): `pip cache purge`.
        guard case .agent(_, let cleanupCmd) = calls[2] else {
            Issue.record("Expected agent cleanup call")
            return
        }
        #expect(cleanupCmd.contains("pip"))
        #expect(cleanupCmd.contains("cache purge"))
    }

    /// Cleanup-throws path: the install fails recoverably, but the
    /// recovery harness's own cleanup throws. The tool surfaces a
    /// structured failure envelope (with the `cleanup_failed` flag and
    /// the original first-attempt output) instead of letting the throw
    /// propagate and become a generic `execution_error` envelope.
    @Test @MainActor
    func sandboxPipInstall_surfacesCleanupErrorAsStructuredFailure() async throws {
        let runner = MockSandboxToolCommandRunner(
            rootResults: [.init(stdout: "", stderr: "", exitCode: 0)],
            agentResults: [
                // Attempt 1 — recoverable failure.
                .init(
                    stdout: "",
                    stderr: "ERROR: Could not install packages due to an OSError",
                    exitCode: 1
                )
                // (No second result needed — cleanup throws before
                //  attempt 2 fires.)
            ],
            // Throw on the second agent call (index 1) — that's the
            // cleanup `pip cache purge`. Index 0 is the install attempt.
            throwOnAgentCallIndex: 1
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_pip_install",
                argumentsJSON: #"{"packages":["flask"]}"#
            )
        }

        #expect(ToolEnvelope.isError(output))
        let payload = try failurePayload(output)
        #expect(payload["kind"] as? String == "execution_error")
        // Critical: the structured `cleanup_failed` metadata flag rides
        // the failure envelope so callers can branch on it.
        #expect(payload["cleanup_failed"] as? Bool == true)
        #expect(payload["retried"] as? Bool == false)

        let message = payload["message"] as? String ?? ""
        #expect(message.contains("recovery cleanup also failed"))
        #expect(message.contains("First attempt output"))

        let calls = await runner.calls
        // root probe + attempt 1 + (throw) cleanup = 3 calls; no retry.
        #expect(calls.count == 3)
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
        // Non-recoverable failure (no idealTree / EEXIST signature) →
        // surface the failure verbatim, no retry. The npm tool now uses
        // `exec` (not `execAsAgent`) so the install result rides in
        // `execResults` rather than `agentResults`.
        let runner = MockSandboxToolCommandRunner(
            rootResults: [.init(stdout: "", stderr: "", exitCode: 0)],
            agentResults: [],
            execResults: [.init(stdout: "", stderr: "npm: not found", exitCode: 127)]
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
        // Just the root probe + one install attempt — no retry because
        // "npm: not found" isn't in the recoverable signature list.
        #expect(calls.count == 2)
        #expect(calls[0] == .root("test -x /usr/bin/node && test -x /usr/bin/npm"))
    }

    @Test @MainActor
    func sandboxNpmInstall_bootstrapsPackageJsonAndUsesWorkdir() async throws {
        let runner = MockSandboxToolCommandRunner(
            rootResults: [.init(stdout: "", stderr: "", exitCode: 0)],
            agentResults: [],
            execResults: [.init(stdout: "added 1 package", stderr: "", exitCode: 0)]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_npm_install",
                argumentsJSON: #"{"packages":["express"]}"#
            )
        }

        let payload = try successPayload(output)
        #expect(payload["exit_code"] as? Int == 0)
        #expect(payload["retried"] == nil)

        let calls = await runner.calls
        // root probe + one install attempt.
        #expect(calls.count == 2)
        guard case .exec(let user, let command, _) = calls[1] else {
            Issue.record("expected install call to use exec (not execAsAgent)")
            return
        }
        #expect(user == "agent-test-agent")
        // Workdir, idempotent package.json bootstrap, no-network flags.
        #expect(command.contains(".osaurus/node_workspace"))
        #expect(command.contains("mkdir -p"))
        #expect(command.contains("[ -f package.json ] || npm init -y"))
        #expect(command.contains("npm install"))
        #expect(command.contains("--no-audit"))
        #expect(command.contains("--no-fund"))
        #expect(command.contains("--no-update-notifier"))
        #expect(command.contains("express"))
        // Regression guard: the install command must NOT start with an
        // outer `cd '<workdir>' && …` prepend. `SandboxManager.exec`
        // adds that prefix when its `cwd:` arg is non-nil, and on a
        // fresh agent home the workdir doesn't exist yet — so an outer
        // `cd` runs before our `mkdir -p` and the whole command fails
        // with `bash: line 1: cd: …: No such file or directory`. Our
        // mock mirrors that prepend (see `MockSandboxToolCommandRunner.exec`),
        // so this assertion catches the bug at unit-test time.
        #expect(
            !command.hasPrefix("cd "),
            "install command must own its own mkdir + cd; outer cd would run before mkdir on a fresh agent home"
        )
    }

    @Test @MainActor
    func sandboxNpmInstall_recoversFromIdealTreeError() async throws {
        // First attempt fails with the well-known "Tracker idealTree
        // already exists" message → harness wipes the lockfile + clears
        // npm cache, retries, succeeds. Result carries `retried: true`.
        let runner = MockSandboxToolCommandRunner(
            rootResults: [.init(stdout: "", stderr: "", exitCode: 0)],
            agentResults: [],
            execResults: [
                // Attempt 1 — recoverable failure.
                .init(
                    stdout: "",
                    stderr: "npm error Tracker \"idealTree\" already exists\n",
                    exitCode: 1
                ),
                // Cleanup — wipe lockfile + cache clean.
                .init(stdout: "", stderr: "", exitCode: 0),
                // Attempt 2 — succeeds after cleanup.
                .init(stdout: "added 5 packages", stderr: "", exitCode: 0),
            ]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_npm_install",
                argumentsJSON: #"{"packages":["@stripe/link-cli"]}"#
            )
        }

        let payload = try successPayload(output)
        #expect(payload["retried"] as? Bool == true)
        #expect(payload["exit_code"] as? Int == 0)

        let calls = await runner.calls
        // root probe + attempt 1 + cleanup + attempt 2 = 4.
        #expect(calls.count == 4)
        // Cleanup is the third call (index 2).
        guard case .exec(_, let cleanupCmd, _) = calls[2] else {
            Issue.record("expected cleanup to use exec")
            return
        }
        #expect(cleanupCmd.contains("rm -rf node_modules/.package-lock.json"))
        #expect(cleanupCmd.contains("npm cache clean"))
    }

    @Test @MainActor
    func sandboxNpmInstall_givesUpAfterOneRetry() async throws {
        // Both attempts fail with the same recoverable signature →
        // retry runs once, then we surface the second failure verbatim.
        // No third attempt fires.
        let trackerError = "npm error Tracker \"idealTree\" already exists\n"
        let runner = MockSandboxToolCommandRunner(
            rootResults: [.init(stdout: "", stderr: "", exitCode: 0)],
            agentResults: [],
            execResults: [
                // Attempt 1
                .init(stdout: "", stderr: trackerError, exitCode: 1),
                // Cleanup
                .init(stdout: "", stderr: "", exitCode: 0),
                // Attempt 2 — same failure
                .init(stdout: "", stderr: trackerError, exitCode: 1),
            ]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_npm_install",
                argumentsJSON: #"{"packages":["express"]}"#
            )
        }

        #expect(ToolEnvelope.isError(output))
        let payload = try failurePayload(output)
        let message = payload["message"] as? String ?? ""
        #expect(message.contains("after retry"))
        #expect(message.contains("idealTree"))
        // The `retried: true` metadata flag rides the failure envelope
        // too (not just the success envelope) so a programmatic caller
        // can branch on retry status without parsing prose.
        #expect(payload["retried"] as? Bool == true)

        let calls = await runner.calls
        // root probe + attempt 1 + cleanup + attempt 2 = 4 (no third attempt).
        #expect(calls.count == 4)
    }

    @Test @MainActor
    func sandboxApkInstall_runsUpdateBeforeAdd() async throws {
        let runner = MockSandboxToolCommandRunner(
            rootResults: [.init(stdout: "", stderr: "", exitCode: 0)],
            agentResults: []
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_install",
                argumentsJSON: #"{"packages":["ffmpeg"]}"#
            )
        }

        let payload = try successPayload(output)
        #expect(payload["exit_code"] as? Int == 0)

        let calls = await runner.calls
        #expect(calls.count == 1)
        guard case .root(let command) = calls[0] else {
            Issue.record("expected apk install via execAsRoot")
            return
        }
        // Refresh the index first so a stale apk db can't poison `add`.
        #expect(command.contains("apk update --quiet"))
        #expect(command.contains("apk add --no-cache"))
        #expect(command.contains("ffmpeg"))
    }

    @Test @MainActor
    func sandboxExecuteCode_writesHelpersAndRunsPython() async throws {
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [],
            execResults: [.init(stdout: "{\"ok\": true}", stderr: "", exitCode: 0)]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_execute_code",
                argumentsJSON: #"{"code":"from osaurus_tools import read_file\nprint(read_file('foo.txt'))"}"#
            )
        }

        let payload = try successPayload(output)
        #expect(payload["exit_code"] as? Int == 0)
        #expect((payload["stdout"] as? String)?.contains("ok") == true)
        #expect(payload["tool_calls"] != nil)

        // The exec command should stage osaurus_tools.py + the script,
        // then invoke python3 with the helpers dir on PYTHONPATH.
        let calls = await runner.calls
        guard case .exec(_, let command, let env) = try #require(calls.first) else {
            Issue.record("Expected exec call")
            return
        }
        #expect(command.contains(".osaurus/osaurus_tools.py"))
        #expect(command.contains(".tmp/exec_"))
        #expect(command.contains("OSAURUS_SCRIPT_ID="))
        #expect(command.contains("PYTHONPATH="))
        #expect(command.contains("python3"))
        #expect(env["VIRTUAL_ENV"]?.contains(".venv") == true)
        #expect(env["PATH"]?.contains(".venv/bin") == true)
    }

    @Test @MainActor
    func sandboxExec_backgroundReturnsPidAndLogFile() async throws {
        // Background mode collapses the old `sandbox_exec_background`
        // into a flag on `sandbox_exec`. Pid + log_file ride back in
        // the success envelope; sandbox_process can poll/wait/kill.
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [],
            execResults: [.init(stdout: "12345\n", stderr: "", exitCode: 0)]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_exec",
                argumentsJSON: #"{"command":"python3 server.py","background":true}"#
            )
        }

        let payload = try successPayload(output)
        #expect(payload["pid"] as? String == "12345")
        #expect(payload["background"] as? Bool == true)
        #expect((payload["log_file"] as? String)?.contains("/bg-") == true)

        let calls = await runner.calls
        guard case .exec(_, let command, _) = try #require(calls.first) else {
            Issue.record("Expected exec call")
            return
        }
        #expect(command.contains("nohup python3 server.py"))
        #expect(command.contains("echo $!"))
    }

    @Test @MainActor
    func sandboxProcess_pollReportsAlive() async throws {
        // Probe `kill -0 <pid>` returns "alive" → tool surfaces alive=true.
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [
                .init(stdout: "alive\n", stderr: "", exitCode: 0)
            ]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_process",
                argumentsJSON: #"{"action":"poll","pid":"42","tail_lines":0}"#
            )
        }

        let payload = try successPayload(output)
        #expect(payload["pid"] as? String == "42")
        #expect(payload["alive"] as? Bool == true)
        // No tracked job → log_tail empty (poll skips the tail call).
        #expect(payload["log_tail"] as? String == "")

        let calls = await runner.calls
        #expect(calls.count == 1)
        guard case .agent(_, let command) = try #require(calls.first) else {
            Issue.record("Expected agent call")
            return
        }
        #expect(command.contains("kill -0 42"))
    }

    @Test @MainActor
    func sandboxProcess_waitTimesOutWhenProcessKeepsRunning() async throws {
        // The wait loop returns "timeout" if the pid is still alive at
        // every probe — the tool surfaces exited=false, timed_out=true.
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [
                .init(stdout: "timeout\n", stderr: "", exitCode: 0)
            ]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_process",
                argumentsJSON: #"{"action":"wait","pid":"42","timeout":1,"tail_lines":0}"#
            )
        }

        let payload = try successPayload(output)
        #expect(payload["exited"] as? Bool == false)
        #expect(payload["timed_out"] as? Bool == true)

        let calls = await runner.calls
        guard case .agent(_, let command) = try #require(calls.first) else {
            Issue.record("Expected agent call")
            return
        }
        #expect(command.contains("for i in $(seq 1 1)"))
        #expect(command.contains("kill -0 42"))
    }

    @Test @MainActor
    func sandboxProcess_killForceUsesSigkill() async throws {
        // `force:true` selects SIGKILL (-9) instead of the SIGTERM default.
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [
                .init(stdout: "dead\n", stderr: "", exitCode: 0)
            ]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_process",
                argumentsJSON: #"{"action":"kill","pid":"42","force":true}"#
            )
        }

        let payload = try successPayload(output)
        #expect(payload["killed"] as? Bool == true)
        #expect(payload["signal"] as? String == "SIGKILL")

        let calls = await runner.calls
        guard case .agent(_, let command) = try #require(calls.first) else {
            Issue.record("Expected agent call")
            return
        }
        #expect(command.contains("kill -9 42"))
    }

    @Test @MainActor
    func sandboxProcess_rejectsNonNumericPid() async throws {
        // Agents have been observed passing job names ("server") instead
        // of the numeric pid. We reject early with a clear envelope so
        // the model fixes the call instead of running `kill server`.
        let runner = MockSandboxToolCommandRunner(rootResults: [], agentResults: [])

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_process",
                argumentsJSON: #"{"action":"poll","pid":"server"}"#
            )
        }

        #expect(ToolEnvelope.isError(output))
        let payload = try failurePayload(output)
        #expect(payload["kind"] as? String == "invalid_args")
        #expect(payload["field"] as? String == "pid")

        let calls = await runner.calls
        #expect(calls.isEmpty, "rejected calls must not exec")
    }

    @Test @MainActor
    func sandboxSearchFiles_targetFilesUsesFind() async throws {
        // `sandbox_find_files` is gone — same behaviour now comes from
        // `sandbox_search_files(target:"files")`. This pins the find
        // command + the unified `matches` result key.
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [.init(stdout: "/workspace/agents/test-agent/foo.py", stderr: "", exitCode: 0)]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_search_files",
                argumentsJSON: #"{"pattern":"*.py","target":"files"}"#
            )
        }

        let payload = try successPayload(output)
        #expect(payload["target"] as? String == "files")
        #expect((payload["matches"] as? String)?.contains("foo.py") == true)

        let calls = await runner.calls
        guard case .agent(_, let command) = try #require(calls.first) else {
            Issue.record("Expected agent call")
            return
        }
        #expect(command.contains("find "))
        #expect(command.contains("-type f -name '*.py'"))
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
        // `sandbox_exec` defaults `cwd` to the agent home, and the mock
        // mirrors `SandboxManager.exec`'s `cd '<cwd>' && …` prepend so
        // we see exactly what bash would run inside the container.
        #expect(command == "cd /workspace/agents/test-agent && pytest test_app.py -v")
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

/// In-memory fake of `SandboxToolCommandRunning` for the sandbox tool
/// suite. Each variant of `exec` / `execAsRoot` / `execAsAgent` consumes
/// one entry from its respective queue (defaulting to a benign success
/// result when the queue is exhausted) and records the call so tests can
/// assert on what the tool actually issued.
///
/// `throwOnAgentCallIndex` is a fault-injection knob: when set, the
/// Nth `execAsAgent` invocation (0-indexed) throws
/// `MockSandboxRunnerError.injectedFailure` instead of returning a
/// result. Used by the cleanup-throws regression test to exercise the
/// install tools' "transport layer died mid-recovery" branch directly.
/// Calls before / after the throw still consume from `agentResults` as
/// usual.
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

    private let throwOnAgentCallIndex: Int?
    private var agentCallCount: Int = 0

    init(
        rootResults: [ContainerExecResult],
        agentResults: [ContainerExecResult],
        execResults: [ContainerExecResult] = [],
        throwOnAgentCallIndex: Int? = nil
    ) {
        self.rootResults = rootResults
        self.agentResults = agentResults
        self.execResults = execResults
        self.throwOnAgentCallIndex = throwOnAgentCallIndex
    }

    func exec(
        user: String?,
        command: String,
        env: [String: String],
        cwd: String?,
        timeout _: TimeInterval,
        streamToLogs _: Bool,
        logSource _: String?
    ) async throws -> ContainerExecResult {
        // Mirror `SandboxManager.exec`'s wire-level shell composition so
        // tests that inspect the recorded command see exactly what the
        // container would actually run — including the outer `cd '<cwd>'
        // && …` prepend when `cwd` is non-nil. Without this the
        // double-`cd` regression that produced `bash: line 1: cd: …: No
        // such file or directory` on a fresh agent home would slip past
        // the unit tests.
        let recorded = cwd.map { "cd \($0) && \(command)" } ?? command
        calls.append(.exec(user, recorded, env))
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
        let index = agentCallCount
        agentCallCount += 1
        if let throwAt = throwOnAgentCallIndex, index == throwAt {
            throw MockSandboxRunnerError.injectedFailure
        }
        return agentResults.isEmpty ? .init(stdout: "", stderr: "", exitCode: 0) : agentResults.removeFirst()
    }
}

/// Sentinel error the mock throws when a caller asks it to simulate a
/// transport-layer failure on a specific agent call.
private enum MockSandboxRunnerError: Error, LocalizedError {
    case injectedFailure
    var errorDescription: String? { "injected sandbox runner failure" }
}

@MainActor
private func withRegisteredSandboxTools<T: Sendable>(
    runner: some SandboxToolCommandRunning,
    _ body: () async throws -> T
) async throws -> T {
    try await SandboxTestLock.shared.run {
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
}

private func parseJSON(_ string: String) throws -> [String: Any]? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
}
