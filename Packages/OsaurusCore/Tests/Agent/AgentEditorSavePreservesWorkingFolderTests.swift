import Foundation
import Testing

@testable import OsaurusCore

/// The agent editor rebuilds the record from its form on every save. The
/// Working Folder is saved by its own picker, so the rebuild must carry it
/// over from the live record instead of resetting it (#3110).
@Suite("Agent editor save preserves working folder")
struct AgentEditorSavePreservesWorkingFolderTests {

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
