//
//  DiagnosticWarningsTests.swift
//
//  Pin the empty-output / SIGPIPE warning logic shared by
//  `SandboxExecTool` and `ShellRunTool`. The model relies on the
//  vocabulary here to tell apart "command did nothing" from
//  "pipeline silently swallowed an error".
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct DiagnosticWarningsTests {

    @Test func emptyOutputWithPipelineSurfacesWarning() {
        let warnings = diagnosticWarnings(
            command: "curl -s ...; echo done | grep needle | head -10",
            exitCode: 0,
            stdout: "",
            stderr: ""
        )
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("produced no output") == true)
    }

    @Test func emptyOutputWith2DevNullSurfacesWarning() {
        let warnings = diagnosticWarnings(
            command: "curl -s https://example.com 2>/dev/null",
            exitCode: 0,
            stdout: "",
            stderr: ""
        )
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("2>/dev/null") == true)
    }

    @Test func emptyOutputWithoutPipelineDoesNotWarn() {
        // `: ; echo` style commands legitimately produce no output and
        // exit 0 — we don't want to flood the model with noise.
        let warnings = diagnosticWarnings(
            command: "true",
            exitCode: 0,
            stdout: "",
            stderr: ""
        )
        #expect(warnings.isEmpty)
    }

    @Test func nonZeroExitDoesNotTriggerEmptyWarning() {
        // The empty warning is for the silent-success-with-no-output
        // pattern; a real failure speaks for itself via exit_code.
        let warnings = diagnosticWarnings(
            command: "false | head -10",
            exitCode: 1,
            stdout: "",
            stderr: ""
        )
        #expect(warnings.isEmpty)
    }

    @Test func sigpipeExitSurfacesSoftNote() {
        // exit 141 is the canonical SIGPIPE shape for `cmd | head -n N`
        // when cmd has more output. Captured stdout is still good.
        let warnings = diagnosticWarnings(
            command: "yes | head -10",
            exitCode: 141,
            stdout: "y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n",
            stderr: ""
        )
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("SIGPIPE") == true)
    }

    @Test func nonEmptyOutputDoesNotTriggerEmptyWarning() {
        let warnings = diagnosticWarnings(
            command: "echo hi | wc -l",
            exitCode: 0,
            stdout: "1\n",
            stderr: ""
        )
        #expect(warnings.isEmpty)
    }

    // MARK: - Inline-code escape hint

    @Test func multilinePythonDashCParseErrorSurfacesEscapeHint() {
        // The canonical local-model failure: a multi-line script embedded
        // in `python3 -c "…"` whose escaping broke, so bash mis-parsed the
        // code body. Reproduces the exact stderr from the pasted session.
        let warnings = diagnosticWarnings(
            command:
                "curl -s https://example.com | python3 -c \"\nimport sys, json\ndata = json.load(sys.stdin)\nprint(data)\"",
            exitCode: 2,
            stdout: "",
            stderr: "bash: -c: line 3: syntax error near unexpected token `('"
        )
        #expect(warnings.contains { $0.contains("sandbox_write_file") })
        #expect(warnings.contains { $0.contains("shell `-c` / `-e`") })
    }

    @Test func nodeDashEParseErrorSurfacesEscapeHint() {
        let warnings = diagnosticWarnings(
            command: "node -e \"\nconst x = (\n\"",
            exitCode: 1,
            stdout: "",
            stderr: "SyntaxError: Unexpected end of file"
        )
        #expect(warnings.contains { $0.contains("sandbox_write_file") })
    }

    @Test func cleanInlinePythonOneLinerDoesNotTriggerEscapeHint() {
        // A correctly-escaped one-liner exits 0 with no parse signature —
        // the hint must stay silent so we don't nag on working commands.
        let warnings = diagnosticWarnings(
            command: "python3 -c 'print(1)'",
            exitCode: 0,
            stdout: "1\n",
            stderr: ""
        )
        #expect(warnings.allSatisfy { !$0.contains("sandbox_write_file") })
    }

    @Test func pythonRuntimeErrorDoesNotTriggerEscapeHint() {
        // A genuine in-script error (module not found) is NOT a shell-parse
        // failure — the escaping was fine, the code just failed. No hint.
        let warnings = diagnosticWarnings(
            command: "python3 -c 'import nope'",
            exitCode: 1,
            stdout: "",
            stderr:
                "Traceback (most recent call last):\n  File \"<string>\", line 1\nModuleNotFoundError: No module named 'nope'"
        )
        #expect(warnings.allSatisfy { !$0.contains("sandbox_write_file") })
    }

    @Test func shellSyntaxErrorWithoutInlineCodeFlagDoesNotTriggerEscapeHint() {
        // A shell-parse error in an ordinary command (no interpreter `-c`/`-e`)
        // is unrelated to the inline-code trap; the targeted hint would be
        // misleading, so it must not fire.
        let warnings = diagnosticWarnings(
            command: "echo $(",
            exitCode: 2,
            stdout: "",
            stderr: "bash: command substitution: line 1: syntax error: unexpected end of file"
        )
        #expect(warnings.allSatisfy { !$0.contains("sandbox_write_file") })
    }

    // MARK: - Unbalanced-quote hint

    @Test func unbalancedSingleQuoteSurfacesQuotingHint() {
        // The model wrapped the whole command in a stray leading single
        // quote, so bash read to end-of-input looking for the closing `'`.
        let warnings = diagnosticWarnings(
            command:
                "'curl -s \"https://api.open-meteo.com/v1/forecast?latitude=33.6884&current_weather=true\"",
            exitCode: 2,
            stdout: "",
            stderr: "bash: -c: line 1: unexpected EOF while looking for matching `''"
        )
        #expect(warnings.contains { $0.contains("unbalanced") })
        #expect(warnings.contains { $0.contains("' quote") })
    }

    @Test func unbalancedDoubleQuoteReportsDoubleQuote() {
        let warnings = diagnosticWarnings(
            command: "echo \"hello",
            exitCode: 2,
            stdout: "",
            stderr: "bash: -c: line 1: unexpected EOF while looking for matching `\"'"
        )
        #expect(warnings.contains { $0.contains("unbalanced \" quote") })
    }

    // MARK: - Unterminated-heredoc hint

    @Test func unterminatedHeredocSurfacesWriteFileHint() {
        let warnings = diagnosticWarnings(
            command: "cat <<EOF\nhello world",
            exitCode: 2,
            stdout: "",
            stderr:
                "bash: -c: line 2: warning: here-document at line 1 delimited by end-of-file (wanted `EOF')"
        )
        #expect(warnings.contains { $0.contains("heredoc") })
        #expect(warnings.contains { $0.contains("sandbox_write_file") })
    }

    @Test func inlineCodeTakesPrecedenceOverQuoteWhenBothSignaturesPresent() {
        // A `python3 -c` script whose quote broke can surface BOTH an
        // inline-code interpreter flag and an unexpected-EOF quote signature.
        // The inline-code hint is the more useful fix, so it must win.
        let warnings = diagnosticWarnings(
            command: "python3 -c \"\nprint('hi)",
            exitCode: 2,
            stdout: "",
            stderr: "bash: -c: line 2: unexpected EOF while looking for matching `\"'"
        )
        #expect(warnings.contains { $0.contains("sandbox_write_file") })
        #expect(warnings.allSatisfy { !$0.contains("unbalanced") })
    }

    // MARK: - Bare install-command redirect

    @Test func bareApkAddFailureRedirectsToSandboxInstall() {
        let warnings = diagnosticWarnings(
            command: "apk add curl ffmpeg",
            exitCode: 1,
            stdout: "",
            stderr: "ERROR: Unable to lock database: Permission denied"
        )
        #expect(warnings.contains { $0.contains("sandbox_install") })
        #expect(warnings.contains { $0.contains("\"apk\"") })
    }

    @Test func barePipInstallFailureRedirectsToSandboxInstall() {
        let warnings = diagnosticWarnings(
            command: "pip install numpy flask",
            exitCode: 1,
            stdout: "",
            stderr: "ERROR: Could not install packages due to an OSError: [Errno 13] Permission denied"
        )
        #expect(warnings.contains { $0.contains("sandbox_install") })
        #expect(warnings.contains { $0.contains("\"pip\"") })
    }

    @Test func bareNpmInstallFailureRedirectsToSandboxInstall() {
        let warnings = diagnosticWarnings(
            command: "cd /tmp && npm install express",
            exitCode: 1,
            stdout: "",
            stderr: "npm error code EACCES"
        )
        #expect(warnings.contains { $0.contains("sandbox_install") })
        #expect(warnings.contains { $0.contains("\"npm\"") })
    }

    @Test func successfulInstallIsNotNagged() {
        // The redirect is failure-gated: a working command (even a bare
        // `pip install`) exits 0 and must stay silent.
        let warnings = diagnosticWarnings(
            command: "pip install numpy",
            exitCode: 0,
            stdout: "Successfully installed numpy-1.26.0",
            stderr: ""
        )
        #expect(warnings.allSatisfy { !$0.contains("sandbox_install") })
    }

    @Test func nonInstallCommandDoesNotTriggerInstallRedirect() {
        // A command that merely *mentions* an install string as an
        // argument (not a statement) must not false-fire.
        let warnings = diagnosticWarnings(
            command: "echo 'run pip install later'",
            exitCode: 1,
            stdout: "",
            stderr: "some unrelated failure"
        )
        #expect(warnings.allSatisfy { !$0.contains("sandbox_install") })
    }

    // MARK: - Combined-mode sandbox_exec host-path backstop

    @Test func sandboxExecHostPath_redirectsToFileToolsInCombinedMode() {
        // The one read surface that can't be path-routed: a raw
        // `sandbox_exec cat /Users/...` still hits the sandbox, which has
        // no copy of the host workspace. Combined mode redirects it.
        ChatExecutionContext.$hostReadOnlyScope.withValue(
            URL(fileURLWithPath: "/Users/me/project")
        ) {
            let hint = sandboxExecHostPathHint(
                command: "cat /Users/me/Desktop/todo.md",
                exitCode: 1,
                stderr: "cat: /Users/me/Desktop/todo.md: No such file or directory"
            )
            #expect(hint?.contains("file_read") == true)
            #expect(hint?.contains("macOS host path") == true)
        }
    }

    @Test func sandboxExecHostPath_silentOutsideCombinedMode() {
        // No host-read scope bound (plain sandbox mode) -> no redirect.
        let hint = sandboxExecHostPathHint(
            command: "cat /Users/me/Desktop/todo.md",
            exitCode: 1,
            stderr: "cat: /Users/me/Desktop/todo.md: No such file or directory"
        )
        #expect(hint == nil)
    }

    @Test func sandboxExecHostPath_silentForLegitimateSandboxCommand() {
        // A normal sandbox command that happens to fail must not be nagged
        // with a host-path redirect.
        ChatExecutionContext.$hostReadOnlyScope.withValue(
            URL(fileURLWithPath: "/Users/me/project")
        ) {
            let hint = sandboxExecHostPathHint(
                command: "cat /workspace/agents/me/notes.txt",
                exitCode: 1,
                stderr: "cat: notes.txt: No such file or directory"
            )
            #expect(hint == nil)
        }
    }
}
