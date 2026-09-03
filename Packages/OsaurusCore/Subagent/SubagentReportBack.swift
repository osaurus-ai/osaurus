//
//  SubagentReportBack.swift
//  OsaurusCore — Subagent framework
//
//  Delivers a background helper's terminal digest back into the chat
//  session that dispatched it. A `background: true` spawn returns an
//  acknowledgment as its tool result, so the digest cannot travel the
//  normal tool-result channel — instead it lands here as a follow-up
//  user-role turn (`session.send`), the same canonical path the notch
//  quick-reply and plugin interrupts use, so the orchestrator narrates
//  the result in a fresh turn.
//

import Foundation

@MainActor
enum SubagentReportBack {
    /// Poll cadence while the launching session is busy. Delivery is not
    /// latency-critical; the loop just has to notice the stream ending.
    static let idlePollInterval: Duration = .milliseconds(250)

    /// The follow-up turn text. Prefixed so the model (and the user) can
    /// tell a helper report from an ordinary user message.
    static func message(title: String, success: Bool, summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = success ? "finished" : "failed"
        let body = trimmed.isEmpty ? "(no summary provided)" : trimmed
        return "[Helper report] \(title) \(outcome): \(body)"
    }

    /// Deliver the digest to the launching session once it is idle —
    /// not streaming and not paused on a clarify prompt (sending during a
    /// clarify would wrongly answer it). The weak box is re-read on every
    /// tick so this loop never extends the session's lifetime; if the chat
    /// is gone, the report is dropped and the notch background-task row
    /// remains the durable record of the digest.
    static func deliver(
        title: String,
        success: Bool,
        summary: String,
        to box: WeakChatSessionBox?
    ) async {
        let report = message(title: title, success: success, summary: summary)
        while !Task.isCancelled {
            guard let session = box?.session else { return }
            if !session.isStreaming, session.awaitingClarify == nil {
                // A background worker's `share_artifact` deposits typed
                // artifacts keyed by this session; no spawn tool return will
                // drain them (the ack already returned), so promote them
                // right before the report lands.
                await session.promoteWorkerSharedArtifacts()
                session.send(report)
                return
            }
            try? await Task.sleep(for: idlePollInterval)
        }
    }

    /// Wait until the launching session finishes its current stream (or the
    /// helper is stopped, or the session goes away). Gates a LOCAL-model
    /// helper's start: its residency handoff may evict the parent's resident
    /// model, which must never happen while the parent is mid-reply.
    /// Returns immediately when there is no live parent session
    /// (headless/eval dispatch).
    static func waitUntilParentStreamEnds(
        _ box: WeakChatSessionBox?,
        orInterrupted interrupt: InterruptToken? = nil
    ) async {
        while !Task.isCancelled {
            if interrupt?.isInterrupted == true { return }
            guard let session = box?.session else { return }
            if !session.isStreaming { return }
            try? await Task.sleep(for: idlePollInterval)
        }
    }
}
