//
//  SyncManageFeed.swift
//  osaurus
//
//  Managing this Mac's agents from an iPhone, through Sync: while an iPhone
//  is in the account, this Mac lists its agents and chat models
//  (`ai.osaurus.manage-state/1`), applies the changes the iPhone asks for
//  (`ai.osaurus.manage-request/1`) through the same calls the Mac's own
//  editor makes (`PhoneAgentEditing`), and says how each went
//  (`ai.osaurus.manage-result/1`).
//

import Combine
import Foundation
import OsaurusSync
import os

@MainActor
final class SyncManageFeed {
    static let shared = SyncManageFeed()

    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.manage")
    private static let publishDebounce: Duration = .milliseconds(500)

    // MARK: - Ledger

    /// The requests this Mac took on, so each one runs once across launches,
    /// whatever happens to the synced results.
    struct Ledger: Codable, Equatable, Sendable {
        struct Entry: Codable, Equatable, Sendable {
            var startedMs: Int64
            /// Nil while the request runs, and forever if this Mac stopped
            /// before it finished.
            var result: SyncDeviceFeedContract.ManageResult?
        }

        /// Request id → entry.
        var requests: [String: Entry] = [:]

        /// Longer than a request lives, so an expired request is never
        /// mistaken for a new one.
        static let retentionMs: Int64 = 2 * SyncDeviceFeedContract.requestTTLMs

        mutating func prune(nowMs: Int64) {
            requests = requests.filter { nowMs - $0.value.startedMs < Self.retentionMs }
        }
    }

    enum LedgerStore {
        static var url: URL { OsaurusPaths.syncLocalState().appendingPathComponent("manage-requests.json") }

        static func load() -> Ledger {
            guard let data = try? EncryptedFileStore.readPolicyAware(plaintextURL: url),
                let ledger = try? JSONDecoder().decode(Ledger.self, from: data)
            else { return Ledger() }
            return ledger
        }

        static func save(_ ledger: Ledger) {
            do {
                try FileManager.default.createDirectory(
                    at: OsaurusPaths.syncLocalState(),
                    withIntermediateDirectories: true
                )
                try EncryptedFileStore.writePolicyAware(JSONEncoder().encode(ledger), toPlaintextURL: url)
            } catch {
                SyncManageFeed.log.error("ledger save failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var listSubscription: OsaurusSync.Subscription?
    private var publishTask: Task<Void, Never>?
    private var applying = false
    private var reapply = false
    private var ledger: Ledger?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        AgentManager.shared.$agents
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { SyncManageFeed.shared.schedulePublish() } }
            .store(in: &cancellables)
        ModelPickerItemCache.shared.$items
            .map { $0.map(\.id) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { SyncManageFeed.shared.schedulePublish() } }
            .store(in: &cancellables)
        SyncPhoneDevices.shared.$hasFeedReader
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { SyncManageFeed.shared.schedulePublish() } }
            .store(in: &cancellables)
        WorkspaceRosterStore.shared.$rosters
            .map { $0.map { roster in [roster.id, roster.workspace.name] + roster.agents.map(\.agentAddress) } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { SyncManageFeed.shared.schedulePublish() } }
            .store(in: &cancellables)
        ProjectManager.shared.$projects
            .map { $0.map { [$0.id.uuidString, $0.name] } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { SyncManageFeed.shared.schedulePublish() } }
            .store(in: &cancellables)
        WorkspacesService.shared.$workspaces
            .map { $0.map { [$0.id, $0.name] } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { SyncManageFeed.shared.schedulePublish() } }
            .store(in: &cancellables)
        // The Default agent's, the Architect's and the Configurator's models live on their own
        // configuration stores, not in `agents`: a model picked for them (in a chat, in
        // Settings) changed nothing the feed watched, and the iPhone kept the old one. Their
        // saves post these. `publish` writes only a changed state, so extra triggers are cheap.
        NotificationCenter.default.publisher(for: .agentUpdated)
            .merge(with: NotificationCenter.default.publisher(for: .appConfigurationChanged))
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { SyncManageFeed.shared.schedulePublish() } }
            .store(in: &cancellables)
        // The workflow list and each one's form and setup (`workflow_library`), and its published
        // status (`workflow_details`).
        InstalledWorkflowStore.shared.$workflows.map { _ in () }
            .merge(with: WorkflowRegistryRecordStore.shared.$records.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { SyncManageFeed.shared.schedulePublish() } }
            .store(in: &cancellables)
        SyncWorkflowRunsFeed.shared.start()
        // Workflow notifications (`workflow_push`): an iPhone that leaves the account gets none.
        NotificationCenter.default.publisher(for: SyncService.devicesDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { SyncWorkflowPush.shared.refresh() } }
            .store(in: &cancellables)
        // Loading or removing a plugin changes the tool list.
        NotificationCenter.default.publisher(for: .toolsListChanged)
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { SyncManageFeed.shared.schedulePublish() } }
            .store(in: &cancellables)
        observers += SyncService.shared.observeCore(
            attach: { core in
                let feed = SyncManageFeed.shared
                feed.subscribe(core)
                feed.schedulePublish()
                SyncWorkflowRunsFeed.shared.reset()
                SyncWorkflowPush.shared.refresh()
            },
            detach: { SyncManageFeed.shared.detach() })
    }

    private func detach() {
        listSubscription?.cancel()
        listSubscription = nil
    }

    private func subscribe(_ core: SyncCore) {
        listSubscription?.cancel()
        let me = core.deviceKey()
        listSubscription = core.subscribeConversations { changes in
            let mine = changes.contains { change in
                guard case .changed(let conversation) = change else { return false }
                return conversation.tag(SyncConversationMapper.TagKey.kind) == SyncDeviceFeedContract.manageKind
                    && conversation.tag(SyncConversationMapper.TagKey.device) == me
            }
            guard mine else { return }
            Task { @MainActor in
                SyncWorkflowPush.shared.refresh()
                await SyncManageFeed.shared.applyRequests()
            }
        }
    }

    // MARK: - State

    /// What the iPhone sees: every user agent, and the Default agent, whose
    /// model is the one thing it can change.
    static func state(
        device: String,
        agents: [Agent],
        models: [ModelPickerItem],
        workspaceAgents: [SyncDeviceFeedContract.WorkspaceAgent] = [],
        filters: HistoryFilters = HistoryFilters(),
        workflows: [SyncDeviceFeedContract.ManagedWorkflow]? = nil,
        pushRegistered: [String] = []
    ) -> SyncDeviceFeedContract.ManageState {
        let manager = AgentManager.shared
        let listed = agents.filter(SyncHostRunner.canHost).map { agent -> SyncDeviceFeedContract.ManagedAgent in
            let isDefault = agent.id == Agent.defaultId
            let description = agent.displayDescription
            return SyncDeviceFeedContract.ManagedAgent(
                id: agent.id.uuidString.lowercased(),
                name: agent.displayName,
                description: description.isEmpty ? nil : description,
                avatar: agent.avatar,
                isDefault: isDefault ? true : nil,
                model: manager.effectiveModel(for: agent.id),
                settings: PhoneAgentEditing.settings(for: agent)
            )
        }
        let chatModels = models.filter(\.isLikelyChatCapable).map {
            SyncDeviceFeedContract.ManagedModel(id: $0.id, name: $0.displayName, provider: $0.source.displayName)
        }
        return SyncDeviceFeedContract.ManageState(
            device: device,
            agents: listed,
            models: chatModels,
            workspaceAgents: workspaceAgents,
            projects: filters.projects,
            plugins: filters.plugins,
            workspaces: filters.workspaces,
            workflows: workflows,
            pushRegistered: pushRegistered.isEmpty ? nil : pushRegistered,
            updatedMs: SyncHostedRunContract.nowMs()
        )
    }

    struct HistoryFilters: Equatable, Sendable {
        var projects: [SyncDeviceFeedContract.HistoryFilter] = []
        var plugins: [SyncDeviceFeedContract.HistoryFilter] = []
        var workspaces: [SyncDeviceFeedContract.HistoryFilter] = []
    }

    /// The chat history's filters, as `GET /projects` and the manage state
    /// list them.
    static func historyFilters() -> HistoryFilters {
        typealias Filter = SyncDeviceFeedContract.HistoryFilter
        return HistoryFilters(
            projects: ProjectManager.shared.projects.map { Filter(id: $0.id.uuidString, name: $0.name) },
            plugins: PluginManager.shared.plugins
                .map { loaded in
                    Filter(
                        id: loaded.plugin.manifest.plugin_id,
                        name: loaded.plugin.manifest.name ?? loaded.plugin.manifest.plugin_id)
                }
                .sorted { $0.name.caseInsensitiveCompare($1.name) == .orderedAscending },
            workspaces: WorkspacesService.shared.workspaces.map { Filter(id: $0.id, name: $0.name) }
        )
    }

    /// Teammates' agents shared into the user's workspaces, which this Mac
    /// runs for the iPhone (it has no wallet of its own to call them). The
    /// user's own agents are listed as agents already.
    static func workspaceAgents(
        rosters: [WorkspaceRosterStore.WorkspaceRoster],
        localAddresses: Set<String>
    ) -> [SyncDeviceFeedContract.WorkspaceAgent] {
        rosters.flatMap { roster in
            roster.agents.compactMap { agent -> SyncDeviceFeedContract.WorkspaceAgent? in
                let address = agent.agentAddress.lowercased()
                guard !localAddresses.contains(address) else { return nil }
                let name = agent.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return SyncDeviceFeedContract.WorkspaceAgent(
                    workspaceId: roster.workspace.id,
                    workspaceName: roster.workspace.name,
                    address: address,
                    name: name.isEmpty ? address : name,
                    ownerName: agent.owner?.displayName ?? agent.owner?.osaurusId.map { "@\($0)" }
                )
            }
        }
    }

    func schedulePublish() {
        SyncManageDetail.shared.schedulePublish()
        publishTask?.cancel()
        publishTask = Task { @MainActor in
            try? await Task.sleep(for: Self.publishDebounce)
            guard !Task.isCancelled else { return }
            publishNow()
        }
    }

    func publishNow() {
        guard let core = SyncService.shared.core else { return }
        let hasReader = SyncPhoneDevices.shared.hasFeedReader
        let agents = AgentManager.shared.agents
        let state = Self.state(
            device: core.deviceKey(),
            agents: agents,
            models: ModelPickerItemCache.shared.items,
            workspaceAgents: Self.workspaceAgents(
                rosters: WorkspaceRosterStore.shared.rosters,
                localAddresses: Set(agents.compactMap { $0.agentAddress?.lowercased() })
            ),
            filters: Self.historyFilters(),
            workflows: SyncWorkflowLibrary.managed(InstalledWorkflowStore.shared.workflows),
            pushRegistered: SyncWorkflowPush.shared.registeredDevices
        )
        Task.detached(priority: .utility) {
            do {
                try SyncConversationStore.shared.performWrite { core in
                    try Self.publish(state, core: core, createIfMissing: hasReader)
                }
            } catch SyncConversationStoreError.notOpen {
            } catch {
                Self.log.error("publish failed: \(error.syncLogDetail, privacy: .public)")
            }
        }
    }

    /// Writes the state when it changed. Without an iPhone in the account
    /// nothing is created.
    nonisolated static func publish(
        _ state: SyncDeviceFeedContract.ManageState,
        core: SyncCore,
        createIfMissing: Bool
    ) throws {
        let me = core.deviceKey()
        let existing = try SyncDeviceFeedContract.conversation(
            kind: SyncDeviceFeedContract.manageKind,
            device: me,
            core: core
        )
        if let existing,
            var current = SyncHostedRunContract.read(
                SyncDeviceFeedContract.ManageState.self,
                SyncDeviceFeedContract.manageStateNamespace,
                from: existing
            )
        {
            current.updatedMs = state.updatedMs
            if current == state { return }
        }
        guard existing != nil || createIfMissing else { return }
        let scope =
            try existing?.scope
            ?? SyncDeviceFeedContract.ensureConversation(
                kind: SyncDeviceFeedContract.manageKind,
                title: String(localized: "Agents to Manage on \(SyncService.deviceName)", bundle: .module),
                core: core
            )
        try core.setConversationAppData(
            scope: scope,
            namespace: SyncDeviceFeedContract.manageStateNamespace,
            bytes: try SyncHostedRunContract.encode(state)
        )
        core.syncNow()
    }

    // MARK: - Requests

    func applyRequests() async {
        guard !applying else {
            reapply = true
            return
        }
        applying = true
        defer { applying = false }
        repeat {
            reapply = false
            await applyOnce()
        } while reapply
    }

    /// One requester's list: an iPhone's own namespace, or the shared one
    /// older iPhone builds write (`device` nil).
    struct RequestSource: Equatable, Sendable {
        var device: String?
        var requests: [SyncDeviceFeedContract.ManageRequest]
        var results: [String: SyncDeviceFeedContract.ManageResult]

        /// Ledger keys for this source, so two iPhones' `r1` never collide.
        var keyPrefix: String { device.map { "\($0)/" } ?? "" }

        var resultNamespace: String {
            device.map(SyncDeviceFeedContract.manageResultNamespace(device:))
                ?? SyncDeviceFeedContract.manageResultNamespace
        }
    }

    nonisolated static func sources(in conversation: Conversation, deviceNames: [String: String]) -> [RequestSource] {
        var sources: [RequestSource] = []
        let lists = SyncDeviceFeedContract.perDevice(
            SyncDeviceFeedContract.ManageRequests.self,
            prefix: SyncDeviceFeedContract.manageRequestNamespacePrefix,
            in: conversation,
            writtenByThatDevice: true
        )
        for (device, list) in lists.sorted(by: { $0.key < $1.key }) where deviceNames[device] != nil {
            let results =
                SyncHostedRunContract.read(
                    SyncDeviceFeedContract.ManageResults.self,
                    SyncDeviceFeedContract.manageResultNamespace(device: device),
                    from: conversation
                )?.results ?? [:]
            sources.append(RequestSource(device: device, requests: list.requests, results: results))
        }
        let legacy =
            SyncHostedRunContract.read(
                SyncDeviceFeedContract.ManageRequests.self,
                SyncDeviceFeedContract.manageRequestNamespace,
                from: conversation
            )?.requests ?? []
        let legacyResults =
            SyncHostedRunContract.read(
                SyncDeviceFeedContract.ManageResults.self,
                SyncDeviceFeedContract.manageResultNamespace,
                from: conversation
            )?.results ?? [:]
        if !legacy.isEmpty || !legacyResults.isEmpty {
            sources.append(RequestSource(device: nil, requests: legacy, results: legacyResults))
        }
        return sources
    }

    private func applyOnce() async {
        guard let core = SyncService.shared.core else { return }
        let devices = SyncService.shared.devices
        let names = SyncDeviceFeedContract.deviceNames(devices)
        let sources = await Task.detached(priority: .userInitiated) { () -> [RequestSource]? in
            guard
                let conversation = try? SyncDeviceFeedContract.conversation(
                    kind: SyncDeviceFeedContract.manageKind,
                    device: core.deviceKey(),
                    core: core
                )
            else { return nil }
            return Self.sources(in: conversation, deviceNames: names)
        }.value
        guard let sources else { return }
        var ledger = self.ledger ?? LedgerStore.load()
        let legacyLabel = SyncAttentionFeed.answerLabel(devices: devices)
        var applied = 0
        for source in sources {
            let deviceLabel = source.device.flatMap { names[$0] } ?? legacyLabel
            let outcome = await Self.apply(
                source: source,
                ledger: &ledger,
                nowMs: SyncHostedRunContract.nowMs(),
                save: LedgerStore.save,
                perform: { request in
                    let started = Date()
                    let result = await Self.perform(request)
                    Self.record(request, result: result, deviceLabel: deviceLabel, started: started)
                    return result
                }
            )
            applied += outcome.applied
            // Fitted to the core's app data cap: one over it failed to write, so it was retried on every
            // change, forever. The same results always fit the same way, so a fitted record that
            // is already written isn't written again.
            let snapshot = SyncDeviceFeedContract.ManageResults(results: outcome.results).fitted()
            guard snapshot.results != source.results else { continue }
            let namespace = source.resultNamespace
            await Task.detached(priority: .userInitiated) {
                do {
                    try SyncConversationStore.shared.performWrite { core in
                        guard
                            let conversation = try SyncDeviceFeedContract.conversation(
                                kind: SyncDeviceFeedContract.manageKind,
                                device: core.deviceKey(),
                                core: core
                            )
                        else { return }
                        try core.setConversationAppData(
                            scope: conversation.scope,
                            namespace: namespace,
                            bytes: try SyncHostedRunContract.encode(snapshot)
                        )
                        core.syncNow()
                    }
                } catch {
                    Self.log.error("results write failed: \(error.syncLogDetail, privacy: .public)")
                }
            }.value
        }
        self.ledger = ledger
        if applied > 0 { publishNow() }
    }

    /// `apply(requests:…)` for one source, its ledger keys prefixed with
    /// the requesting device. Results come back under the iPhone's own ids.
    static func apply(
        source: RequestSource,
        ledger: inout Ledger,
        nowMs: Int64,
        save: (Ledger) -> Void,
        perform: (SyncDeviceFeedContract.ManageRequest) async -> SyncDeviceFeedContract.ManageResult
    ) async -> (results: [String: SyncDeviceFeedContract.ManageResult], applied: Int) {
        let prefix = source.keyPrefix
        let keyed = source.requests.map { request -> SyncDeviceFeedContract.ManageRequest in
            var copy = request
            copy.id = prefix + request.id
            return copy
        }
        let synced = Dictionary(uniqueKeysWithValues: source.results.map { (prefix + $0.key, $0.value) })
        let outcome = await apply(
            requests: keyed,
            synced: synced,
            ledger: &ledger,
            nowMs: nowMs,
            save: save,
            perform: { request in
                var original = request
                original.id = String(request.id.dropFirst(prefix.count))
                return await perform(original)
            }
        )
        let results = Dictionary(
            uniqueKeysWithValues: outcome.results.map { (String($0.key.dropFirst(prefix.count)), $0.value) })
        return (results, outcome.applied)
    }

    /// Runs the listed requests this Mac hasn't taken on, recording each in
    /// the ledger before it runs, and returns the results the iPhone should
    /// see: one for every listed request this Mac has answered.
    static func apply(
        requests: [SyncDeviceFeedContract.ManageRequest],
        synced: [String: SyncDeviceFeedContract.ManageResult],
        ledger: inout Ledger,
        nowMs: Int64,
        save: (Ledger) -> Void,
        perform: (SyncDeviceFeedContract.ManageRequest) async -> SyncDeviceFeedContract.ManageResult
    ) async -> (results: [String: SyncDeviceFeedContract.ManageResult], applied: Int) {
        let before = ledger
        ledger.prune(nowMs: nowMs)
        let todo = requests.filter {
            ledger.requests[$0.id] == nil && synced[$0.id] == nil
                && nowMs - $0.requestedMs < SyncDeviceFeedContract.requestTTLMs
        }
        if todo.isEmpty, ledger != before { save(ledger) }
        for request in todo {
            ledger.requests[request.id] = Ledger.Entry(startedMs: nowMs)
            save(ledger)
            ledger.requests[request.id]?.result = await perform(request)
            save(ledger)
        }
        var results: [String: SyncDeviceFeedContract.ManageResult] = [:]
        for request in requests {
            if let entry = ledger.requests[request.id] {
                results[request.id] = entry.result ?? interrupted(startedMs: entry.startedMs)
            } else if let result = synced[request.id] {
                results[request.id] = result
            }
        }
        return (results, todo.count)
    }

    /// One Insights row per applied request, as the phone's HTTP edits were
    /// logged: who asked, which agent, and how it went. No field values.
    static func record(
        _ request: SyncDeviceFeedContract.ManageRequest,
        result: SyncDeviceFeedContract.ManageResult,
        deviceLabel: String,
        started: Date
    ) {
        let agentId = result.agentId.flatMap(UUID.init(uuidString:)) ?? request.agentId.flatMap(UUID.init(uuidString:))
        var details = ["op": request.op.rawValue, "request_id": request.id]
        if let error = result.error { details["error"] = error }
        InsightsService.logEgress(
            category: .inboundAPI,
            source: .chatUI,
            method: "SYNC",
            path: "/manage/\(request.op.rawValue)",
            statusCode: result.ok ? 200 : 400,
            durationMs: Date().timeIntervalSince(started) * 1000,
            egress: EgressInfo(details: details),
            locality: .local,
            errorMessage: result.ok ? nil : result.message,
            attribution: InsightsService.ActivityAttribution(
                agentId: agentId,
                agentName: agentId.flatMap { AgentManager.shared.agent(for: $0)?.displayName },
                participant: .ownerDevice(deviceLabel)
            )
        )
    }

    /// A request this Mac started but didn't see finish. It isn't run again,
    /// because it may have taken effect.
    static func interrupted(startedMs: Int64) -> SyncDeviceFeedContract.ManageResult {
        .init(
            ok: false,
            error: "interrupted",
            message: "This Mac stopped before it could confirm this change. Check the agent list before trying again.",
            doneMs: startedMs
        )
    }

    /// Applies one request as the Mac's own editor would.
    static func perform(_ request: SyncDeviceFeedContract.ManageRequest) async -> SyncDeviceFeedContract.ManageResult {
        func done(agentId: UUID? = nil) -> SyncDeviceFeedContract.ManageResult {
            .init(ok: true, agentId: agentId?.uuidString.lowercased(), doneMs: SyncHostedRunContract.nowMs())
        }
        func failed(_ code: String, _ message: String) -> SyncDeviceFeedContract.ManageResult {
            .init(ok: false, error: code, message: message, doneMs: SyncHostedRunContract.nowMs())
        }
        func failed(_ error: Error) -> SyncDeviceFeedContract.ManageResult {
            if let edit = error as? PhoneAgentEditing.EditError {
                let reply = edit.reply
                return failed(reply.code, reply.message)
            }
            return failed("failed", error.localizedDescription)
        }

        if let problem = oversized(request) { return failed("bad_request", problem) }

        switch request.op {
        case .unsupported:
            return failed("unsupported_op", "This Mac's Osaurus doesn't know that change yet. Update Osaurus on this Mac.")
        case .setFavorite:
            guard let key = request.key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
                let favorite = request.favorite
            else { return failed("bad_request", "Expected key and favorite") }
            let store = FavoriteModelsStore.shared
            if favorite { store.add(key) } else { store.remove(key) }
            SyncManageDetail.shared.schedulePublish()
            return answered(["favorites": store.favoriteKeys])
        case .getModelOptions, .setModelOption:
            guard let model = request.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
                return failed("bad_request", "Expected model")
            }
            var write: (option: String, value: ModelOptionValue?)?
            if request.op == .setModelOption {
                guard let option = request.option, !option.isEmpty else {
                    return failed("bad_request", "Expected option")
                }
                let value: ModelOptionValue?
                switch request.value {
                case .bool(let flag)?: value = .bool(flag)
                case .string(let text)?: value = .string(text)
                case nil, .null?: value = nil
                default: return failed("invalid_value", "value must be a segment id or a bool")
                }
                guard value != nil || request.clearValue == true || request.value == .null else {
                    return failed("bad_request", "Expected value, or clearValue to reset")
                }
                write = (option, value)
            }
            do {
                return answered(try await ModelOptionsSnapshot.answer(model: model, write: write))
            } catch ModelOptionsSnapshot.ApplyError.unknownOption {
                return failed("unknown_option", "This model has no such option.")
            } catch {
                return failed("invalid_value", "That value isn't one this option takes.")
            }
        case .contextUsage:
            return await contextUsage(request)
        case .workflowOutput:
            let payload: SyncWorkflowOutput.Payload
            switch SyncWorkflowOutput.payload(runId: request.runId) {
            case .success(let found): payload = found
            case .failure(.notFound): return failed("run_not_found", "That run isn't on this Mac any more.")
            case .failure(.running): return failed("running", "The run hasn't finished yet.")
            }
            let written = await Task.detached(priority: .userInitiated) { () -> Bool in
                defer {
                    // JSON staged for blobs; the files themselves stay where the run left them.
                    for blob in payload.blobs where SyncWorkflowOutput.isStaged(blob.path) {
                        try? FileManager.default.removeItem(atPath: blob.path)
                    }
                }
                do {
                    try SyncConversationStore.shared.performWrite { core in
                        try SyncWorkflowOutput.write(payload, core: core)
                    }
                    return true
                } catch {
                    return false
                }
            }.value
            guard written else { return failed("failed", "The run's output couldn't be sent.") }
            return answered(["runId": payload.runId])
        case .runWorkflow:
            switch SyncWorkflowLibrary.start(workflowId: request.workflowId, values: request.input) {
            case .success(let runId):
                return answered(["runId": runId.uuidString.lowercased()])
            case .failure(.notFound):
                return failed("workflow_not_found", "That workflow isn't on this Mac.")
            case .failure(.blocked(let reason)):
                return failed("needs_setup", "Finish setting it up on your Mac first. \(reason)")
            case .failure(.invalidInput(let reason)):
                return failed("invalid_input", reason)
            }
        default:
            break
        }

        if request.op == .createAgent {
            let name = request.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return failed("bad_request", "name must not be empty") }
            let model = request.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let agent = AgentManager.shared.createFromPhone(
                name: String(name.prefix(80)),
                description: request.description ?? "",
                systemPrompt: request.systemPrompt ?? "",
                defaultModel: (model?.isEmpty ?? true) ? nil : model
            )
            return done(agentId: agent.id)
        }

        guard let raw = request.agentId, let agentId = UUID(uuidString: raw),
            let agent = AgentManager.shared.agent(for: agentId)
        else { return failed("agent_not_found", "That agent isn't on this Mac.") }

        do {
            switch request.op {
            case .createAgent:
                return done()
            case .setModel:
                guard SyncHostRunner.canHost(agent) else { throw PhoneAgentEditing.EditError.notEditable }
                let model = request.model?.trimmingCharacters(in: .whitespacesAndNewlines)
                AgentManager.shared.updateDefaultModel(for: agentId, model: (model?.isEmpty ?? true) ? nil : model)
            case .updateAgent:
                if let value = request.temperature, !PhoneAgentEditing.temperatureRange.contains(value) {
                    return failed("bad_request", "temperature must be between 0 and 2")
                }
                if let value = request.maxTokens, !PhoneAgentEditing.maxTokensRange.contains(value) {
                    return failed("bad_request", "maxTokens must be a whole number from 1 to 1,000,000")
                }
                let patch = patch(from: request)
                guard !patch.isEmpty else { return failed("bad_request", "Nothing to change") }
                try await PhoneAgentEditing.apply(patch, to: agentId)
            case .setToolPreset:
                guard let preset = request.preset.flatMap(PhoneAgentEditing.ToolPreset.init(rawValue:)) else {
                    return failed("bad_request", "preset must be all, essential or none")
                }
                try PhoneAgentEditing.apply(preset, to: agentId)
            case .deleteAgent:
                guard try await PhoneAgentEditing.delete(agentId) else {
                    return failed("failed", "The agent couldn't be deleted.")
                }
            case .setTool:
                guard let name = request.name, !name.isEmpty else { return failed("bad_request", "Expected name") }
                do {
                    let row = try PhoneAgentEditing.changeTool(
                        name, agentId: agentId, enabled: request.enabled, agentEnabled: request.agentEnabled,
                        policy: request.policy)
                    SyncManageDetail.shared.schedulePublish()
                    return answered(row, agentId: agentId)
                } catch PhoneAgentEditing.ToolChangeError.toolNotFound {
                    return failed("tool_not_found", "That tool isn't on this Mac.")
                } catch PhoneAgentEditing.ToolChangeError.badRequest {
                    return failed("bad_request", "Expected enabled, agentEnabled or policy (auto, ask or deny)")
                } catch PhoneAgentEditing.ToolChangeError.edit(let edit) {
                    return failed(edit)
                }
            case .warm:
                let requested = request.model?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard
                    let model = (requested?.isEmpty ?? true)
                        ? AgentManager.shared.effectiveModel(for: agentId) : requested
                else { return answered(["loaded": false], agentId: agentId) }
                do {
                    switch try await ModelRuntime.shared.warmForVoiceCall(name: model) {
                    case nil: return answered(["loaded": false], agentId: agentId)
                    case let already?: return answered(["loaded": true, "already": already], agentId: agentId)
                    }
                } catch {
                    return failed("load_failed", "The model couldn't be loaded on this Mac.")
                }
            case .setFavorite, .getModelOptions, .setModelOption, .contextUsage, .runWorkflow, .workflowOutput,
                .unsupported:
                return done()
            }
            return done(agentId: agentId)
        } catch {
            return failed(error)
        }
    }

    /// A successful read, its answer as `data`.
    static func answered<T: Encodable>(_ value: T, agentId: UUID? = nil) -> SyncDeviceFeedContract.ManageResult {
        let now = SyncHostedRunContract.nowMs()
        guard let bytes = try? JSONEncoder.osaurusCanonical().encode(value),
            bytes.count <= SyncDeviceFeedContract.resultDataLimit,
            let data = try? JSONDecoder().decode(JSONValue.self, from: bytes)
        else {
            return .init(ok: false, error: "too_large", message: "The answer is too large to send.", doneMs: now)
        }
        return .init(ok: true, agentId: agentId?.uuidString.lowercased(), data: data, doneMs: now)
    }

    /// Prices the chat as its next turn would see it and writes it on the
    /// chat (`ai.osaurus.context-usage/1`), answering with it too.
    static func contextUsage(_ request: SyncDeviceFeedContract.ManageRequest) async
        -> SyncDeviceFeedContract.ManageResult
    {
        let now = SyncHostedRunContract.nowMs()
        guard let scope = request.scope, !scope.isEmpty else {
            return .init(ok: false, error: "bad_request", message: "Expected scope", doneMs: now)
        }
        guard let sessionId = SyncConversationStore.shared.sessionId(forScope: scope) else {
            return .init(ok: false, error: "chat_not_found", message: "That chat isn't on this Mac.", doneMs: now)
        }
        let agentId =
            request.agentId.flatMap(UUID.init(uuidString:))
            ?? SyncConversationStore.shared.loadSession(id: sessionId)?.agentId ?? Agent.defaultId
        guard AgentManager.shared.agent(for: agentId) != nil else {
            return .init(ok: false, error: "agent_not_found", message: "That agent isn't on this Mac.", doneMs: now)
        }
        let model = request.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usage = await PhoneContextUsage.compute(
            sessionId: sessionId, agentId: agentId, model: (model?.isEmpty ?? true) ? nil : model)
        SyncContextUsage.write(usage, scope: scope, agentId: agentId, model: (model?.isEmpty ?? true) ? nil : model)
        return answered(usage, agentId: agentId)
    }

    static let nameLimit = 200
    static let descriptionLimit = 2_000
    static let systemPromptLimit = 100_000

    /// Why a request's text is too long to apply, if it is.
    static func oversized(_ request: SyncDeviceFeedContract.ManageRequest) -> String? {
        if (request.name?.count ?? 0) > nameLimit { return "name is longer than \(nameLimit) characters" }
        if (request.description?.count ?? 0) > descriptionLimit {
            return "description is longer than \(descriptionLimit) characters"
        }
        if (request.systemPrompt?.count ?? 0) > systemPromptLimit {
            return "systemPrompt is longer than \(systemPromptLimit) characters"
        }
        return nil
    }

    static func patch(from request: SyncDeviceFeedContract.ManageRequest) -> PhoneAgentEditing.Patch {
        var patch = PhoneAgentEditing.Patch()
        patch.name = request.name
        patch.description = request.description
        patch.systemPrompt = request.systemPrompt
        patch.toolsEnabled = request.toolsEnabled
        patch.memoryEnabled = request.memoryEnabled
        patch.webSearchEnabled = request.webSearchEnabled
        patch.autonomousExecEnabled = request.autonomousExecEnabled
        if request.clearTemperature == true {
            patch.temperature = .clear
        } else if let value = request.temperature, PhoneAgentEditing.temperatureRange.contains(value) {
            patch.temperature = .set(value)
        }
        if request.clearMaxTokens == true {
            patch.maxTokens = .clear
        } else if let value = request.maxTokens, PhoneAgentEditing.maxTokensRange.contains(value) {
            patch.maxTokens = .set(value)
        }
        return patch
    }

    #if DEBUG
        func _resetForTesting() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            cancellables.removeAll()
            detach()
            publishTask?.cancel()
            publishTask = nil
            ledger = nil
            started = false
        }
    #endif
}

extension SyncDeviceFeedContract.ManageResults {
    /// The core refuses one app data value over 64 KiB; a little under, for the encoding's own size.
    static let maxBytes = 60_000

    /// These results, made to fit `maxBytes`: the oldest lose their `data` first (the iPhone has
    /// read them), then the oldest go. Deterministic, so the same results always fit the same way.
    func fitted(maxBytes: Int = Self.maxBytes) -> Self {
        func fits(_ results: [String: SyncDeviceFeedContract.ManageResult]) -> Bool {
            ((try? SyncHostedRunContract.encode(Self(v: v, results: results)))?.count ?? .max) <= maxBytes
        }
        guard !fits(results) else { return self }
        var kept = results
        let oldestFirst = results.sorted { ($0.value.doneMs, $0.key) < ($1.value.doneMs, $1.key) }
            .map(\.key)
        for key in oldestFirst where kept[key]?.data != nil {
            kept[key]?.data = nil
            if fits(kept) { return Self(v: v, results: kept) }
        }
        for key in oldestFirst {
            kept[key] = nil
            if fits(kept) { break }
        }
        return Self(v: v, results: kept)
    }
}
