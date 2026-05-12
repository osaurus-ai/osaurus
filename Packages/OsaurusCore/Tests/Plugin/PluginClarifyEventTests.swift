//
//  PluginClarifyEventTests.swift
//  OsaurusCoreTests
//
//  Pins the agent-loop `clarify` → plugin event contract:
//
//   1. `serializeClarificationEvent` (pure) — payload shape, options-key
//      omission for free-form questions, allow_multiple round-trip.
//   2. `BackgroundTaskManager` bridge — `ChatSession.awaitingClarify`
//      transitions the task to `.awaitingClarification` and SUPPRESSES
//      the spurious COMPLETED event that previously fired the moment
//      the chat-layer intercept yielded the iteration loop.
//   3. End-to-end emission through a fake `LoadedPlugin` — the plugin
//      sees a single `OSR_TASK_EVENT_CLARIFICATION` (type 3) with the
//      parsed payload, and no terminal event follows for the pause.
//
//  Without these guards, plugin-dispatched `clarify` runs would post
//  the literal tool envelope JSON as a "completion" — the production
//  bug that surfaced as a Telegram bot replying with
//  `{"ok":true,"result":{"text":"Awaiting user response."},"tool":"clarify"}`.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - 1. Serializer shape

@MainActor
struct ClarifyEventSerializationTests {

    private func parse(_ json: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }

    /// Free-form clarify (no options) MUST omit the `options` key entirely
    /// so plugins can use key-presence as the "free-form vs choice"
    /// discriminator instead of distinguishing `[]` from missing.
    @Test
    func freeFormClarify_omitsOptionsKey() {
        let payload = ClarifyPayload(question: "What city?", options: [], allowMultiple: false)
        let json = PluginHostContext.serializeClarificationEvent(payload: payload)
        let dict = parse(json)
        #expect(dict?["question"] as? String == "What city?")
        #expect(dict?["allow_multiple"] as? Bool == false)
        #expect(dict?["options"] == nil)
    }

    @Test
    func choiceClarify_emitsOptionsAndAllowMultiple() {
        let payload = ClarifyPayload(
            question: "Pick platforms",
            options: ["iOS", "Android"],
            allowMultiple: true
        )
        let json = PluginHostContext.serializeClarificationEvent(payload: payload)
        let dict = parse(json)
        #expect(dict?["question"] as? String == "Pick platforms")
        #expect(dict?["allow_multiple"] as? Bool == true)
        let options = dict?["options"] as? [String]
        #expect(options == ["iOS", "Android"])
    }

    @Test
    func choiceClarify_singleSelectKeepsAllowMultipleFalse() {
        let payload = ClarifyPayload(
            question: "DB?",
            options: ["Postgres", "SQLite"],
            allowMultiple: false
        )
        let dict = parse(PluginHostContext.serializeClarificationEvent(payload: payload))
        #expect(dict?["allow_multiple"] as? Bool == false)
        #expect((dict?["options"] as? [String])?.count == 2)
    }
}

// MARK: - 2. BTM bridge: state transitions + COMPLETED suppression

@Suite(.serialized)
@MainActor
struct BackgroundTaskClarifyObserverTests {

    private func makeObservedState() -> (state: BackgroundTaskState, mgr: BackgroundTaskManager) {
        let context = ExecutionContext(agentId: Agent.defaultId)
        // Mock engine yields nothing so isStreaming only flips when the
        // test sets it explicitly. Mirrors `BackgroundTaskStreamingObserverTests`.
        context.chatSession.chatEngineFactory = { MockChatEngine() }

        let state = BackgroundTaskState(
            id: UUID(),
            taskTitle: "clarify-observer-test",
            agentId: Agent.defaultId,
            chatSession: context.chatSession,
            executionContext: context,
            status: .running,
            currentStep: "Running..."
        )
        let mgr = BackgroundTaskManager.shared
        mgr.registerTaskForTesting(state)
        mgr.observeChatTask(state, session: context.chatSession)
        return (state, mgr)
    }

    /// Setting `awaitingClarify` while streaming flips the task to
    /// `.awaitingClarification`. The status carries through to the
    /// streaming-end branch so `markCompleted` is skipped.
    @Test
    func awaitingClarifySet_transitionsStatus() async throws {
        let (state, mgr) = makeObservedState()
        defer { mgr.finalizeTask(state.id) }

        state.chatSession?.isStreaming = true
        try await Task.sleep(for: .milliseconds(10))
        state.chatSession?.awaitingClarify =
            ClarifyPayload(question: "Use Postgres or SQLite?", options: [], allowMultiple: false)
        try await Task.sleep(for: .milliseconds(10))

        #expect(state.status == .awaitingClarification)
    }

    /// Streaming-end while `state.status == .awaitingClarification` MUST
    /// NOT mark the task completed. This is the regression guard for the
    /// Telegram-bot bug where COMPLETED was firing with the clarify
    /// envelope as `output`.
    @Test
    func streamingEnd_duringClarifyPause_doesNotCompleteTask() async throws {
        let (state, mgr) = makeObservedState()
        defer { mgr.finalizeTask(state.id) }

        state.chatSession?.isStreaming = true
        try await Task.sleep(for: .milliseconds(10))
        state.chatSession?.awaitingClarify =
            ClarifyPayload(question: "Pick a name", options: [], allowMultiple: false)
        try await Task.sleep(for: .milliseconds(10))
        // Stream ends as soon as the intercept's `break outer` unwinds.
        state.chatSession?.isStreaming = false
        try await Task.sleep(for: .milliseconds(10))

        #expect(state.status == .awaitingClarification)
    }

    /// After the user answers (clearing `awaitingClarify`) the loop
    /// resumes, isStreaming flips back to true, and a subsequent
    /// streaming-end DOES mark the task completed normally. Guards
    /// against an over-broad fix that would leave the task stuck in
    /// `.awaitingClarification` forever.
    @Test
    func resumeAfterClarify_thenStreamingEnd_marksCompleted() async throws {
        let (state, mgr) = makeObservedState()
        defer { mgr.finalizeTask(state.id) }

        state.chatSession?.isStreaming = true
        try await Task.sleep(for: .milliseconds(10))
        state.chatSession?.awaitingClarify =
            ClarifyPayload(question: "Q", options: [], allowMultiple: false)
        try await Task.sleep(for: .milliseconds(10))
        // User answers — clear the pause and resume streaming.
        state.chatSession?.awaitingClarify = nil
        state.chatSession?.isStreaming = true
        try await Task.sleep(for: .milliseconds(10))
        state.chatSession?.isStreaming = false
        try await Task.sleep(for: .milliseconds(10))

        #expect(state.status == .completed(success: true, summary: "Chat completed"))
    }
}

// MARK: - 3. End-to-end emission through a fake LoadedPlugin

/// Side-channel for the C `on_task_event` callback: the recorder is
/// passed through the opaque `ctx` pointer because `@convention(c)`
/// blocks can't capture Swift state. Mirrors the pattern used in
/// `PluginRelayReconnectRedeliveryTests`.
private final class TaskEventRecorder: @unchecked Sendable {
    struct Event {
        let type: Int32
        let json: String
    }
    private let lock = NSLock()
    private var _events: [Event] = []
    var events: [Event] {
        lock.withLock { _events }
    }
    func record(type: Int32, json: String) {
        lock.withLock { _events.append(Event(type: type, json: json)) }
    }
}

@Suite(.serialized)
@MainActor
struct PluginClarifyEmissionTests {

    private func parse(_ json: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }

    /// Build a fake `LoadedPlugin` whose `on_task_event` records every
    /// `(eventType, json)` it receives. The recorder is held by the
    /// caller via the returned `Unmanaged` so `@convention(c)` can
    /// reach it via the opaque ctx pointer without retaining at
    /// construction time.
    private func makeRecordingPlugin(
        pluginId: String,
        recorder: TaskEventRecorder
    ) -> (loaded: PluginManager.LoadedPlugin, retain: Unmanaged<TaskEventRecorder>) {
        let retain = Unmanaged.passRetained(recorder)
        let ctx = retain.toOpaque()
        let api = osr_plugin_api(
            free_string: nil,
            init: nil,
            destroy: nil,
            get_manifest: nil,
            invoke: nil,
            version: 2,
            handle_route: nil,
            on_config_changed: nil,
            on_task_event: { ctxPtr, _, eventType, jsonPtr in
                guard let ctxPtr, let jsonPtr else { return }
                let r = Unmanaged<TaskEventRecorder>.fromOpaque(ctxPtr).takeUnretainedValue()
                r.record(type: eventType, json: String(cString: jsonPtr))
            }
        )
        let manifest = PluginManifest(
            plugin_id: pluginId,
            description: nil,
            capabilities: .init(tools: nil, routes: nil, config: nil, web: nil, artifact_handler: nil),
            instructions: nil,
            name: nil,
            version: nil,
            license: nil,
            authors: nil,
            min_macos: nil,
            min_osaurus: nil,
            secrets: nil,
            docs: nil
        )
        let plugin = ExternalPlugin(
            handle: ctx,
            api: api,
            ctx: ctx,
            manifest: manifest,
            path: "/tmp/test-\(pluginId)",
            abiVersion: 2
        )
        let loaded = PluginManager.LoadedPlugin(
            plugin: plugin,
            handle: ctx,
            tools: [],
            skills: [],
            routes: [],
            webConfig: nil,
            readmePath: nil,
            changelogPath: nil
        )
        return (loaded, retain)
    }

    private func makeObservedState(
        pluginId: String
    ) -> (state: BackgroundTaskState, mgr: BackgroundTaskManager) {
        let context = ExecutionContext(agentId: Agent.defaultId)
        context.chatSession.chatEngineFactory = { MockChatEngine() }
        let state = BackgroundTaskState(
            id: UUID(),
            taskTitle: "clarify-emit-test",
            agentId: Agent.defaultId,
            chatSession: context.chatSession,
            executionContext: context,
            status: .running,
            currentStep: "Running...",
            sourcePluginId: pluginId
        )
        let mgr = BackgroundTaskManager.shared
        mgr.registerTaskForTesting(state)
        mgr.observeChatTask(state, session: context.chatSession)
        return (state, mgr)
    }

    /// Setting `awaitingClarify` on a plugin-dispatched session emits
    /// exactly one `OSR_TASK_EVENT_CLARIFICATION` (type 3) carrying the
    /// parsed `{question, options, allow_multiple}` payload — and no
    /// terminal event (type 4/5/6) follows even after streaming ends.
    @Test
    func clarifyEvent_emittedOnce_noTerminalFollows() async throws {
        let recorder = TaskEventRecorder()
        let pluginId = "com.test.clarify.emit.\(UUID().uuidString)"
        let (loaded, retain) = makeRecordingPlugin(pluginId: pluginId, recorder: recorder)

        let mgr = PluginManager.shared
        mgr.injectLoadedPluginForTesting(loaded)
        defer {
            mgr.removeLoadedPluginForTesting(pluginId: pluginId)
            retain.release()
        }

        let (state, btm) = makeObservedState(pluginId: pluginId)
        defer { btm.finalizeTask(state.id) }

        state.chatSession?.isStreaming = true
        try await Task.sleep(for: .milliseconds(10))
        state.chatSession?.awaitingClarify = ClarifyPayload(
            question: "Use Postgres or SQLite?",
            options: ["Postgres", "SQLite"],
            allowMultiple: false
        )
        try await Task.sleep(for: .milliseconds(50))
        // Stream ends as the chat-layer intercept yields. With the
        // suppression contract this MUST NOT trigger a COMPLETED event.
        state.chatSession?.isStreaming = false
        try await Task.sleep(for: .milliseconds(50))

        let clarifyEvents = recorder.events.filter { $0.type == TaskEventType.clarification.rawValue }
        let terminalEvents = recorder.events.filter {
            $0.type == TaskEventType.completed.rawValue
                || $0.type == TaskEventType.failed.rawValue
                || $0.type == TaskEventType.cancelled.rawValue
        }

        #expect(clarifyEvents.count == 1)
        #expect(terminalEvents.isEmpty)

        let payload = parse(clarifyEvents[0].json)
        #expect(payload?["question"] as? String == "Use Postgres or SQLite?")
        #expect(payload?["allow_multiple"] as? Bool == false)
        #expect((payload?["options"] as? [String]) == ["Postgres", "SQLite"])
    }

    /// Regression guard for the "100+ tests crashed with signal segv"
    /// pattern that hit `main` after PR #1066 (CI runs 25738325529 and
    /// 25742705850). The actual crash was a use-after-free in this very
    /// suite: `clarifyEvent_emittedOnce_noTerminalFollows` would
    /// `Unmanaged.passRetained(recorder)` and then `release()` it in the
    /// outer `defer` — but `removeLoadedPluginForTesting` did NOT drain
    /// the plugin's per-task event dispatch queue first, so a terminal
    /// event queued by the inner `BackgroundTaskManager.finalizeTask`
    /// defer would fire AFTER the recorder was deallocated and SIGSEGV
    /// the entire xctest process. Because the dying process took out
    /// every test scheduled on the same worker, the failure surfaced as
    /// 100+ unrelated tests tagged "crashed with signal segv" across
    /// 50+ suites — the actual culprit was invisible without a
    /// symbolicated crash report.
    ///
    /// This test pins the contract that fixes the crash:
    /// `removeLoadedPluginForTesting(pluginId:)` MUST synchronously
    /// drain every pending `notifyTaskEvent` callback for that plugin
    /// before returning, so a test's matched `Unmanaged.release()` in
    /// the same `defer` is always safe. We make the contract observable
    /// by injecting a deliberately-slow event handler (50 ms `usleep`)
    /// and firing three events across two task IDs immediately before
    /// `removeLoadedPluginForTesting`. With the drain, the call blocks
    /// until all three handlers complete; without it, the call returns
    /// immediately and the counter is still 0.
    @Test
    func removeLoadedPluginForTesting_drainsPendingTaskEvents() async throws {
        final class CallCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0
            var count: Int { lock.withLock { _count } }
            // 50 ms is well above the few µs `q.sync(flags: .barrier)`
            // takes to schedule on an idle queue — large enough that an
            // un-drained `removeLoadedPluginForTesting` would race past
            // the increment and observe `count == 0`.
            func slowIncrement() {
                usleep(50_000)
                lock.withLock { _count += 1 }
            }
        }

        let counter = CallCounter()
        let pluginId = "com.test.drain.\(UUID().uuidString)"
        let retain = Unmanaged.passRetained(counter)
        let ctx = retain.toOpaque()
        // The whole point of the bug was that this `release()` would run
        // BEFORE pending events drained. With the drain in place, every
        // queued handler has already completed by the time we get here,
        // so the release is safe.
        defer { retain.release() }

        let api = osr_plugin_api(
            free_string: nil,
            init: nil,
            destroy: nil,
            get_manifest: nil,
            invoke: nil,
            version: 2,
            handle_route: nil,
            on_config_changed: nil,
            on_task_event: { ctxPtr, _, _, _ in
                guard let ctxPtr else { return }
                let c = Unmanaged<CallCounter>.fromOpaque(ctxPtr).takeUnretainedValue()
                c.slowIncrement()
            }
        )
        let manifest = PluginManifest(
            plugin_id: pluginId,
            description: nil,
            capabilities: .init(tools: nil, routes: nil, config: nil, web: nil, artifact_handler: nil),
            instructions: nil,
            name: nil,
            version: nil,
            license: nil,
            authors: nil,
            min_macos: nil,
            min_osaurus: nil,
            secrets: nil,
            docs: nil
        )
        let plugin = ExternalPlugin(
            handle: ctx,
            api: api,
            ctx: ctx,
            manifest: manifest,
            path: "/tmp/test-\(pluginId)",
            abiVersion: 2
        )
        let loaded = PluginManager.LoadedPlugin(
            plugin: plugin,
            handle: ctx,
            tools: [],
            skills: [],
            routes: [],
            webConfig: nil,
            readmePath: nil,
            changelogPath: nil
        )

        let mgr = PluginManager.shared
        mgr.injectLoadedPluginForTesting(loaded)

        // Fan-out: two events on `task-1` (same serial queue) and one on
        // `task-2` (separate serial queue). The drain must wait for
        // BOTH per-task queues, not just the first one created.
        plugin.notifyTaskEvent(taskId: "task-1", eventType: .clarification, eventJSON: "{}")
        plugin.notifyTaskEvent(taskId: "task-1", eventType: .clarification, eventJSON: "{}")
        plugin.notifyTaskEvent(taskId: "task-2", eventType: .clarification, eventJSON: "{}")

        // The synchronous contract: when `removeLoadedPluginForTesting`
        // returns, ALL three queued events have run to completion. The
        // pre-fix behavior returned immediately and observed
        // `counter.count == 0`.
        mgr.removeLoadedPluginForTesting(pluginId: pluginId)

        #expect(
            counter.count == 3,
            "removeLoadedPluginForTesting must synchronously drain pending events; counter was \(counter.count) (expected 3)"
        )
    }

    /// After the user answers, the next streaming-end DOES emit a
    /// COMPLETED event — confirming the suppression is a per-pause
    /// guard, not a permanent block.
    @Test
    func resumeAfterClarify_thenStreamingEnd_emitsCompleted() async throws {
        let recorder = TaskEventRecorder()
        let pluginId = "com.test.clarify.resume.\(UUID().uuidString)"
        let (loaded, retain) = makeRecordingPlugin(pluginId: pluginId, recorder: recorder)

        let mgr = PluginManager.shared
        mgr.injectLoadedPluginForTesting(loaded)
        defer {
            mgr.removeLoadedPluginForTesting(pluginId: pluginId)
            retain.release()
        }

        let (state, btm) = makeObservedState(pluginId: pluginId)
        defer { btm.finalizeTask(state.id) }

        state.chatSession?.isStreaming = true
        try await Task.sleep(for: .milliseconds(10))
        state.chatSession?.awaitingClarify =
            ClarifyPayload(question: "Q", options: [], allowMultiple: false)
        try await Task.sleep(for: .milliseconds(50))
        // User answered — clear the pause and resume the loop.
        state.chatSession?.awaitingClarify = nil
        state.chatSession?.isStreaming = true
        try await Task.sleep(for: .milliseconds(10))
        state.chatSession?.isStreaming = false
        try await Task.sleep(for: .milliseconds(50))

        let clarifyEvents = recorder.events.filter { $0.type == TaskEventType.clarification.rawValue }
        let completedEvents = recorder.events.filter { $0.type == TaskEventType.completed.rawValue }
        #expect(clarifyEvents.count == 1)
        #expect(completedEvents.count == 1)
    }
}
