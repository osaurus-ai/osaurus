//
//  SpawnGuidanceTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  The dynamic `spawn_agent` system-prompt renderer: one delegation tool,
//  one parallelism rule, one follow-up rule, one results rule, and the
//  launching agent's actual runnable targets. Availability lifecycle
//  coverage lives in SpawnTargetAvailabilityTests.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SpawnGuidanceTests {

    private func agent(
        _ name: String,
        id: UUID = UUID(uuidString: "5E80D9D2-B821-4B43-AE3B-8C0C7F83E005")!,
        description: String? = nil,
        modelId: String? = nil,
        isLocal: Bool? = nil,
        provider: String? = nil,
        folder: String? = nil
    ) -> SpawnAgentDescriptor {
        SpawnAgentDescriptor(
            id: id,
            name: name,
            description: description,
            modelId: modelId,
            isLocal: isLocal,
            providerName: provider,
            workingFolderPath: folder
        )
    }

    // MARK: - Renderer: descriptor detail

    @Test("the agent list renders name, description, model locality, and own folder")
    func agentLinesCarryDescriptorDetail() {
        let text = SystemPromptTemplates.spawnGuidance(
            agents: [
                agent(
                    "sparky",
                    description: "Concise helper",
                    modelId: "qwen3-4b-4bit",
                    isLocal: true
                ),
                agent(
                    "cloudy",
                    id: UUID(uuidString: "4A78F152-34AC-4867-AD7C-CB5FB6905E70")!,
                    description: "Frontier reasoning",
                    modelId: "gpt-4o-mini",
                    isLocal: false,
                    provider: "OpenAI",
                    folder: "/Users/me/Project"
                ),
            ]
        )

        #expect(text.contains("## Delegating work (spawn_agent)"))
        #expect(text.contains("`spawn_agent(input, agent)`"))
        // Names and stable IDs are quoted together with their routing descriptions.
        #expect(text.contains("\"name\":\"sparky\""))
        #expect(text.contains("\"description\":\"Concise helper\""))
        #expect(text.contains("5E80D9D2-B821-4B43-AE3B-8C0C7F83E005"))
        #expect(text.contains("model: qwen3-4b-4bit (local)"))
        #expect(text.contains("\"name\":\"cloudy\""))
        #expect(text.contains("\"description\":\"Frontier reasoning\""))
        #expect(text.contains("gpt-4o-mini (remote) via OpenAI"))
        #expect(text.contains("own folder: /Users/me/Project"))
    }

    @Test("an empty pool renders the rules but no agent list")
    func emptyPoolRendersNoList() {
        let text = SystemPromptTemplates.spawnGuidance(agents: [])
        #expect(text.contains("`spawn_agent(input, agent)`"))
        #expect(!text.contains("Your agents"))
    }

    // MARK: - One delegation story

    @Test("the removed spawn_model / spawn_batch vocabulary never renders")
    func removedToolsAreGone() {
        let text = SystemPromptTemplates.spawnGuidance(
            agents: [agent("helper")],
            maxParallel: 3
        )
        #expect(!text.contains("spawn_model"))
        #expect(!text.contains("spawn_batch"))
        #expect(!text.contains("Bare-model"))
        #expect(!text.contains("digest"))
        #expect(!text.contains("target_type"))
    }

    @Test("the model is told one fan-out story: N spawn_agent calls in one message")
    func parallelSpawnStoryIsUnified() {
        let text = SystemPromptTemplates.spawnGuidance(
            agents: [agent("helper")],
            maxParallel: 2,
            maxRemoteParallel: 6
        )
        #expect(text.contains("call `spawn_agent` several times in the SAME message"))
        #expect(text.contains("up to 2 local and 6 remote/workspace agents"))
        #expect(text.contains("each call returns its own answer"))
        #expect(text.contains("Never send independent tasks one message at a time"))
        #expect(
            SystemPromptTemplates.parallelSpawnGuidance(maxParallel: 1, maxRemoteParallel: 8)
                .contains("up to 1 local and 8 remote/workspace agents")
        )
    }

    @Test("follow-ups use continue with the session_id; NEEDS INPUT is answered the same way")
    func followUpRuleIsPresent() {
        let text = SystemPromptTemplates.spawnGuidance(agents: [agent("helper")])
        #expect(text.contains("`continue`"))
        #expect(text.contains("`session_id`"))
        #expect(text.contains("NEEDS INPUT:"))
        #expect(text.contains("`background: true`"))
        #expect(text.contains("Do not poll or re-send the task"))
    }

    @Test("the spawn_agent tool description tells the same story as the guidance")
    func toolDescriptionAgrees() {
        let description = SpawnAgentTool().description
        #expect(description.contains("emit all the spawn_agent calls in one message"))
        #expect(description.contains("`continue`"))
        #expect(description.contains("NEEDS INPUT:"))
        #expect(description.contains("inherits yours if it has none"))
        #expect(!description.contains("spawn_batch"))
        #expect(!description.contains("spawn_model"))
    }

    // MARK: - Working folder / deliverables

    @Test("with a launcher folder, folder-less agents inherit it and deliverables go to disk")
    func launcherFolderInheritance() {
        let text = SystemPromptTemplates.agentWorkingFolderGuidance(
            agents: [agent("helper")],
            launcherHasFolder: true
        )
        #expect(text.contains("only spawning and `clarify` are removed"))
        #expect(text.contains("work in YOUR working folder"))
        #expect(text.contains("save deliverables"))
        #expect(text.contains("`file_read`"))
        #expect(text.contains("`share_artifact`"))
    }

    @Test("no folder anywhere: agents cannot write files, results come back in the answer")
    func noFolderAnywhere() {
        let text = SystemPromptTemplates.agentWorkingFolderGuidance(
            agents: [agent("helper")],
            launcherHasFolder: false
        )
        #expect(text.contains("cannot write files to disk"))
        #expect(text.contains("`share_artifact`"))
        #expect(!text.contains("YOUR working folder"))
    }

    @Test("agents with their own folder are named and win over inheritance")
    func ownFolderIsNamed() {
        let text = SystemPromptTemplates.agentWorkingFolderGuidance(
            agents: [
                agent("helper"),
                agent(
                    "coder", id: UUID(uuidString: "4A78F152-34AC-4867-AD7C-CB5FB6905E70")!,
                    folder: "/Users/me/Repo"),
            ],
            launcherHasFolder: true
        )
        #expect(text.contains("coder work in their own folder"))
        #expect(text.contains("work in YOUR working folder"))
    }

    // MARK: - Workspace agents

    @Test("shared agents render as Name@Workspace with owner, address, and the no-folder caveat")
    func workspaceAgentsRender() throws {
        let ref = try #require(
            WorkspaceAgentRef(
                key: "ws-team:0x0123456789abcdef0123456789abcdef01234567"
            )
        )
        let text = SystemPromptTemplates.spawnGuidance(
            agents: [],
            workspaceAgents: [
                SpawnWorkspaceAgentDescriptor(
                    ref: ref,
                    name: "Reviewer",
                    description: "Reviews PRs",
                    workspaceName: "Team",
                    ownerName: "Ana"
                )
            ]
        )
        #expect(text.contains("Teammates' shared agents"))
        #expect(text.contains("\"name\":\"Reviewer@Team\""))
        #expect(text.contains("Reviews PRs"))
        #expect(text.contains("owner: Ana"))
        #expect(text.contains(ref.agentAddress))
        #expect(text.contains("cannot see your folder"))
        #expect(text.contains("put the content in `input`"))
        #expect(text.contains("offline"))
        // Presence is deliberately absent so the prompt stays byte-stable.
        #expect(!text.contains("online"))
    }

    @Test("settings lookup is orchestrator work, not a spawn")
    func settingsLookupIsNotAWorkerJob() {
        let text = SystemPromptTemplates.spawnGuidance(agents: [agent("helper")])
        #expect(text.contains("never delegated"))
        #expect(text.contains("`osaurus_help`"))
        #expect(text.contains("`osaurus_config`"))
    }
}
