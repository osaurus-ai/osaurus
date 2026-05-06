//
//  FolderContextRenderTests.swift
//
//  Pin the rendered shape of `SystemPromptTemplates.folderContext`:
//  empty fields hide instead of rendering placeholders, the new
//  one-line path rule replaced the three-sentence security paragraph,
//  and behavioural directives that now live in `agentLoopGuidance` /
//  `modelFamilyGuidance` no longer get restated inside the folder block.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("FolderContext render shape")
struct FolderContextRenderTests {

    // MARK: - Helpers

    private func ctx(
        path: String = "/tmp/render-test",
        projectType: ProjectType = .swift,
        tree: String = "./\nREADME.md\nPackage.swift",
        gitStatus: String? = nil,
        contextFiles: String? = nil
    ) -> FolderContext {
        FolderContext(
            rootPath: URL(fileURLWithPath: path),
            projectType: projectType,
            tree: tree,
            manifest: nil,
            gitStatus: gitStatus,
            isGitRepo: gitStatus != nil,
            contextFiles: contextFiles
        )
    }

    // MARK: - Empty-field suppression

    @Test("unknown project type does NOT render `Project Type:` line")
    func unknownProjectTypeIsHidden() {
        let rendered = SystemPromptTemplates.folderContext(from: ctx(projectType: .unknown))
        #expect(
            !rendered.contains("Project Type:"),
            "Folder section emitted `Project Type:` for an unknown project; the line should be suppressed when projectType == .unknown."
        )
    }

    @Test("known project type renders `Project Type: <displayName>`")
    func knownProjectTypeRenders() {
        let rendered = SystemPromptTemplates.folderContext(from: ctx(projectType: .swift))
        #expect(rendered.contains("**Project Type:** Swift"))
    }

    @Test("empty file tree does NOT render `Root contents:` line")
    func emptyTreeIsHidden() {
        let rendered = SystemPromptTemplates.folderContext(from: ctx(tree: ""))
        #expect(
            !rendered.contains("Root contents:"),
            "Folder section emitted `Root contents:` for an empty tree; the line should be suppressed when the summary is blank."
        )
    }

    @Test("git status is omitted entirely when nil")
    func noGitStatusIsHidden() {
        let rendered = SystemPromptTemplates.folderContext(from: ctx(gitStatus: nil))
        #expect(!rendered.contains("Git status"))
    }

    @Test("Project Context section is omitted when contextFiles is nil")
    func noContextFilesIsHidden() {
        let rendered = SystemPromptTemplates.folderContext(from: ctx(contextFiles: nil))
        #expect(!rendered.contains("## Project Context"))
    }

    // MARK: - Trimmed path-relative paragraph

    @Test("path rule renders as a single sentence; no `security boundary` framing")
    func pathRuleIsTrimmed() {
        let rendered = SystemPromptTemplates.folderContext(from: ctx())
        #expect(rendered.contains(SystemPromptTemplates.folderPathRule))
        #expect(!rendered.contains("security boundary"))
        #expect(!rendered.contains("for orientation when you describe"))
    }

    // MARK: - Restated-directive guards

    @Test("folder section does NOT restate `Always read a file before editing it`")
    func droppedReadBeforeEditDirective() {
        let rendered = SystemPromptTemplates.folderContext(from: ctx())
        #expect(!rendered.contains("Always read a file before editing"))
    }

    @Test("folder section does NOT restate the multi-step `Don't narrate intent` directive")
    func droppedMultiStepDirective() {
        let rendered = SystemPromptTemplates.folderContext(from: ctx())
        #expect(!rendered.contains("Don't narrate intent"))
        #expect(!rendered.contains("just do the thing"))
    }

    // MARK: - Positive dispatch shape

    @Test("tool guide uses positive dispatch (no `not X` negation)")
    func toolGuideIsPositiveDispatch() {
        let guide = SystemPromptTemplates.folderToolGuide
        #expect(guide.contains("Tool dispatch"))
        #expect(guide.contains("Layout: `file_tree`"))
        #expect(guide.contains("Search: `file_search`"))
        #expect(guide.contains("Read: `file_read`"))
        #expect(guide.contains("Edit: `file_edit`"))
        #expect(guide.contains("Shell: `shell_run`"))
        // Negation framing should be gone — that lives in tool descriptions.
        #expect(!guide.contains("**not**"))
        #expect(!guide.contains("instead of"))
    }

    // MARK: - Subsection ordering

    /// The rendered folder section should land subsections in this order:
    /// heading → metadata lines → (git block if any) → path rule →
    /// dispatch → artifact reminder → (Project Context if any).
    @Test("folder section emits subsections in canonical order")
    func canonicalSubsectionOrder() {
        let rendered = SystemPromptTemplates.folderContext(
            from: ctx(
                projectType: .swift,
                gitStatus: " M file.swift",
                contextFiles: "## AGENTS\nfollow this"
            )
        )
        // Markers, in expected order:
        let anchors: [(label: String, text: String)] = [
            ("heading", "## Working Directory"),
            ("path metadata", "**Path:**"),
            ("project type", "**Project Type:** Swift"),
            ("root contents", "**Root contents:**"),
            ("git block", "**Git status (uncommitted changes):**"),
            ("path rule", SystemPromptTemplates.folderPathRule),
            ("dispatch", "Tool dispatch"),
            ("artifact reminder", "Files land in the working folder"),
            ("project context heading", "## Project Context"),
        ]
        var lastIdx = -1
        var lastLabel = "(start)"
        for (label, text) in anchors {
            guard let range = rendered.range(of: text) else {
                Issue.record("Anchor `\(label)` (\(text)) not found in folder section.")
                continue
            }
            let idx = rendered.distance(from: rendered.startIndex, to: range.lowerBound)
            #expect(
                idx > lastIdx,
                "Anchor `\(label)` appeared at byte \(idx); previous anchor `\(lastLabel)` was at \(lastIdx). Order broken."
            )
            lastIdx = idx
            lastLabel = label
        }
    }
}
