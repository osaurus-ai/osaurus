//
//  WorkflowEvalHarness+ClaudeCode.swift
//  osaurus
//
//  The Architect eval on Claude Code. The brief goes through the product
//  path (launch context, agent token, the `osaurus mcp` proxy, and the
//  in-process server's `/mcp/call`), and the transcript is rebuilt from the
//  calls the server ran, so the scored arguments are the real ones. Model
//  steps inside test runs still run on the case's Osaurus model.
//

import Foundation

extension WorkflowEvalHarness {

    public enum ArchitectDriver: Sendable, Equatable {
        /// Osaurus's own agent loop.
        case builtIn
        case claudeCode(ClaudeCodeLane)
    }

    public struct ClaudeCodeLane: Sendable, Equatable {
        /// Claude Code `--model`: `opus`, `sonnet`, or a full model id.
        public var claudeModel: String
        /// The in-process server the harness's tools call back into.
        public var apiPort: Int
        /// The `osaurus` CLI the MCP proxy runs; the app bundle's when nil.
        public var osaurusCLIPath: String?
        /// A turn still running after this is stopped and fails the row.
        public var turnTimeout: TimeInterval

        public init(claudeModel: String, apiPort: Int, osaurusCLIPath: String?, turnTimeout: TimeInterval = 1_800) {
            self.claudeModel = claudeModel
            self.apiPort = apiPort
            self.osaurusCLIPath = osaurusCLIPath
            self.turnTimeout = turnTimeout
        }
    }

    /// The person's replies, in order, shared by every way the Architect
    /// can ask.
    @MainActor
    final class ReplyQueue {
        private var replies: [String]
        private(set) var used = 0

        init(_ replies: [String]) { self.replies = replies }

        func next() -> String? {
            guard used < replies.count else { return nil }
            defer { used += 1 }
            return replies[used]
        }
    }

    @MainActor
    static func claudeCodeRuntime() -> HarnessRuntime {
        HarnessRuntimeStore.shared.runtime(id: HarnessRuntime.builtInClaudeCodeId) ?? .builtInClaudeCode
    }

    /// Why the lane can't run on this host, or nil. Checked before the case
    /// touches any state, so a missing prerequisite is a blocker, not a fail.
    @MainActor
    static func claudeCodeBlocker(_ lane: ClaudeCodeLane, runtime: HarnessRuntime) async -> String? {
        guard let cli = lane.osaurusCLIPath ?? ClaudeCodeConfiguration.embeddedCLIPath(),
            FileManager.default.isExecutableFile(atPath: cli)
        else {
            return "osaurus CLI not built: build the osaurus product and set OSAURUS_CLI_PATH"
        }
        let port = lane.apiPort
        guard await Task.detached(operation: { HarnessServerProbe.isListening(port: port) }).value else {
            return "Osaurus server unreachable on 127.0.0.1:\(port)"
        }
        switch await ClaudeCodeConfiguration.setupState(command: runtime.executable, overlay: runtime.environment) {
        case .notInstalled(let searched):
            return "Claude Code CLI not installed (searched \(searched))"
        case .signedOut:
            return "Claude Code is signed out: run `claude auth login`"
        case .statusUnavailable, .signedIn:
            return nil
        }
    }

    private struct TurnResult {
        var text = ""
        var failure: String?
        var timedOut = false
        var outputTokens = 0
        var promptTokens: Int?
        var tokensPerSecond = 0.0
        var firstOutputAt: Date?
        var notices: [String] = []
    }

    /// Runs the Architect's chat on Claude Code until it stops asking.
    @MainActor
    static func runClaudeCodeArchitect(
        brief: String, replies: ReplyQueue, lane: ClaudeCodeLane, runtime: HarnessRuntime, chatId: UUID
    ) async -> AgentLoopTranscript {
        let previousCLI = HarnessTurnDriver.osaurusCLIPathOverride
        let previousPort = HarnessTurnDriver.apiPortOverride
        HarnessTurnDriver.osaurusCLIPathOverride = lane.osaurusCLIPath ?? previousCLI
        HarnessTurnDriver.apiPortOverride = lane.apiPort
        let previousAnswers = HarnessClarifyBridge.answerOverride
        HarnessClarifyBridge.answerOverride = { askedIn, _ in askedIn == chatId ? replies.next() : nil }
        defer {
            HarnessTurnDriver.osaurusCLIPathOverride = previousCLI
            HarnessTurnDriver.apiPortOverride = previousPort
            HarnessClarifyBridge.answerOverride = previousAnswers
        }

        let started = Date()
        let session = await HarnessSessionManager.shared.session(for: chatId)
        var systemPrompt = ""
        var schema: [String] = []
        var finalText = ""
        var notices: [String] = []
        var error: String?
        var exit = "finalResponse"
        var turns = 0
        var outputTokens = 0
        var promptTokens: Int?
        var decodeSeconds = 0.0
        var firstOutputAt: Date?
        var message: String? = brief

        while let text = message {
            message = nil
            turns += 1
            let result: TurnResult
            do {
                let context = try await HarnessTurnDriver.launchContext(
                    runtime: runtime, chatId: chatId, agentId: Agent.architectId, folderRoot: nil)
                if turns == 1 {
                    systemPrompt = context.systemPrompt ?? ""
                    let attached = context.serverReachable && context.osaurusCLIPath != nil
                    schema = attached ? HarnessGrantStore.architectToolNames.sorted() : []
                }
                let stream = try await session.send(HarnessUserMessage(text: text), context: context)
                result = await consume(stream, session: session, timeout: lane.turnTimeout)
            } catch let launchError {
                error = launchError.localizedDescription
                exit = "error"
                break
            }
            finalText = result.text
            notices += result.notices
            firstOutputAt = firstOutputAt ?? result.firstOutputAt
            outputTokens += result.outputTokens
            if let prompt = result.promptTokens { promptTokens = (promptTokens ?? 0) + prompt }
            if result.tokensPerSecond > 0 { decodeSeconds += Double(result.outputTokens) / result.tokensPerSecond }
            if result.timedOut {
                exit = "timeout"
                error = "turn \(turns) still running after \(Int(lane.turnTimeout))s"
                break
            }
            if let failure = result.failure {
                exit = "error"
                error = failure
                break
            }
            // A question asked in a plain reply gets the person's next answer.
            let proposed = await HarnessBridgeCalls.shared.records(chatId: chatId)
                .contains { $0.name == WorkflowProposeSaveTool.toolName && !$0.isError }
            if !proposed, result.text.contains("?"), let reply = replies.next() {
                notices.append("asked in a plain reply on turn \(turns); answered with reply \(replies.used)")
                message = reply
            }
        }

        await HarnessSessionManager.shared.close(chatId: chatId)
        let records = await HarnessBridgeCalls.shared.records(chatId: chatId)
        await HarnessBridgeCalls.shared.clearRecords(chatId: chatId)
        let calls = records.enumerated().map { index, record in
            AgentLoopTranscript.ToolInvocation(
                name: record.name, arguments: record.arguments, resultPreview: String(record.result.prefix(300)),
                wasDeduped: false, wasError: record.isError, step: index + 1,
                resultCharacters: record.result.count)
        }
        return AgentLoopTranscript(
            toolCalls: calls, finalText: finalText, iterations: turns, exit: exit,
            exitOrigin: "claude-code", systemPrompt: systemPrompt, toolSchemaNames: schema,
            loopDurationMs: Date().timeIntervalSince(started) * 1000, notices: notices, error: error,
            decodeTokensPerSecond: decodeSeconds > 0 ? Double(outputTokens) / decodeSeconds : nil,
            ttftMs: firstOutputAt.map { $0.timeIntervalSince(started) * 1000 },
            completionTokens: outputTokens > 0 ? outputTokens : nil,
            promptTokensTotal: promptTokens)
    }

    /// One turn's events, stopping the turn after `timeout`. Claude Code's
    /// own permission prompts are refused by the adapter; any dialog that
    /// still arrives is cancelled, as nobody is there to answer it.
    @MainActor
    private static func consume(
        _ stream: AsyncThrowingStream<HarnessEvent, Error>, session: HarnessSession, timeout: TimeInterval
    ) async -> TurnResult {
        let started = Date()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await session.interrupt()
        }
        defer { watchdog.cancel() }
        var result = TurnResult()
        func noteOutput() { if result.firstOutputAt == nil { result.firstOutputAt = Date() } }
        do {
            for try await event in stream {
                switch event {
                case .text(let text):
                    noteOutput()
                    result.text += text
                case .reasoning, .toolStarted, .toolFinished:
                    noteOutput()
                case .notice(let text, let isError):
                    result.notices.append((isError ? "error notice: " : "notice: ") + text)
                case .dialog(let request):
                    await session.respondToDialog(id: request.id, response: .cancelled)
                case .stats(let outputTokens, let tokensPerSecond, _, let promptTokens):
                    result.outputTokens += outputTokens
                    if tokensPerSecond > 0 { result.tokensPerSecond = tokensPerSecond }
                    if let promptTokens { result.promptTokens = (result.promptTokens ?? 0) + promptTokens }
                case .turnFailed(let error):
                    result.failure = error.localizedDescription
                case .turnCompleted:
                    break
                }
            }
        } catch {
            result.failure = error.localizedDescription
        }
        result.timedOut = Date().timeIntervalSince(started) >= timeout
        return result
    }
}
