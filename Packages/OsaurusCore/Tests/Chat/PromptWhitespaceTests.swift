//
//  PromptWhitespaceTests.swift
//
//  Regression: Swift `\` line continuations in `"""..."""` blocks
//  preserve any leading whitespace on the follow-on line BEYOND the
//  closing `"""` strip column. Mis-indented continuations leak 2-3
//  spaces into the rendered prompt (e.g. `"list,   or describe..."`)
//  which is visible in real prompt logs. This test pins the dedented
//  shape so a future refactor that re-indents bullets for source
//  readability is forced to use natural newlines or stay flush.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Prompt template whitespace artifact guard")
struct PromptWhitespaceTests {

    /// Any run of 3+ consecutive spaces in the rendered template is the
    /// continuation-bleed signature. We tolerate 2-space sequences because
    /// markdown indented blocks legitimately use them, but 3+ in a row
    /// inside a paragraph indicates a `\`-continuation indent leak.
    private func assertNoContinuationLeak(_ rendered: String, label: String) {
        let leak = rendered.range(of: "   ")  // three spaces
        #expect(
            leak == nil,
            "\(label) contains a 3+ space run — likely a `\\` continuation with over-indented follow-on line. Dedent the follow-on flush to the closing \"\"\" column."
        )
    }

    @Test("googleGemmaGuidance has no whitespace continuation artifacts")
    func gemmaGuidanceRendersClean() {
        assertNoContinuationLeak(
            ModelFamilyGuidance.googleGemmaGuidance,
            label: "googleGemmaGuidance"
        )
    }

    @Test("gptCodexGuidance has no whitespace continuation artifacts")
    func gptCodexGuidanceRendersClean() {
        assertNoContinuationLeak(
            ModelFamilyGuidance.gptCodexGuidance,
            label: "gptCodexGuidance"
        )
    }

    @Test("googleGeminiGuidance has no whitespace continuation artifacts")
    func geminiGuidanceRendersClean() {
        assertNoContinuationLeak(
            ModelFamilyGuidance.googleGeminiGuidance,
            label: "googleGeminiGuidance"
        )
    }

    @Test("compact family variants have no whitespace continuation artifacts")
    func compactFamilyVariantsRenderClean() {
        assertNoContinuationLeak(
            ModelFamilyGuidance.gptCodexGuidanceCompact,
            label: "gptCodexGuidanceCompact"
        )
        assertNoContinuationLeak(
            ModelFamilyGuidance.googleGemmaGuidanceCompact,
            label: "googleGemmaGuidanceCompact"
        )
    }

    @Test("glmQwenGuidance has no whitespace continuation artifacts")
    func glmQwenGuidanceRendersClean() {
        assertNoContinuationLeak(
            ModelFamilyGuidance.glmQwenGuidance,
            label: "glmQwenGuidance"
        )
    }

    @Test("deepSeekGuidance has no whitespace continuation artifacts")
    func deepSeekGuidanceRendersClean() {
        assertNoContinuationLeak(
            ModelFamilyGuidance.deepSeekGuidance,
            label: "deepSeekGuidance"
        )
    }

    @Test("capabilityDiscoveryNudge has no whitespace continuation artifacts")
    func capabilityNudgeRendersClean() {
        assertNoContinuationLeak(
            SystemPromptTemplates.capabilityDiscoveryNudge,
            label: "capabilityDiscoveryNudge"
        )
    }

    @Test("defaultPersona has no whitespace continuation artifacts")
    func defaultPersonaRendersClean() {
        assertNoContinuationLeak(
            SystemPromptTemplates.defaultPersona,
            label: "defaultPersona"
        )
    }

    @Test("agentLoopGuidance has no whitespace continuation artifacts")
    func agentLoopGuidanceRendersClean() {
        assertNoContinuationLeak(
            SystemPromptTemplates.agentLoopGuidance,
            label: "agentLoopGuidance"
        )
    }

    @Test("groundingDirective variants have no whitespace continuation artifacts")
    func groundingDirectiveRendersClean() {
        assertNoContinuationLeak(
            SystemPromptTemplates.groundingDirectiveFull,
            label: "groundingDirectiveFull"
        )
        assertNoContinuationLeak(
            SystemPromptTemplates.groundingDirectiveBase,
            label: "groundingDirectiveBase"
        )
    }

    @Test("lfm2Guidance has no whitespace continuation artifacts")
    func lfm2GuidanceRendersClean() {
        assertNoContinuationLeak(
            ModelFamilyGuidance.lfm2Guidance,
            label: "lfm2Guidance"
        )
    }

    @Test("defaultGuidance has no whitespace continuation artifacts")
    func defaultGuidanceRendersClean() {
        assertNoContinuationLeak(
            ModelFamilyGuidance.defaultGuidance,
            label: "defaultGuidance"
        )
    }

    /// Composed sandbox section bundles `sandboxToolGuide` (the historical
    /// offender — `target="content"` had a 3-space leak) — assert the
    /// composition stays clean. The compact variant was dropped in the
    /// sandbox tightening pass; only the canonical version exists now.
    @Test("sandbox prompt section has no whitespace continuation artifacts")
    func sandboxSectionRendersClean() {
        let section = SystemPromptTemplates.sandbox()
        assertNoContinuationLeak(section, label: "sandbox()")
    }

    /// SOUL section is rendered with the same `\` continuation style as
    /// `sandboxEnvironmentBlock` — pin both the bare framing (no agent
    /// content, just the standing intro paragraph) and a sample with a
    /// short body so a future re-indent of the spec wording cannot leak
    /// stray spaces into the prompt.
    @Test("soul section has no whitespace continuation artifacts")
    func soulSectionRendersClean() {
        let bare = SystemPromptTemplates.soulSection("- prefer Postgres")
        assertNoContinuationLeak(bare, label: "soulSection")
    }

    /// The seeded `~/SOUL.md` begins with its own `# SOUL` title. The
    /// wrapper already emits a `## SOUL` heading, so the file's title must
    /// be stripped to avoid a doubled heading in the rendered prompt.
    @Test("soul section strips the file's own SOUL heading")
    func soulSectionDedupesHeading() {
        let rendered = SystemPromptTemplates.soulSection("# SOUL\n\n- prefer Postgres")
        // Exactly one heading line containing SOUL (the wrapper's `## SOUL`).
        let soulHeadingLines =
            rendered
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("#") && $0.localizedCaseInsensitiveContains("SOUL") }
        #expect(soulHeadingLines == ["## SOUL"])
        #expect(rendered.contains("- prefer Postgres"))
    }

    @Test("soul section keeps non-heading content intact")
    func soulSectionKeepsBodyWhenNoHeading() {
        let rendered = SystemPromptTemplates.soulSection("- prefer Postgres\n# Notes")
        #expect(rendered.contains("- prefer Postgres"))
        // A non-SOUL heading deeper in the body is preserved.
        #expect(rendered.contains("# Notes"))
    }

    /// Folder section runs through the same composition path. Pin both
    /// the bare guide and the fully-rendered section so a future
    /// `\` continuation regression in either surfaces immediately.
    @Test("folder section has no whitespace continuation artifacts")
    func folderSectionRendersClean() {
        assertNoContinuationLeak(
            SystemPromptTemplates.folderToolGuide,
            label: "folderToolGuide"
        )
        let folder = FolderContext(
            rootPath: URL(fileURLWithPath: "/tmp/whitespace-test"),
            projectType: .swift,
            tree: "./\nREADME.md",
            manifest: nil,
            gitStatus: " M file.swift",
            isGitRepo: true,
            contextFiles: nil
        )
        let section = SystemPromptTemplates.folderContext(from: folder)
        assertNoContinuationLeak(section, label: "folderContext(from:)")
    }
}
