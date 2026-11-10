//
//  SyncWorkflowOutput.swift
//  osaurus
//
//  A finished workflow run's output for the iPhone (`workflow_outputs`,
//  docs/SYNC_MOBILE_CONTRACT.md §5.5): asked for with `workflowOutput`, and
//  written as a message in the manage conversation carrying the run's input,
//  its output and its files, the files as blobs. Only runs the phone opens
//  are sent; the last few are kept.
//

import CryptoKit
import Foundation
import OsaurusSync
import os

extension SyncDeviceFeedContract {
    /// Message app data on a run's output message.
    static let workflowOutputNamespace = "ai.osaurus.workflow-output/1"
    static let workflowOutputMessageContent = "workflow-output"
}

enum SyncWorkflowOutput {
    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.workflow-output")

    /// Output messages kept; the oldest goes when another is written.
    static let keep = 10
    /// JSON larger than this goes to a blob.
    static let inlineLimit = 16 * 1024
    /// A file over this, or past the total, is listed without its bytes.
    static let fileLimit = 10 * 1024 * 1024
    static let totalLimit = 32 * 1024 * 1024

    struct Payload: Sendable {
        var runId: String
        var object: [String: JSONValue]
        var blobs: [AttachmentFile]
        var digest: String
    }

    static let stagedPrefix = "osaurus-run-output-"

    /// A JSON value staged for a blob, removed once written; never one of the run's own files.
    nonisolated static func isStaged(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent.hasPrefix(stagedPrefix)
    }

    enum Failure: Error, Equatable {
        case notFound
        case running
    }

    /// The output message's content for `runId`, once the run has ended.
    @MainActor
    static func payload(runId raw: String?) -> Result<Payload, Failure> {
        guard let raw, let id = UUID(uuidString: raw), let run = WorkflowRunStore.shared.run(id: id) else {
            return .failure(.notFound)
        }
        guard run.status.isTerminal else { return .failure(.running) }
        return .success(payload(for: run, staging: FileManager.default.temporaryDirectory))
    }

    /// `run`'s input, output and files. JSON over the inline limit is staged
    /// as a file under `staging` and sent as a blob.
    static func payload(for run: WorkflowRun, staging: URL) -> Payload {
        var object: [String: JSONValue] = [
            "v": .number(1),
            "runId": .string(run.id.uuidString.lowercased()),
            "status": .string(run.status.rawValue),
        ]
        var blobs: [AttachmentFile] = []
        var hasher = SHA256()

        func place(_ key: String, _ value: JSONValue) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let bytes = try? encoder.encode(value) else { return }
            hasher.update(data: bytes)
            guard bytes.count > inlineLimit else {
                object[key] = value
                return
            }
            let file = staging.appendingPathComponent("\(stagedPrefix)\(run.id.uuidString)-\(key).json")
            guard (try? bytes.write(to: file)) != nil else { return }
            blobs.append(AttachmentFile(path: file.path, mediaType: "application/json", name: "\(key).json"))
            object[key] = .object(["$blob": .number(Double(blobs.count - 1)), "size": .number(Double(bytes.count))])
        }
        place("input", run.input)
        if let output = run.output { place("output", output) }
        if let error = run.error?.reason { object["error"] = .string(error) }

        var total = 0
        var files: [JSONValue] = []
        for artifact in run.artifacts where !artifact.isDirectory {
            var entry: [String: JSONValue] = [
                "id": .string(artifact.id),
                "filename": .string(artifact.filename),
                "mimeType": .string(artifact.mimeType),
                "fileSize": .number(Double(artifact.fileSize)),
            ]
            if let description = artifact.description, !description.isEmpty {
                entry["description"] = .string(description)
            }
            let readable = artifact.problem == nil && FileManager.default.isReadableFile(atPath: artifact.path)
            if !readable {
                entry["skipped"] = .string("missing")
            } else if artifact.fileSize > fileLimit || total + artifact.fileSize > totalLimit {
                entry["skipped"] = .string("tooLarge")
            } else {
                total += artifact.fileSize
                blobs.append(AttachmentFile(path: artifact.path, mediaType: artifact.mimeType, name: artifact.filename))
                entry["blob"] = .number(Double(blobs.count - 1))
            }
            hasher.update(data: Data("\(artifact.id)|\(artifact.fileSize)|\(entry["skipped"] == nil)".utf8))
            files.append(.object(entry))
        }
        if !files.isEmpty { object["files"] = .array(files) }
        hasher.update(data: Data(run.status.rawValue.utf8))
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        object["digest"] = .string(digest)
        return Payload(runId: run.id.uuidString.lowercased(), object: object, blobs: blobs, digest: digest)
    }

    /// Writes `payload` as the run's output message, unless one with the same
    /// digest is there, and drops the oldest past `keep`.
    nonisolated static func write(_ payload: Payload, core: SyncCore) throws {
        guard
            let conversation = try SyncDeviceFeedContract.conversation(
                kind: SyncDeviceFeedContract.manageKind, device: core.deviceKey(), core: core)
        else { return }
        let scope = conversation.scope
        // Newest first: pages go back in time, each oldest to newest.
        var outputs: [(id: String, runId: String, digest: String?)] = []
        var cursor: PageCursor?
        repeat {
            let page = try core.messages(scope: scope, before: cursor, limit: 200)
            for message in page.messages.reversed() {
                guard let data = message.appData(SyncDeviceFeedContract.workflowOutputNamespace),
                    let object = SyncConversationMapper.parseObject(data.bytes),
                    let runId = object["runId"] as? String
                else { continue }
                outputs.append((message.id, runId, object["digest"] as? String))
            }
            cursor = page.nextCursor
        } while cursor != nil

        let mine = outputs.filter { $0.runId == payload.runId }
        if mine.count == 1, mine[0].digest == payload.digest { return }
        for stale in mine { try? core.deleteMessage(id: stale.id) }
        let others = outputs.filter { $0.runId != payload.runId }
        for old in others.dropFirst(keep - 1) { try? core.deleteMessage(id: old.id) }

        let bytes = try SyncHostedRunContract.encode(JSONValue.object(payload.object))
        let write = AppDataWrite(
            namespace: SyncDeviceFeedContract.workflowOutputNamespace, bytes: bytes, attachments: payload.blobs)
        let message = OutgoingMessage(
            role: .system, content: SyncDeviceFeedContract.workflowOutputMessageContent,
            attachments: [], replyTo: nil, asAgent: nil, toolCallId: nil, toolName: nil, appData: [write])
        _ = try core.sendMessage(scope: scope, message: message)
        core.syncNow()
        log.notice("wrote output of run \(payload.runId, privacy: .public): \(payload.blobs.count) blobs")
    }
}
