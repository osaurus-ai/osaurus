//
//  SyncRunProgress.swift
//  osaurus
//
//  What a chat's run is doing while it generates, for the user's other
//  devices: its phase, prompt progress, tool calls, image steps and shared
//  files. Conversation app data `ai.osaurus.run-progress/1`, written by the
//  device running the reply (docs/SYNC_MOBILE_CONTRACT.md §5). The reply's
//  text streams separately; this is everything around it.
//

import Foundation
import OsaurusSync
import os

enum SyncRunProgressContract {
    static let namespace = "ai.osaurus.run-progress/1"

    struct Progress: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable {
            /// Queued, or loading the model: nothing has come back yet.
            case waiting
            case prefill
            case thinking
            case answering
            /// A tool call is being written or is running.
            case tool
            case image
            /// The run ended; its turns are committed as messages.
            case done
        }

        var v = 1
        /// The user turn the run answers (lowercased id).
        var turn: String
        var phase: Phase
        var prefill: Prefill?
        var tools: [Tool] = []
        var image: ImageStep?
        var artifacts: [Artifact] = []
        /// Characters of reasoning so far; its text arrives with the message.
        var thinkingChars: Int?
        var startedMs: Int64
        var updatedMs: Int64

        /// Equal apart from counters and timestamps.
        func sameShape(as other: Progress) -> Bool {
            shape == other.shape
        }

        private var shape: Progress {
            var shape = self
            shape.updatedMs = 0
            shape.thinkingChars = nil
            shape.prefill = prefill.map { Prefill(stage: $0.stage, done: 0, total: 0) }
            shape.image = image.map { ImageStep(step: 0, total: $0.total) }
            shape.tools = tools.map {
                var tool = $0
                tool.argumentBytes = nil
                tool.label = ""
                return tool
            }
            return shape
        }
    }

    struct Prefill: Codable, Equatable, Sendable {
        /// queued | cacheLookup | cacheRestore | prefill
        var stage: String
        var done: Int
        var total: Int
    }

    struct Tool: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable { case preparing, running, done, failed }
        var id: String
        var name: String
        /// The Mac chat's label for the call, in its current tense.
        var label: String
        var icon: String
        var state: State
        var durationMs: Int?
        /// Bytes of arguments written so far, while `preparing`.
        var argumentBytes: Int?
    }

    struct ImageStep: Codable, Equatable, Sendable {
        var step: Int
        var total: Int
    }

    struct Artifact: Codable, Equatable, Sendable {
        var id: String
        var filename: String
        var mimeType: String
        var fileSize: Int
    }

    static let preparingToolId = "preparing"

    /// The progress of the run answering the last user turn in `turns`.
    @MainActor
    static func snapshot(of turns: [ChatTurn], startedMs: Int64, nowMs: Int64) -> Progress? {
        guard let userIndex = turns.lastIndex(where: { $0.role == .user }) else { return nil }
        let run = turns[(userIndex + 1)...]
        var progress = Progress(
            turn: turns[userIndex].id.uuidString.lowercased(), phase: .waiting, startedMs: startedMs,
            updatedMs: nowMs)

        for turn in run where turn.role == .assistant {
            for call in turn.toolCalls ?? [] {
                let result = turn.toolResults[call.id]
                let failed = result.map(ToolEnvelope.isError) ?? false
                let (_, icon) = AgentToolTraceDetail.categoryAndIcon(call.function.name)
                progress.tools.append(
                    Tool(
                        id: call.id,
                        name: call.function.name,
                        label: ToolDisplayName.friendly(
                            for: call.function.name, running: result == nil, arguments: call.function.arguments,
                            failed: failed),
                        icon: icon,
                        state: result == nil ? .running : (failed ? .failed : .done),
                        durationMs: turn.toolCallDurations[call.id].map { Int(($0 * 1000).rounded()) }
                    ))
            }
            for artifact in turn.sharedArtifacts where !progress.artifacts.contains(where: { $0.id == artifact.id }) {
                progress.artifacts.append(
                    Artifact(
                        id: artifact.id, filename: artifact.filename, mimeType: artifact.mimeType,
                        fileSize: artifact.fileSize))
            }
        }

        guard let last = run.last(where: { $0.role == .assistant }) else { return progress }
        if let name = last.pendingToolName {
            let (_, icon) = AgentToolTraceDetail.categoryAndIcon(name)
            progress.tools.append(
                Tool(
                    id: preparingToolId,
                    name: name == ToolDisplayName.pendingToolSentinel ? "" : name,
                    label: ToolDisplayName.friendly(for: name, running: true, pendingBytes: last.pendingToolArgSize),
                    icon: icon,
                    state: .preparing,
                    argumentBytes: last.pendingToolArgSize
                ))
        }
        if !last.thinkingIsEmpty { progress.thinkingChars = last.thinkingLength }

        if let step = last.imageStep {
            progress.phase = .image
            progress.image = ImageStep(step: step.step, total: step.total)
        } else if let prefill = last.prefillProgress {
            progress.phase = .prefill
            progress.prefill = Prefill(
                stage: prefill.stage.rawValue, done: prefill.completedUnitCount, total: prefill.totalUnitCount)
        } else if progress.tools.contains(where: { $0.state == .running || $0.state == .preparing }) {
            progress.phase = .tool
        } else if last.isReasoningActive {
            progress.phase = .thinking
        } else if !last.contentIsEmpty {
            progress.phase = .answering
        } else if !last.thinkingIsEmpty {
            progress.phase = .thinking
        }
        return progress
    }
}

/// Writes a session's run progress as it changes: a new shape at most every
/// half second, counters alone every two.
@MainActor
final class SyncRunProgressPublisher {
    nonisolated static let shapeInterval: Int64 = 500
    nonisolated static let counterInterval: Int64 = 2_000

    private static let log = Logger(subsystem: "ai.osaurus", category: "sync.progress")
    private static let writes = DispatchQueue(label: "ai.osaurus.sync.run-progress")

    private var startedMs: Int64 = 0
    private var written: SyncRunProgressContract.Progress?
    private var writtenMs: Int64 = 0
    private var scope: String?

    func runStarted() {
        startedMs = SyncHostedRunContract.nowMs()
        written = nil
        writtenMs = 0
        scope = nil
    }

    func update(_ session: ChatSession) {
        guard SyncTurnStreamer.canStream(session), let sessionId = session.sessionId,
            let scope = SyncConversationStore.shared.scope(forSession: sessionId)
        else { return }
        let now = SyncHostedRunContract.nowMs()
        guard let progress = SyncRunProgressContract.snapshot(of: session.turns, startedMs: startedMs, nowMs: now)
        else { return }
        guard Self.shouldWrite(progress, after: written, writtenMs: writtenMs, nowMs: now) else { return }
        self.scope = scope
        write(progress, scope: scope, nowMs: now)
    }

    /// The run ended: says so, keeping the final tool and file list.
    func runEnded(_ session: ChatSession) {
        guard let scope = scope ?? session.sessionId.flatMap(SyncConversationStore.shared.scope(forSession:)),
            var last = written ?? session.sessionId.flatMap({ _ in
                SyncRunProgressContract.snapshot(
                    of: session.turns, startedMs: startedMs, nowMs: SyncHostedRunContract.nowMs())
            })
        else { return }
        guard last.phase != .done else { return }
        last.phase = .done
        last.prefill = nil
        last.image = nil
        last.tools.removeAll { $0.state == .preparing }
        write(last, scope: scope, nowMs: SyncHostedRunContract.nowMs())
    }

    nonisolated static func shouldWrite(
        _ progress: SyncRunProgressContract.Progress,
        after written: SyncRunProgressContract.Progress?,
        writtenMs: Int64,
        nowMs: Int64
    ) -> Bool {
        guard let written else { return true }
        if progress.sameShape(as: written) {
            var a = progress
            a.updatedMs = written.updatedMs
            return a != written && nowMs - writtenMs >= counterInterval
        }
        return nowMs - writtenMs >= shapeInterval
    }

    private func write(_ progress: SyncRunProgressContract.Progress, scope: String, nowMs: Int64) {
        var progress = progress
        progress.updatedMs = nowMs
        written = progress
        writtenMs = nowMs
        let value = progress
        Self.writes.async {
            do {
                let bytes = try SyncHostedRunContract.encode(value)
                try SyncConversationStore.shared.performWrite { core in
                    try core.setConversationAppData(
                        scope: scope, namespace: SyncRunProgressContract.namespace, bytes: bytes)
                    core.syncNow()
                }
            } catch {
                Self.log.error("run progress write failed: \(error.syncLogDetail, privacy: .public)")
            }
        }
    }
}
