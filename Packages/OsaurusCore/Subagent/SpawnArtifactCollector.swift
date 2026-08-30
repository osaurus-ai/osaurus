//
//  SpawnArtifactCollector.swift
//  OsaurusCore
//
//  Typed artifact pipeline for spawned workers: when a worker calls
//  `share_artifact`, the child dispatch processes the marker blob RIGHT
//  THERE (file copied into the artifact store under the PARENT session's
//  context id — no dangling worker paths), deposits the typed
//  `SharedArtifact` here, and hands the worker model only a compact
//  confirmation. After the spawn tool returns, the parent chat drains this
//  collector and attaches the artifacts to the current assistant turn.
//
//  Hardening contract: no artifact bytes or marker blobs ever travel
//  through model-visible JSON — not the worker transcript, not the digest,
//  not the `spawn_result` payload (which carries only an
//  `artifacts_shared` count). The orchestrator has no re-share step to get
//  wrong.
//
//  Lock-protected statics (same pattern as `MemoryScopeRegistry`) because
//  deposits happen on worker executors while the drain runs on the
//  MainActor chat loop.
//

import Foundation

public enum SpawnArtifactCollector {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [String: [SharedArtifact]] = [:]

    /// Bounded storage: a spawn dispatched from a non-chat surface (HTTP,
    /// eval) has no parent chat loop to drain it, so cap what can pile up.
    private static let maxArtifactsPerSession = 32
    private static let maxSessions = 16

    /// Deposit a processed artifact for the parent session to drain.
    static func deposit(_ artifact: SharedArtifact, sessionId: String) {
        var dropped: [SharedArtifact] = []
        lock.lock()
        if pending[sessionId] == nil, pending.count >= maxSessions {
            // Evict an arbitrary stale session rather than grow unboundedly;
            // chat parents drain promptly, so survivors are orphans.
            if let stale = pending.keys.first(where: { $0 != sessionId }),
                let evicted = pending.removeValue(forKey: stale)
            {
                dropped.append(contentsOf: evicted)
            }
        }
        var bucket = pending[sessionId, default: []]
        if bucket.count < maxArtifactsPerSession {
            bucket.append(artifact)
            pending[sessionId] = bucket
        } else {
            // Bucket full: the artifact will never reach a drain, so its
            // already-written store file must not linger either.
            dropped.append(artifact)
        }
        lock.unlock()
        deleteFiles(of: dropped)
    }

    /// Remove and return every pending artifact for a session. The parent
    /// chat loop calls this after each `spawn_agent` / `spawn_batch` tool
    /// returns — including failure envelopes, so artifacts a worker shared
    /// before failing or being cancelled still reach the user.
    public static func drain(sessionId: String) -> [SharedArtifact] {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: sessionId) ?? []
    }

    /// Drop every pending artifact for a session AND delete their files
    /// from the artifact store. Non-chat parents (HTTP `/agents/{id}/run`,
    /// the plugin host loop) call this when their run ends: they have no
    /// turn to attach artifacts to, so anything a worker shared must not
    /// survive as an undrained bucket plus orphaned files on disk.
    public static func discard(sessionId: String) {
        lock.lock()
        let dropped = pending.removeValue(forKey: sessionId) ?? []
        lock.unlock()
        deleteFiles(of: dropped)
    }

    /// Remove the store files backing dropped artifacts, off the caller's
    /// thread (deposits run on worker executors, discards on request tasks).
    private static func deleteFiles(of artifacts: [SharedArtifact]) {
        guard !artifacts.isEmpty else { return }
        let paths = artifacts.map(\.hostPath)
        Task.detached(priority: .utility) {
            for path in paths where !path.isEmpty {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    /// Test hook: clear all pending artifacts.
    static func _resetForTesting() {
        lock.lock()
        pending = [:]
        lock.unlock()
    }

    // MARK: - Worker-side processing

    /// Outcome of intercepting a worker's `share_artifact` result: the
    /// compact string the worker MODEL sees, and the filename when an
    /// artifact was actually deposited (nil on pass-through / failure).
    struct WorkerShareOutcome {
        let modelResult: String
        let sharedFilename: String?
    }

    /// Process a worker's raw `share_artifact` tool result: parse the
    /// marker blob, copy/write the file into the artifact store keyed by
    /// the PARENT session id, deposit the typed artifact, and return a
    /// compact confirmation for the worker model (never the marker blob).
    ///
    /// Workers run without a folder/sandbox execution mode, so `path`-mode
    /// shares resolve under `.none` and fail with the standard
    /// model-readable envelope steering the model to `content`+`filename`
    /// — inline content is a worker's delivery format (workers carry no
    /// write tools). Non-success results pass through unchanged so the
    /// tool's own `invalidArgs` envelopes stay intact.
    static func processWorkerShareArtifact(
        rawResult: String,
        parentSessionId: String
    ) -> WorkerShareOutcome {
        guard
            let payload = ToolEnvelope.successPayload(rawResult) as? [String: Any],
            let markerText = payload["text"] as? String
        else {
            return WorkerShareOutcome(modelResult: rawResult, sharedFilename: nil)
        }

        let outcome = SharedArtifact.processToolResultDetailed(
            markerText,
            contextId: parentSessionId,
            contextType: .chat,
            executionMode: .none
        )
        switch outcome {
        case .success(let processed):
            deposit(processed.artifact, sessionId: parentSessionId)
            let confirmation =
                "Artifact '\(processed.artifact.filename)' is now visible to the user. "
                + "Reference it by name in your answer; do NOT repeat its content or share it again."
            return WorkerShareOutcome(
                modelResult: ToolEnvelope.success(tool: "share_artifact", text: confirmation),
                sharedFilename: processed.artifact.filename
            )
        case .failure(let reason):
            return WorkerShareOutcome(
                modelResult: SharedArtifact.failureEnvelope(
                    reason: reason,
                    executionMode: .none
                ),
                sharedFilename: nil
            )
        }
    }
}
