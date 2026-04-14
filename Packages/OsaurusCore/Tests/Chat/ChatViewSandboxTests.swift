import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ChatViewSandboxTests {
    @Test
    func buildToolSpecs_sandboxDisabledExcludesBuiltInSandboxTools() {
        withRegisteredSandboxBuiltins {
            let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)

            #expect(specs.contains(where: { $0.function.name == "sandbox_exec" }) == false)
            #expect(specs.contains(where: { $0.function.name == "sandbox_read_file" }) == false)
        }
    }

    @Test
    func buildToolSpecs_sandboxEnabledIncludesBuiltIns() {
        withRegisteredSandboxBuiltins {
            let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: .sandbox)

            #expect(specs.contains(where: { $0.function.name == "capabilities_search" }))
            #expect(specs.contains(where: { $0.function.name == "capabilities_load" }))
        }
    }

    @Test
    func buildSystemPrompt_includesSandboxContextOnlyWhenExpected() async {
        let standardCtx = await SystemPromptComposer.composeChatContext(
            agentId: Agent.defaultId,
            executionMode: .none
        )
        let sandboxCtx = await SystemPromptComposer.composeChatContext(
            agentId: Agent.defaultId,
            executionMode: .sandbox
        )
        let standardPrompt = standardCtx.prompt
        let sandboxPrompt = sandboxCtx.prompt

        #expect(standardPrompt.contains(SystemPromptTemplates.sandboxSectionHeading) == false)
        #expect(sandboxPrompt.contains(SystemPromptTemplates.sandboxSectionHeading))
        #expect(sandboxPrompt.contains("sandbox_run_script"))
    }

    @Test
    func estimatedContextBreakdown_includesSandboxPromptAndToolsWhenEnabled() {
        let manager = AgentManager.shared
        let originalActiveAgentId = manager.activeAgentId
        let inactiveAgent = Agent(name: "Chat Estimate Off")
        let sandboxAgent = Agent(
            name: "Chat Estimate On",
            autonomousExec: AutonomousExecConfig(enabled: true)
        )
        manager.add(inactiveAgent)
        manager.add(sandboxAgent)
        defer {
            manager.setActiveAgent(originalActiveAgentId)
            Task {
                _ = await manager.delete(id: inactiveAgent.id)
                _ = await manager.delete(id: sandboxAgent.id)
            }
        }

        let inactiveSession = ChatSession()
        inactiveSession.agentId = inactiveAgent.id
        let sandboxSession = ChatSession()
        sandboxSession.agentId = sandboxAgent.id

        withRegisteredSandboxBuiltins {
            let inactiveBreakdown = inactiveSession.estimatedContextBreakdown
            let sandboxBreakdown = sandboxSession.estimatedContextBreakdown

            let inactiveContextTokens = inactiveBreakdown.context.reduce(0) { $0 + $1.tokens }
            let sandboxContextTokens = sandboxBreakdown.context.reduce(0) { $0 + $1.tokens }
            #expect(sandboxContextTokens > inactiveContextTokens)

            let sandboxToolTokens = sandboxBreakdown.context.first { $0.id == "tools" }?.tokens ?? 0
            let inactiveToolTokens = inactiveBreakdown.context.first { $0.id == "tools" }?.tokens ?? 0
            #expect(sandboxToolTokens > inactiveToolTokens)
            #expect(sandboxToolTokens >= ToolRegistry.shared.estimatedTokens(for: "sandbox_exec"))
        }
    }

    @Test
    func alwaysLoadedSpecs_includesCapabilityTools() {
        let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)

        #expect(specs.contains(where: { $0.function.name == "capabilities_search" }))
        #expect(specs.contains(where: { $0.function.name == "capabilities_load" }))
        #expect(specs.contains(where: { $0.function.name == "methods_save" }))
        #expect(specs.contains(where: { $0.function.name == "methods_report" }))
    }

    @Test
    func prepareChatExecutionMode_usesSessionAgentInsteadOfActiveAgent() async {
        let manager = AgentManager.shared
        let registrar = SandboxToolRegistrar.shared
        let originalActiveAgentId = manager.activeAgentId
        let originalStatus = SandboxManager.State.shared.status
        let originalProvisionOverride = registrar.provisionAgentOverride

        let inactiveAgent = Agent(name: "Chat Sandbox Off")
        let sandboxAgent = Agent(
            name: "Chat Sandbox On",
            autonomousExec: AutonomousExecConfig(enabled: true)
        )
        manager.add(inactiveAgent)
        manager.add(sandboxAgent)
        manager.setActiveAgent(inactiveAgent.id)

        SandboxManager.State.shared.status = .running
        registrar.provisionAgentOverride = { _ in }

        let session = ChatSession()
        let inactiveMode = await session.prepareChatExecutionMode(agentId: inactiveAgent.id)
        let sandboxMode = await session.prepareChatExecutionMode(agentId: sandboxAgent.id)

        #expect(inactiveMode.usesSandboxTools == false)
        #expect(sandboxMode.usesSandboxTools)

        let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: sandboxMode)
        #expect(specs.contains(where: { $0.function.name == "sandbox_exec" }))

        ToolRegistry.shared.unregisterAllSandboxTools()
        SandboxManager.State.shared.status = originalStatus
        registrar.provisionAgentOverride = originalProvisionOverride
        manager.setActiveAgent(originalActiveAgentId)
        _ = await manager.delete(id: inactiveAgent.id)
        _ = await manager.delete(id: sandboxAgent.id)
    }

    @Test
    func workSessionEstimate_includesSandboxPromptAndToolsWhenEnabled() {
        let manager = AgentManager.shared
        let originalActiveAgentId = manager.activeAgentId
        let inactiveAgent = Agent(name: "Work Estimate Off")
        let sandboxAgent = Agent(
            name: "Work Estimate On",
            autonomousExec: AutonomousExecConfig(enabled: true)
        )
        manager.add(inactiveAgent)
        manager.add(sandboxAgent)
        defer {
            manager.setActiveAgent(originalActiveAgentId)
            Task {
                _ = await manager.delete(id: inactiveAgent.id)
                _ = await manager.delete(id: sandboxAgent.id)
            }
        }

        let issue = Issue(taskId: "task-1", title: "Verify sandbox budget")
        let inactiveSession = WorkSession(agentId: inactiveAgent.id)
        let sandboxSession = WorkSession(agentId: sandboxAgent.id)

        withRegisteredSandboxBuiltins {
            let inactiveBreakdown = inactiveSession.estimateContextBreakdown(for: issue)
            let sandboxBreakdown = sandboxSession.estimateContextBreakdown(for: issue)
            let sandboxTools = ToolRegistry.shared.alwaysLoadedSpecs(mode: .sandbox)

            let inactiveContextTokens = inactiveBreakdown.context.reduce(0) { $0 + $1.tokens }
            let sandboxContextTokens = sandboxBreakdown.context.reduce(0) { $0 + $1.tokens }
            #expect(sandboxContextTokens > inactiveContextTokens)

            let sandboxToolTokens = sandboxBreakdown.context.first { $0.id == "tools" }?.tokens ?? 0
            let inactiveToolTokens = inactiveBreakdown.context.first { $0.id == "tools" }?.tokens ?? 0
            #expect(sandboxToolTokens > inactiveToolTokens)
            #expect(sandboxToolTokens == ToolRegistry.shared.totalEstimatedTokens(for: sandboxTools))
        }
    }

    @Test
    func selectedModelIsLocal_treatsSlashStyleLocalPickerIdsAsLocal() {
        let session = ChatSession()
        let modelId = "TheCluster/Gemma-4-31B-Heretic-MLX-mxfp4"
        session.pickerItems = [
            ModelPickerItem(
                id: modelId,
                displayName: "Gemma 4 31B",
                source: .local
            )
        ]
        session.selectedModel = modelId

        #expect(session.selectedModelIsLocal)
    }

    @Test
    func buildUserMessageText_truncatesOversizedDocumentsWhenBudgetProvided() {
        let repeated = String(repeating: "line 1234567890\n", count: 300)
        let attachment = Attachment.document(
            filename: "_chat.txt",
            content: repeated,
            fileSize: repeated.utf8.count
        )

        let built = ChatSession.buildUserMessageText(
            content: "Analyze this closely.",
            attachments: [attachment],
            maxInputTokens: 200
        )

        #expect(built.contains("<attached_document name=\"_chat.txt\">"))
        #expect(built.contains("Document truncated to fit local model context"))
        #expect(built.contains("Analyze this closely."))
        #expect(built.count < repeated.count)
    }

    @Test
    func buildUserMessageText_truncatesOversizedDocumentsWhenOnlyCapProvided() {
        let repeated = String(repeating: "transcript line 1234567890\n", count: 600)
        let attachment = Attachment.document(
            filename: "_chat.txt",
            content: repeated,
            fileSize: repeated.utf8.count
        )

        let built = ChatSession.buildUserMessageText(
            content: "What matters here?",
            attachments: [attachment],
            documentTokenCap: 256
        )

        #expect(built.contains("<attached_document name=\"_chat.txt\">"))
        #expect(built.contains("Document truncated to fit local model context"))
        #expect(built.contains("What matters here?"))
        #expect(built.count < repeated.count)
    }

    @Test
    func buildUserMessageText_rendersDocumentManifestWhenReferencesProvided() {
        let attachment = Attachment.document(
            filename: "_chat.txt",
            content: "alpha beta gamma",
            fileSize: 16
        )

        let built = ChatSession.buildUserMessageText(
            content: "Analyze the transcript.",
            attachments: [attachment],
            documentReferences: [
                AttachedDocumentReference(
                    attachmentId: attachment.id.uuidString,
                    filename: "_chat.txt",
                    characterCount: 16,
                    chunkCount: 1,
                    preview: "alpha beta gamma"
                )
            ]
        )

        #expect(built.contains("<attached_documents>"))
        #expect(built.contains("search_attached_documents"))
        #expect(built.contains("read_attached_document"))
        #expect(built.contains(attachment.id.uuidString))
        #expect(built.contains("Analyze the transcript."))
        #expect(!built.contains("<attached_document name=\"_chat.txt\">\nalpha beta gamma"))
    }

    @Test
    func buildUserMessageText_prefersPromptContextBlockOverRawDocumentInlining() {
        let attachment = Attachment.document(
            filename: "_chat.txt",
            content: "alpha beta gamma delta epsilon",
            fileSize: 32
        )

        let built = ChatSession.buildUserMessageText(
            content: "Summarize the transcript.",
            attachments: [attachment],
            documentPromptBlock:
                "<attached_document_context>\n<attached_document_excerpt id=\"1\" name=\"_chat.txt\" chunk=\"1/1\" score=\"42\">gamma delta</attached_document_excerpt>\n</attached_document_context>"
        )

        #expect(built.contains("<attached_document_context>"))
        #expect(built.contains("gamma delta"))
        #expect(built.contains("Summarize the transcript."))
        #expect(!built.contains("<attached_document name=\"_chat.txt\">"))
    }

    @Test
    func buildUserMessageText_combinesManifestAndPromptContextForLocalDocuments() {
        let attachment = Attachment.document(
            filename: "_chat.txt",
            content: "alpha beta gamma delta epsilon",
            fileSize: 32
        )

        let built = ChatSession.buildUserMessageText(
            content: "Please analyze the full file, not just one excerpt.",
            attachments: [attachment],
            documentPromptBlock:
                "<attached_document_context>\n<attached_document_excerpt id=\"doc-1\" name=\"_chat.txt\" chunk=\"2/4\" score=\"42\">gamma delta</attached_document_excerpt>\n</attached_document_context>",
            documentReferences: [
                AttachedDocumentReference(
                    attachmentId: attachment.id.uuidString,
                    filename: "_chat.txt",
                    characterCount: 32,
                    chunkCount: 4,
                    preview: "alpha beta gamma"
                )
            ]
        )

        #expect(built.contains("<attached_documents>"))
        #expect(built.contains("<attached_document_context>"))
        #expect(built.contains("search_attached_documents"))
        #expect(built.contains("read_attached_document"))
        #expect(built.contains(attachment.id.uuidString))
        #expect(built.contains("Please analyze the full file"))
    }

    @Test
    func isFailedAttachedDocumentProbe_detectsStaleNoMatchToolLoops() {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.toolCalls = [
            ToolCall(
                id: "call_123",
                type: "function",
                function: ToolCallFunction(
                    name: "search_attached_documents",
                    arguments: "{}"
                )
            )
        ]
        turn.toolResults = [
            "call_123": "No matching excerpts found in the requested attached documents."
        ]

        #expect(ChatSession.isFailedAttachedDocumentProbe(turn))
    }

    @Test
    func isStaleExcerptOnlyAttachedDocumentAnswer_detectsOldExcerptBoundResponses() {
        let turn = ChatTurn(
            role: .assistant,
            content:
                "Since I only have access to the specific excerpts provided in the prompt, my previous analysis was limited to those snippets. Based on the provided excerpts, here is a focused summary."
        )

        #expect(ChatSession.isStaleExcerptOnlyAttachedDocumentAnswer(turn))
    }

    @Test
    func shouldInjectHistoricalDocumentContext_disablesForImageOnlyTurns() {
        let turn = ChatTurn(
            role: .user,
            content: "What do you see in this photo?",
            attachments: [.image(Data([0x89, 0x50, 0x4E, 0x47]))]
        )

        #expect(!ChatSession.shouldInjectHistoricalDocumentContext(for: turn))
    }
}

@MainActor
private func withRegisteredSandboxBuiltins(_ body: () -> Void) {
    BuiltinSandboxTools.register(
        agentId: "chat-sandbox-test",
        agentName: "chat-sandbox-test",
        config: AutonomousExecConfig(enabled: true)
    )
    defer {
        ToolRegistry.shared.unregisterAllSandboxTools()
    }
    body()
}
