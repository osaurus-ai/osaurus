//
//  SpawnGuidanceTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  The dynamic `spawn` system-prompt renderer. Each tool's block appears ONLY
//  when its request-local runnable pool is non-empty, and every descriptor
//  field (locality, provider, size/quant, vision, agent description, and the
//  user's per-model NOTE) reaches the prose. Availability lifecycle coverage
//  lives in SpawnTargetAvailabilityTests.
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
        provider: String? = nil
    ) -> SpawnAgentDescriptor {
        SpawnAgentDescriptor(
            id: id,
            name: name,
            description: description,
            modelId: modelId,
            isLocal: isLocal,
            providerName: provider
        )
    }

    private func model(
        _ id: String,
        displayName: String,
        isLocal: Bool? = nil,
        provider: String? = nil,
        params: String? = nil,
        quant: String? = nil,
        isVLM: Bool = false,
        note: String? = nil
    ) -> SpawnModelDescriptor {
        SpawnModelDescriptor(
            id: id,
            displayName: displayName,
            isLocal: isLocal,
            providerName: provider,
            parameterCount: params,
            quantization: quant,
            isVLM: isVLM,
            note: note
        )
    }

    // MARK: - Renderer: both pools

    @Test("both pools render both tool blocks with full descriptor detail + the per-model note")
    func bothBlocksRenderWithDescriptorDetailAndNote() {
        let text = SystemPromptTemplates.spawnGuidance(
            agents: [
                agent(
                    "sparky",
                    description: "Concise helper",
                    modelId: "qwen3-4b-4bit",
                    isLocal: true
                )
            ],
            models: [
                model(
                    "qwen3-4b-4bit",
                    displayName: "Qwen3 4B",
                    isLocal: true,
                    params: "4B",
                    quant: "4bit",
                    isVLM: true,
                    note: "Use for quick local edits"
                ),
                model(
                    "openai/gpt-4o-mini",
                    displayName: "GPT-4o mini",
                    isLocal: false,
                    provider: "OpenAI"
                ),
            ]
        )

        // Header + both tool blocks present.
        #expect(text.contains("## Delegating subtasks (spawn)"))
        #expect(text.contains("`spawn_agent(input, agent)`"))
        #expect(text.contains("`spawn_model(input, model)`"))
        #expect(text.contains("`spawn_batch(jobs)`"))

        // Agent descriptor: canonical UUID, display name, description,
        // locality, and model id.
        #expect(text.contains("`5E80D9D2-B821-4B43-AE3B-8C0C7F83E005` — sparky"))
        #expect(text.contains("Concise helper"))
        #expect(text.contains("local"))
        #expect(text.contains("model: qwen3-4b-4bit"))

        // Local model descriptor: id, size, quant, vision, AND the note.
        #expect(text.contains("`qwen3-4b-4bit`"))
        #expect(text.contains("4B"))
        #expect(text.contains("4bit"))
        #expect(text.contains("vision"))
        #expect(text.contains("Use for quick local edits"))

        // Remote model descriptor: id, remote locality + provider; no note.
        #expect(text.contains("`openai/gpt-4o-mini`"))
        #expect(text.contains("remote"))
        #expect(text.contains("OpenAI"))
    }

    // MARK: - Renderer: per-tool gating

    @Test("an empty agent pool omits the spawn_agent block (and vice-versa for models)")
    func eachBlockGatesOnItsOwnPool() {
        // Models only → spawn_model present, spawn_agent absent.
        let modelsOnly = SystemPromptTemplates.spawnGuidance(
            agents: [],
            models: [model("local-model", displayName: "Local", isLocal: true)]
        )
        #expect(modelsOnly.contains("`spawn_model(input, model)`"))
        #expect(!modelsOnly.contains("`spawn_agent(input, agent)`"))

        // Agents only → spawn_agent present, spawn_model absent.
        let agentsOnly = SystemPromptTemplates.spawnGuidance(
            agents: [agent("helper")],
            models: []
        )
        #expect(agentsOnly.contains("`spawn_agent(input, agent)`"))
        #expect(!agentsOnly.contains("`spawn_model(input, model)`"))
        #expect(modelsOnly.contains("`spawn_batch(jobs)`"))
        #expect(agentsOnly.contains("`spawn_batch(jobs)`"))
    }

    @Test("batch-only composition advertises both frozen target pools without single-spawn tools")
    func batchOnlyCompositionUsesBothTargetPools() {
        let agentID = UUID(uuidString: "4A78F152-34AC-4867-AD7C-CB5FB6905E70")!
        let text = SystemPromptTemplates.spawnGuidance(
            agents: [
                agent(
                    "Helper",
                    id: agentID,
                    description: "Reads source",
                    modelId: "local/helper"
                )
            ],
            models: [
                model(
                    "remote/reviewer",
                    displayName: "Reviewer",
                    isLocal: false,
                    provider: "Remote"
                )
            ],
            availableToolNames: [SubagentCapabilityRegistry.spawnBatchToolName],
            maxParallel: 2
        )

        #expect(text.contains("`spawn_batch(jobs)`"))
        #expect(text.contains("Available agent targets for `spawn_batch`"))
        #expect(text.contains(agentID.uuidString))
        #expect(text.contains("Available model targets for `spawn_batch`"))
        #expect(text.contains("`remote/reviewer`"))
        #expect(!text.contains("`spawn_agent(input, agent)`"))
        #expect(!text.contains("`spawn_model(input, model)`"))
    }

    // MARK: - Renderer: tool reach + parallelism policy

    @Test("tool-reach line tracks the launching agent's SpawnToolAccess")
    func toolReachLineTracksAccess() {
        let textOnly = SystemPromptTemplates.spawnGuidance(
            agents: [agent("helper")],
            models: [],
            toolAccess: SpawnToolAccess.none
        )
        #expect(
            textOnly.contains(
                "Target-agent workers receive only their enabled tools whose implementations are "
                    + "cancellation-audited for spawned execution"
            )
        )
        #expect(textOnly.contains("bare-model workers have no tools"))
        #expect(textOnly.contains("No extra generic read-only file tools"))
        #expect(!textOnly.contains("Workers also CAN read files"))
        #expect(textOnly.contains("A direct-chat tool omitted from a worker's schema"))

        let readOnly = SystemPromptTemplates.spawnGuidance(
            agents: [agent("helper")],
            models: [],
            toolAccess: .readOnly
        )
        #expect(
            readOnly.contains(
                "Target-agent workers receive only their enabled tools whose implementations are "
                    + "cancellation-audited for spawned execution"
            )
        )
        #expect(readOnly.contains("Workers also CAN read files"))
        #expect(readOnly.contains("file_read"))
        #expect(readOnly.contains("Bare-model workers receive only these added read-only tools"))
        #expect(!readOnly.contains("bare-model workers have no tools"))
        #expect(!readOnly.contains("sandbox reads"))
    }

    @Test("context-offload framing, self-contained input rule, and batch limits are always present")
    func coreRulesAlwaysPresent() {
        let text = SystemPromptTemplates.spawnGuidance(
            agents: [agent("helper")],
            models: [],
            maxParallel: 3
        )
        #expect(text.contains("compact result digest"))
        #expect(text.contains("bulk reading + summarization"))
        #expect(text.contains("COMPLETE task as a self-contained prompt"))
        #expect(text.contains("not this conversation"))
        #expect(text.contains("at most 3 jobs in one batch"))
        #expect(text.contains("3 is an upper bound on concurrent workers"))
        #expect(text.contains("SAME model share one load"))
        #expect(text.contains("different local models are serialized"))
    }

    @Test("a note is only rendered when present (no dangling em-dash for note-less models)")
    func noteOnlyRendersWhenPresent() {
        let text = SystemPromptTemplates.spawnGuidance(
            agents: [],
            models: [model("bare-model", displayName: "Bare", isLocal: true)]
        )
        #expect(text.contains("`bare-model`"))
        // The note-less model line ends after the meta parens — there is no
        // " — " note separator appended for it.
        #expect(!text.contains("`bare-model` (local) —"))
    }

}
