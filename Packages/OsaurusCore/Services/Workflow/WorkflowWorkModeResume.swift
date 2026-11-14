//
//  WorkflowWorkModeResume.swift
//  osaurus
//
//  A Work Mode task whose workflow call stopped for a form. The tool
//  answered `awaiting_user` and the turn ended; when the run ends, its
//  result replaces that answer in the transcript and the task continues
//  from it, the way a clarify answer continues a paused chat. A turn can
//  park several calls at once; the task waits until every run has ended.
//  The parked set is saved with the session, so a chat opened after a
//  relaunch picks its runs up again (`WorkflowRunService` resumes them).
//

import Foundation

/// One workflow call a chat is waiting on: the run and the tool-call row
/// whose result the run's outcome replaces.
public struct ParkedWorkflowCall: Codable, Sendable, Equatable, Hashable {
    public var runID: UUID
    public var callId: String
    public var toolName: String

    public init(runID: UUID, callId: String, toolName: String) {
        self.runID = runID
        self.callId = callId
        self.toolName = toolName
    }

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case callId = "call_id"
        case toolName = "tool_name"
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// The set as stored on the session row; nil when empty.
    public static func encodedJSON(_ calls: [ParkedWorkflowCall]) -> String? {
        guard !calls.isEmpty, let data = try? encoder.encode(calls.sorted { $0.callId < $1.callId }) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(json: String?) -> [ParkedWorkflowCall] {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ParkedWorkflowCall].self, from: data)) ?? []
    }
}

extension ChatSession {
    /// Parked calls, as saved with the session.
    var parkedWorkflowCalls: [ParkedWorkflowCall] {
        awaitingWorkflowRuns.values.sorted { $0.callId < $1.callId }
    }

    func parkOnWorkflowRun(_ runID: UUID, callId: String, toolName: String) {
        removeWorkflowRunObserver(runID)
        awaitingWorkflowRuns[runID] = ParkedWorkflowCall(runID: runID, callId: callId, toolName: toolName)
        workflowRunObservers[runID] = NotificationCenter.default.addObserver(
            forName: .workflowRunFinished, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.userInfo?["runID"] as? UUID) == runID else { return }
            MainActor.assumeIsolated {
                self?.resumeAfterWorkflowRun(runID)
            }
        }
        // The run can end between parking and the observer being added.
        if let run = WorkflowRunStore.shared.run(id: runID), run.status.isTerminal,
            !WorkflowRunService.shared.isActive(runID)
        {
            resumeAfterWorkflowRun(runID)
        }
    }

    /// Parks the calls a saved session was waiting on when it was last
    /// written. A run that ended meanwhile lands in the transcript now; the
    /// task continues once every run has, unless the run was cancelled —
    /// the person stopped it, and a cancelled call is nothing to go on
    /// with.
    func reparkWorkflowRuns(_ calls: [ParkedWorkflowCall]) {
        var continues = true
        for call in calls {
            if let run = WorkflowRunStore.shared.run(id: call.runID), run.status == .cancelled,
                !WorkflowRunService.shared.isActive(call.runID)
            {
                continues = false
            }
        }
        for call in calls {
            awaitingWorkflowRuns[call.runID] = call
        }
        resumesAfterParkedWorkflowRuns = continues
        for call in calls {
            parkOnWorkflowRun(call.runID, callId: call.callId, toolName: call.toolName)
        }
    }

    /// The user stopped a task that is waiting on forms: every run is
    /// cancelled and the task does not resume.
    func cancelParkedWorkflowRuns() {
        let runIDs = Array(awaitingWorkflowRuns.keys)
        guard !runIDs.isEmpty else { return }
        for runID in runIDs { removeWorkflowRunObserver(runID) }
        awaitingWorkflowRuns = [:]
        resumesAfterParkedWorkflowRuns = true
        for runID in runIDs { WorkflowRunService.shared.cancel(runID) }
    }

    func resumeAfterWorkflowRun(_ runID: UUID) {
        guard let call = awaitingWorkflowRuns.removeValue(forKey: runID) else { return }
        removeWorkflowRunObserver(runID)
        guard let run = WorkflowRunStore.shared.run(id: runID) else { return }
        let result = WorkflowToolCall.envelope(
            WorkflowCallResult(run: run), workflow: run.workflowName, tool: call.toolName)
        if let toolTurn = turns.last(where: { $0.role == .tool && $0.toolCallId == call.callId }) {
            toolTurn.content = result
        }
        turns.last(where: { $0.toolCalls?.contains { $0.id == call.callId } ?? false })?
            .setToolResult(result, for: call.callId)
        rebuildVisibleBlocks()
        save()
        Task { await self.promoteWorkerSharedArtifacts(callId: call.callId) }
        // The task goes on once every parked run has ended. A run the user
        // already started (a reply typed meanwhile) carries the
        // conversation on; the updated results are in its history.
        guard awaitingWorkflowRuns.isEmpty else { return }
        let continues = resumesAfterParkedWorkflowRuns
        resumesAfterParkedWorkflowRuns = true
        guard continues, !isStreaming else { return }
        send("")
    }

    func removeWorkflowRunObserver(_ runID: UUID) {
        if let observer = workflowRunObservers.removeValue(forKey: runID) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    nonisolated func removeAllWorkflowRunObservers() {
        for observer in workflowRunObservers.values { NotificationCenter.default.removeObserver(observer) }
        workflowRunObservers = [:]
    }
}
