//
//  ChatSession+Harness.swift
//  osaurus
//
//  Chat turns for agents that run on an external harness (Claude Code, Pi).
//  The harness owns the agent loop and its own history; a turn sends the
//  newest user message and renders what streams back.
//

import Foundation

extension ChatSession {
    /// The harness this chat's agent runs on, or nil for the built-in loop.
    /// A remote agent target always runs on its host.
    var harnessSelection: HarnessSelection? {
        guard !isRemoteAgentTarget else { return nil }
        return AgentManager.shared.effectiveHarness(for: agentId ?? Agent.defaultId)
    }

    var isHarnessAgentActive: Bool { harnessSelection != nil }

    /// Run one turn on the agent's harness, streaming into `turn`.
    func runHarnessTurn(
        _ selection: HarnessSelection,
        prompt: String,
        attachments: [Attachment],
        agentId: UUID,
        folderRoot: URL?,
        into turn: ChatTurn,
        runId: UUID
    ) async {
        guard case .resolved(let runtime) = selection else {
            failHarnessTurn(HarnessError.runtimeMissing, on: turn)
            return
        }
        guard let chatId = sessionId else {
            failHarnessTurn(
                HarnessError.launchFailed(runtime: runtime.displayName, detail: L("This chat has no id yet.")),
                on: turn
            )
            return
        }

        let streamStart = Date()
        let processor = StreamingDeltaProcessor(turn: turn) { [weak self] in
            self?.rebuildVisibleBlocks()
        }
        var rollingRate = RollingTokenRate()
        var lastRateRefreshAt = Date.distantPast
        var authoritativeRate: Double?
        var firstOutputAt: Date?
        var lastNotice: String?
        var openDialogs: [String: ClarifyPromptState] = [:]

        func noteOutput(_ text: String) {
            let now = Date()
            if firstOutputAt == nil { firstOutputAt = now }
            rollingRate.observe(tokens: ContextBudgetManager.estimateTokens(for: text), at: now)
            refreshLiveRate(rolling: &rollingRate, lastRefreshAt: &lastRateRefreshAt, now: now, turn: turn)
            turn.lastOutputAt = now
        }

        func appendNotice(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != lastNotice else { return }
            lastNotice = trimmed
            let quoted = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            let lead = turn.contentIsEmpty ? "" : "\n\n"
            processor.receiveDelta("\(lead)\(quoted)\n\n")
        }

        do {
            let context = try await HarnessTurnDriver.launchContext(
                runtime: runtime,
                chatId: chatId,
                agentId: agentId,
                folderRoot: folderRoot
            )
            guard isRunActive(runId) else { return }

            let session = await HarnessSessionManager.shared.session(for: chatId)
            let previousFolder = await session.launchedWorkingDirectory
            let message = HarnessTurnDriver.userMessage(text: prompt, attachments: attachments)
            let stream = try await session.send(message, context: context)

            let newFolder = context.workingDirectory.standardizedFileURL.path
            if let previousFolder, previousFolder != newFolder {
                appendNotice(
                    String(
                        format: L("Working folder changed to %@. Restarted %@."),
                        context.isUserFolder ? newFolder : L("this chat's scratch folder"),
                        runtime.displayName
                    )
                )
            }

            for try await event in stream {
                noteRunProgress(.stream)
                guard isRunActive(runId) else { break }
                switch event {
                case .text(let text):
                    noteOutput(text)
                    processor.receiveDelta(text)
                case .reasoning(let text):
                    noteOutput(text)
                    processor.receiveReasoning(text)
                case .toolStarted(let callId, let name):
                    await processor.finalize()
                    turn.noteRemoteToolStarted(callId: callId ?? name, name: name)
                    rebuildVisibleBlocks()
                case .toolFinished(let callId, let name, let isError):
                    turn.noteRemoteToolFinished(callId: callId ?? name, name: name, isError: isError)
                    rebuildVisibleBlocks()
                case .notice(let text, _):
                    appendNotice(text)
                case .dialog(let request):
                    if let state = presentHarnessDialog(request, session: session) {
                        openDialogs[request.id] = state
                    }
                case .stats(let outputTokens, let tokensPerSecond, let stopReason):
                    if outputTokens > 0 { turn.generationTokenCount = outputTokens }
                    if tokensPerSecond.isFinite, tokensPerSecond > 0 { authoritativeRate = tokensPerSecond }
                    if let stopReason { turn.terminalStopReason = stopReason }
                case .turnCompleted, .turnFailed:
                    // The session ends the stream for these.
                    break
                }
            }
        } catch is CancellationError {
        } catch {
            if isRunActive(runId) {
                await processor.finalize()
                failHarnessTurn(error, on: turn)
            }
        }

        // Questions the harness stopped waiting for must not stay on screen.
        if !openDialogs.isEmpty {
            promptQueue.dismiss(Set(openDialogs.values.map { ObjectIdentifier($0) }))
        }
        await processor.finalize()
        turn.finalizeRemoteToolActivity()

        if let firstOutputAt {
            turn.timeToFirstToken = max(0, firstOutputAt.timeIntervalSince(streamStart))
        }
        turn.generationTokensPerSecond = rollingRate.finalRate(authoritativeTokensPerSecond: authoritativeRate)
        if turn.generationTokenCount == nil, rollingRate.totalTokens > 0 {
            turn.generationTokenCount = rollingRate.totalTokens
        }
        let endedAt = Date()
        if turn.completedAt == nil { turn.completedAt = endedAt }
        if turn.lastOutputAt == nil { turn.lastOutputAt = endedAt }
        isDirty = true
        rebuildVisibleBlocks()
    }

    private func failHarnessTurn(_ error: Error, on turn: ChatTurn) {
        let message = error.localizedDescription
        if turn.contentIsBlank {
            turn.content = message
        } else {
            turn.content += "\n\n" + message
        }
        lastStreamError = message
        rebuildVisibleBlocks()
    }

    /// Show a harness question in the clarify overlay and send the answer
    /// back. A chat with no window (a headless run) can't answer, so the
    /// question is cancelled immediately rather than left blocking.
    private func presentHarnessDialog(
        _ request: HarnessDialogRequest,
        session: HarnessSession
    ) -> ClarifyPromptState? {
        let respond: @MainActor (HarnessDialogResponse) -> Void = { response in
            Task { await session.respondToDialog(id: request.id, response: response) }
        }
        guard windowState != nil else {
            respond(.cancelled)
            return nil
        }

        let question: String
        var options: [String] = []
        let answer: (String) -> HarnessDialogResponse
        switch request.kind {
        case .select(let choices):
            question = request.title
            options = choices
            answer = { .value($0) }
        case .confirm(let message):
            question = [request.title, message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            let yes = L("Yes")
            options = [yes, L("No")]
            answer = { .confirmed($0 == yes || $0.lowercased() == "yes") }
        case .input(let placeholder):
            question = [request.title, placeholder].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            answer = { .value($0) }
        case .editor(let prefill):
            if let prefill, !prefill.isEmpty {
                question = "\(request.title)\n\n```\n\(prefill)\n```"
            } else {
                question = request.title
            }
            answer = { .value($0) }
        }

        let state = ClarifyPromptState(
            question: question,
            options: options,
            onSubmit: { respond(answer($0)) },
            onCancel: { respond(.cancelled) }
        )
        promptQueue.enqueue(.clarify(state))
        return state
    }

    /// Shut down this chat's harness process (it resumes on the next send
    /// when the runtime supports it).
    func closeHarnessSession(for chatId: UUID? = nil) {
        guard let id = chatId ?? sessionId else { return }
        Task { await HarnessSessionManager.shared.close(chatId: id) }
    }
}
