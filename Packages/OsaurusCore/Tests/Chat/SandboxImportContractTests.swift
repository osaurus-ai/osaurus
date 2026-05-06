//
//  SandboxImportContractTests.swift
//
//  Pin the contract between the rendered sandbox section and the actual
//  `osaurus_tools` Python helper module that gets staged inside the
//  sandbox. The system prompt previously listed `share_artifact` in its
//  `from osaurus_tools import ...` example, but the helper module
//  intentionally does NOT export `share_artifact` — the bridge endpoint
//  enforces the same allow-list and an in-script call would silently
//  no-op the chat artifact card. Keeping the import list out of sync
//  trains the model to write code that fails opaquely.
//
//  Truth source: `BuiltinSandboxTools.SandboxExecuteCodeHelpers.pythonSource`
//  (pinned by `SandboxExecuteCodeHelpersSourceTests`).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Sandbox prompt / osaurus_tools helper import contract")
struct SandboxImportContractTests {

    /// The rendered sandbox section must NOT name `share_artifact` inside
    /// any `from osaurus_tools import ...` clause. Catches the literal
    /// bug where the prompt advertised an import the helper module never
    /// exported. The check parses the actual comma-separated import list
    /// rather than scanning the whole line, so a clarifying note like
    /// "share_artifact is NOT exposed" outside the import clause is fine.
    @Test("sandbox section does not list share_artifact in any osaurus_tools import")
    func sandboxSectionDoesNotImportShareArtifact() throws {
        // Match `from osaurus_tools import <identifiers>`. The capture stops
        // at the first character that can't appear in a Python import list:
        // backtick (markdown end), parenthesis, or end of line. That keeps
        // the match scoped to the import clause itself.
        let pattern = #"from osaurus_tools import ([A-Za-z0-9_,\s]+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let section = SystemPromptTemplates.sandbox()
        let range = NSRange(section.startIndex..., in: section)
        for match in regex.matches(in: section, range: range) {
            guard let importsRange = Range(match.range(at: 1), in: section) else { continue }
            let imports = section[importsRange]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            #expect(
                !imports.contains("share_artifact"),
                "Sandbox section lists `share_artifact` inside a `from osaurus_tools import ...` clause — the helper module does NOT export it. Bridge rejects any in-script call. Imports parsed: \(imports)"
            )
        }
    }

    /// Reverse pin: the section MUST name the five helpers that ARE
    /// exported, so a future "trim everything" refactor can't strip the
    /// import hint entirely without anyone noticing.
    @Test("sandbox section still hints at the five exported osaurus_tools helpers")
    func sandboxSectionMentionsExportedHelpers() {
        let section = SystemPromptTemplates.sandbox()
        let exported = ["read_file", "write_file", "edit_file", "search_files", "terminal"]
        for name in exported {
            #expect(
                section.contains(name),
                "Sandbox section dropped the `\(name)` mention. Models reading the section still need to know the helper is callable from `sandbox_execute_code`."
            )
        }
    }

    /// SOUL.md advert contract (PR3 of the SOUL.md spec): the rendered
    /// sandbox section must name the two write-capable tools an agent
    /// would use to edit its soul. Without this hint the agent has the
    /// affordance (sandbox_edit_file / sandbox_write_file are in the
    /// schema) but no link from "I noticed a durable pattern" to "I
    /// can record it in `~/SOUL.md`". A drift between the bootstrap
    /// seed (which exists) and the prompt (which advertises it) leaves
    /// the file inert — exactly the failure mode the SOUL.md spec
    /// calls out for the advertisement step.
    @Test("sandbox SOUL.md advert names sandbox_edit_file + sandbox_write_file")
    func sandboxSoulAdvertNamesEditTools() {
        let section = SystemPromptTemplates.sandbox()
        guard let advertRange = section.range(of: "~/SOUL.md") else {
            Issue.record("Sandbox section is missing the `~/SOUL.md` advert entirely.")
            return
        }
        // Constrain the assertion to the advert sentence so a stray
        // `sandbox_edit_file` mention elsewhere can't satisfy the
        // contract by accident.
        let lineStart =
            section[..<advertRange.lowerBound].lastIndex(of: "\n")
            .map { section.index(after: $0) } ?? section.startIndex
        let lineEnd =
            section[advertRange.upperBound...].firstIndex(of: "\n")
            ?? section.endIndex
        let advertLine = String(section[lineStart ..< lineEnd])
        #expect(
            advertLine.contains("sandbox_edit_file"),
            "SOUL.md advert dropped `sandbox_edit_file`; the agent loses one of the two sanctioned ways to edit its soul. Line: \(String(reflecting: advertLine))"
        )
        #expect(
            advertLine.contains("sandbox_write_file"),
            "SOUL.md advert dropped `sandbox_write_file`; the agent loses the only sanctioned way to wholesale rewrite its soul. Line: \(String(reflecting: advertLine))"
        )
    }
}
