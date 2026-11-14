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
        #expect(context.chatSession.source.inferenceSource == .schedule)
    }

    // MARK: - The trap

    @Test("Fire Now stays interactive even though it is a schedule")
    func fireNowIsNotBackground() throws {
        // Fire Now and the timer both submit a schedule occurrence that reaches
        // the same executor with the SAME `source: .schedule`. Only the explicit
        // intent tells them apart. If someone "simplifies" this by inferring
        // intent from `source`, Fire Now silently stops being able to load its
        // model whenever another model is resident — and it will look like a
        // hang, not a refusal. Each adapter's `fireNow` sets it.
        let schedule = try Self.source("Services/Event/ScheduleEventSource.swift")
        #expect(schedule.contains("trigger: .manual, loadIntent: .interactive"))
        #expect(schedule.contains("loadIntent: .background"))
        let webhook = try Self.source("Services/Event/WebhookEventSource.swift")
        #expect(webhook.contains("trigger: .manual, loadIntent: .interactive"))

        // Same trap in the Next Run panel: a self-scheduled wake and the panel's
        // own "Run now" button both fire the agent's wake automation, so the
        // dispatch takes the occurrence's intent instead of fixing one.
        let wakes = try Self.source("Services/Event/SelfScheduleAutomations.swift")
        #expect(wakes.contains("loadIntent: occurrence.loadIntent"))
        let panel = try Self.source("Views/Agent/NextRunPanelView.swift")
        #expect(panel.contains("EventManager.shared.fireNow(wake.id)"))
        #expect(
            !panel.contains("loadIntent: .background"),
            "the Next Run panel button is a human pressing it — it must not be background"
        )
    }

    @Test("Every autonomous trigger is background")
    func autonomousTriggersAreBackground() throws {
        // A folder's first Fire Now pass is the only interactive folder run.
        let folder = try Self.source("Services/Event/FolderEventSource.swift")
        #expect(folder.contains("loadIntent: trigger == .manual && iteration == 1 ? .interactive : .background"))
        let webhook = try Self.source("Services/Event/WebhookEventSource.swift")
        #expect(webhook.contains("isExternal: true, loadIntent: .background"))
        // Every channel kind (Email included) reaches agents through the relay.
        let relay = try Self.source("Services/AgentChannel/AgentChannelInboundRelay.swift")
        #expect(relay.contains("externalSurface: true,\n                loadIntent: .background"))
    }

    @Test("An event's intent reaches the dispatch unchanged")
    @MainActor
    func eventIntentReachesTheDispatch() {
        let action = AgentEventAction(target: .local(UUID()), instructions: "digest")
        let event = OsaurusEvent(
            name: "Digest", source: .schedule(ScheduleSourceConfig(frequency: .daily(hour: 8, minute: 0))),
            action: .agent(action))
        for intent in [ModelLoadIntent.background, .interactive] {
            let occurrence = EventOccurrence(eventId: event.id, payload: .object([:]), loadIntent: intent)
            let request = AgentTurnWorker.dispatchRequest(event: event, action: action, occurrence: occurrence)
            #expect(request.loadIntent == intent)
            #expect(request.source == .automation)
            #expect(request.automationKind == .schedule)
        }
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
        #expect(chatView.contains("chatEngineFactory(runtimeSource.inferenceSource)"))
        for kind in [EventSourceKind.schedule, .folder, .webhook] {
            #expect(SessionSource.automation.runtimeSource(automationKind: kind) == kind.sessionSource)
            #expect(SessionSource.automation.runtimeSource(automationKind: kind).inferenceSource != .chatUI)
        }
    }

    @Test("Autonomous sources map to a provenance that is not chatUI")
    func autonomousSourcesMapAwayFromChatUI() {
        #expect(SessionSource.schedule.inferenceSource == .schedule)
        #expect(SessionSource.watcher.inferenceSource == .watcher)
        #expect(SessionSource.selfSchedule.inferenceSource == .selfSchedule)

        // …and the ones a human drives keep theirs.
        #expect(SessionSource.chat.inferenceSource == .chatUI)
        #expect(SessionSource.http.inferenceSource == .httpAPI)
        #expect(SessionSource.plugin.inferenceSource == .plugin)

        // The chat-close accelerated unload keys on exactly this: anything that is
        // not `.chatUI` is left alone.
        #expect(SessionSource.schedule.inferenceSource != .chatUI)
    }
}
