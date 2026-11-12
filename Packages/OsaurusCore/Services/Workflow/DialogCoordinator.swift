//
//  DialogCoordinator.swift
//  osaurus
//
//  Pending workflow forms. Each workflow has a FIFO queue: only its head
//  is presented, so two calls to one workflow never show two forms at
//  once. Presenters (the inline chat card, the workflow tab, Work Mode's
//  notification, and the relay HTTP endpoints) read `pending` and answer
//  through `answer(_:values:)`. A form waits until answered, dismissed,
//  its run is cancelled, or its node times out.
//

import Combine
import Foundation

public struct PendingDialog: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let runID: UUID
    public let workflowID: UUID
    public let workflowName: String
    public let nodeID: String
    public let title: String
    /// Rendered with bindings.
    public let message: String
    /// Only the fields that need an answer.
    public let fields: [DialogField]
    public let prefill: [String: JSONValue]
    public let caller: WorkflowCaller
    public let createdAt: Date

    public var isTest: Bool { caller.kind == .test }

    /// Schema answers are validated against.
    var answerSchema: JSONValue { DialogSpec(title: title, fields: fields).derivedOutputSchema }
}

public enum DialogAnswerError: Error, LocalizedError, Equatable {
    case notFound
    case notCurrent
    case invalid([String])

    public var errorDescription: String? {
        switch self {
        case .notFound: return L("That form is no longer waiting for an answer.")
        case .notCurrent: return L("Another form for this workflow comes first.")
        case .invalid(let issues): return L("Check the form: \(issues.joined(separator: "; "))")
        }
    }
}

@MainActor
public final class DialogCoordinator: ObservableObject {
    public static let shared = DialogCoordinator()

    /// Every waiting form, oldest first.
    @Published public private(set) var pending: [PendingDialog] = []

    private var continuations: [UUID: CheckedContinuation<[String: JSONValue], Error>] = [:]

    /// What was typed into a form that closed without an answer (it
    /// expired, its run stopped or failed), by workflow and node, so the
    /// next time that form is asked it starts from there. Memory only, and
    /// never secret fields.
    private var drafts: [String: [String: JSONValue]] = [:]

    private init() {}

    private static func draftKey(workflowID: UUID, nodeID: String) -> String {
        workflowID.uuidString + "/" + nodeID
    }

    /// Keeps what is typed into `dialog` until it is answered.
    func saveDraft(for dialog: PendingDialog, values: [String: JSONValue]) {
        guard pending.contains(where: { $0.id == dialog.id }) else { return }
        let keep = Set(dialog.fields.filter { $0.type != .secret }.map(\.key))
        drafts[Self.draftKey(workflowID: dialog.workflowID, nodeID: dialog.nodeID)] = values.filter {
            keep.contains($0.key)
        }
    }

    func draft(workflowID: UUID, nodeID: String) -> [String: JSONValue] {
        drafts[Self.draftKey(workflowID: workflowID, nodeID: nodeID)] ?? [:]
    }

    /// Heads of each workflow's queue: the forms to show now.
    public var presentable: [PendingDialog] {
        var seen = Set<UUID>()
        return pending.filter { seen.insert($0.workflowID).inserted }
    }

    public func isPresentable(_ dialog: PendingDialog) -> Bool {
        pending.first { $0.workflowID == dialog.workflowID }?.id == dialog.id
    }

    public func dialog(runID: UUID, nodeID: String) -> PendingDialog? {
        pending.first { $0.runID == runID && $0.nodeID == nodeID }
    }

    /// Suspends until the form is answered. Throws `CancellationError` when
    /// the calling task is cancelled (run cancel, node timeout) and
    /// `WorkflowNodeError.dialogDismissed` when the user dismisses it.
    func present(_ dialog: PendingDialog) async throws -> [String: JSONValue] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                continuations[dialog.id] = cont
                pending.append(dialog)
                WorkflowDialogNotifier.dialogPresented(dialog)
            }
        } onCancel: {
            Task { @MainActor in DialogCoordinator.shared.resolve(dialog.id, with: .failure(CancellationError())) }
        }
    }

    /// Validates and submits answers for the form at the head of its queue.
    @discardableResult
    public func answer(_ id: UUID, values: [String: JSONValue]) -> Result<Void, DialogAnswerError> {
        guard let dialog = pending.first(where: { $0.id == id }) else { return .failure(.notFound) }
        guard isPresentable(dialog) else { return .failure(.notCurrent) }
        let cleaned = Self.normalize(values, fields: dialog.fields)
        let issues = JSONSchemaValidator.validate(.object(cleaned), against: dialog.answerSchema)
        if !issues.isEmpty { return .failure(.invalid(issues.map(\.description))) }
        drafts[Self.draftKey(workflowID: dialog.workflowID, nodeID: dialog.nodeID)] = nil
        resolve(id, with: .success(cleaned))
        return .success(())
    }

    public func dismiss(_ id: UUID) {
        resolve(id, with: .failure(WorkflowNodeError.dialogDismissed))
    }

    public func cancelAll(runID: UUID) {
        for dialog in pending where dialog.runID == runID {
            resolve(dialog.id, with: .failure(CancellationError()))
        }
    }

    private func resolve(_ id: UUID, with result: Result<[String: JSONValue], Error>) {
        pending.removeAll { $0.id == id }
        continuations.removeValue(forKey: id)?.resume(with: result)
        WorkflowDialogNotifier.dialogResolved(id)
    }

    /// Drops empty optional answers and coerces numeric strings from text
    /// inputs, so the schema check sees what the form meant.
    static func normalize(_ values: [String: JSONValue], fields: [DialogField]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for field in fields {
            guard var value = values[field.key] else { continue }
            if case .string(let s) = value {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty, !field.required { continue }
                if field.type == .number, let n = Double(trimmed) { value = .number(n) }
            }
            if value == .null, !field.required { continue }
            out[field.key] = value
        }
        return out
    }

    // MARK: - Relay clients

    /// `GET /workflows/pending-dialogs` body. Secret prefills never leave
    /// the Mac; `current` is false for dialogs queued behind another one
    /// of the same workflow.
    func remoteListJSON() -> Data {
        let items: [JSONValue] = pending.map(remoteJSON)
        return Data(JSONValue.object(["dialogs": .array(items)]).compactJSONString.utf8)
    }

    /// One pending dialog as the relay sees it.
    func remoteJSON(_ dialog: PendingDialog) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let secretKeys = Set(dialog.fields.filter { $0.type == .secret }.map(\.key))
        let fields = (try? JSONDecoder().decode(JSONValue.self, from: encoder.encode(dialog.fields))) ?? .array([])
        return .object([
            "id": .string(dialog.id.uuidString),
            "run_id": .string(dialog.runID.uuidString),
            "workflow_id": .string(dialog.workflowID.uuidString),
            "workflow_name": .string(dialog.workflowName),
            "node_id": .string(dialog.nodeID),
            "title": .string(dialog.title),
            "message": .string(dialog.message),
            "fields": fields,
            "prefill": .object(dialog.prefill.filter { !secretKeys.contains($0.key) }),
            "current": .bool(isPresentable(dialog)),
            "created_at": .string(Template.iso8601.string(from: dialog.createdAt)),
        ])
    }

    /// `GET /workflows/runs/{id}` body: the same `WorkflowCallResult` shape
    /// a `run_workflow` tool call returns (status, output, error, run_id),
    /// plus the form the run is waiting on, if any. Nil when no such run.
    func remoteRunJSON(runID: UUID) -> Data? {
        guard let run = WorkflowRunStore.shared.run(id: runID) else { return nil }
        var object = JSONValue.parse(WorkflowCallResult(run: run).jsonString)?.objectValue ?? [:]
        // `WorkflowCallResult` is the shape a finished tool call returns, so
        // it has no "running"; a poll of a live run must not read as failed.
        if run.status == .running { object["status"] = .string("running") }
        object["workflow_id"] = .string(run.workflowID.uuidString)
        object["workflow_name"] = .string(run.workflowName)
        object["run_status"] = .string(run.status.rawValue)
        if let dialog = pending.first(where: { $0.runID == runID }) {
            object["pending_dialog"] = remoteJSON(dialog)
        }
        return Data(JSONValue.object(object).compactJSONString.utf8)
    }

    /// `POST /workflows/runs/{id}/dialogs/{nodeId}`: answer or dismiss.
    func answerFromRemote(runID: UUID, nodeID: String, values: [String: JSONValue]?, dismiss: Bool)
        -> Result<Void, DialogAnswerError>
    {
        guard let dialog = dialog(runID: runID, nodeID: nodeID) else { return .failure(.notFound) }
        if dismiss {
            self.dismiss(dialog.id)
            return .success(())
        }
        return answer(dialog.id, values: values ?? [:])
    }

    func resetForTesting() {
        for id in pending.map(\.id) { resolve(id, with: .failure(CancellationError())) }
        drafts.removeAll()
    }
}

/// Posts the "a workflow needs your input" notification for background
/// callers. Replaced in tests.
@MainActor
enum WorkflowDialogNotifier {
    static var onPresented: (PendingDialog) -> Void = { dialog in
        guard dialog.caller.background else { return }
        NotificationService.shared.postWorkflowNeedsInput(dialog)
    }
    static var onResolved: (UUID) -> Void = { id in
        NotificationService.shared.removeWorkflowNeedsInput(dialogID: id)
    }
    /// Asks the form in the channel conversation that started the run.
    static var onChannelPresented: (PendingDialog) -> Void = { ChannelDialogRelay.shared.dialogPresented($0) }
    static var onChannelResolved: (UUID) -> Void = { ChannelDialogRelay.shared.dialogResolved($0) }

    static func dialogPresented(_ dialog: PendingDialog) {
        onPresented(dialog)
        onChannelPresented(dialog)
    }
    static func dialogResolved(_ id: UUID) {
        onResolved(id)
        onChannelResolved(id)
    }
}
