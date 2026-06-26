import Containerization
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
                name: "sandbox_install",
                argumentsJSON: #"{"manager":"pip","packages":["flask","pytest"]}"#
            )
        }

        let payload = try successPayload(output)
        let installed = try #require(payload["installed"] as? [String])
        #expect(installed == ["flask", "pytest"])
        #expect(payload["requested"] == nil)
        #expect(payload["exit_code"] as? Int == 0)
        // First-attempt success — no recovery retry happened.
        #expect(payload["retried"] == nil)
        // Trim: the verbose installer log is dropped on success — the model
        // gets the `installed` list + a one-line summary, not the raw output.
        #expect(payload["output"] == nil)
        #expect((payload["summary"] as? String)?.contains("flask") == true)

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
                name: "sandbox_install",
                argumentsJSON: #"{"manager":"pip","packages":["flask"]}"#
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
                name: "sandbox_install",
                argumentsJSON: #"{"manager":"pip","packages":["flask"]}"#
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
                name: "sandbox_install",
                argumentsJSON: #"{"manager":"pip","packages":["flask","pytest"]}"#
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
                name: "sandbox_install",
                argumentsJSON: #"{"manager":"npm","packages":["vite"]}"#
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
                name: "sandbox_install",
                argumentsJSON: #"{"manager":"npm","packages":["express"]}"#
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
                name: "sandbox_install",
                argumentsJSON: #"{"manager":"npm","packages":["@stripe/link-cli"]}"#
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
                name: "sandbox_install",
                argumentsJSON: #"{"manager":"npm","packages":["express"]}"#
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
                argumentsJSON: #"{"manager":"apk","packages":["ffmpeg"]}"#
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
    func sandboxExec_backgroundReturnsPidAndLogFile() async throws {
        // Background mode collapses the old `sandbox_exec_background`
        // into a flag on `sandbox_exec`. Pid + log_file ride back in
        // the success envelope; sandbox_process can poll/wait/kill.
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [],
            execResults: [.init(stdout: "12345\n", stderr: "", exitCode: 0)]
        )

        let output = try await withRegisteredSandboxTools(runner: runner, backgroundEnabled: true) {
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
        // Background is wrapped via `nohup setsid bash -c 'set -o pipefail;
        // <cmd>'` so a pipeline failure in the spawned command surfaces as
        // the rightmost non-zero exit (mirroring the foreground path) and
        // the wrapper leads its own process group so `kill -- -<pid>` can
        // take down the whole job tree.
        #expect(command.contains("nohup setsid bash -c 'set -o pipefail; python3 server.py'"))
        #expect(command.contains("echo $!"))
    }

    @Test @MainActor
    func sandboxProcess_pollReportsAlive() async throws {
        // Zombie-aware probe returns "alive" → tool surfaces alive=true.
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [
                .init(stdout: "alive\n", stderr: "", exitCode: 0)
            ]
        )

        let output = try await withRegisteredSandboxTools(runner: runner, backgroundEnabled: true) {
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
        // The probe must be zombie-aware: `kill -0` alone reports a dead
        // unreaped wrapper as alive forever.
        #expect(command.contains("kill -0 42"))
        #expect(command.contains("/proc/42/status"))
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

        let output = try await withRegisteredSandboxTools(runner: runner, backgroundEnabled: true) {
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
        #expect(command.contains("/proc/42/status"))
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

        let output = try await withRegisteredSandboxTools(runner: runner, backgroundEnabled: true) {
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
        // Group kill first (jobs are setsid leaders), bare-pid fallback for
        // pre-setsid jobs, then a zombie-aware dead check.
        #expect(command.contains("kill -9 -- -42"))
        #expect(command.contains("kill -9 42"))
        #expect(command.contains("/proc/42/status"))
    }

    @Test @MainActor
    func sandboxProcess_rejectsNonNumericPid() async throws {
        // Agents have been observed passing job names ("server") instead
        // of the numeric pid. We reject early with a clear envelope so
        // the model fixes the call instead of running `kill server`.
        let runner = MockSandboxToolCommandRunner(rootResults: [], agentResults: [])

        let output = try await withRegisteredSandboxTools(runner: runner, backgroundEnabled: true) {
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
    func backgroundDisabled_stripsProcessToolAndRejectsBackgroundExec() async throws {
        // With `backgroundProcessEnabled` off (the default), `sandbox_process`
        // is never registered and `sandbox_exec` no longer advertises the
        // `background` flag — so a `background:true` call is refused (schema
        // validation rejects the unknown property; the tool's own runtime
        // guard is the defense-in-depth backstop) and nothing is spawned.
        let runner = MockSandboxToolCommandRunner(rootResults: [], agentResults: [], execResults: [])

        let output = try await withRegisteredSandboxTools(runner: runner) {
            // sandbox_process must not be registered when background is off.
            #expect(ToolRegistry.shared.specs(forTools: ["sandbox_process"]).isEmpty)
            return try await ToolRegistry.shared.execute(
                name: "sandbox_exec",
                argumentsJSON: #"{"command":"python3 server.py","background":true}"#
            )
        }

        #expect(ToolEnvelope.isError(output))

        let calls = await runner.calls
        #expect(calls.isEmpty, "background-disabled exec must not spawn anything")
    }

    @Test @MainActor
    func backgroundDisabled_foregroundExecStillWorks() async throws {
        // Sanity: with background off, an ordinary foreground command runs
        // normally (the gate only removes the background affordance).
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [],
            execResults: [.init(stdout: "hello\n", stderr: "", exitCode: 0)]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_exec",
                argumentsJSON: #"{"command":"echo hello"}"#
            )
        }

        #expect(!ToolEnvelope.isError(output))
        let calls = await runner.calls
        #expect(!calls.isEmpty, "foreground exec should run")
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
        // A glob pattern is passed through, case-insensitively (`-iname`).
        #expect(command.contains("-type f -iname '*.py'"))
    }

    @Test @MainActor
    func sandboxSearchFiles_bareWordWrapsAsCaseInsensitiveSubstring() async throws {
        // A bare word (no glob metacharacters) becomes `-iname '*word*'` so
        // `q4` matches `q4_sales_report.xlsx`, mirroring the host route.
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [
                .init(
                    stdout: "/workspace/agents/test-agent/q4_sales_report.xlsx",
                    stderr: "",
                    exitCode: 0
                )
            ]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_search_files",
                argumentsJSON: #"{"pattern":"q4","target":"files"}"#
            )
        }

        let payload = try successPayload(output)
        #expect((payload["matches"] as? String)?.contains("q4_sales_report.xlsx") == true)

        let calls = await runner.calls
        guard case .agent(_, let command) = try #require(calls.first) else {
            Issue.record("Expected agent call")
            return
        }
        #expect(command.contains("-type f -iname '*q4*'"))
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
        // `sandbox_exec` defaults `cwd` to the agent home, prepends
        // `set -o pipefail; ` to the model's command (so pipelines
        // surface the rightmost non-zero exit), and the mock mirrors
        // `SandboxManager.exec`'s `cd '<cwd>' && …` prepend so we see
        // exactly what bash would run inside the container.
        #expect(
            command
                == "cd /workspace/agents/test-agent && set -o pipefail; pytest test_app.py -v"
        )
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

    // MARK: - Merged write/edit (`sandbox_write_file`)

    /// `sandbox_write_file` with `content` writes the whole file (the
    /// pre-merge behavior): `mkdir -p` the parent then `printf … > path`.
    @Test @MainActor
    func sandboxWriteFile_contentWritesWholeFile() async throws {
        let runner = MockSandboxToolCommandRunner(rootResults: [], agentResults: [])

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_write_file",
                argumentsJSON: #"{"path":"notes/index.html","content":"<h1>hi</h1>"}"#
            )
        }

        let payload = try successPayload(output)
        #expect((payload["path"] as? String)?.contains("notes/index.html") == true)

        let calls = await runner.calls
        let commands = calls.compactMap { call -> String? in
            if case .agent(_, let c) = call { return c }
            return nil
        }
        #expect(commands.contains { $0.contains("printf") && $0.contains("notes/index.html") })
        // The whole-file write must NOT touch the in-place edit machinery.
        #expect(!commands.contains { $0.contains("python3 -c") })
    }

    /// `sandbox_write_file` with `old_string` selects the in-place edit
    /// path — the presence of the argument decides edit-vs-write, with no
    /// separate `sandbox_edit_file` tool. It runs the exact-match Python
    /// replace and returns a `summary`.
    @Test @MainActor
    func sandboxWriteFile_oldStringRoutesToInPlaceEdit() async throws {
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [
                // Diff capture reads the file before and after the edit; the
                // reads emit a `1`/`0` existence marker line then the contents.
                .init(stdout: "1\nold()", stderr: "", exitCode: 0),  // readForDiff (before)
                .init(stdout: "", stderr: "", exitCode: 0),  // mkdir tmp
                .init(stdout: "", stderr: "", exitCode: 0),  // printf old
                .init(stdout: "", stderr: "", exitCode: 0),  // printf new
                .init(stdout: "replaced 1 line(s) with 1 line(s)", stderr: "", exitCode: 0),  // python
                .init(stdout: "1\nnew()", stderr: "", exitCode: 0),  // readForDiff (after)
            ]
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_write_file",
                argumentsJSON:
                    #"{"path":"app.py","old_string":"old()","new_string":"new()"}"#
            )
        }

        let payload = try successPayload(output)
        #expect((payload["summary"] as? String)?.contains("replaced") == true)

        let calls = await runner.calls
        let commands = calls.compactMap { call -> String? in
            if case .agent(_, let c) = call { return c }
            return nil
        }
        // The edit path runs the exact-match Python replace, not a plain write.
        #expect(commands.contains { $0.contains("python3 -c") })
    }

    /// `old_string` without `new_string` is the merge's only new
    /// validation: an in-place edit needs both, so it returns `invalid_args`
    /// pointing at `new_string` rather than silently writing nothing.
    @Test @MainActor
    func sandboxWriteFile_oldStringWithoutNewStringIsInvalidArgs() async throws {
        let runner = MockSandboxToolCommandRunner(rootResults: [], agentResults: [])

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_write_file",
                argumentsJSON: #"{"path":"app.py","old_string":"old()"}"#
            )
        }

        #expect(ToolEnvelope.isError(output))
        let payload = try failurePayload(output)
        #expect(payload["kind"] as? String == "invalid_args")
        #expect(payload["field"] as? String == "new_string")

        // Nothing should have run — the edit was rejected before dispatch.
        let calls = await runner.calls
        #expect(calls.isEmpty)
    }

    /// After the merge, `sandbox_edit_file` is no longer a registered tool —
    /// its behavior lives in `sandbox_write_file`. The schema must show one
    /// write tool, not two.
    @Test @MainActor
    func sandboxEditFile_isUnregisteredAfterMerge() async throws {
        let runner = MockSandboxToolCommandRunner(rootResults: [], agentResults: [])

        try await withRegisteredSandboxTools(runner: runner) {
            #expect(ToolRegistry.shared.specs(forTools: ["sandbox_edit_file"]).isEmpty)
            #expect(ToolRegistry.shared.specs(forTools: ["sandbox_write_file"]).count == 1)
        }
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

    /// Host-vs-sandbox confusion regression: a small model handed a host
    /// filesystem path to `sandbox_read_file`. The rejection must redirect
    /// it to the `file_*` host tools instead of just saying "outside the
    /// agent home". (`ToolRegistry.execute` rebinds `hostReadOnlyScope`
    /// from its own combined-mode policy, which is nil in this harness, so
    /// the broad macOS-path branch produces the redirect here; the precise
    /// workspace-scope wording is pinned in `HostPathRedirectTests`.)
    @Test @MainActor
    func sandboxReadFile_hostPathRedirectsToFileTools() async throws {
        let runner = MockSandboxToolCommandRunner(rootResults: [], agentResults: [])

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ToolRegistry.shared.execute(
                name: "sandbox_read_file",
                argumentsJSON: #"{"path":"/Users/tpae/Desktop"}"#
            )
        }

        #expect(ToolEnvelope.isError(output))
        let payload = try failurePayload(output)
        #expect(payload["kind"] as? String == "invalid_args")
        let message = payload["message"] as? String ?? ""
        #expect(message.contains("file_read"))

        // The read must NOT have run against the sandbox.
        let calls = await runner.calls
        #expect(calls.isEmpty, "no read call should be made when the path is rejected")
    }

    // MARK: - Combined-mode unified file routing

    /// Combined mode: the unified host `file_read` serves an absolute
    /// `/workspace/...` path from the Linux sandbox via the bridge,
    /// translating the host `start_line`/`end_line` range to the sandbox
    /// `start_line`/`line_count` convention.
    @Test @MainActor
    func combinedMode_fileRead_workspacePathRoutesToSandbox() async throws {
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [.init(stdout: "sandbox-line-5\n", stderr: "", exitCode: 0)]
        )
        let bridge = SandboxReadBridge(
            agentName: "test-agent",
            home: "/workspace/agents/test-agent"
        )
        let hostRoot = URL(fileURLWithPath: "/tmp/osaurus-combined-route-\(UUID().uuidString)")

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ChatExecutionContext.$sandboxReadBridge.withValue(bridge) {
                try await FileReadTool(rootPath: hostRoot).execute(
                    argumentsJSON:
                        #"{"path":"/workspace/agents/test-agent/notes.txt","start_line":5,"end_line":6}"#
                )
            }
        }

        // Normalized to the host-style text envelope (one shape per tool,
        // regardless of route).
        let payload = try successPayload(output)
        #expect((payload["text"] as? String)?.contains("sandbox-line-5") == true)
        #expect(payload["content"] == nil, "sandbox-route output must be normalized to `text`")

        let calls = await runner.calls
        guard case .agent(_, let command) = try #require(calls.first) else {
            Issue.record("expected the sandbox bridge to issue an agent read")
            return
        }
        // start_line 5 + end_line 6 -> sandbox sed range 5,6.
        #expect(command.contains("sed -n '5,6p'"))
        #expect(command.contains("/workspace/agents/test-agent/notes.txt"))
    }

    /// Combined mode: `file_read(tail_lines:)` on a `/workspace/...` path
    /// issues a `tail -n N` against the sandbox (log-style read) and is
    /// normalized to the host text envelope.
    @Test @MainActor
    func combinedMode_fileRead_tailLinesIssuesTailCommand() async throws {
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [.init(stdout: "last-log-line\n", stderr: "", exitCode: 0)]
        )
        let bridge = SandboxReadBridge(
            agentName: "test-agent",
            home: "/workspace/agents/test-agent"
        )
        let hostRoot = URL(fileURLWithPath: "/tmp/osaurus-combined-route-\(UUID().uuidString)")

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ChatExecutionContext.$sandboxReadBridge.withValue(bridge) {
                try await FileReadTool(rootPath: hostRoot).execute(
                    argumentsJSON:
                        #"{"path":"/workspace/agents/test-agent/server.log","tail_lines":20}"#
                )
            }
        }

        let payload = try successPayload(output)
        #expect((payload["text"] as? String)?.contains("last-log-line") == true)

        let calls = await runner.calls
        guard case .agent(_, let command) = try #require(calls.first) else {
            Issue.record("expected the sandbox bridge to issue an agent tail")
            return
        }
        #expect(command.contains("tail -n 20"))
        #expect(command.contains("/workspace/agents/test-agent/server.log"))
    }

    /// Combined mode: `file_read` on a `/workspace/...` DIRECTORY lists it
    /// through the sandbox. The unified reader first attempts a read, sees
    /// the "Is a directory" failure, and falls back to a depth-bounded
    /// `find` — the path (not a separate `file_tree` tool) decides
    /// file-vs-directory on the sandbox route too.
    @Test @MainActor
    func combinedMode_fileRead_workspaceDirectoryListsViaSandbox() async throws {
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [
                // 1) the read attempt fails because the path is a directory
                .init(
                    stdout: "",
                    stderr: "cat: /workspace/agents/test-agent: Is a directory",
                    exitCode: 1
                ),
                // 2) the depth-bounded listing fallback — `find -printf '%y\t%p'`
                //    emits a type letter + path per entry (root dir first).
                .init(
                    stdout:
                        "d\t/workspace/agents/test-agent\n"
                        + "f\t/workspace/agents/test-agent/a.py\n"
                        + "f\t/workspace/agents/test-agent/b.py",
                    stderr: "",
                    exitCode: 0
                ),
            ]
        )
        let bridge = SandboxReadBridge(
            agentName: "test-agent",
            home: "/workspace/agents/test-agent"
        )
        let hostRoot = URL(fileURLWithPath: "/tmp/osaurus-combined-route-\(UUID().uuidString)")

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ChatExecutionContext.$sandboxReadBridge.withValue(bridge) {
                try await FileReadTool(rootPath: hostRoot).execute(
                    argumentsJSON: #"{"path":"/workspace/agents/test-agent","max_depth":2}"#
                )
            }
        }

        // Structured, actionable listing — entries (typed paths), not prose.
        let payload = try successPayload(output)
        #expect(payload["kind"] as? String == "listing")
        let entries = try #require(payload["entries"] as? [[String: Any]])
        let paths = entries.compactMap { $0["path"] as? String }
        #expect(paths.contains("/workspace/agents/test-agent/a.py"))
        #expect(paths.contains("/workspace/agents/test-agent/b.py"))
        // The search root itself is not a child entry.
        #expect(!paths.contains("/workspace/agents/test-agent"))
        #expect(entries.allSatisfy { $0["type"] as? String == "file" })
        #expect(payload["text"] == nil, "a listing must not hand the model a prose tree")

        let calls = await runner.calls
        guard calls.count >= 2, case .agent(_, let listCmd) = calls[1] else {
            Issue.record("expected a read attempt followed by a listing fallback")
            return
        }
        // Depth-bounded listing honors `max_depth` and emits typed entries.
        #expect(listCmd.contains("find "))
        #expect(listCmd.contains("-maxdepth 2"))
        #expect(listCmd.contains("-printf"))
    }

    /// Combined mode: `file_search(target:"files")` on a `/workspace/...`
    /// path maps to a sandbox `find -name <glob>`; `file_search` content
    /// route escapes regex metacharacters so it matches the same literal
    /// substring the host route does, and forwards `file_pattern` as the
    /// ripgrep `--glob` include.
    @Test @MainActor
    func combinedMode_fileSearch_filesAndContentRoutes() async throws {
        let runner = MockSandboxToolCommandRunner(
            rootResults: [],
            agentResults: [
                .init(stdout: "/workspace/agents/test-agent/a.py\n", stderr: "", exitCode: 0),
                .init(stdout: "a.py:1: TODO(x)\n", stderr: "", exitCode: 0),
            ]
        )
        let bridge = SandboxReadBridge(
            agentName: "test-agent",
            home: "/workspace/agents/test-agent"
        )
        let hostRoot = URL(fileURLWithPath: "/tmp/osaurus-combined-route-\(UUID().uuidString)")

        let (filesOut, contentOut) = try await withRegisteredSandboxTools(runner: runner) {
            try await ChatExecutionContext.$sandboxReadBridge.withValue(bridge) {
                let files = try await FileSearchTool(rootPath: hostRoot).execute(
                    argumentsJSON:
                        #"{"pattern":"*.py","target":"files","path":"/workspace/agents/test-agent"}"#
                )
                let content = try await FileSearchTool(rootPath: hostRoot).execute(
                    argumentsJSON:
                        #"{"pattern":"TODO(x)","path":"/workspace/agents/test-agent","file_pattern":"*.py"}"#
                )
                return (files, content)
            }
        }

        // Both routes normalized to the host text envelope.
        #expect((try successPayload(filesOut)["text"] as? String)?.contains("a.py") == true)
        #expect((try successPayload(contentOut)["text"] as? String)?.contains("TODO(x)") == true)

        let calls = await runner.calls
        guard case .agent(_, let filesCmd) = try #require(calls.first),
            calls.count >= 2,
            case .agent(_, let contentCmd) = calls[1]
        else {
            Issue.record("expected two sandbox search commands")
            return
        }
        // target=files -> find -iname glob (case-insensitive).
        #expect(filesCmd.contains("find "))
        #expect(filesCmd.contains("-iname '*.py'"))
        // content -> rg with the regex-escaped literal + the include glob.
        #expect(contentCmd.contains("rg -n"))
        #expect(contentCmd.contains(#"TODO\(x\)"#))
        #expect(contentCmd.contains("--glob"))
    }

    /// Combined mode: a relative / default path keeps `file_read` on the
    /// host workspace even with a sandbox bridge bound — the exact "what's
    /// on my Desktop?" listing that the old two-family split kept getting
    /// wrong. A directory path lists the host folder; no sandbox call is
    /// issued.
    @Test @MainActor
    func combinedMode_fileRead_defaultDirectoryListsHostWorkspace() async throws {
        let runner = MockSandboxToolCommandRunner(rootResults: [], agentResults: [])
        let bridge = SandboxReadBridge(
            agentName: "test-agent",
            home: "/workspace/agents/test-agent"
        )
        let hostRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("osaurus-host-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: hostRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: hostRoot) }
        try "hi".write(
            to: hostRoot.appendingPathComponent("hello.txt"),
            atomically: true,
            encoding: .utf8
        )

        let output = try await withRegisteredSandboxTools(runner: runner) {
            try await ChatExecutionContext.$sandboxReadBridge.withValue(bridge) {
                try await FileReadTool(rootPath: hostRoot).execute(argumentsJSON: #"{"path":"."}"#)
            }
        }

        #expect(output.contains("hello.txt"))
        let calls = await runner.calls
        #expect(calls.isEmpty, "a default/relative path must stay on the host, not hit the sandbox")
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
        timeout _: TimeInterval?,
        streamToLogs _: Bool,
        logSource _: String?,
        stdoutTee _: (any Writer)?,
        stderrTee _: (any Writer)?,
        onProcessStarted _: (@Sendable (ProcessHandle) -> Void)?
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
        timeout _: TimeInterval?,
        streamToLogs _: Bool,
        logSource _: String?,
        stdoutTee _: (any Writer)?,
        stderrTee _: (any Writer)?
    ) async throws -> ContainerExecResult {
        calls.append(.root(command))
        return rootResults.isEmpty ? .init(stdout: "", stderr: "", exitCode: 0) : rootResults.removeFirst()
    }

    func execAsAgent(
        _ agentName: String,
        command: String,
        pluginName _: String?,
        env _: [String: String],
        timeout _: TimeInterval?,
        streamToLogs _: Bool,
        logSource _: String?,
        stdoutTee _: (any Writer)?,
        stderrTee _: (any Writer)?,
        onProcessStarted _: (@Sendable (ProcessHandle) -> Void)?
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
    backgroundEnabled: Bool = false,
    _ body: () async throws -> T
) async throws -> T {
    try await SandboxTestLock.shared.run {
        let agentId = "test-agent"
        let config = AutonomousExecConfig(
            enabled: true,
            maxCommandsPerTurn: 10,
            pluginCreate: true,
            backgroundProcessEnabled: backgroundEnabled
        )
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
