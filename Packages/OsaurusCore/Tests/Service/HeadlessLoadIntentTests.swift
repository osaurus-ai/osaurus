// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

/// Autonomous runs — a cron schedule firing, a file watcher tripping, an agent
/// waking itself — must not evict the model the user is chatting with. Runs a
/// human is waiting on must still load freely.
///
/// The trap this suite exists to hold shut: **`source` and intent are different
/// questions.** A cron fire and the user pressing "Run Now" on that same schedule
/// both arrive as `source: .schedule`. Deriving intent from `source` would make
/// the button refuse to load its own model — a "fix" that breaks the feature it
/// was meant to protect. So intent is set at the trigger boundary, which is the
/// only place that knows whether anyone is waiting.
@Suite("Headless load intent")
struct HeadlessLoadIntentTests {
    private static func packageRoot() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        var cursor = here.deletingLastPathComponent()  // Service/
        cursor.deleteLastPathComponent()  // Tests/
        return cursor.deletingLastPathComponent()  // OsaurusCore/
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Defaults fail safe (toward loading, never toward refusing)

    @Test("A dispatch is interactive unless its trigger says otherwise")
    func dispatchDefaultsToInteractive() {
        let request = DispatchRequest(prompt: "hi")
        // The dangerous default would be `.background`: a real user-facing run
        // that forgot the flag would silently decline to load its model.
        #expect(request.loadIntent == .interactive)
    }

    @Test("An autonomous trigger carries background intent end to end")
    @MainActor
    func backgroundDispatchCarriesIntent() {
        let cron = DispatchRequest(prompt: "daily digest", source: .schedule, loadIntent: .background)
        #expect(cron.loadIntent == .background)

        let context = ExecutionContext(
            agentId: UUID(),
            source: .schedule,
            loadIntent: cron.loadIntent
        )
        // The session is what ultimately builds the request the model sees; if the
        // intent dies here, everything downstream is interactive again.
        #expect(context.chatSession.loadIntent == .background)
        #expect(context.chatSession.source.inferenceSource == .scheduled)
    }

    // MARK: - The trap

    @Test("Run Now stays interactive even though it is a schedule")
    func runNowIsNotBackground() throws {
        let src = try Self.source("Managers/ScheduleManager.swift")

        // `runNow` and the cron fire call the SAME `executeSchedule` with the SAME
        // `source: .schedule`. Only the explicit intent tells them apart. If someone
        // "simplifies" this by inferring intent from `source`, the Run Now button
        // silently stops being able to load its model whenever another model is
        // resident — and it will look like a hang, not a refusal.
        #expect(src.contains("executeSchedule(schedule, loadIntent: .interactive)"))
        #expect(src.contains("executeSchedule(schedule, loadIntent: .background)"))
        #expect(
            !src.contains("executeSchedule(schedule)\n"),
            "every executeSchedule call must state its intent explicitly"
        )

        // Same shared-builder trap in the Next Run panel: the automatic wake and the
        // panel's own "Run now" button both go through `makeDispatchRequest`.
        let scheduler = try Self.source("Managers/NextRunScheduler.swift")
        #expect(scheduler.contains("makeDispatchRequest(for: entry, loadIntent: .background)"))
        let panel = try Self.source("Views/Agent/NextRunPanelView.swift")
        #expect(
            !panel.contains("loadIntent: .background"),
            "the Next Run panel button is a human pressing it — it must not be background"
        )
    }

    @Test("Every autonomous trigger is background")
    func autonomousTriggersAreBackground() throws {
        let watcher = try Self.source("Managers/WatcherManager.swift")
        #expect(watcher.contains("loadIntent: .background"))
    }

    // MARK: - The session's provenance must survive to the engine

    @Test("Headless sessions no longer masquerade as the chat UI")
    func headlessSessionsAreNotChatUI() throws {
        let chatView = try Self.source("Views/Chat/ChatView.swift")

        // The engine factory used to hardcode `ChatEngine(source: .chatUI)` and ignore
        // the session's own `source`, flattening cron/watcher/self-wake runs into
        // "the user is typing". That mislabel had teeth beyond eviction:
        // `accelerateIdleUnloadAfterChatClose` only shortens residency for `.chatUI`
        // models, so closing an unrelated chat window could accelerate the unload of
        // the model a scheduled job was mid-run with.
        #expect(
            !chatView.contains("ChatEngine(source: .chatUI)"),
            "the engine must take the session's real source, not a hardcoded .chatUI"
        )
        #expect(chatView.contains("chatEngineFactory(source.inferenceSource)"))
    }

    @Test("Autonomous sources map to a provenance that is not chatUI")
    func autonomousSourcesMapAwayFromChatUI() {
        #expect(SessionSource.schedule.inferenceSource == .scheduled)
        #expect(SessionSource.watcher.inferenceSource == .scheduled)
        #expect(SessionSource.selfSchedule.inferenceSource == .scheduled)

        // …and the ones a human drives keep theirs.
        #expect(SessionSource.chat.inferenceSource == .chatUI)
        #expect(SessionSource.http.inferenceSource == .httpAPI)
        #expect(SessionSource.plugin.inferenceSource == .plugin)

        // The chat-close accelerated unload keys on exactly this: anything that is
        // not `.chatUI` is left alone.
        #expect(SessionSource.schedule.inferenceSource != .chatUI)
    }
}
