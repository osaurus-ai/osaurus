//
//  SyncHostRunner.swift
//  osaurus
//
//  The host side of hosted runs: answers chats another of the user's
//  devices asked this Mac to run. Each request runs once, headless, on the
//  stored conversation; the reply goes out as the agent, tool approvals go
//  to the device the user is chatting on, and a stop from it cancels the run.
//

import Foundation
import OsaurusSync
import os

@MainActor
final class SyncHostRunner: ObservableObject {
    static let shared = SyncHostRunner()

    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.host")

    /// How long an agent stays assigned to a conversation it answered in.
    nonisolated static let agentTTLMs: UInt64 = 30 * 24 * 3600 * 1000
    /// Assignments closer than this to expiring are renewed on the next run.
    nonisolated static let agentRenewMs: UInt64 = 7 * 24 * 3600 * 1000
    /// Requests older than this when first seen are not started.
    static let staleRequestAge: TimeInterval = 3600
    /// Longest a hosted run may take.
    static let runTimeoutSeconds: UInt64 = 3 * 3600

    // MARK: - Ledger

    /// The runs this device took on, so each request runs once across launches.
    struct Ledger: Codable, Equatable, Sendable {
        struct Entry: Codable, Equatable, Sendable {
            var sessionId: UUID
            var scope: String
            var state: SyncHostedRunContract.HostRun.State
            var updatedMs: Int64
        }

        /// Turn id (lowercased) → entry.
        var runs: [String: Entry] = [:]

        static let retentionMs: Int64 = 30 * 24 * 3600 * 1000

        mutating func prune(nowMs: Int64) {
            runs = runs.filter { $0.value.state == .running || nowMs - $0.value.updatedMs < Self.retentionMs }
        }
    }

    enum LedgerStore {
        static var url: URL { OsaurusPaths.syncLocalState().appendingPathComponent("host-runs.json") }

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
                SyncHostRunner.log.error("ledger save failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - State

    private struct ActiveRun {
        let sessionId: UUID
        let turnId: String
        /// Sync device key of the device that asked for this run.
        var requester: String?
        var taskId: UUID?
        var stopRequested = false
        var published: [SyncHostedRunContract.PendingApproval] = []
        var publishedPrompts: [SyncHostedRunContract.PendingPrompt] = []
    }

    /// A chat this Mac is answering for another of the user's devices.
    struct HostedRequest: Equatable, Sendable {
        /// Sync device key of the asking device.
        let deviceKey: String
        let agentId: UUID
        let startedAt: Date
    }

    /// Chats this Mac is answering for another device right now, by session.
    /// The open chat and Inbox → Live Now name that device.
    @Published private(set) var runningFor: [UUID: HostedRequest] = [:]

    private var started = false
    private var recovered = false
    private var ledger = Ledger()
    private var observers: [NSObjectProtocol] = []
    private var listSubscription: OsaurusSync.Subscription?
    private var watches: [String: OsaurusSync.Subscription] = [:]
    private var active: [String: ActiveRun] = [:]
    private var processing: Set<String> = []
    private var queued: Set<String> = []
    private var flushTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        ledger = LedgerStore.load()
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: SyncService.didChangeConfigurationNotification, object: nil, queue: .main) {
                _ in
                MainActor.assumeIsolated { SyncHostRunner.shared.rescan() }
            })
        observers.append(
            center.addObserver(
                forName: ToolPermissionPromptService.syncedPromptsDidChangeNotification,
                object: nil,
                queue: .main
            ) { note in
                guard let scope = note.userInfo?["scope"] as? String else { return }
                MainActor.assumeIsolated { SyncHostRunner.shared.publishApprovals(scope: scope) }
            })
        observers.append(
            center.addObserver(forName: SyncSecretPromptQueue.didChangeNotification, object: nil, queue: .main) { note in
                guard let scope = note.userInfo?["scope"] as? String else { return }
                MainActor.assumeIsolated { SyncHostRunner.shared.publishPrompts(scope: scope) }
            })
        observers += SyncService.shared.observeCore(
            attach: { SyncHostRunner.shared.subscribe($0) },
            detach: { SyncHostRunner.shared.detach() })
    }

    private func detach() {
        listSubscription?.cancel()
        listSubscription = nil
        for watch in watches.values { watch.cancel() }
        watches.removeAll()
    }

    private func subscribe(_ core: SyncCore) {
        detach()
        let me = core.deviceKey()
        listSubscription = core.subscribeConversations { changes in
            var hostedHere: [String] = []
            var ownChats: [String] = []
            var removed: [String] = []
            for change in changes {
                switch change {
                case .changed(let conversation):
                    if conversation.tag(SyncConversationMapper.TagKey.hostDevice) == me {
                        hostedHere.append(conversation.scope)
                    } else if Self.mayBeOwnChat(conversation) {
                        ownChats.append(conversation.scope)
                    }
                case .removed(let scope):
                    removed.append(scope)
                default:
                    break
                }
            }
            guard !hostedHere.isEmpty || !ownChats.isEmpty || !removed.isEmpty else { return }
            Task { @MainActor in
                let runner = SyncHostRunner.shared
                for scope in removed { runner.unwatch(scope) }
                for scope in hostedHere {
                    runner.watch(scope)
                    runner.schedule(scope)
                }
                runner.checkOwnChats(ownChats)
            }
        }
        if !recovered {
            recovered = true
            recoverInterruptedRuns()
        }
        rescan()
    }

    /// Watches every conversation hosted here and checks each for work.
    private func rescan() {
        guard let core = SyncService.shared.core else { return }
        Task { @MainActor in
            let scopes = await Task.detached(priority: .utility) { () -> [String] in
                let filter = ConversationFilter(
                    tags: [Tag(key: SyncConversationMapper.TagKey.hostDevice, value: core.deviceKey())]
                )
                return ((try? core.conversationsFiltered(filter: filter)) ?? []).map(\.scope)
            }.value
            for scope in scopes {
                watch(scope)
                schedule(scope)
            }
            // This Mac's own chats that another device asked to continue
            // while it was away. Older requests aren't started, so only
            // chats active within that window are read.
            let staleAge = Self.staleRequestAge
            let recent = await Task.detached(priority: .utility) { () -> [String] in
                let filter = ConversationFilter(
                    tags: [Tag(key: SyncConversationMapper.TagKey.source, value: SessionSource.chat.rawValue)]
                )
                let cutoffMs = UInt64(max(0, Date().timeIntervalSince1970 - staleAge) * 1000)
                return ((try? core.conversationsFiltered(filter: filter)) ?? [])
                    .filter { Self.mayBeOwnChat($0) && $0.lastActivityHlc >> 16 >= cutoffMs }
                    .map(\.scope)
            }.value
            checkOwnChats(recent)
        }
    }

    // MARK: - This Mac's own chats

    /// A chat that may be this Mac's own: a synced chat no device hosts.
    /// Hosted chats carry `hostDevice`; app conversations carry a kind.
    nonisolated static func mayBeOwnChat(_ conversation: Conversation) -> Bool {
        conversation.tag(SyncConversationMapper.TagKey.hostDevice) == nil
            && !SyncConversationMapper.isAppInternal(conversation)
            && conversation.tag(SyncConversationMapper.TagKey.source) == SessionSource.chat.rawValue
    }

    /// Whether `message` asks this Mac to continue one of its own chats
    /// (docs/SYNC_MOBILE_CONTRACT.md §3.10): a user message written on
    /// another device, whose turn names this Mac in `hostRun`.
    nonisolated static func asksToContinueOwnChat(_ message: SyncMessage, me: String) -> Bool {
        guard message.role == .user, !message.isAgent, message.authorDevice != me,
            let data = message.appData(SyncConversationMapper.turnNamespace)?.bytes,
            let object = SyncConversationMapper.parseObject(data),
            let hostRun = object["hostRun"] as? JSONObject,
            let device = hostRun["device"] as? String
        else { return false }
        return device == me
    }

    /// Takes on the own chats among `scopes` whose latest message asks
    /// this Mac to continue them. Only that message is read, so a chat the
    /// Mac itself just saved costs one small read.
    private func checkOwnChats(_ scopes: [String]) {
        let candidates = scopes.filter { watches[$0] == nil }
        guard !candidates.isEmpty, let core = SyncService.shared.core else { return }
        Task { @MainActor in
            let asking = await Task.detached(priority: .utility) { () -> [String] in
                let me = core.deviceKey()
                return candidates.filter { scope in
                    guard let last = (try? core.messages(scope: scope, before: nil, limit: 1))?.messages.last
                    else { return false }
                    return Self.asksToContinueOwnChat(last, me: me)
                }
            }.value
            for scope in asking {
                watch(scope)
                schedule(scope)
            }
        }
    }

    private func watch(_ scope: String) {
        guard watches[scope] == nil, let core = SyncService.shared.core else { return }
        do {
            watches[scope] = try core.subscribe(scope: scope) { changes in
                let messages = changes.contains { change in
                    switch change {
                    case .messageAdded, .messageChanged, .messageRemoved, .reset: return true
                    default: return false
                    }
                }
                guard messages else { return }
                Task { @MainActor in SyncHostRunner.shared.schedule(scope) }
            }
        } catch {
            Self.log.error("watch \(scope, privacy: .public) failed: \(error.syncLogDetail, privacy: .public)")
        }
    }

    private func unwatch(_ scope: String) {
        watches.removeValue(forKey: scope)?.cancel()
    }

    private func schedule(_ scope: String) {
        queued.insert(scope)
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            let runner = SyncHostRunner.shared
            let scopes = runner.queued
            runner.queued.removeAll()
            runner.flushTask = nil
            for scope in scopes { await runner.process(scope) }
        }
    }

    // MARK: - Processing

    private struct Snapshot: Sendable {
        let me: String
        let conversation: Conversation
        let session: ChatSessionData
        /// Device that wrote the latest user message.
        let requester: String?
    }

    private func process(_ scope: String) async {
        guard !processing.contains(scope), let core = SyncService.shared.core else { return }
        processing.insert(scope)
        defer { processing.remove(scope) }

        let snapshot = await Task.detached(priority: .userInitiated) { () -> Snapshot? in
            let me = core.deviceKey()
            guard let conversation = try? core.conversation(scope: scope),
                conversation.tag(SyncConversationMapper.TagKey.hostDevice) == me || Self.mayBeOwnChat(conversation),
                let session = SyncConversationStore.shared.loadSession(
                    id: SyncConversationMapper.sessionId(of: conversation)
                )
            else { return nil }
            let requester = (try? core.messages(scope: scope, before: nil, limit: 20))?
                .messages.last { $0.role == .user && !$0.isAgent }?.authorDevice
            return Snapshot(me: me, conversation: conversation, session: session, requester: requester)
        }.value
        guard let snapshot else { return }
        let control = SyncHostedRunContract.read(
            SyncHostedRunContract.RunControl.self,
            SyncHostedRunContract.runNamespace,
            from: snapshot.conversation
        )

        if active[scope] != nil {
            controlActiveRun(scope: scope, control: control, conversation: snapshot.conversation)
            return
        }

        let session = snapshot.session
        // One of this Mac's own chats, continued from another device
        // (§3.10): no host is set, and the asking device is one of the
        // user's own that isn't revoked. Anything else stays the Mac's.
        let ownChat = session.hostDevice == nil
        if ownChat {
            guard let requester = snapshot.requester, requester != snapshot.me,
                SyncService.shared.devices.contains(where: { $0.id == requester && !$0.revoked })
            else { return }
        }
        guard session.hostDevice == snapshot.me || ownChat,
            let request = SyncHostedRunContract.latestRunRequest(in: session.turns),
            let marker = request.turn.hostRun, marker.device == snapshot.me
        else { return }
        let turnId = request.turn.id.uuidString.lowercased()
        guard ledger.runs[turnId] == nil else { return }
        if SyncHostedRunContract.isAnswered(request.index, in: session.turns) {
            record(turnId, sessionId: session.id, scope: scope, state: .done)
            return
        }

        let requestedAt = Date(timeIntervalSince1970: TimeInterval(marker.requestedMs) / 1000)
        if control?.stop == turnId || Date().timeIntervalSince(requestedAt) > Self.staleRequestAge {
            record(turnId, sessionId: session.id, scope: scope, state: .done)
            writeHostRun(scope: scope, turnId: turnId, state: .done)
            return
        }

        guard SyncConfigurationStore.load().hostAgentsForOtherDevices else {
            decline(
                session: session,
                scope: scope,
                turnId: turnId,
                text: L(
                    "This Mac isn't running agents for your other devices. Turn on Run Agents for My Other Devices in Sharing → Devices on this Mac to use its agents here."
                )
            )
            return
        }
        let workspaceTarget: WorkspaceAgentRef?
        switch Self.workspaceTarget(for: session, listed: Self.listedWorkspaceAgents()) {
        case .success(let ref): workspaceTarget = ref
        case .failure(let refusal):
            decline(session: session, scope: scope, turnId: turnId, text: refusal.message)
            return
        }
        let agentId = session.agentId ?? Agent.defaultId
        let agent = AgentManager.shared.agent(for: agentId)
        // The Mac's own Default-agent chats carry no agent id; hosted chats
        // always name one.
        let namesAgent = session.agentId != nil || ownChat
        guard workspaceTarget != nil || (namesAgent && agent.map(Self.canHost) == true) else {
            decline(
                session: session,
                scope: scope,
                turnId: turnId,
                text: L("This agent is no longer on this Mac. Pick another agent to continue.")
            )
            return
        }

        var choices: HostedChoices
        switch Self.choices(
            for: marker,
            requester: snapshot.requester,
            me: snapshot.me,
            devices: SyncService.shared.devices,
            pickerItems: await ModelPickerItemCache.shared.currentItems()
        ) {
        case .success(let resolved): choices = resolved
        case .failure(let refusal):
            decline(session: session, scope: scope, turnId: turnId, text: refusal.message)
            return
        }
        if workspaceTarget != nil {
            // The teammate's Mac picks the model and runs it; a call's note,
            // privacy and reasoning choices still apply here.
            choices.run?.model = nil
            choices.run?.image = nil
            do { try choices.overrides?.validate(forWorkspaceAgent: true) } catch {
                decline(session: session, scope: scope, turnId: turnId, text: error.localizedDescription)
                return
            }
        }

        record(turnId, sessionId: session.id, scope: scope, state: .running)
        writeHostRun(scope: scope, turnId: turnId, state: .running)
        active[scope] = ActiveRun(sessionId: session.id, turnId: turnId, requester: snapshot.requester)
        if let requester = snapshot.requester, requester != snapshot.me {
            runningFor[session.id] = HostedRequest(deviceKey: requester, agentId: agentId, startedAt: Date())
            if SyncPhoneDevices.isPhone(deviceKey: requester) {
                PhoneChatHandoff.shared.notePhoneActivity(sessionId: session.id)
            }
        }
        if let agent, workspaceTarget == nil {
            await assignSender(agent: agent, scope: scope, sessionId: session.id)
        } else {
            SyncConversationStore.shared.setAgentSender(nil, forSession: session.id)
        }

        var dispatch = DispatchRequest(
            prompt: "",
            agentId: workspaceTarget == nil ? agentId : nil,
            target: workspaceTarget.map(AgentDispatchTarget.workspace),
            title: session.title,
            showToast: false,
            source: .chat,
            continueSessionId: session.id,
            generationOverrides: choices.overrides,
            syncReviewerScope: scope
        )
        dispatch.hostedRun = choices.run
        guard let handle = await BackgroundTaskManager.shared.dispatchChat(dispatch) else {
            active[scope] = nil
            runningFor[session.id] = nil
            ledger.runs[turnId] = nil
            decline(
                session: session,
                scope: scope,
                turnId: turnId,
                text: L("This chat is busy on this Mac. Try again when it finishes.")
            )
            return
        }
        active[scope]?.taskId = handle.id
        Self.log.info("running \(turnId, privacy: .public) as task \(handle.id, privacy: .public)")
        // Waited on outside `processing`, so a stop or answers that come in
        // during the run reach `controlActiveRun`.
        Task { @MainActor in
            _ = await BackgroundTaskManager.shared.awaitCompletion(handle.id, timeoutSeconds: Self.runTimeoutSeconds)
            SyncHostRunner.shared.finish(scope: scope, turnId: turnId)
        }
        // A stop or answers may have arrived while the run was being set up.
        schedule(scope)
    }

    // MARK: - Workspace agents

    /// The teammate's agent a chat is with, when it's one; refused when that
    /// agent is no longer shared into one of the user's workspaces.
    static func workspaceTarget(
        for session: ChatSessionData,
        listed: Set<String>
    ) -> Result<WorkspaceAgentRef?, ChoiceRefusal> {
        guard session.isWorkspaceAgentChat, let workspace = session.workspace else { return .success(nil) }
        let ref = WorkspaceAgentRef(workspaceId: workspace.workspaceId, agentAddress: workspace.agentAddress)
        guard listed.contains(ref.key) else {
            return .failure(.init(
                message: L("This agent is no longer shared with you in that workspace. Pick another agent to continue.")))
        }
        return .success(ref)
    }

    /// `WorkspaceAgentRef.key` of every agent in the user's workspaces.
    static func listedWorkspaceAgents() -> Set<String> {
        Set(WorkspaceRosterStore.shared.rosters.flatMap { roster in
            roster.agents.map { WorkspaceAgentRef(workspaceId: roster.workspace.id, agentAddress: $0.agentAddress).key }
        })
    }

    // MARK: - Run choices

    struct HostedChoices: Equatable, Sendable {
        var run: DispatchRequest.HostedRunChoices?
        var overrides: ChatTurnOverrides?
    }

    struct ChoiceRefusal: Error, Equatable {
        let message: String
    }

    /// What a run request's own fields ask for. They're honoured only from
    /// this Mac or another of the user's devices that's still on the
    /// account; from anyone else the turn runs the agent as set up here.
    static func choices(
        for marker: HostRunRequest,
        requester: String?,
        me: String,
        devices: [Device],
        pickerItems: [ModelPickerItem]
    ) -> Result<HostedChoices, ChoiceRefusal> {
        let ownDevice =
            requester.map { key in key == me || devices.contains { $0.id == key && !$0.revoked } } ?? false
        guard ownDevice else { return .success(HostedChoices()) }

        var run = DispatchRequest.HostedRunChoices()
        if let model = marker.pinnedModel {
            guard let id = ChatSession.resolvePickerModelId(model, in: pickerItems) else {
                return .failure(
                    ChoiceRefusal(
                        message: L("\(model) isn't on this Mac. Pick another model to continue.")
                    ))
            }
            run.model = id
        }
        let overrides = marker.generationOverrides
        if let overrides {
            do { try overrides.validate() } catch {
                return .failure(ChoiceRefusal(message: error.localizedDescription))
            }
        }
        if let voiceCall = marker.voiceCall {
            run.voiceCall = true
            let note = voiceCall.instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !note.isEmpty { run.instructions = String(note.prefix(HostRunRequest.instructionsLimit)) }
        }
        run.privacy = marker.privacy.flatMap(VoiceCallPrivacy.init(rawValue:))
        run.image = marker.image
        let asksForNothing = run == DispatchRequest.HostedRunChoices()
        return .success(HostedChoices(run: asksForNothing ? nil : run, overrides: overrides))
    }

    private func controlActiveRun(scope: String, control: SyncHostedRunContract.RunControl?, conversation: Conversation) {
        guard var run = active[scope] else { return }
        if control?.stop == run.turnId, !run.stopRequested, let taskId = run.taskId {
            run.stopRequested = true
            active[scope] = run
            Self.log.info("stop requested for \(run.turnId, privacy: .public)")
            BackgroundTaskManager.shared.cancelTask(taskId)
        }
        let answers =
            SyncHostedRunContract.read(
                SyncHostedRunContract.ApprovalAnswers.self,
                SyncHostedRunContract.approvalAnswerNamespace,
                from: conversation
            )?.answers ?? [:]
        for (id, answer) in answers {
            guard let uuid = UUID(uuidString: id) else { continue }
            _ = ToolPermissionPromptService.resolveFromSyncedDevice(id: uuid, scope: scope, outcome: answer.resolution)
        }
        let promptAnswers =
            SyncHostedRunContract.read(
                SyncHostedRunContract.PromptAnswers.self,
                SyncHostedRunContract.promptAnswerNamespace,
                from: conversation
            )?.answers ?? [:]
        if !promptAnswers.isEmpty {
            let label = Self.deviceLabel(run.requester)
            for (id, answer) in promptAnswers {
                guard let uuid = UUID(uuidString: id) else { continue }
                SyncSecretPromptQueue.shared.resolve(id: uuid, scope: scope, answer: answer, deviceLabel: label)
            }
        }
    }

    /// Agents this Mac runs for other devices: the user's own, and the
    /// Default agent, which only devices without agents of their own list.
    nonisolated static func canHost(_ agent: Agent) -> Bool {
        !agent.isBuiltIn || agent.id == Agent.defaultId
    }

    private static func deviceLabel(_ deviceKey: String?) -> String {
        if SyncPhoneDevices.isPhone(deviceKey: deviceKey) { return L("Your iPhone") }
        return deviceKey.flatMap { SyncService.shared.deviceName(forKey: $0) } ?? L("Your other device")
    }

    private func finish(scope: String, turnId: String) {
        let hadApprovals = !(active[scope]?.published.isEmpty ?? true)
        let hadPrompts = !(active[scope]?.publishedPrompts.isEmpty ?? true)
        if let run = active[scope] {
            runningFor[run.sessionId] = nil
            if SyncPhoneDevices.isPhone(deviceKey: run.requester) {
                PhoneChatHandoff.shared.notePhoneActivity(sessionId: run.sessionId)
            }
            let sessionId = run.sessionId
            Task { await SyncContextUsage.refresh(scope: scope, sessionId: sessionId) }
        }
        active[scope] = nil
        ToolPermissionPromptService.denySyncedPrompts(scope: scope)
        SyncSecretPromptQueue.shared.cancelAll(scope: scope)
        if hadApprovals { writeApprovals(scope: scope, pending: []) }
        if hadPrompts { writePrompts(scope: scope, pending: []) }
        if let entry = ledger.runs[turnId] {
            record(turnId, sessionId: entry.sessionId, scope: scope, state: .done)
        }
        writeHostRun(scope: scope, turnId: turnId, state: .done)
        // A newer request may have come in during the run.
        schedule(scope)
    }

    // MARK: - Replies the host writes itself

    private func decline(session: ChatSessionData, scope: String, turnId: String, text: String) {
        Self.log.notice("declined \(turnId, privacy: .public)")
        appendReply(
            to: session,
            text: text,
            stopReason: SyncHostedRunContract.declinedStopReason
        )
        record(turnId, sessionId: session.id, scope: scope, state: .done)
        writeHostRun(scope: scope, turnId: turnId, state: .done)
    }

    /// Runs a quit or crash cut off get a reply saying so.
    private func recoverInterruptedRuns() {
        let interrupted = ledger.runs.filter { $0.value.state == .running }
        guard !interrupted.isEmpty else {
            pruneLedger()
            return
        }
        Task { @MainActor in
            for (turnId, entry) in interrupted {
                let session = await Task.detached(priority: .utility) {
                    SyncConversationStore.shared.loadSession(id: entry.sessionId)
                }.value
                if let session, session.turns.last?.role == .user {
                    appendReply(
                        to: session,
                        text: L("This run stopped before it finished because Osaurus quit on this Mac. Send your message again to retry."),
                        stopReason: SyncHostedRunContract.interruptedStopReason
                    )
                }
                record(turnId, sessionId: entry.sessionId, scope: entry.scope, state: .done)
                writeHostRun(scope: entry.scope, turnId: turnId, state: .done)
            }
            pruneLedger()
        }
    }

    /// Appends an assistant turn: through an open copy of the chat when
    /// there is one, so its next save doesn't drop the turn.
    private func appendReply(to session: ChatSessionData, text: String, stopReason: String) {
        var turn = ChatTurnData(role: .assistant, content: text, createdAt: Date())
        turn.completedAt = Date()
        turn.terminalStopReason = stopReason
        if let live = ChatWindowManager.shared.session(forSessionId: session.id)
            ?? LiveChatSessionRegistry.shared.liveSession(for: session.id)
        {
            if live.turns.last?.id != session.turns.last?.id, live.canApplyRemoteChanges {
                live.applyRemoteChanges(from: session)
            }
            if live.turns.last?.id == session.turns.last?.id, live.canApplyRemoteChanges {
                live.turns.append(ChatTurn(from: turn))
                live.isDirty = true
                live.save()
                return
            }
        }
        var updated = session
        updated.turns.append(turn)
        updated.updatedAt = Date()
        ChatSessionsManager.shared.saveAsync(updated)
    }

    // MARK: - Agent identity

    /// Replies go out as the agent: assigns it to the conversation (renewing
    /// an assignment near expiry) and names it the session's sender. On any
    /// failure the reply goes out as this device.
    private func assignSender(agent: Agent, scope: String, sessionId: UUID) async {
        let store = SyncConversationStore.shared
        guard let path = agent.agentKeyPath, let address = agent.agentAddress?.lowercased(),
            let core = SyncService.shared.core
        else {
            store.setAgentSender(nil, forSession: sessionId)
            return
        }
        let sender = await Task.detached(priority: .userInitiated) { () -> String? in
            let nowMs = UInt64(max(0, SyncHostedRunContract.nowMs()))
            if let current = (try? core.agents(scope: scope))?.first(where: {
                $0.hostedHere && $0.address.lowercased() == address
            }), (current.expiresMs ?? .max) > nowMs + Self.agentRenewMs {
                return current.agent
            }
            guard OsaurusIdentity.exists(),
                var masterKey = try? MasterKey.getPrivateKey(context: OsaurusIdentityContext.biometric())
            else { return nil }
            defer { masterKey.zeroOut() }
            var secret = AgentKey.derive(masterKey: masterKey, path: path)
            defer { secret.zeroOut() }
            do {
                return try store.performWrite { core in
                    try core.assignAgent(
                        scope: scope,
                        agentSecret: secret,
                        host: nil,
                        role: .member,
                        ttlMs: Self.agentTTLMs
                    )
                }
            } catch {
                Self.log.error("assign agent failed: \(error.syncLogDetail, privacy: .public)")
                return nil
            }
        }.value
        store.setAgentSender(sender, forSession: sessionId)
    }

    // MARK: - Approvals

    /// Publishes the prompts the run in `scope` is waiting on.
    private func publishApprovals(scope: String) {
        guard var run = active[scope] else { return }
        let pending = ToolPermissionPromptService.syncedPrompts(scope: scope).map { prompt in
            SyncHostedRunContract.PendingApproval(
                id: prompt.id.uuidString.lowercased(),
                turnId: run.turnId,
                tool: prompt.toolName,
                description: prompt.description,
                arguments: prompt.argumentsJSON,
                surface: prompt.surface,
                offersRunLease: prompt.offersRunLease,
                requestedMs: Int64((prompt.requestedAt.timeIntervalSince1970 * 1000).rounded())
            )
        }
        guard pending != run.published else { return }
        run.published = pending
        active[scope] = run
        writeApprovals(scope: scope, pending: pending)
    }

    /// Publishes the questions (secrets) the run in `scope` is waiting on.
    private func publishPrompts(scope: String) {
        guard var run = active[scope] else { return }
        let pending = SyncSecretPromptQueue.shared.pending(scope: scope).map { request in
            SyncHostedRunContract.PendingPrompt(
                id: request.id.uuidString.lowercased(),
                turnId: run.turnId,
                kind: .secret,
                key: request.key,
                description: request.description,
                instructions: request.instructions,
                sealKey: request.sealKey,
                requestedMs: Int64((request.requestedAt.timeIntervalSince1970 * 1000).rounded())
            )
        }
        guard pending != run.publishedPrompts else { return }
        run.publishedPrompts = pending
        active[scope] = run
        writePrompts(scope: scope, pending: pending)
    }

    // MARK: - Writes

    private func record(_ turnId: String, sessionId: UUID, scope: String, state: SyncHostedRunContract.HostRun.State) {
        ledger.runs[turnId] = Ledger.Entry(
            sessionId: sessionId,
            scope: scope,
            state: state,
            updatedMs: SyncHostedRunContract.nowMs()
        )
        LedgerStore.save(ledger)
    }

    private func pruneLedger() {
        let before = ledger
        ledger.prune(nowMs: SyncHostedRunContract.nowMs())
        if ledger != before { LedgerStore.save(ledger) }
    }

    private func writeHostRun(scope: String, turnId: String, state: SyncHostedRunContract.HostRun.State) {
        let record = SyncHostedRunContract.HostRun(turn: turnId, state: state, updatedMs: SyncHostedRunContract.nowMs())
        write(scope: scope, namespace: SyncHostedRunContract.hostRunNamespace, record)
    }

    private func writeApprovals(scope: String, pending: [SyncHostedRunContract.PendingApproval]) {
        write(scope: scope, namespace: SyncHostedRunContract.approvalNamespace, SyncHostedRunContract.Approvals(pending: pending))
    }

    private func writePrompts(scope: String, pending: [SyncHostedRunContract.PendingPrompt]) {
        write(scope: scope, namespace: SyncHostedRunContract.promptNamespace, SyncHostedRunContract.Prompts(pending: pending))
    }

    private func write<T: Encodable & Sendable>(scope: String, namespace: String, _ value: T) {
        Task.detached(priority: .userInitiated) {
            do {
                let bytes = try SyncHostedRunContract.encode(value)
                try SyncConversationStore.shared.performWrite { core in
                    try core.setConversationAppData(scope: scope, namespace: namespace, bytes: bytes)
                    core.syncNow()
                }
            } catch {
                Self.log.error("\(namespace, privacy: .public) write failed: \(error.syncLogDetail, privacy: .public)")
            }
        }
    }

    #if DEBUG
        func _ledgerForTesting() -> Ledger { ledger }
        var _isAttachedForTesting: Bool { listSubscription != nil }

        func _resetForTesting() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            listSubscription?.cancel()
            listSubscription = nil
            for watch in watches.values { watch.cancel() }
            watches.removeAll()
            runningFor.removeAll()
            flushTask?.cancel()
            flushTask = nil
            active.removeAll()
            queued.removeAll()
            processing.removeAll()
            ledger = Ledger()
            started = false
            recovered = false
        }
    #endif
}
