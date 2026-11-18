import Foundation
import Testing

@testable import OsaurusCore

/// The agent editor rebuilds the record from its form on every save. The
/// Working Folder is saved by its own picker, so the rebuild must carry it
/// over from the live record instead of resetting it (#3110).
@Suite("Agent editor save preserves working folder")
struct AgentEditorSavePreservesWorkingFolderTests {
    @Test("an unrelated editor save preserves a newer picker model and generation choice")
    func unrelatedSaveKeepsLiveGeneration() {
        var live = Agent(name: "Notes", systemPrompt: "Prompt", defaultModel: "old-model",
            temperature: 0.4, maxTokens: 128, generationSettings: .init(reasoningEffort: "high"))
        var rebuilt = live
        rebuilt.name = "Renamed"
        live.defaultModel = "new-model"
        live.temperature = 0.6
        live.maxTokens = 1024
        live.generationSettings = .init(topP: 0.9, reasoningEffort: "low")

        AgentDetailView.carryDirectlySavedFields(from: live, into: &rebuilt)

        #expect(rebuilt.name == "Renamed")
        #expect(rebuilt.defaultModel == "new-model")
        #expect(rebuilt.temperature == 0.6)
        #expect(rebuilt.maxTokens == 1024)
        #expect(rebuilt.generationSettings == live.generationSettings)
    }

    @Test("explicit generation Save can reset overrides while preserving the live model")
    func explicitGenerationResetIsNotAnUnrelatedSave() {
        let live = Agent(name: "Notes", systemPrompt: "Prompt", defaultModel: "live-model",
            temperature: 0.6, maxTokens: 1024, generationSettings: .init(reasoningEffort: "low"))
        var rebuilt = live
        let inherited = AgentGenerationDraft.Values(temperature: nil, maxTokens: nil, settings: nil)

        AgentDetailView.carryDirectlySavedFields(from: live, into: &rebuilt, generationValues: inherited)

        #expect(rebuilt.defaultModel == "live-model")
        #expect(rebuilt.temperature == nil)
        #expect(rebuilt.maxTokens == nil)
        #expect(rebuilt.generationSettings == nil)
        #expect(live.generationSettings?.reasoningEffort == "low")
    }


    @Test func promptEditKeepsTheWorkingFolder() {
        var live = Agent(name: "Notes", systemPrompt: "Old prompt")
        live.workingFolderBookmark = Data([0x01, 0x02, 0x03])
        live.workingFolderPath = "/Users/me/Notes"

        var rebuilt = Agent(id: live.id, name: "Notes", systemPrompt: "New prompt")
        AgentDetailView.carryDirectlySavedFields(from: live, into: &rebuilt)

        #expect(rebuilt.systemPrompt == "New prompt")
        #expect(rebuilt.workingFolderBookmark == Data([0x01, 0x02, 0x03]))
        #expect(rebuilt.workingFolderPath == "/Users/me/Notes")
    }

    @Test func clearedFolderStaysCleared() {
        let live = Agent(name: "Notes", systemPrompt: "Prompt")
        var rebuilt = Agent(id: live.id, name: "Notes", systemPrompt: "Prompt")
        rebuilt.workingFolderPath = "/stale"

        AgentDetailView.carryDirectlySavedFields(from: live, into: &rebuilt)

        #expect(rebuilt.workingFolderBookmark == nil)
        #expect(rebuilt.workingFolderPath == nil)
    }
}
