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
}
