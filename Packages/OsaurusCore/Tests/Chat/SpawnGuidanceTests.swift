//
//  SpawnGuidanceTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  The dynamic `spawn` system-prompt block. Two layers are pinned here:
//   1. `SystemPromptTemplates.spawnGuidance(agents:models:)` — the pure
//      renderer: each tool's block appears ONLY when its pool is non-empty,
//      and every descriptor field (locality, provider, size/quant, vision,
//      agent description, and the user's per-model NOTE) reaches the prose.
//   2. `SpawnDescriptors.resolve(...)` — the `@MainActor` resolver: an
//      unknown model id falls back to its short name yet still carries the
//      user's note through to the descriptor (so the note survives even when
//      the model isn't in the picker cache).
//

import Foundation
import Testing

@testable import OsaurusCore

struct SpawnGuidanceTests {

    private func agent(
        _ name: String,
        description: String? = nil,
        modelId: String? = nil,
        isLocal: Bool? = nil,
        provider: String? = nil
    ) -> SpawnAgentDescriptor {
        SpawnAgentDescriptor(
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

        // Agent descriptor: name, description, locality, model id.
        #expect(text.contains("`sparky`"))
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
    }

    // MARK: - Renderer: tool reach + parallelism policy

    @Test("tool-reach line tracks the launching agent's SpawnToolAccess")
    func toolReachLineTracksAccess() {
        let textOnly = SystemPromptTemplates.spawnGuidance(
            agents: [agent("helper")],
            models: [],
            toolAccess: SpawnToolAccess.none
        )
        #expect(textOnly.contains("Workers are text-only"))
        #expect(!textOnly.contains("Workers CAN read files"))

        let readOnly = SystemPromptTemplates.spawnGuidance(
            agents: [agent("helper")],
            models: [],
            toolAccess: .readOnly
        )
        #expect(readOnly.contains("Workers CAN read files"))
        #expect(readOnly.contains("file_read"))
        #expect(!readOnly.contains("Workers are text-only"))
    }

    @Test("context-offload framing, self-contained input rule, and the parallel policy are always present")
    func coreRulesAlwaysPresent() {
        let text = SystemPromptTemplates.spawnGuidance(
            agents: [agent("helper")],
            models: []
        )
        #expect(text.contains("compact result digest"))
        #expect(text.contains("bulk reading + summarization"))
        #expect(text.contains("COMPLETE task as a self-contained prompt"))
        #expect(text.contains("not this conversation"))
        #expect(text.contains("may run in parallel"))
        #expect(text.contains("local targets run one at a time"))
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

    // MARK: - Resolver: unknown id keeps the note + short display name

    @MainActor
    @Test("resolve carries a user note through even for a model id not in the picker cache")
    func resolveKeepsNoteForUnknownModelId() {
        let bogusModel = "vendor/zzz-not-a-real-model-eval"
        let bogusAgent = "zzz-not-a-real-agent-eval"
        let resolved = SpawnDescriptors.resolve(
            agentNames: [bogusAgent],
            modelNames: [bogusModel],
            modelNotes: [bogusModel: "Pinned note for an unknown id"]
        )

        // Unknown agent → name preserved, no agent detail.
        #expect(resolved.agents.count == 1)
        #expect(resolved.agents.first?.name == bogusAgent)
        #expect(resolved.agents.first?.description == nil)
        #expect(resolved.agents.first?.modelId == nil)

        // Unknown model → id preserved, display name is the short (post-slash)
        // name, and the user's note survives the cache miss.
        #expect(resolved.models.count == 1)
        let modelDescriptor = resolved.models.first
        #expect(modelDescriptor?.id == bogusModel)
        #expect(modelDescriptor?.displayName == "zzz-not-a-real-model-eval")
        #expect(modelDescriptor?.note == "Pinned note for an unknown id")
    }
}
