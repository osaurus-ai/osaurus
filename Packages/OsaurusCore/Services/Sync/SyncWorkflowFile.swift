//
//  SyncWorkflowFile.swift
//  osaurus
//
//  One of a run's files too large to go with its output (`workflow_file_fetch`, docs/SYNC_MOBILE_CONTRACT.md §5.5),
//  sent only when the phone asks for it with `workflowFile`: a message in the manage conversation carrying the file
//  as its one blob. The phone names the run and the file by id, never a path: the Mac reads the path from its own
//  record of the run. Only the newest few are kept, so large files don't pile up.
//

import Foundation
import OsaurusSync
import os

extension SyncDeviceFeedContract {
    /// Message app data on a fetched file's message.
    static let workflowFileNamespace = "ai.osaurus.workflow-file/1"
    static let workflowFileMessageContent = "workflow-file"
}

enum SyncWorkflowFile {
    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.workflow-file")

    /// The largest file sent on asking.
    static let fetchLimit = 512 * 1024 * 1024
    /// Fetched-file messages kept; older ones go when another is written.
    static let keep = 2
    static let stagedPrefix = "osaurus-run-file-"

    enum Failure: Error, Equatable {
        case notFound
        case tooLarge
        /// This Mac's manage conversation isn't there yet (Sync just opened): worth asking again.
        case notReady
    }

    struct Source: Sendable, Equatable {
        var runId: String
        var fileId: String
        var path: String
        var filename: String
        var mimeType: String
    }

    /// Whether a file listed `tooLarge` with the output can still be asked for.
    nonisolated static func fetchable(size: Int) -> Bool { size <= fetchLimit }

    /// The file `fileId` of run `runId`, as this Mac recorded it.
    @MainActor
    static func source(runId raw: String?, fileId: String?) -> Result<Source, Failure> {
        guard let raw, let id = UUID(uuidString: raw), let fileId,
            let run = WorkflowRunStore.shared.run(id: id), run.status.isTerminal,
            let artifact = run.artifacts.first(where: { $0.id == fileId && !$0.isDirectory }),
            artifact.problem == nil
        else { return .failure(.notFound) }
        return .success(
            Source(
                runId: run.id.uuidString.lowercased(), fileId: artifact.id, path: artifact.path,
                filename: artifact.filename, mimeType: artifact.mimeType))
    }

    /// Copies the file (a plain file, no link, at most `fetchLimit`) to a staged file the caller removes. Off the
    /// main thread, and outside the core's queue: a copy this size would hold up every other Sync read and write.
    nonisolated static func stage(_ source: Source) -> Result<URL, Failure> {
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(stagedPrefix)\(UUID().uuidString)")
        switch SyncWorkflowOutput.copyRegularFile(source.path, to: staged, limit: fetchLimit) {
        case .missing:
            try? FileManager.default.removeItem(at: staged)
            return .failure(.notFound)
        case .tooLarge:
            try? FileManager.default.removeItem(at: staged)
            return .failure(.tooLarge)
        case .copied(let copy, _): return .success(copy)
        }
    }

    /// Writes the message carrying `file` (from `stage`), on the core's queue.
    nonisolated static func send(_ source: Source, file: URL, core: SyncCore) throws -> Result<Void, Failure> {
        guard
            let conversation = try SyncDeviceFeedContract.conversation(
                kind: SyncDeviceFeedContract.manageKind, device: core.deviceKey(), core: core)
        else { return .failure(.notReady) }
        let scope = conversation.scope

        // Newest first.
        var earlier: [String] = []
        var cursor: PageCursor?
        repeat {
            let page = try core.messages(scope: scope, before: cursor, limit: 200)
            for message in page.messages.reversed()
            where message.appData(SyncDeviceFeedContract.workflowFileNamespace) != nil {
                earlier.append(message.id)
            }
            cursor = page.nextCursor
        } while cursor != nil

        let object: [String: JSONValue] = [
            "v": .number(1), "runId": .string(source.runId), "fileId": .string(source.fileId), "blob": .number(0),
        ]
        let bytes = try SyncHostedRunContract.encode(JSONValue.object(object))
        let attachment = AttachmentFile(path: file.path, mediaType: source.mimeType, name: source.filename)
        let write = AppDataWrite(
            namespace: SyncDeviceFeedContract.workflowFileNamespace, bytes: bytes, attachments: [attachment])
        let message = OutgoingMessage(
            role: .system, content: SyncDeviceFeedContract.workflowFileMessageContent,
            attachments: [], replyTo: nil, asAgent: nil, toolCallId: nil, toolName: nil, appData: [write])
        _ = try core.sendMessage(scope: scope, message: message)
        for old in earlier.dropFirst(keep - 1) { try? core.deleteMessage(id: old) }
        core.syncNow()
        log.notice("sent a file of run \(source.runId, privacy: .public)")
        return .success(())
    }
}
