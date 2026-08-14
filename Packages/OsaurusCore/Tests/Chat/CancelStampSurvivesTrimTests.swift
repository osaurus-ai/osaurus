//
//  CancelStampSurvivesTrimTests.swift
//  osaurus
//
//  Source pins for the pre-persist cancel race. Two mechanisms erased the
//  record that a stopped run ever happened:
//
//  1. `finalizeRun` stamps the last assistant turn `cancelled` on a user
//     Stop, but `completeRunCleanup → trimTrailingEmptyAssistantTurn` then
//     dropped that same turn whenever the Stop landed before the first
//     delta — blank content, no stats, so every keep-condition failed and
//     the persisted session ended on the user row with no assistant row.
//  2. A Stop during the pre-send handshake (the "Loading Model..." window)
//     cancels the send before the run task ever appends its assistant
//     turn, so there was nothing to stamp at all.
//
//  Live proof on the keychain-free proof app: stop-during-cold-load now
//  persists `assistant / 0 chars / cancelled` where the pre-fix build
//  persisted only the user row; a mid-stream Stop persists the truncated
//  content with `cancelled` as before. These pins keep both fixes from
//  regressing textually; invert them only with a replacement mechanism.
//

import Foundation
import Testing

struct CancelStampSurvivesTrimTests {
    private static func packageRoot() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        var cursor = here.deletingLastPathComponent()  // Chat/
        cursor.deleteLastPathComponent()  // Tests/
        return cursor.deletingLastPathComponent()  // OsaurusCore/
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = packageRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("trailing-blank trim keeps turns that carry a terminal stop reason")
    func trimKeepsTerminalStopReason() throws {
        let chatView = try Self.source("Views/Chat/ChatView.swift")

        // The trim's keep-condition list must include the stop-reason guard —
        // without it, the `cancelled` stamp from `finalizeRun` is erased for
        // any Stop that lands before the first delta.
        let trimStart = try #require(
            chatView.range(of: "private func trimTrailingEmptyAssistantTurn()"))
        let trimEnd = try #require(
            chatView.range(of: "private func consolidateAssistantTurns()"))
        let trimBody = String(chatView[trimStart.lowerBound..<trimEnd.lowerBound])
        #expect(trimBody.contains("lastTurn.terminalStopReason == nil"))
        // The stamp itself still exists upstream of the trim.
        #expect(chatView.contains("turns[lastAssistant].terminalStopReason = \"cancelled\""))
    }

    @Test("a handshake-window Stop appends the cancelled marker turn")
    func handshakeStopAppendsCancelledMarker() throws {
        let chatView = try Self.source("Views/Chat/ChatView.swift")

        let stopStart = try #require(chatView.range(of: "func stop() {"))
        let stopWindow = String(
            chatView[stopStart.lowerBound...].prefix(2400))
        // Inside the `wasAwaitingPreSendHandshake` branch: the send was
        // cancelled before the run task appended its assistant turn, so
        // stop() itself must leave the record.
        #expect(stopWindow.contains("wasAwaitingPreSendHandshake"))
        #expect(stopWindow.contains("cancelledTurn.terminalStopReason = \"cancelled\""))
        #expect(stopWindow.contains("turns.append(cancelledTurn)"))
    }
}
