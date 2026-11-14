//
//  SessionSourceGateTests.swift
//  osaurusTests
//
//  Automation sessions persist as `.automation` plus the trigger kind, but
//  every gate, label and residency decision keyed on the trigger-specific
//  source (`.schedule`, `.watcher`, …). These pin the sites that must read
//  `runtimeSource` rather than the stored `source`.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct SessionSourceGateTests {
    static func request(_ kind: EventSourceKind?, unattended: Bool = false) -> DispatchRequest {
        DispatchRequest(
            prompt: "Run", agentId: UUID(), source: kind == nil ? .chat : .automation, automationKind: kind,
            unattended: unattended)
    }

    @Test func runtimeSourceMapsTheTriggerKind() {
        #expect(SessionSource.automation.runtimeSource(automationKind: .schedule) == .schedule)
        #expect(SessionSource.automation.runtimeSource(automationKind: .folder) == .watcher)
        #expect(SessionSource.automation.runtimeSource(automationKind: .webhook) == .webhook)
        #expect(SessionSource.automation.runtimeSource(automationKind: nil) == .automation)
        #expect(SessionSource.chat.runtimeSource(automationKind: .schedule) == .chat)
    }

    @Test func scheduleAndFolderAutomationsAreUnattended() {
        #expect(BackgroundTaskManager.isUnattended(Self.request(.schedule), externalSurface: false))
        #expect(BackgroundTaskManager.isUnattended(Self.request(.folder), externalSurface: false))
        #expect(!BackgroundTaskManager.isUnattended(Self.request(.webhook), externalSurface: false))
        #expect(!BackgroundTaskManager.isUnattended(Self.request(nil), externalSurface: false))
        #expect(!BackgroundTaskManager.isUnattended(Self.request(.schedule), externalSurface: true))
    }

    @Test func storedAutomationRowsLabelByTrigger() {
        let session = ChatSessionData(source: .automation, automationKind: .schedule)
        #expect(session.runtimeSource == .schedule)
        #expect(session.runtimeSource.originLabel() == "scheduled")
        #expect(session.runtimeSource.iconName == SessionSource.schedule.iconName)
        #expect(ChatSessionData(source: .chat, automationKind: .schedule).automationKind == nil)
    }

    @Test func watcherFramingStripsOnlyForFolderRuns() throws {
        let raw = FolderEventSource.buildDispatchPrompt(
            instructions: "Sort new files.", iteration: 1, resolvedWatchPath: "/Users/me/Downloads",
            changedPaths: ["a.pdf"])
        let folder = ChatSessionData(source: .automation, automationKind: .folder)
        let env = try #require(DispatchEnvelope.parse(raw, sessionSource: folder.runtimeSource))
        #expect(env.displayText == "Sort new files.")
        let feed = ChatSessionData(source: .automation, automationKind: .rss)
        #expect(DispatchEnvelope.parse(raw, sessionSource: feed.runtimeSource) == nil)

        let turns = [ChatTurnData(role: .user, content: raw)]
        #expect(ChatSessionData.generateTitle(from: turns, source: folder.runtimeSource) == "Sort new files.")
    }
}
