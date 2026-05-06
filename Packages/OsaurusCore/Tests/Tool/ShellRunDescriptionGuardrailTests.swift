//
//  ShellRunDescriptionGuardrailTests.swift
//
//  Pin the "use `file_*` tools instead of shell_run for IO" guardrail
//  inside `ShellRunTool.description`. Without it the model has no
//  description-level reason not to default to `shell_run` for file
//  reads, listings, or edits — every dedicated `file_*` tool already
//  says "use this instead of … in shell_run", but that pointer only
//  fires when the model is already considering `file_*`. This guardrail
//  closes the loop in the opposite direction.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("shell_run description guardrail")
struct ShellRunDescriptionGuardrailTests {

    @Test("shell_run description points back at the file_* tools for IO")
    func shellRunPointsAtFileTools() {
        let tool = ShellRunTool(rootPath: URL(fileURLWithPath: "/tmp/guardrail-test"))
        let description = tool.description
        // The pointer wording can shift; pin the two anchor concepts:
        // (1) it mentions "file_*" by family name, and (2) it uses
        // "prefer" / "instead" framing so the model reads it as a
        // dispatch hint rather than a capability claim.
        #expect(
            description.contains("file_*"),
            "shell_run description no longer mentions `file_*` — the back-pointer guardrail is gone. Models will default to shell_run for file IO. Description: \(description)"
        )
        #expect(
            description.contains("prefer") || description.contains("instead"),
            "shell_run description lost the `prefer X / instead of Y` framing. The guardrail needs that to read as a dispatch hint."
        )
    }

    @Test("shell_run description still names its real responsibilities")
    func shellRunStillNamesItsResponsibilities() {
        let tool = ShellRunTool(rootPath: URL(fileURLWithPath: "/tmp/guardrail-test"))
        let description = tool.description
        // Don't lose the original framing — shell_run IS the right tool
        // for these. Pin a representative subset.
        for responsibility in ["builds", "tests", "git"] {
            #expect(
                description.contains(responsibility),
                "shell_run description dropped the `\(responsibility)` responsibility. Trimming back too far defeats the dispatch hint."
            )
        }
    }
}
