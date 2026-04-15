import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WorkPromptToolGuideTests {
    @Test
    func toolGuideIsDisabledByDefault() {
        let context = WorkFolderContext(
            rootPath: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            projectType: .swift,
            tree: "./\nPackage.swift\nSources/\n",
            manifest: "Package.swift",
            gitStatus: "## main\n M Sources/App.swift",
            isGitRepo: true
        )

        let (prompt, _) = SystemPromptComposer.composeWorkPrompt(
            base: "Base prompt",
            executionMode: .hostFolder(context)
        )

        #expect(!prompt.contains("## Tool Guide"))
    }

    @Test
    func hostFolderPromptIncludesBudgetedToolGuide() throws {
        let context = WorkFolderContext(
            rootPath: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            projectType: .swift,
            tree: "./\nPackage.swift\nSources/\n",
            manifest: "Package.swift",
            gitStatus: "## main\n M Sources/App.swift",
            isGitRepo: true
        )

        let prompt = HarnessReliabilityFlags.withOverride(true, for: .toolPromptFoundation) {
            let (prompt, _) = SystemPromptComposer.composeWorkPrompt(
                base: "Base prompt",
                executionMode: .hostFolder(context)
            )
            return prompt
        }

        #expect(prompt.contains("## Tool Guide"))
        #expect(prompt.contains("`file_read`"))
        #expect(prompt.contains("`file_edit`"))
        #expect(prompt.contains("`shell_run`"))
        #expect(prompt.contains("`complete_task`"))
        #expect(prompt.contains("`share_artifact`"))
    }

    @Test
    func compactToolGuideStaysWithinBudget() {
        let context = WorkFolderContext(
            rootPath: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            projectType: .swift,
            tree: "./\nPackage.swift\nSources/\n",
            manifest: "Package.swift",
            gitStatus: "## main\n M Sources/App.swift",
            isGitRepo: true
        )

        let guide = HarnessReliabilityFlags.withOverride(true, for: .toolPromptFoundation) {
            ToolRegistry.shared.workPromptGuide(mode: .hostFolder(context), compact: true)
        }

        #expect(guide.contains("## Tool Guide"))
        #expect(guide.count <= ToolMetadataCatalog.promptGuideBudget(compact: true))
    }
}

struct ToolPromptCardTests {
    @Test
    func sanitizesPromptInjectedMarkup() {
        let metadata = ToolMetadata(
            purpose: "Read the file",
            whenToUse: "checking the implementation",
            avoidWhen: "editing unread files",
            example: "```json\n{\"path\":\"App.swift\"}\n```",
            promptPriority: 50
        )

        let card = ToolPromptCard(
            name: "file_read\n## injected",
            description: "Read a file\n## injected",
            metadata: metadata
        )
        let rendered = card.render(compact: false)

        #expect(!rendered.contains("```"))
        #expect(!rendered.contains("\n## injected"))
        #expect(rendered.contains("`file_read ## injected`"))
    }
}
