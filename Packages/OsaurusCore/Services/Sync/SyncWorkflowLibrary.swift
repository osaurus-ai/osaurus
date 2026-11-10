//
//  SyncWorkflowLibrary.swift
//  osaurus
//
//  Workflows for the iPhone (`workflow_library`, docs/SYNC_MOBILE_CONTRACT.md
//  §5.4): the installed workflows and their input forms in the manage state,
//  the `runWorkflow` request that starts one on this Mac as its Run button
//  does, and the recent runs with each one's card, written on the manage
//  conversation as they go. A run started from the phone is a background
//  run: its forms reach the phone through the attention feed (§4).
//

import Combine
import Foundation
import OsaurusSync
import os

extension SyncDeviceFeedContract {
    /// Conversation app data on the manage conversation: recent runs, newest first.
    static let workflowRunsNamespace = "ai.osaurus.workflow-runs/1"

    struct ManagedWorkflow: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var summary: String?
        /// The input form, as the Mac's Run page builds it from the input schema.
        var fields: [WorkflowInputField]
        /// The last run's input, which the Mac's Run page starts from.
        var prefill: [String: JSONValue]?
        /// False when a required field is a file or folder on this Mac.
        var phoneStartable: Bool
        /// Why it can't run until it's set up on the Mac.
        var blocked: String?
    }

    struct WorkflowInputField: Codable, Equatable, Sendable {
        var key: String
        var label: String
        var type: String
        var required: Bool
        var options: [String]?
        var help: String?
        var `default`: JSONValue?
    }

    struct WorkflowRuns: Codable, Equatable, Sendable {
        var v = 1
        var runs: [WorkflowRunEntry]
        var updatedMs: Int64
    }

    struct WorkflowRunEntry: Codable, Equatable, Sendable {
        var workflowId: String
        var card: SyncWorkflowCard
        /// What started it: `user` (a Run button, the phone's included), `agent`, `orchestrator`,
        /// `workflow`, `event`.
        var caller: String
        var startedMs: Int64
        var finishedMs: Int64?
    }
}

@MainActor
enum SyncWorkflowLibrary {
    static let workflowLimit = 100
    static let runLimit = 20
    static let summaryLimit = 500
    static let helpLimit = 500

    /// The phone fills these in; a file or folder is a path on this Mac.
    static let phoneTypes: Set<DialogFieldType> = [.text, .longText, .number, .bool, .choice, .date]

    // MARK: Library

    static func managed(_ workflows: [InstalledWorkflow]) -> [SyncDeviceFeedContract.ManagedWorkflow] {
        let recent = WorkflowRunStore.shared.recentRuns()
        return workflows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(workflowLimit)
            .map { workflow in
                let fields = WorkflowFormFields.fields(fromInputSchema: workflow.definition.inputSchema)
                let report = setupReport(workflow)
                let last = recent.first { $0.workflowID == workflow.id }?.input.objectValue
                let prefill = last?.filter { key, _ in fields.contains { $0.key == key } }
                return SyncDeviceFeedContract.ManagedWorkflow(
                    id: workflow.id.uuidString.lowercased(),
                    name: workflow.name,
                    summary: workflow.summary.flatMap { $0.isEmpty ? nil : String($0.prefix(summaryLimit)) },
                    fields: fields.map(inputField),
                    prefill: (prefill?.isEmpty ?? true) ? nil : prefill,
                    phoneStartable: fields.allSatisfy { !$0.required || phoneTypes.contains($0.type) },
                    blocked: report.hasBlockers ? report.blocking.map(\.title).joined(separator: "; ") : nil
                )
            }
    }

    private static func inputField(_ field: DialogField) -> SyncDeviceFeedContract.WorkflowInputField {
        SyncDeviceFeedContract.WorkflowInputField(
            key: field.key,
            label: field.label,
            type: field.type.rawValue,
            required: field.required,
            options: (field.options?.isEmpty ?? true) ? nil : field.options,
            help: field.help.flatMap { $0.isEmpty ? nil : String($0.prefix(helpLimit)) },
            default: field.defaultValue
        )
    }

    /// A phone run uses the keys shared by all agents, with nobody at the Mac.
    private static func setupReport(_ workflow: InstalledWorkflow) -> SetupReport {
        SetupChecker.check(workflow, secrets: .caller(nil), attended: false)
    }

    // MARK: Starting

    enum StartFailure: Error, Equatable {
        case notFound
        case blocked(String)
        case invalidInput(String)
    }

    /// Starts `workflowId` with the phone's values, as the Mac's Run button
    /// does: the fields the phone left out keep their defaults, and the
    /// input is checked against the schema first.
    static func start(workflowId raw: String?, values: JSONValue?) -> Result<UUID, StartFailure> {
        guard let raw, let id = UUID(uuidString: raw), let workflow = InstalledWorkflowStore.shared.workflow(id: id)
        else { return .failure(.notFound) }
        let report = setupReport(workflow)
        if report.hasBlockers { return .failure(.blocked(report.summary)) }
        let schema = workflow.definition.inputSchema
        let fields = WorkflowFormFields.fields(fromInputSchema: schema)
        let given = values?.objectValue ?? [:]
        let input = WorkflowFormFields.inputValue(
            WorkflowFormFields.initialValues(fields, prefill: given), fields: fields, schema: schema)
        let problems = JSONSchemaValidator.validate(input, against: schema)
        if !problems.isEmpty {
            return .failure(.invalidInput(problems.map(\.description).joined(separator: "; ")))
        }
        // Nobody at this Mac sees its forms: they park and go to the attention feed.
        let caller = WorkflowCaller(kind: .user, background: true)
        return .success(WorkflowRunService.shared.start(workflow, input: input, caller: caller))
    }

    // MARK: Runs

    static func runs(nowMs: Int64) -> SyncDeviceFeedContract.WorkflowRuns {
        let entries = WorkflowRunStore.shared.recentRuns(limit: runLimit).map { run in
            SyncDeviceFeedContract.WorkflowRunEntry(
                workflowId: run.workflowID.uuidString.lowercased(),
                card: SyncWorkflowCard.make(
                    run, definition: InstalledWorkflowStore.shared.workflow(id: run.workflowID)?.definition),
                caller: run.caller.kind.rawValue,
                startedMs: Int64((run.startedAt.timeIntervalSince1970 * 1000).rounded()),
                finishedMs: run.finishedAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
            )
        }
        return SyncDeviceFeedContract.WorkflowRuns(runs: entries, updatedMs: nowMs)
    }
}

/// Writes the recent runs on the manage conversation when a card changes:
/// at most every half second, and only a changed list.
@MainActor
final class SyncWorkflowRunsFeed {
    static let shared = SyncWorkflowRunsFeed()

    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.workflow-runs")
    private static let debounce: Duration = .milliseconds(500)

    private var cancellable: AnyCancellable?
    private var task: Task<Void, Never>?
    private var written: [SyncDeviceFeedContract.WorkflowRunEntry]?

    func start() {
        guard cancellable == nil else { return }
        cancellable = WorkflowRunStore.shared.$live
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { SyncWorkflowRunsFeed.shared.schedule() } }
        schedule()
    }

    func schedule() {
        guard task == nil else { return }
        task = Task { @MainActor in
            try? await Task.sleep(for: Self.debounce)
            self.task = nil
            self.publishNow()
        }
    }

    private func publishNow() {
        guard SyncService.shared.core != nil, SyncPhoneDevices.shared.hasPhone else { return }
        let state = SyncWorkflowLibrary.runs(nowMs: SyncHostedRunContract.nowMs())
        // Streamed step text isn't on the card: most store changes write nothing.
        guard state.runs != written else { return }
        written = state.runs
        Task.detached(priority: .utility) {
            do {
                try SyncConversationStore.shared.performWrite { core in
                    guard
                        let conversation = try SyncDeviceFeedContract.conversation(
                            kind: SyncDeviceFeedContract.manageKind, device: core.deviceKey(), core: core)
                    else { return }
                    try core.setConversationAppData(
                        scope: conversation.scope,
                        namespace: SyncDeviceFeedContract.workflowRunsNamespace,
                        bytes: try SyncHostedRunContract.encode(state))
                    core.syncNow()
                }
            } catch SyncConversationStoreError.notOpen {
            } catch {
                Self.log.error("workflow runs write failed: \(error.syncLogDetail, privacy: .public)")
            }
        }
    }

    /// Forgets what was written, so the next change writes again (a new core).
    func reset() {
        written = nil
        schedule()
    }
}
