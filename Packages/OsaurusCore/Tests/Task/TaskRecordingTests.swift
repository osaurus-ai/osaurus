//
//  TaskRecordingTests.swift
//  osaurusTests
//
//  Shadow records and projections around the task store: subagent spawns
//  as child tasks (and a user Stop recorded as cancelled), the Insights
//  row a finished task mirrors, and the Tasks → History filter.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct SubagentTaskRecorderTests {
    static func withStore(_ body: (TaskStore) throws -> Void) rethrows {
        let previous = SubagentTaskRecorder.store
        let store = TaskStore(database: nil)
        SubagentTaskRecorder.store = store
        defer {
            SubagentTaskRecorder.store = previous
            SubagentTaskRecorder.stopRequested.removeAll()
        }
        try body(store)
    }

    static let scope = SubagentScope(sessionId: UUID().uuidString, toolCallId: "call-1", agentId: UUID())

    @Test func spawnIsAChildOfTheRunningTask() throws {
        try Self.withStore { store in
            let parent = OsaurusTask(
                title: "Parent", origin: .automation, createdBy: .user,
                work: .agentTurn(AgentTurnWork(agentId: Self.scope.agentId, source: .automation)), state: .running)
            store.record(parent)

            let childId = ChatExecutionContext.$currentTaskId.withValue(parent.id) {
                SubagentTaskRecorder.began(title: "Research", scope: Self.scope, model: "m")
            }
            let child = try #require(store.task(id: childId))
            #expect(child.parentId == parent.id)
            #expect(child.rootId == parent.rootId)
            #expect(child.depth == 1)
            #expect(child.origin == .spawn)
            #expect(child.state == .running)
            #expect(child.sessionId?.uuidString == Self.scope.sessionId)
        }
    }

    @Test func recordingFromARunDoesNotWaitForTheMainActor() async throws {
        let previous = SubagentTaskRecorder.store
        let store = TaskStore(database: nil)
        SubagentTaskRecorder.store = store
        defer { SubagentTaskRecorder.store = previous }
        let parent = OsaurusTask(
            title: "Parent", origin: .automation, createdBy: .user,
            work: .agentTurn(AgentTurnWork(agentId: Self.scope.agentId, source: .automation)), state: .running)
        store.record(parent)

        let scope = Self.scope
        let id = await Task.detached {
            ChatExecutionContext.$currentTaskId.withValue(parent.id) {
                let id = SubagentTaskRecorder.record(title: "Off main", scope: scope, model: nil)
                SubagentTaskRecorder.recordFinished(id, envelope: ToolEnvelope.success(text: "ok"), interrupted: false)
                return id
            }
        }.value
        for _ in 0 ..< 100 where store.task(id: id)?.state != .succeeded {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.task(id: id)?.state == .succeeded)
        #expect(store.task(id: id)?.parentId == parent.id)
    }

    @Test func outcomesMapToStates() {
        Self.withStore { store in
            let ok = SubagentTaskRecorder.began(title: "A", scope: Self.scope, model: nil)
            SubagentTaskRecorder.finished(ok, envelope: ToolEnvelope.success(text: "done"), interrupted: false)
            #expect(store.task(id: ok)?.state == .succeeded)

            let failure = ToolEnvelope.failure(kind: .executionError, message: "boom")
            let failed = SubagentTaskRecorder.began(title: "B", scope: Self.scope, model: nil)
            SubagentTaskRecorder.finished(failed, envelope: failure, interrupted: false)
            #expect(store.task(id: failed)?.state == .failed)
            #expect(store.task(id: failed)?.lastError == "boom")

            let interrupted = SubagentTaskRecorder.began(title: "C", scope: Self.scope, model: nil)
            SubagentTaskRecorder.finished(interrupted, envelope: failure, interrupted: true)
            #expect(store.task(id: interrupted)?.state == .cancelled)
        }
    }

    @Test func spawnFromAnInteractiveChatRemembersTheChat() {
        Self.withStore { store in
            let chat = UUID()
            let interactive = ChatExecutionContext.$currentSessionId.withValue(chat.uuidString) {
                SubagentTaskRecorder.began(title: "Research", scope: Self.scope, model: nil)
            }
            #expect(store.task(id: interactive)?.originSessionId == chat)

            let background = ChatExecutionContext.$currentSessionId.withValue(chat.uuidString) {
                ChatExecutionContext.$currentBackgroundId.withValue(UUID()) {
                    SubagentTaskRecorder.began(title: "Research", scope: Self.scope, model: nil)
                }
            }
            #expect(store.task(id: background)?.originSessionId == nil)
        }
    }

    @Test func childrenInheritTheRootsChatNotTheCurrentOne() {
        Self.withStore { store in
            let rootChat = UUID()
            var fromChat = OsaurusTask(
                title: "From chat", origin: .spawn, createdBy: .user,
                work: .agentTurn(AgentTurnWork(agentId: nil, source: .chat)), state: .running)
            fromChat.originSessionId = rootChat
            let unattended = OsaurusTask(
                title: "Automation", origin: .automation, createdBy: .user,
                work: .agentTurn(AgentTurnWork(agentId: nil, source: .automation)), state: .running)
            store.record(fromChat)
            store.record(unattended)

            @MainActor func spawn(under parent: OsaurusTask) -> UUID {
                ChatExecutionContext.$currentSessionId.withValue(UUID().uuidString) {
                    ChatExecutionContext.$currentTaskId.withValue(parent.id) {
                        SubagentTaskRecorder.began(title: "Child", scope: Self.scope, model: nil)
                    }
                }
            }
            #expect(store.task(id: spawn(under: fromChat))?.originSessionId == rootChat)
            #expect(store.task(id: spawn(under: unattended))?.originSessionId == nil)
        }
    }

    @Test func aUserStopIsRecordedAsCancelled() {
        Self.withStore { store in
            let id = SubagentTaskRecorder.began(title: "A", scope: Self.scope, model: nil)
            SubagentTaskRecorder.stopRequested.insert(id)
            let failure = ToolEnvelope.failure(kind: .executionError, message: "interrupted")
            SubagentTaskRecorder.finished(id, envelope: failure, interrupted: false)
            #expect(store.task(id: id)?.state == .cancelled)
            #expect(store.task(id: id)?.lastError == nil)
            #expect(!SubagentTaskRecorder.stopRequested.contains(id))
        }
    }
}

/// Background dispatches and workflow runs a chat turn starts link back to
/// the chat; workflow steps run under the run's task.
@MainActor
struct OriginSessionTests {
    @Test func dispatchFromAChatRemembersTheChat() {
        let manager = BackgroundTaskManager.makeForTesting()
        let agentId = UUID()
        let context = ExecutionContext(agentId: agentId)
        let state = BackgroundTaskState(
            id: context.id, taskTitle: "dispatch", agentId: agentId, chatSession: context.chatSession,
            executionContext: context, status: .queued, currentStep: "Queued")
        defer { manager.finalizeTask(state.id) }
        let chat = UUID()
        ChatExecutionContext.$currentSessionId.withValue(chat.uuidString) {
            manager.recordTaskForTesting(
                DispatchRequest(id: state.id, prompt: "hi", agentId: agentId, source: .http), state: state)
        }
        #expect(manager.taskRecordForTesting(state.id)?.originSessionId == chat)
    }

    @Test func workflowRunFromAChatRemembersTheChat() {
        let previous = WorkflowTaskRecorder.store
        let store = TaskStore(database: nil)
        WorkflowTaskRecorder.store = store
        defer { WorkflowTaskRecorder.store = previous }
        let template = WF.template(WF.intake())
        func request() -> WorkflowRunner.Request {
            WorkflowRunner.Request(
                workflowID: UUID(), workflowName: template.name, template: template,
                caller: WorkflowCaller(kind: .agent), input: .object([:]))
        }
        let chat = UUID()
        let fromChat = request()
        ChatExecutionContext.$currentSessionId.withValue(chat.uuidString) {
            WorkflowTaskRecorder.began(fromChat, resuming: false)
        }
        #expect(store.task(id: fromChat.runID)?.originSessionId == chat)

        let fromBackground = request()
        ChatExecutionContext.$currentSessionId.withValue(chat.uuidString) {
            ChatExecutionContext.$currentBackgroundId.withValue(UUID()) {
                WorkflowTaskRecorder.began(fromBackground, resuming: false)
            }
        }
        #expect(store.task(id: fromBackground.runID)?.originSessionId == nil)
    }

    @Test func workflowStepsRunUnderTheRunsTask() {
        let run = UUID()
        #expect(WorkflowCaller(kind: .user).runTaskId(runID: run) == run)
        #expect(WorkflowCaller(kind: .test).runTaskId(runID: run) == nil)
        var automation = WorkflowCaller(kind: .event)
        let owner = UUID()
        automation.taskId = owner
        #expect(automation.runTaskId(runID: run) == owner)
    }
}

@MainActor
struct TaskActivityLoggerTests {
    static func task(_ state: TaskState, origin: TaskOrigin = .automation) -> OsaurusTask {
        OsaurusTask(
            title: "Digest", origin: origin, createdBy: .system("test"),
            work: .agentTurn(AgentTurnWork(agentId: nil, source: .automation)), state: state)
    }

    @Test func onlyFinishedWorkIsLogged() {
        #expect(TaskActivityLogger.shouldLog(Self.task(.succeeded)))
        #expect(TaskActivityLogger.shouldLog(Self.task(.failed)))
        #expect(TaskActivityLogger.shouldLog(Self.task(.suppressed)))
        #expect(!TaskActivityLogger.shouldLog(Self.task(.running)))
        #expect(!TaskActivityLogger.shouldLog(Self.task(.filtered)))
        #expect(!TaskActivityLogger.shouldLog(Self.task(.duplicate)))
    }

    @Test func detailsCarryTheTaskLinks() {
        let parent = UUID()
        let subscription = UUID()
        var task = OsaurusTask(
            title: "Child", rootId: parent, parentId: parent, depth: 1, subscriptionId: subscription,
            origin: .spawn, createdBy: .system("test"),
            work: .agentTurn(AgentTurnWork(agentId: nil, source: .automation)), state: .succeeded)
        task.reason = "done"
        let details = TaskActivityLogger.details(task, queue: TaskQueue.makeDefault())
        #expect(details["task_id"] == task.id.uuidString)
        #expect(details["parent_task_id"] == parent.uuidString)
        #expect(details["root_task_id"] == parent.uuidString)
        #expect(details["depth"] == "1")
        #expect(details["automation_id"] == subscription.uuidString)
        #expect(details["state"] == TaskState.succeeded.rawValue)
        #expect(details["reason"] == "done")
        #expect(details["queue_id"] == TaskQueue.defaultID.uuidString)
    }

    @Test func statusCodesAndSources() {
        #expect(TaskActivityLogger.statusCode(.succeeded) == 200)
        #expect(TaskActivityLogger.statusCode(.suppressed) == 204)
        #expect(TaskActivityLogger.statusCode(.cancelled) == 499)
        #expect(TaskActivityLogger.statusCode(.failed) == 500)
        #expect(TaskActivityLogger.requestSource(.automation) == .automation)
        #expect(TaskActivityLogger.requestSource(.selfSchedule) == .selfSchedule)
        #expect(TaskActivityLogger.requestSource(.spawn) == .agent)
        #expect(TaskActivityLogger.requestSource(.apiDispatch) == .httpAPI)
    }
}

struct TaskHistoryFilterTests {
    @Test func filtersBuildTheMatchingQuery() {
        #expect(TaskHistoryFilter.automations.query().origin == .automation)
        let agentId = UUID()
        #expect(TaskHistoryFilter.agent(agentId).query().agentId == agentId)
        let workflowID = UUID()
        #expect(TaskHistoryFilter.workflow(workflowID).query(limit: 5).workflowID == workflowID)
        #expect(TaskHistoryFilter.workflow(workflowID).query(limit: 5).limit == 5)
        let chat = UUID()
        #expect(TaskHistoryFilter.chat(chat).query().originSessionId == chat)

        var filter = TaskHistoryFilter()
        #expect(filter.query().states == nil)
        filter.status = .failed
        #expect(filter.query().states == [.failed])
        filter.status = .skipped
        #expect(Set(filter.query().states ?? []) == [.filtered, .duplicate, .suppressed])
    }

    @Test func everyTerminalStateFallsInOneStatus() {
        let buckets = TaskHistoryFilter.Status.allCases.compactMap(\.states)
        for state in TaskState.allCases where state.isTerminal {
            #expect(buckets.filter { $0.contains(state) }.count == 1, "\(state)")
        }
    }
}
