//
//  HarnessSession.swift
//  osaurus
//
//  One chat's harness: a long-lived process that receives one user message
//  per turn and streams events back until the turn settles.
//

import Foundation
import os

actor HarnessSession {
    let chatId: UUID

    /// How long Stop waits for the harness to settle on its own before the
    /// process is killed (the next send relaunches it).
    static let interruptGrace: TimeInterval = 8

    private struct ActiveTurn {
        let id: UUID
        let continuation: AsyncThrowingStream<HarnessEvent, Error>.Continuation
        let message: HarnessUserMessage
        let context: HarnessLaunchContext
        var freshProcess: Bool
        var retried = false
        var interruptRequested = false
        var sawOutput = false
    }

    private var adapter: HarnessAdapter?
    private var process: HarnessProcess?
    private var codec: HarnessCodec?
    private var plan: HarnessLaunchPlan?
    private var token: String?
    private var launchedFingerprint: HarnessLaunchContext.Fingerprint?
    private var generation = 0
    private var turn: ActiveTurn?
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []
    private var stale = false

    private static let log = Logger(subsystem: "com.dinoki.osaurus", category: "HarnessSession")

    init(chatId: UUID) {
        self.chatId = chatId
    }

    // MARK: - State

    var isBusy: Bool { turn != nil }
    var hasLiveProcess: Bool { process?.isRunning ?? false }
    var runtimeId: UUID? { launchedFingerprint?.runtime.id }
    var agentId: UUID? { launchedFingerprint?.agentId }
    /// The folder the last launched process started in, kept after it exits
    /// so a relaunch elsewhere can be reported.
    var launchedWorkingDirectory: String? { launchedFingerprint?.workingDirectory }
    var processId: Int32? { process?.pid }

    /// Whether the next send would start a new process rather than reuse the
    /// running one.
    func needsRelaunch(for context: HarnessLaunchContext) -> Bool {
        guard let process, process.isRunning, !stale else { return true }
        return launchedFingerprint != context.fingerprint
    }

    /// The working folder changed: the process's cwd is fixed at launch, so
    /// the next send restarts it there.
    func markStale() {
        stale = true
    }

    // MARK: - Turns

    /// Send the newest user message. Throws for launch failures; failures
    /// after launch arrive through the stream.
    func send(
        _ message: HarnessUserMessage,
        context: HarnessLaunchContext
    ) async throws -> AsyncThrowingStream<HarnessEvent, Error> {
        if let current = turn {
            guard current.interruptRequested else {
                throw HarnessError.turnFailed(
                    runtime: context.runtime.displayName,
                    detail: L("A reply is still in progress.")
                )
            }
            await waitForSettle()
        }

        let fresh = try await ensureProcess(context: context)
        let (stream, continuation) = AsyncThrowingStream<HarnessEvent, Error>.makeStream()
        let turnId = UUID()
        turn = ActiveTurn(
            id: turnId,
            continuation: continuation,
            message: message,
            context: context,
            freshProcess: fresh
        )
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.consumerCancelled(turnId: turnId) }
        }
        await writeTurnStart(message)
        return stream
    }

    /// Stop the running turn: ask the harness, then kill it if it doesn't
    /// settle within `interruptGrace`.
    func interrupt() async {
        guard var current = turn, !current.interruptRequested else { return }
        current.interruptRequested = true
        turn = current

        if let codec {
            for id in codec.pendingDialogIds {
                if let record = codec.dialogResponse(id: id, response: .cancelled) {
                    try? await process?.send(record)
                }
            }
            for record in codec.interruptRecords() {
                try? await process?.send(record)
            }
        }

        let turnId = current.id
        let processGeneration = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.interruptGrace * 1_000_000_000))
            await self?.interruptDeadlinePassed(turnId: turnId, generation: processGeneration)
        }
    }

    func respondToDialog(id: String, response: HarnessDialogResponse) async {
        guard let record = codec?.dialogResponse(id: id, response: response) else { return }
        try? await process?.send(record)
    }

    /// Shut the process down (close stdin, grace, then signals). A running
    /// turn ends without error.
    func close(grace: TimeInterval = 5) async {
        finishTurn(error: nil)
        await shutdownProcess(grace: grace)
    }

    // MARK: - Process lifecycle

    /// Returns true when a new process was started.
    private func ensureProcess(context: HarnessLaunchContext) async throws -> Bool {
        if let process, process.isRunning, !stale, launchedFingerprint == context.fingerprint {
            return false
        }
        await shutdownProcess(grace: 5)
        try await launch(context: context)
        return true
    }

    private func launch(context: HarnessLaunchContext) async throws {
        let adapter = HarnessAdapters.adapter(for: context.runtime)
        let token = HarnessGrantStore.shared.mint(
            agentId: context.agentId,
            allowsConfigWrites: adapter.tokenAllowsConfigWrites(context: context),
            allowedToolNames: adapter.tokenToolScope(context: context)
        )
        let plan: HarnessLaunchPlan
        let process: HarnessProcess
        do {
            plan = try adapter.launchPlan(context: context, token: token)
        } catch {
            HarnessGrantStore.shared.revoke(token)
            throw error
        }
        do {
            process = try await HarnessProcess.launch(plan.spec)
        } catch {
            HarnessGrantStore.shared.revoke(token)
            Self.removeFiles(plan.temporaryFiles)
            throw error
        }

        generation += 1
        let processGeneration = generation
        self.adapter = adapter
        self.process = process
        self.codec = adapter.makeCodec()
        self.plan = plan
        self.token = token
        self.launchedFingerprint = context.fingerprint
        self.stale = false
        Self.log.info(
            "Launched \(context.runtime.kind.rawValue, privacy: .public) harness pid \(process.pid, privacy: .public) for chat \(self.chatId.uuidString, privacy: .public)"
        )

        let lines = process.lines
        Task { [weak self] in
            for await line in lines {
                guard let self else { return }
                await self.handle(line: line, generation: processGeneration)
            }
            await self?.processEnded(generation: processGeneration)
        }
    }

    /// Detach and stop the current process. Its reader's late callbacks are
    /// ignored via `generation`.
    private func shutdownProcess(grace: TimeInterval) async {
        generation += 1
        let process = self.process
        releaseProcessResources()
        if let process { await process.shutdown(grace: grace) }
    }

    private func releaseProcessResources() {
        if let token { HarnessGrantStore.shared.revoke(token) }
        if let plan { Self.removeFiles(plan.temporaryFiles) }
        process = nil
        codec = nil
        plan = nil
        token = nil
    }

    private func processEnded(generation processGeneration: Int) async {
        guard processGeneration == generation else { return }
        let exitCode = process?.exitCode ?? -1
        let stderr = process?.stderrText() ?? ""
        let runtimeName = launchedFingerprint?.runtime.displayName ?? L("The harness")
        releaseProcessResources()

        guard let current = turn else { return }
        if current.interruptRequested {
            finishTurn(error: nil)
            return
        }
        var error = HarnessError.exited(runtime: runtimeName, code: exitCode, stderrTail: stderr)
        if !stderr.isEmpty {
            switch HarnessError.classify(runtime: runtimeName, detail: stderr) {
            case .notAuthenticated(let runtime, let detail):
                error = .notAuthenticated(runtime: runtime, detail: detail)
            case .rateLimited(let runtime, let detail):
                error = .rateLimited(runtime: runtime, detail: detail)
            default:
                break
            }
        }
        await failTurn(error)
    }

    // MARK: - Decoding

    private func handle(line: Data, generation processGeneration: Int) async {
        guard processGeneration == generation, let codec else { return }
        let (events, replies) = codec.decode(line: line)
        for reply in replies {
            try? await process?.send(reply)
        }
        for event in events {
            await deliver(event)
        }
    }

    private func deliver(_ event: HarnessEvent) async {
        guard var current = turn else {
            // Nobody is listening; never leave the harness blocked on a
            // question no one will see.
            if case .dialog(let request) = event {
                await respondToDialog(id: request.id, response: .cancelled)
            }
            return
        }
        switch event {
        case .turnCompleted:
            finishTurn(error: nil)
        case .turnFailed(let error):
            if current.interruptRequested {
                finishTurn(error: nil)
            } else {
                await failTurn(error)
            }
        case .dialog(let request):
            if current.interruptRequested {
                await respondToDialog(id: request.id, response: .cancelled)
            } else {
                current.continuation.yield(event)
            }
        default:
            current.sawOutput = true
            turn = current
            current.continuation.yield(event)
        }
    }

    /// Fail the turn, unless this is the first turn of a fresh process and
    /// the adapter knows a session mode that recovers (e.g. Claude's
    /// "session already in use" → resume).
    private func failTurn(_ error: HarnessError) async {
        guard var current = turn else { return }
        let adapter = self.adapter ?? HarnessAdapters.adapter(for: current.context.runtime)
        if current.freshProcess, !current.retried, !current.sawOutput,
            let mode = adapter.retryMode(after: error, context: current.context)
        {
            var context = current.context
            context.sessionMode = mode
            current.retried = true
            turn = current
            await shutdownProcess(grace: 1)
            do {
                try await launch(context: context)
                await writeTurnStart(current.message)
            } catch {
                finishTurn(error: error)
            }
            return
        }
        finishTurn(error: error)
    }

    private func writeTurnStart(_ message: HarnessUserMessage) async {
        guard let codec, let process else {
            finishTurn(error: HarnessError.exited(runtime: L("The harness"), code: -1, stderrTail: ""))
            return
        }
        do {
            for record in try codec.beginTurn(message) {
                try await process.send(record)
            }
        } catch {
            finishTurn(error: error)
        }
    }

    private func finishTurn(error: Error?) {
        guard let current = turn else { return }
        turn = nil
        if let error {
            current.continuation.finish(throwing: error)
        } else {
            current.continuation.finish()
        }
        let waiters = settleWaiters
        settleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForSettle() async {
        guard turn != nil else { return }
        await withCheckedContinuation { continuation in
            settleWaiters.append(continuation)
        }
    }

    private func consumerCancelled(turnId: UUID) async {
        guard turn?.id == turnId else { return }
        await interrupt()
    }

    private func interruptDeadlinePassed(turnId: UUID, generation processGeneration: Int) {
        guard turn?.id == turnId, processGeneration == generation else { return }
        Self.log.info("Harness did not settle after Stop; killing it (next message relaunches)")
        process?.kill()
    }

    private static func removeFiles(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}

/// Every chat's harness session, keyed by the chat's session id.
actor HarnessSessionManager {
    static let shared = HarnessSessionManager()

    private var sessions: [UUID: HarnessSession] = [:]

    func session(for chatId: UUID) -> HarnessSession {
        if let existing = sessions[chatId] { return existing }
        let session = HarnessSession(chatId: chatId)
        sessions[chatId] = session
        return session
    }

    func existingSession(for chatId: UUID) -> HarnessSession? {
        sessions[chatId]
    }

    func markStale(chatId: UUID) async {
        await sessions[chatId]?.markStale()
    }

    func close(chatId: UUID) async {
        guard let session = sessions.removeValue(forKey: chatId) else { return }
        await session.close()
    }

    /// Close idle sessions running a runtime that was edited or deleted. Busy
    /// ones relaunch (or fail with `runtimeMissing`) on their next send.
    func closeIdleSessions(runtimeId: UUID) async {
        for (chatId, session) in sessions {
            guard await session.runtimeId == runtimeId, await !session.isBusy else { continue }
            sessions[chatId] = nil
            await session.close()
        }
    }

    /// Close idle sessions of an agent whose runtime changed, so a chat that
    /// moved back to the built-in loop doesn't keep a harness process alive.
    func closeIdleSessions(agentId: UUID) async {
        for (chatId, session) in sessions {
            guard await session.agentId == agentId, await !session.isBusy else { continue }
            sessions[chatId] = nil
            await session.close()
        }
    }

    func closeAll() async {
        let all = sessions
        sessions.removeAll()
        for session in all.values { await session.close(grace: 2) }
    }

    func liveSessionCount() async -> Int {
        var count = 0
        for session in sessions.values where await session.hasLiveProcess { count += 1 }
        return count
    }
}
