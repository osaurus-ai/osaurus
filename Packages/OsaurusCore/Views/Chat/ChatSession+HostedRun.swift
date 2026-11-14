//
//  ChatSession+HostedRun.swift
//  osaurus
//
//  The caller's side of a hosted chat: another of the user's Macs runs the
//  agent, this one only writes the user's turns, a stop request and
//  approval answers (osaurus-sync docs/app-data.md, "Hosted runs").
//

import Foundation

struct HostStopRequest: Equatable {
    let turnId: UUID
    let at: Date
}

extension ChatSession {
    /// How long Stop waits for the host to confirm before the composer
    /// unlocks anyway (the host may have gone to sleep).
    static let hostStopGrace: TimeInterval = 15

    /// The host's device id when this chat's agent runs on another Mac.
    var hostDeviceElsewhere: String? {
        guard let hostDevice, !hostDevice.isEmpty else { return nil }
        if let me = SyncService.shared.core?.deviceKey(), me == hostDevice { return nil }
        return hostDevice
    }

    /// The Mac that served this chat when it isn't this one.
    var servedElsewhere: String? {
        guard let servedBy, !servedBy.isEmpty else { return nil }
        if let me = SyncService.shared.core?.deviceKey(), me == servedBy { return nil }
        return servedBy
    }

    /// The latest user turn the host hasn't finished answering.
    var pendingHostedTurn: ChatTurn? {
        guard hostDeviceElsewhere != nil,
            let index = turns.lastIndex(where: { $0.role == .user && $0.hostRun != nil })
        else { return nil }
        let turn = turns[index]
        if let stop = hostStopRequest, stop.turnId == turn.id,
            Date().timeIntervalSince(stop.at) >= Self.hostStopGrace
        {
            return nil
        }
        if let state = hostRunState, state.turn == turn.id.uuidString.lowercased() {
            return state.state == .running ? turn : nil
        }
        let answered = turns[(index + 1)...].contains { $0.role == .assistant && !$0.isRemotePreview }
        return answered ? nil : turn
    }

    var isWaitingOnHost: Bool { pendingHostedTurn != nil }

    /// Stop was asked, the grace ran out and unlocked the composer, but the
    /// host never reported the turn stopped: it may still finish the reply.
    var hostStopUnconfirmed: Bool {
        guard let stop = hostStopRequest, Date().timeIntervalSince(stop.at) >= Self.hostStopGrace else {
            return false
        }
        if let state = hostRunState, state.turn == stop.turnId.uuidString.lowercased() {
            return state.state == .running
        }
        guard let index = turns.firstIndex(where: { $0.id == stop.turnId }) else { return false }
        return !turns[(index + 1)...].contains { $0.role == .assistant && !$0.isRemotePreview }
    }

    /// Adds the user's turn with a request for `host` to answer it, and
    /// saves. False while the host is offline or still on the previous turn.
    @discardableResult
    func sendToHost(_ text: String, attachments: [Attachment], host: String) -> Bool {
        guard !isWaitingOnHost, remoteReply == nil, SyncHostedRunMonitor.shared.isConnected(host) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        if sessionId == nil {
            sessionId = UUID()
            createdAt = Date()
        }
        let turn = ChatTurn(role: .user, content: trimmed, attachments: attachments)
        turn.hostRun = HostRunRequest(device: host)
        turns.append(turn)
        hostStopRequest = nil
        isDirty = true
        rebuildVisibleBlocks()
        save()
        SyncHostedRunMonitor.shared.syncSoon()
        return true
    }

    /// Asks the host to stop the turn it's answering.
    func stopHostedRun() {
        guard let turn = pendingHostedTurn, let sessionId else { return }
        hostStopRequest = HostStopRequest(turnId: turn.id, at: Date())
        SyncHostedRunMonitor.shared.requestStop(sessionId: sessionId, turnId: turn.id)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.hostStopGrace))
            self?.objectWillChange.send()
        }
    }

    /// Answers one of the host's approval cards.
    func answerHostApproval(id: String, _ answer: SyncHostedRunContract.Answer) {
        guard let sessionId else { return }
        hostApprovals.removeAll { $0.id == id }
        SyncHostedRunMonitor.shared.answer(sessionId: sessionId, approvalId: id, answer: answer)
    }

    /// Answers one of the host's secret prompts: the value, or nil to decline.
    func answerHostPrompt(_ prompt: SyncHostedRunContract.PendingPrompt, value: String?) {
        guard let sessionId else { return }
        hostPrompts.removeAll { $0.id == prompt.id }
        SyncHostedRunMonitor.shared.answer(sessionId: sessionId, prompt: prompt, value: value)
    }
}
