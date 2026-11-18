//
//  PerfAuditContractTests.swift
//  osaurusTests
//
//  Bounds and persistence contracts from the memory and performance audit:
//  capped tool output, trimmed block memo, capped run-log archive, quit-time
//  drafts, unchanged sidebar rows, and swap-episode record pruning.
//

import Foundation
import Testing

@testable import OsaurusCore

struct PerfAuditContractTests {

    // MARK: shell_run capture

    @Test func headTailCaptureKeepsBothEndsAndCountsTheGap() {
        var capture = HeadTailByteCapture(headCap: 8, tailCap: 8)
        capture.append(Data("HEADHEAD".utf8))
        for _ in 0 ..< 100 { capture.append(Data("middle--".utf8)) }
        capture.append(Data("TAILTAIL".utf8))

        #expect(capture.head == Data("HEADHEAD".utf8))
        #expect(capture.tail.count <= 16)
        let text = capture.string
        #expect(text.hasPrefix("HEADHEAD"))
        #expect(text.hasSuffix("TAILTAIL"))
        #expect(text.contains("800"))
    }

    @Test func headTailCaptureUnderCapIsVerbatim() {
        var capture = HeadTailByteCapture(headCap: 8, tailCap: 8)
        capture.append(Data("short".utf8))
        capture.append(Data(" text".utf8))
        #expect(capture.string == "short text")
    }

    // MARK: BlockMemoizer trim

    @Test func blockTrimCutsOnlyAtTurnBoundaries() {
        var blocks: [ContentBlock] = []
        var turnIds: [UUID] = []
        for _ in 0 ..< 10 {
            let turnId = UUID()
            turnIds.append(turnId)
            blocks.append(
                .header(turnId: turnId, role: .assistant, agentName: "A", isFirstInGroup: true, position: .first))
            for i in 0 ..< 4 {
                blocks.append(
                    .paragraph(
                        turnId: turnId, index: i, text: "p\(i)", isStreaming: false, role: .assistant,
                        position: .middle))
            }
        }
        let trimmed = BlockMemoizer.trimmedAtTurnBoundary(blocks, keeping: 12)
        #expect(trimmed.count <= 12)
        #expect(!trimmed.isEmpty)
        let firstTurn = trimmed[0].turnId
        #expect(trimmed.filter { $0.turnId == firstTurn }.count == 5)
        #expect(trimmed.last?.turnId == turnIds.last)
        #expect(BlockMemoizer.trimmedAtTurnBoundary(blocks, keeping: 100).count == blocks.count)
    }

    // MARK: Run-log archive

    @Test func runLogArchiveEvictsLeastRecentPastCap() {
        let archive = SubagentRunLogArchive.shared
        let prefix = "perf-audit-\(UUID().uuidString)-"
        let total = SubagentRunLogArchive.maxLogs + 20
        for i in 0 ..< total {
            let log = SubagentRunLog(
                kindId: SubagentCapabilityRegistry.computerUse.id, title: "run \(i)", startedAt: Date(),
                success: true, summary: "done", events: [], truncatedEventCount: 0)
            archive.store(log, for: prefix + "\(i)")
        }
        #expect(archive.feed(for: prefix + "0") == nil)
        #expect(archive.feed(for: prefix + "\(total - 1)") != nil)
    }

    // MARK: Sidebar rows

    @Test func listRowComparisonSeesDisplayedFields() {
        let row = ChatSessionData(id: UUID(), title: "Chat")
        var renamed = row
        renamed.title = "Renamed"
        var pinned = row
        pinned.pinned = true
        #expect(ChatSessionData.sameListRows([row], [row]))
        #expect(!ChatSessionData.sameListRows([row], [renamed]))
        #expect(!ChatSessionData.sameListRows([row], [pinned]))
        #expect(!ChatSessionData.sameListRows([row], []))
    }

    // MARK: Swap episode records

    @Test func unloadDropsThatModelsFinishedRecords() {
        let monitor = SwapPressureMonitor()
        monitor.swapSampler = { (used: 1 << 30, total: 8 << 30) }
        monitor.beginResidencyEpisode(model: "B")
        monitor.markLoadCompleted(model: "B")
        for _ in 0 ..< 5 {
            monitor.beginResidencyEpisode(model: "A")
            monitor.markLoadCompleted(model: "A")
            monitor.endEpisodeIfIdle(residentCount: 1, unloaded: "A")
        }
        let state = monitor.currentState()
        #expect(state.phase == .resident)
        #expect(state.modelName == "B")
        monitor.endEpisodeIfIdle(residentCount: 0, unloaded: "B")
        #expect(monitor.currentState().phase == .idle)
    }
}

// MARK: - Drafts across quit

@Suite(.serialized)
@MainActor
struct ChatDraftQuitPersistenceTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("drafts-\(UUID().uuidString).json")
    }

    @Test func keysRoundTripThroughTheirPersistedNames() {
        let id = UUID()
        let keys: [ChatDraftStore.Key] = [.session(id), .newChat(agentId: id), .newChat(agentId: nil)]
        for key in keys {
            #expect(ChatDraftStore.Key(persistedName: key.persistedName) == key)
        }
        #expect(ChatDraftStore.Key(persistedName: "nonsense") == nil)
    }

    @Test func openComposerTextSurvivesQuitAndRelaunch() async throws {
        try await ChatHistoryTestStorage.run {
            let url = tempURL()
            let store = ChatDraftStore.shared
            store.removeAll()
            let saved = ChatSessionData(id: UUID(), title: "Saved")
            let session = ChatSession()
            session.load(from: saved)
            session.input = "unsent at quit"

            store.persistForQuit(openSessions: [session], to: url)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(session.input == "unsent at quit")

            store.removeAll()
            store.restorePersisted(from: url)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(store.take(for: .session(saved.id))?.text == "unsent at quit")
        }
    }

    @Test func restoreKeepsDraftsStashedThisRun() {
        let url = tempURL()
        let store = ChatDraftStore.shared
        store.removeAll()
        let key = ChatDraftStore.Key.session(UUID())
        store.stash("from last run", for: key)
        store.persistForQuit(openSessions: [], to: url)
        store.removeAll()
        store.stash("typed this run", for: key)
        store.restorePersisted(from: url)
        #expect(store.take(for: key)?.text == "typed this run")
    }

    @Test func nothingToSaveRemovesTheFile() throws {
        let url = tempURL()
        try Data("{}".utf8).write(to: url)
        let store = ChatDraftStore.shared
        store.removeAll()
        store.persistForQuit(openSessions: [], to: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
