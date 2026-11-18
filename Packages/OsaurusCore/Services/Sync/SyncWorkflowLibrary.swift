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
    /// Conversation app data on the manage conversation: recent runs, newest first. No longer
    /// written (cleared once): every card change rewrote the whole list, and the conversation's
    /// history keeps every value written.
    static let workflowRunsNamespace = "ai.osaurus.workflow-runs/1"
    /// One recent run per entry, `<prefix><runId>`: a step changing rewrites only its run.
    static let workflowRunNamespacePrefix = "ai.osaurus.workflow-run/1/"
    /// A pinned workflow, `<prefix><workflowId>`, written by whichever of the user's devices pinned it; removed
    /// when unpinned. One entry per workflow, so two devices pinning different workflows never overwrite each
    /// other. The phone pins today; this Mac reads and writes them through `SyncWorkflowPins` once it pins too.
    static let workflowPinNamespacePrefix = "ai.osaurus.workflow-pin/1/"

    /// A workflow pin's value.
    struct WorkflowPin: Codable, Equatable, Sendable {
        /// When it was pinned: pinned workflows are listed most recent first.
        var pinnedMs: Int64
    }

    struct ManagedWorkflow: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var summary: String?
        /// The input form, as the Mac's Run page builds it from the input schema.
        var fields: [WorkflowInputField]
        /// The last run's input, which the Mac's Run page starts from.
        var prefill: [String: JSONValue]?
        /// False when a required field is a secret, or a file or folder no earlier run used. A phone that
        /// knows `workflow_file_inputs` can still start one whose only such fields are files, by attaching them.
        var phoneStartable: Bool
        /// Why it can't run until it's set up on the Mac.
        var blocked: String?
        /// The facts the Mac's workflow page shows under its summary (`workflow_details`): whether it
        /// can run, how many steps, where its models run, its version, whether it's published.
        var facts: [WorkflowChip]?
        /// Its steps in run order, each with the badges the Mac's page gives it.
        var steps: [WorkflowStep]?
        /// What it hands back, as the page's "You get" names it (the phone's Overview).
        var outputs: [String]?
        /// What it can reach (the phone's About tab): the page's "Your files" and "Before It Runs".
        var access: WorkflowAccess?
        /// Where its file came from (the phone's About tab).
        var source: WorkflowSource?
        /// Shared to the workflow registry and still listed there (the phone's Published tab).
        var published: Bool?
    }

    /// A small labelled capsule. `tone`: neutral, success, warning (needs attention), caution,
    /// risky; kept open.
    struct WorkflowChip: Codable, Equatable, Sendable {
        var icon: String
        var text: String
        var tone: String
    }

    struct WorkflowStep: Codable, Equatable, Sendable {
        var name: String
        /// What kind of work it is, in words: "Uses a model and tools".
        var kind: String
        var icon: String
        var badges: [WorkflowChip]
    }

    /// One line of what a workflow can reach: a label and its value, `problem` when it needs setting up.
    struct WorkflowAccessRow: Codable, Equatable, Sendable {
        var icon: String
        var title: String
        var detail: String
        var problem: Bool?
    }

    struct WorkflowAccess: Codable, Equatable, Sendable {
        /// What it reads, writes and replaces, and what reaches past its folders ("Your files").
        var files: [WorkflowAccessRow]
        /// Where that happens: "Your Mac", "Sandbox".
        var places: [String]
        /// The page's sentence under them.
        var note: String?
        /// Models, keys, internet, workflows it runs, tools, packages and folders ("Before It Runs").
        var needs: [WorkflowAccessRow]
    }

    /// The installed version's file: its author when it names one, and whether it came from the Store.
    struct WorkflowSource: Codable, Equatable, Sendable {
        var author: String?
        /// The signing key, when the file is signed.
        var key: String?
        var version: Int
        var changelog: String?
        var hash: String
        var createdMs: Int64
        var fromStore: Bool
    }

    struct WorkflowInputField: Codable, Equatable, Sendable {
        var key: String
        var label: String
        var type: String
        var required: Bool
        var options: [String]?
        var help: String?
        var `default`: JSONValue?
        /// A file or folder field: the name of what the last run used, which a start from the phone reuses
        /// when it sends none (`workflow_file_inputs`). The name only, never the path.
        var lastUsed: String?
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
    /// Runs sent per workflow (`runs(nowMs:)`).
    static let runLimit = 10
    static let summaryLimit = 500
    static let helpLimit = 500

    /// The phone fills these in; a file or folder is a path on this Mac.
    static var phoneTypes: Set<DialogFieldType> { WorkflowDialogAttention.phoneTypes }

    // MARK: Library

    static func managed(_ workflows: [InstalledWorkflow]) -> [SyncDeviceFeedContract.ManagedWorkflow] {
        let recent = WorkflowRunStore.shared.recentRuns()
        let catalog = ConfigModelReference.liveCatalog()
        return workflows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(workflowLimit)
            .map { workflow in
                let fields = WorkflowFormFields.fields(fromInputSchema: workflow.definition.inputSchema)
                let report = setupReport(workflow)
                let lastRun = recent.first { $0.workflowID == workflow.id }
                // A file or folder's path stays on this Mac: the phone gets its name only (`lastUsed`).
                let prefill = lastRun?.input.objectValue?.filter { key, _ in
                    fields.contains { $0.key == key && $0.type != .file && $0.type != .folder }
                }
                return SyncDeviceFeedContract.ManagedWorkflow(
                    id: workflow.id.uuidString.lowercased(),
                    name: workflow.name,
                    summary: workflow.summary.flatMap { $0.isEmpty ? nil : String($0.prefix(summaryLimit)) },
                    fields: fields.map { inputField($0, lastRun: lastRun) },
                    prefill: (prefill?.isEmpty ?? true) ? nil : prefill,
                    phoneStartable: fields.allSatisfy { field in
                        !field.required || phoneTypes.contains(field.type)
                            || SyncWorkflowInputs.lastUsedName(field, lastRun: lastRun) != nil
                    },
                    blocked: report.hasBlockers ? report.blocking.map(\.title).joined(separator: "; ") : nil,
                    facts: facts(workflow, report: report),
                    steps: steps(workflow, catalog: catalog),
                    outputs: WorkflowSummary.outputs(workflow.definition),
                    access: access(workflow),
                    source: source(workflow),
                    published: WorkflowRegistryRecordStore.shared.record(for: workflow.templateID)?.isLive ?? false
                )
            }
    }

    private static func inputField(
        _ field: DialogField,
        lastRun: WorkflowRun?
    ) -> SyncDeviceFeedContract.WorkflowInputField {
        SyncDeviceFeedContract.WorkflowInputField(
            key: field.key,
            label: field.label,
            type: field.type.rawValue,
            required: field.required,
            options: (field.options?.isEmpty ?? true) ? nil : field.options,
            help: field.help.flatMap { $0.isEmpty ? nil : String($0.prefix(helpLimit)) },
            default: field.defaultValue,
            lastUsed: SyncWorkflowInputs.lastUsedName(field, lastRun: lastRun)
        )
    }

    /// A phone run uses the keys shared by all agents, with nobody at the Mac.
    private static func setupReport(_ workflow: InstalledWorkflow) -> SetupReport {
        SetupChecker.check(workflow, secrets: .caller(nil), attended: false)
    }

    // MARK: Details (`workflow_details`)

    static let stepLimit = 30

    /// The chips under the Mac's workflow page heading, as `WorkflowDetailPage.hero` shows them.
    private static func facts(_ workflow: InstalledWorkflow, report: SetupReport)
        -> [SyncDeviceFeedContract.WorkflowChip]
    {
        typealias Chip = SyncDeviceFeedContract.WorkflowChip
        let missingKeys = !SetupChecker.missingKeys(report).isEmpty
        var chips = [
            report.hasBlockers
                ? Chip(icon: "exclamationmark.circle.fill", text: L("Needs setup"), tone: "warning")
                : missingKeys
                    ? Chip(icon: "key.fill", text: L("Keys missing"), tone: "warning")
                    : Chip(icon: "checkmark.circle.fill", text: L("Ready to run"), tone: "success")
        ]
        let count = workflow.definition.nodes.count
        chips.append(Chip(icon: "list.number", text: count == 1 ? L("1 step") : L("\(count) steps"), tone: "neutral"))
        if let locality = locality(workflow) {
            chips.append(Chip(icon: locality.icon, text: locality.text, tone: "neutral"))
        }
        chips.append(
            Chip(icon: "clock.arrow.circlepath", text: L("Version \(workflow.templateVersion)"), tone: "neutral"))
        if let published = WorkflowRegistryRecordStore.shared.record(for: workflow.templateID) {
            chips.append(
                Chip(
                    icon: published.isLive ? published.visibility.symbol : "eye.slash",
                    text: WorkflowShareCopy.status(published, includesReview: false), tone: "neutral"))
        }
        return chips
    }

    /// Where its model steps run once chosen; nil when it uses no model or none is chosen yet. Seen on the
    /// phone, so the Desktop by name rather than "this Mac".
    private static func locality(_ workflow: InstalledWorkflow) -> (icon: String, text: String)? {
        let env = SetupChecker.Environment.live()
        let models = workflow.template.requirements.models.compactMap {
            SetupChecker.resolvedModel(for: $0, bindings: workflow.bindings, environment: env)
        }
        guard !models.isEmpty else { return nil }
        return models.allSatisfy({ SetupChecker.isLocalModel($0, catalog: env.modelCatalog) })
            ? ("lock.laptopcomputer", L("Runs on Desktop"))
            : ("cloud", L("Uses the cloud"))
    }

    /// The steps in run order with their risk and cost badges, as the page's "Osaurus does" lists them.
    private static func steps(_ workflow: InstalledWorkflow, catalog: ConfigModelReference.Catalog)
        -> [SyncDeviceFeedContract.WorkflowStep]
    {
        let definition = workflow.definition
        return WorkflowSummary.steps(definition).prefix(stepLimit).map { step in
            let badges = definition.node(step.id).map {
                WorkflowStepRisk.badges(for: $0, in: workflow, catalog: catalog)
            } ?? []
            return SyncDeviceFeedContract.WorkflowStep(
                name: step.name, kind: step.kind, icon: step.icon,
                badges: badges.map { .init(icon: $0.systemImage, text: $0.label, tone: $0.tone.rawValue) })
        }
    }

    // MARK: Access and source (the phone's About tab)

    /// What it can reach, as the page shows it: its "Your files" rows (`WorkflowAccessRows`) and the
    /// "Before It Runs" list (`WorkflowDetailPage.beforeItRuns`), without the setup actions. Keys by name
    /// only: their state is the Mac's to manage, and the phone already hears when one blocks a run.
    private static func access(_ workflow: InstalledWorkflow) -> SyncDeviceFeedContract.WorkflowAccess {
        typealias Row = SyncDeviceFeedContract.WorkflowAccessRow
        let store = InstalledWorkflowStore.shared
        let scope = WorkflowAccessScope.derive(workflow.definition)
        let files = scope.rows.map { Row(icon: $0.systemImage, title: $0.title, detail: $0.value, problem: nil) }

        let reach = WorkflowRequirementsDeriver.reach(workflow.definition) { store.workflow(named: $0)?.definition }
        let reqs = reach.requirements
        let env = SetupChecker.Environment.live()
        var needs: [Row] = []
        for slot in reqs.models {
            let label =
                reqs.models.count > 1 ? WorkflowSummary.slotLabel(slot.slot, in: workflow.definition) : L("Runs on")
            let model = SetupChecker.resolvedModel(for: slot, bindings: workflow.bindings, environment: env)
            needs.append(
                Row(
                    icon: "cube", title: label, detail: model.map(WorkflowModelChoices.runsOn) ?? L("Not chosen yet"),
                    problem: model == nil ? true : nil))
        }
        for secret in reqs.secrets { needs.append(Row(icon: "key", title: secret.label, detail: "", problem: nil)) }
        if !reqs.network.isEmpty {
            needs.append(
                Row(
                    icon: "network", title: L("Internet access"), detail: reqs.network.joined(separator: ", "),
                    problem: nil))
        }
        for child in reach.subworkflows {
            needs.append(
                Row(
                    icon: "flowchart", title: L("Runs \(child.name)"),
                    detail: TemplateImportReviewView.summary(of: child),
                    problem: child.requirements == nil ? true : nil))
        }
        for tool in workflow.definition.calledTools {
            needs.append(
                Row(
                    icon: "wrench.and.screwdriver", title: tool.name, detail: WorkflowToolCatalog.status(of: tool.name),
                    problem: nil))
        }
        for dependency in reqs.dependencies {
            let status = WorkflowSandboxEnvironment.shared.status(of: dependency, environmentID: workflow.templateID)
            needs.append(
                Row(
                    icon: "shippingbox", title: dependency.summary, detail: WorkflowDependenciesStep.label(status),
                    problem: status != .installed ? true : nil))
        }
        for folder in reqs.folders {
            let path = workflow.bindings.folders[folder.key]
            needs.append(
                Row(
                    icon: "folder", title: folder.label, detail: path ?? L("Not chosen yet"),
                    problem: path == nil ? true : nil))
        }
        let grants: [(paths: [String], title: String, icon: String)] = [
            (workflow.bindings.folderGrants, L("Always allowed to save"), "folder"),
            (workflow.bindings.folderReadGrants, L("Always allowed to read"), "folder"),
            (workflow.bindings.replaceGrants, L("Always allowed to replace files"), "arrow.triangle.2.circlepath"),
        ]
        for grant in grants {
            for path in grant.paths {
                needs.append(Row(icon: grant.icon, title: grant.title, detail: path, problem: nil))
            }
        }
        return SyncDeviceFeedContract.WorkflowAccess(
            files: files, places: scope.places.map(\.title), note: scope.architectSentence, needs: needs)
    }

    /// The installed version's file, as its template carries it.
    private static func source(_ workflow: InstalledWorkflow) -> SyncDeviceFeedContract.WorkflowSource {
        let template = workflow.template
        let author = template.author
        let changelog = template.changelog.trimmingCharacters(in: .whitespacesAndNewlines)
        return SyncDeviceFeedContract.WorkflowSource(
            author: author?.name.flatMap { $0.isEmpty ? nil : $0 },
            key: author?.isSigned == true ? author?.address : nil,
            version: template.version,
            changelog: changelog.isEmpty ? nil : changelog,
            hash: template.contentHash,
            createdMs: Int64(template.createdAt.timeIntervalSince1970 * 1000),
            fromStore: workflow.source != nil)
    }

    // MARK: Starting

    enum StartFailure: Error, Equatable {
        case notFound
        case blocked(String)
        case invalidInput(String)
    }

    /// What would stop a phone's start before any file it attached is fetched: the workflow gone, not set up, or
    /// a required field the phone can't fill with nothing attached or reused for it. `start` checks again.
    static func precheck(workflowId raw: String?, attached: Set<String>) -> StartFailure? {
        guard let raw, let id = UUID(uuidString: raw), let workflow = InstalledWorkflowStore.shared.workflow(id: id)
        else { return .notFound }
        let report = setupReport(workflow)
        if report.hasBlockers { return .blocked(report.summary) }
        let fields = WorkflowFormFields.fields(fromInputSchema: workflow.definition.inputSchema)
        let lastRun = SyncWorkflowInputs.lastRun(workflowId: id)
        let fillable = fields.allSatisfy { field in
            !field.required || phoneTypes.contains(field.type)
                || (field.type == .file && attached.contains(field.key))
                || SyncWorkflowInputs.lastPath(field, lastRun: lastRun) != nil
        }
        return fillable ? nil : .invalidInput("This workflow needs a file, folder or secret, filled in on the Mac.")
    }

    /// Starts `workflowId` with the phone's values, as the Mac's Run button
    /// does: the fields the phone left out keep their defaults, and the
    /// input is checked against the schema first. `paths`: what file and folder fields get, paths this
    /// Mac made (`SyncWorkflowInputs.paths`), never the phone's.
    static func start(
        workflowId raw: String?,
        values: JSONValue?,
        paths: [String: String] = [:]
    ) -> Result<UUID, StartFailure> {
        guard let raw, let id = UUID(uuidString: raw), let workflow = InstalledWorkflowStore.shared.workflow(id: id)
        else { return .failure(.notFound) }
        let report = setupReport(workflow)
        if report.hasBlockers { return .failure(.blocked(report.summary)) }
        let schema = workflow.definition.inputSchema
        let fields = WorkflowFormFields.fields(fromInputSchema: schema)
        // Enforced here, not left to the phone: the phone's values count only for the fields it fills in, and
        // a file or folder field gets only a path this Mac made (a path from the phone would widen what the run
        // reaches on this Mac). A secret, or a file or folder with none, is filled in on the Mac.
        let made = paths.filter { key, _ in
            fields.contains { $0.key == key && ($0.type == .file || $0.type == .folder) }
        }
        guard fields.allSatisfy({ !$0.required || phoneTypes.contains($0.type) || made[$0.key] != nil }) else {
            return .failure(.invalidInput("This workflow needs a file, folder or secret, filled in on the Mac."))
        }
        let given = WorkflowDialogAttention.phoneValues(
            values?.objectValue ?? [:], fields: fields, prefill: made.mapValues { .string($0) })
        let input = WorkflowFormFields.inputValue(
            WorkflowFormFields.initialValues(fields, prefill: given), fields: fields, schema: schema)
        let problems = JSONSchemaValidator.validate(input, against: schema)
        if !problems.isEmpty {
            return .failure(.invalidInput(problems.map(\.description).joined(separator: "; ")))
        }
        // Nobody at this Mac sees its forms: they park and go to the attention feed.
        var caller = WorkflowCaller(kind: .user, background: true)
        caller.fromPhone = true
        let runId = WorkflowRunService.shared.start(workflow, input: input, caller: caller)
        SyncWorkflowPush.shared.noteStartedFromPhone(runId)
        return .success(runId)
    }

    // MARK: Runs

    /// Each workflow's newest `runLimit` runs, newest first. Capped per workflow, not overall: a busy workflow's
    /// runs used to fill the whole list and leave the others with none on the phone.
    static func runs(nowMs: Int64) -> SyncDeviceFeedContract.WorkflowRuns {
        var perWorkflow: [UUID: Int] = [:]
        let kept = WorkflowRunStore.shared.recentRuns().filter { run in
            perWorkflow[run.workflowID, default: 0] += 1
            return perWorkflow[run.workflowID, default: 0] <= runLimit
        }
        let entries = kept.map { run in
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
    /// Notifications don't wait for the list's debounce: they only compare statuses. A short
    /// window still folds a streaming step's per-token store changes into one check.
    private static let pushDebounce: Duration = .milliseconds(250)
    private var pushTask: Task<Void, Never>?

    private var cancellable: AnyCancellable?
    private var task: Task<Void, Never>?
    private var written: [SyncDeviceFeedContract.WorkflowRunEntry]?

    func start() {
        guard cancellable == nil else { return }
        // The saved history too: it's read from disk only when something asks, and after a launch
        // `live` holds nothing until a run starts.
        cancellable = WorkflowRunStore.shared.$live.map { _ in () }
            .merge(with: WorkflowRunStore.shared.$recentPersisted.map { _ in () })
            // And once a phone is known: before then nothing is written.
            .merge(with: SyncPhoneDevices.shared.$hasPhone.removeDuplicates().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { SyncWorkflowRunsFeed.shared.schedule() } }
        schedule()
    }

    func schedule() {
        schedulePushCheck()
        guard task == nil else { return }
        task = Task { @MainActor in
            try? await Task.sleep(for: Self.debounce)
            self.task = nil
            self.publishNow()
        }
    }

    private func schedulePushCheck() {
        guard pushTask == nil else { return }
        pushTask = Task { @MainActor in
            try? await Task.sleep(for: Self.pushDebounce)
            self.pushTask = nil
            guard SyncService.shared.core != nil, SyncPhoneDevices.shared.hasPhone,
                WorkflowRunStore.shared.recentPersisted != nil
            else { return }
            SyncWorkflowPush.shared.observe(SyncWorkflowLibrary.runs(nowMs: SyncHostedRunContract.nowMs()).runs)
        }
    }

    private func publishNow() {
        guard SyncService.shared.core != nil, SyncPhoneDevices.shared.hasPhone else {
            Self.trace("not written: core \(SyncService.shared.core != nil), phone \(SyncPhoneDevices.shared.hasPhone)")
            return
        }
        let store = WorkflowRunStore.shared
        guard store.recentPersisted != nil else {
            Self.trace("loading the saved run history first")
            // Loaded first, then written (its arrival schedules this again).
            Task { @MainActor in await store.loadRecentRunsIfNeeded() }
            return
        }
        let state = SyncWorkflowLibrary.runs(nowMs: SyncHostedRunContract.nowMs())
        // Notifications are checked sooner (`schedulePushCheck`); this one finds nothing new unless
        // that check was skipped (the run history still loading), so nothing is missed.
        SyncWorkflowPush.shared.observe(state.runs)
        // Streamed step text isn't on the card: most store changes write nothing.
        guard state.runs != written else { return }
        let (live, saved) = (store.live.count, store.recentPersisted?.count ?? 0)
        Self.trace("writing \(state.runs.count) runs (\(live) live, \(saved) saved)")
        // Set now so the next change doesn't write the same runs while this write is queued; a
        // write that fails undoes it and tries again (`writeFailed`).
        written = state.runs
        let runs = state.runs
        // A run that ended changes its steps' time and token badges (`workflow_details`).
        SyncManageFeed.shared.schedulePublish()
        Task.detached(priority: .utility) {
            do {
                try SyncConversationStore.shared.performWrite { core in
                    guard
                        let conversation = try SyncDeviceFeedContract.conversation(
                            kind: SyncDeviceFeedContract.manageKind, device: core.deviceKey(), core: core)
                    else {
                        // The manage state hasn't made the conversation yet: sent again on the next change.
                        Self.trace("no manage conversation yet")
                        Task { @MainActor in SyncWorkflowRunsFeed.shared.written = nil }
                        return
                    }
                    let (changed, removed) = try Self.write(state.runs, to: conversation, core: core)
                    guard changed + removed > 0 else { return }
                    core.syncNow()
                    Self.trace("wrote \(changed) runs, removed \(removed), on \(conversation.scope.prefix(8))")
                }
            } catch SyncConversationStoreError.notOpen {
                Self.trace("not written: the store isn't open")
                Task { @MainActor in SyncWorkflowRunsFeed.shared.writeFailed(runs) }
            } catch {
                Self.log.error("workflow runs write failed: \(error.syncLogDetail, privacy: .public)")
                Self.trace("write failed: \(error.syncLogDetail)")
                Task { @MainActor in SyncWorkflowRunsFeed.shared.writeFailed(runs) }
            }
        }
    }

    /// How long after a failed write it's tried again, with nothing else changing.
    nonisolated static let retryAfter: Duration = .seconds(15)
    private var retryTask: Task<Void, Never>?

    /// `runs` weren't written: forgotten as written, unless newer ones were since, and tried again.
    private func writeFailed(_ runs: [SyncDeviceFeedContract.WorkflowRunEntry]) {
        guard written == runs else { return }
        written = nil
        retryTask?.cancel()
        retryTask = Task { @MainActor in
            try? await Task.sleep(for: Self.retryAfter)
            guard !Task.isCancelled else { return }
            SyncWorkflowRunsFeed.shared.schedule()
        }
    }

    /// Writes each run whose entry differs from the stored one, and removes runs no longer listed
    /// and the old whole-list value. Compared with what the conversation holds, so a relaunch
    /// rewrites nothing that didn't change.
    nonisolated static func write(
        _ runs: [SyncDeviceFeedContract.WorkflowRunEntry], to conversation: Conversation, core: SyncCore
    ) throws -> (changed: Int, removed: Int) {
        let prefix = SyncDeviceFeedContract.workflowRunNamespacePrefix
        var stored: [String: Data] = [:]
        for entry in conversation.appData where entry.namespace.hasPrefix(prefix) {
            stored[entry.namespace] = entry.bytes
        }
        var wanted = Set<String>()
        var changed = 0
        for run in runs {
            let namespace = prefix + run.card.runId
            guard wanted.insert(namespace).inserted else { continue }
            let bytes = try SyncHostedRunContract.encode(run)
            if stored[namespace] == bytes { continue }
            try core.setConversationAppData(scope: conversation.scope, namespace: namespace, bytes: bytes)
            changed += 1
        }
        var removed = 0
        for namespace in stored.keys where !wanted.contains(namespace) {
            try core.setConversationAppData(scope: conversation.scope, namespace: namespace, bytes: nil)
            removed += 1
        }
        if conversation.appData(SyncDeviceFeedContract.workflowRunsNamespace) != nil {
            try core.setConversationAppData(
                scope: conversation.scope, namespace: SyncDeviceFeedContract.workflowRunsNamespace, bytes: nil)
            removed += 1
        }
        return (changed, removed)
    }

    /// Debug builds: to the console, so `tmp/osaurus.log` has it.
    nonisolated private static func trace(_ line: @autoclosure () -> String) {
        #if DEBUG
            print("[SyncWorkflowRuns] \(line())")
        #endif
    }

    /// Forgets what was written, so the next change writes again (a new core).
    func reset() {
        written = nil
        schedule()
    }
}

/// Workflow pins on the manage conversation (`workflow_library`, §5.4), shared by the user's devices.
/// The iPhone pins today; nothing on this Mac pins yet. These keep its reads and writes to the same entries, so
/// pinning added here later starts from the pins the phone already made instead of losing them.
enum SyncWorkflowPins {
    /// The pinned workflows by id, with when each was pinned. An unreadable entry is skipped.
    nonisolated static func pins(in conversation: Conversation) -> [String: Int64] {
        pins(conversation.appData.map { ($0.namespace, $0.bytes) })
    }

    nonisolated static func pins(_ entries: [(namespace: String, bytes: Data)]) -> [String: Int64] {
        let prefix = SyncDeviceFeedContract.workflowPinNamespacePrefix
        var pins: [String: Int64] = [:]
        for entry in entries where entry.namespace.hasPrefix(prefix) {
            let id = String(entry.namespace.dropFirst(prefix.count)).lowercased()
            guard !id.isEmpty,
                let pin = try? JSONDecoder().decode(SyncDeviceFeedContract.WorkflowPin.self, from: entry.bytes)
            else { continue }
            pins[id] = pin.pinnedMs
        }
        return pins
    }

    /// Pins or unpins `workflowId` on the manage conversation. Run inside `SyncConversationStore.performWrite`.
    nonisolated static func set(
        _ workflowId: String, pinned: Bool, nowMs: Int64, conversation: Conversation, core: SyncCore
    ) throws {
        let namespace = SyncDeviceFeedContract.workflowPinNamespacePrefix + workflowId.lowercased()
        let bytes = try pinned ? JSONEncoder().encode(SyncDeviceFeedContract.WorkflowPin(pinnedMs: nowMs)) : nil
        try core.setConversationAppData(scope: conversation.scope, namespace: namespace, bytes: bytes)
    }
}
