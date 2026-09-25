//
//  RemoteRunArtifacts.swift
//  osaurus
//
//  Artifacts back over the relay. A teammate's shared agent runs on ITS
//  owner's Mac (`/agents/{id}/run`, Mode 2); until now anything it shared
//  with `share_artifact` stayed there. This file carries small artifacts to
//  the requester:
//
//  Host side — `RemoteRunArtifactRelay` intercepts every successful
//  `share_artifact` result of a hosted inbound run (`InboundSharedRunBridge`
//  runs only), processes the marker blob into the hosted session's artifact
//  store exactly like a chat turn would, hands the model a compact
//  confirmation, and — when the run ends — serialises the collected files
//  as `osaurus_artifacts` (`[{name, mime, size_bytes, bytes_base64}]`) on
//  one extension SSE chunk (empty `choices`, so OpenAI text parsers ignore
//  it). Capped at `maxTotalBytes` / `maxCount`; an artifact over the cap or
//  a directory is listed with `omitted_reason` and no bytes.
//
//  Client side — `RemoteProviderService` decodes that chunk into a
//  `StreamingArtifactHint` (same `\u{FFFE}` sentinel family as billing /
//  prefill hints, so it never reaches visible text or token counting);
//  `ChatSession` imports the bytes into ITS session's artifact store and
//  attaches them to the assistant turn as `sharedArtifacts` — the exact
//  surface a local child uses, so `AgentDelegationDispatcher
//  .adoptChildArtifacts` promotes them to the parent chat and
//  `artifacts_shared` lands in the spawn payload unchanged.
//
//  Version-tolerant: an older host never emits the chunk; an older client
//  ignores an unknown chunk with empty choices.
//

import Foundation

// MARK: - Wire shape

/// One artifact on the `osaurus_artifacts` chunk.
struct RemoteRunArtifact: Codable, Equatable, Sendable {
    let name: String
    let mime: String
    var description: String? = nil
    let size_bytes: Int
    /// Present for artifacts within the cap; nil when omitted.
    var bytes_base64: String? = nil
    /// `too_large` | `directory` | `unreadable` when the bytes were left
    /// on the host.
    var omitted_reason: String? = nil

    var isOmitted: Bool { bytes_base64 == nil }
}

/// Client-side decode of the extension chunk (only the field we need).
struct RemoteRunArtifactsChunk: Decodable {
    let osaurus_artifacts: [RemoteRunArtifact]?
}

/// In-band client signal: the decoded `osaurus_artifacts` list riding the
/// stream as a `\u{FFFE}` sentinel delta.
enum StreamingArtifactHint: Sendable {
    private static let prefix = "\u{FFFE}artifacts:"

    static func encode(_ artifacts: [RemoteRunArtifact]) -> String {
        guard let data = try? JSONEncoder().encode(artifacts),
            let json = String(data: data, encoding: .utf8)
        else { return prefix + "[]" }
        return prefix + json
    }

    static func decode(_ delta: String) -> [RemoteRunArtifact]? {
        guard delta.hasPrefix(prefix) else { return nil }
        let json = String(delta.dropFirst(prefix.count))
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([RemoteRunArtifact].self, from: data)
    }
}

// MARK: - Host side

/// Collects the artifacts a hosted `/agents/{id}/run` shares and builds the
/// final chunk. Deposits happen on tool executors; reads on the request
/// task — hence the lock.
final class RemoteRunArtifactRelay: @unchecked Sendable {
    /// Total bytes the final chunk may carry (base64 adds ~33% on the wire).
    static let maxTotalBytes = 4 * 1024 * 1024
    static let maxCount = 16

    private let lock = NSLock()
    private var collected: [SharedArtifact] = []
    let contextId: String
    let executionMode: ExecutionMode
    let sandboxAgentName: String?

    init(contextId: String, executionMode: ExecutionMode, sandboxAgentName: String? = nil) {
        self.contextId = contextId
        self.executionMode = executionMode
        self.sandboxAgentName = sandboxAgentName
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return collected.count
    }

    var artifacts: [SharedArtifact] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    /// Process one `share_artifact` result. Success: the file lands in the
    /// hosted session's store, the artifact is collected, and the model
    /// sees a compact confirmation (never the marker blob). Failures and
    /// non-success envelopes pass through unchanged so the tool's own
    /// `invalidArgs` / path errors keep steering the model.
    func intercept(rawResult: String) -> String {
        guard
            let payload = ToolEnvelope.successPayload(rawResult) as? [String: Any],
            let markerText = payload["text"] as? String
        else { return rawResult }
        switch SharedArtifact.processToolResultDetailed(
            markerText,
            contextId: contextId,
            contextType: .chat,
            executionMode: executionMode,
            sandboxAgentName: sandboxAgentName
        ) {
        case .success(let processed):
            lock.lock()
            collected.append(processed.artifact)
            lock.unlock()
            let note =
                processed.artifact.isDirectory || processed.artifact.fileSize > Self.maxTotalBytes
                ? " It is too large to travel back to the requester — say so in your final message."
                : " It travels back to the requester with your final message."
            return ToolEnvelope.success(
                tool: "share_artifact",
                text: "Artifact '\(processed.artifact.filename)' shared.\(note) Reference it by name; do NOT "
                    + "repeat its content or share it again."
            )
        case .failure(let reason):
            return SharedArtifact.failureEnvelope(reason: reason, executionMode: executionMode)
        }
    }

    /// The `osaurus_artifacts` list: files within the caps carry bytes,
    /// the rest are listed with `omitted_reason`. Pure over `artifacts`.
    func payload() -> [RemoteRunArtifact] {
        Self.payload(for: artifacts)
    }

    static func payload(
        for artifacts: [SharedArtifact],
        maxTotalBytes: Int = maxTotalBytes,
        maxCount: Int = maxCount
    ) -> [RemoteRunArtifact] {
        var out: [RemoteRunArtifact] = []
        var budget = maxTotalBytes
        for artifact in artifacts.prefix(maxCount) {
            var row = RemoteRunArtifact(
                name: artifact.filename,
                mime: artifact.mimeType,
                description: artifact.description,
                size_bytes: artifact.fileSize
            )
            if artifact.isDirectory {
                row.omitted_reason = "directory"
            } else if artifact.fileSize > budget {
                row.omitted_reason = "too_large"
            } else if let data = Self.bytes(of: artifact), data.count <= budget {
                row.bytes_base64 = data.base64EncodedString()
                budget -= data.count
            } else {
                row.omitted_reason = "unreadable"
            }
            out.append(row)
        }
        return out
    }

    private static func bytes(of artifact: SharedArtifact) -> Data? {
        if !artifact.hostPath.isEmpty,
            let data = try? Data(contentsOf: URL(fileURLWithPath: artifact.hostPath))
        {
            return data
        }
        return artifact.content?.data(using: .utf8)
    }
}

// MARK: - Client side

extension SharedArtifact {
    /// Write the artifacts a remote host returned into `contextId`'s store
    /// and return the typed artifacts (omitted rows produce none). The
    /// filename is sanitised and the destination resolved inside the
    /// context directory exactly like a local `share_artifact`.
    static func importRemoteArtifacts(
        _ remote: [RemoteRunArtifact],
        contextId: String
    ) -> [SharedArtifact] {
        let contextDir = OsaurusPaths.contextArtifactsDir(contextId: contextId)
        OsaurusPaths.ensureExistsSilent(contextDir)
        var out: [SharedArtifact] = []
        for row in remote {
            guard let encoded = row.bytes_base64, let data = Data(base64Encoded: encoded) else { continue }
            let filename = sanitizeArtifactFilename(row.name)
            guard !filename.isEmpty,
                let dest = resolveDestinationPath(filename: filename, contextDir: contextDir)
            else { continue }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try data.write(to: dest, options: .atomic)
            } catch {
                NSLog("[SharedArtifact] remote import failed for %@: %@", filename, error.localizedDescription)
                continue
            }
            let mime = row.mime.isEmpty ? SharedArtifact.mimeType(from: filename) : row.mime
            let isText =
                mime.hasPrefix("text/") || mime == "application/json" || mime == "application/xml"
                || mime == "application/x-yaml"
            out.append(
                SharedArtifact(
                    contextId: contextId,
                    contextType: .chat,
                    filename: filename,
                    mimeType: mime,
                    fileSize: data.count,
                    hostPath: dest.path,
                    content: isText ? String(data: data, encoding: .utf8) : nil,
                    description: row.description,
                    isFinalResult: false
                )
            )
        }
        return out
    }
}
