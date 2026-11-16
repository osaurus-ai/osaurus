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

        /// `value` inline, or over `limit` staged as a blob and referred to by its index.
        func placed(_ key: String, _ value: JSONValue, limit: Int = inlineLimit) -> JSONValue? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let bytes = try? encoder.encode(value) else { return nil }
            hasher.update(data: bytes)
            guard bytes.count > limit else { return value }
            let file = staging.appendingPathComponent("\(stagedPrefix)\(run.id.uuidString)-\(key).json")
            guard (try? bytes.write(to: file)) != nil else { return nil }
            blobs.append(AttachmentFile(path: file.path, mediaType: "application/json", name: "\(key).json"))
            return .object(["$blob": .number(Double(blobs.count - 1)), "size": .number(Double(bytes.count))])
        }
        object["input"] = placed("input", run.input)
        if let output = run.output { object["output"] = placed("output", output) }
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
            // The file as it is now, not as the run recorded it: a plain file (not a link, which could point
            // anywhere on this Mac, `~/.ssh` say) at its size now, which the caps are checked against.
            let attributes = try? FileManager.default.attributesOfItem(atPath: artifact.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            let readable =
                artifact.problem == nil && attributes?[.type] as? FileAttributeType == .typeRegular
                && FileManager.default.isReadableFile(atPath: artifact.path)
            if !readable {
                entry["skipped"] = .string("missing")
            } else if size > fileLimit || total + size > totalLimit {
                entry["skipped"] = .string("tooLarge")
            } else {
                total += size
                blobs.append(AttachmentFile(path: artifact.path, mediaType: artifact.mimeType, name: artifact.filename))
                entry["blob"] = .number(Double(blobs.count - 1))
            }
            hasher.update(data: Data("\(artifact.id)|\(artifact.fileSize)|\(entry["skipped"] == nil)".utf8))
            files.append(.object(entry))
        }
        if !files.isEmpty { object["files"] = .array(files) }
        var steps = run.nodes.enumerated().compactMap { index, node in
            step(node, placed: { name, value in placed("step\(index)-\(name)", value, limit: stepInlineLimit) })
        }
        // The message is app data, which the sync core caps at 64 KB a write: past it the write fails and the
        // phone never gets the output. Logs and tool calls are what can still grow past the caps: over
        // `messageLimit`, the steps go without them.
        if encodedSize(object.merging(["steps": .array(steps)]) { _, new in new }) > messageLimit {
            steps = steps.map(Self.withoutLogsOrCalls)
        }
        // Always, an empty list too: a message without it was written before steps were sent (`workflow_step_details`).
        object["steps"] = .array(steps)
        // The steps in the digest too, with a mark for this shape: a message written before steps were sent
        // would otherwise match and be kept, leaving the phone without them.
        hasher.update(data: Data("steps/1".utf8))
        if let encoded = try? JSONEncoder().encode(JSONValue.array(steps)) { hasher.update(data: encoded) }
        hasher.update(data: Data(run.status.rawValue.utf8))
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        object["digest"] = .string(digest)
        return Payload(runId: run.id.uuidString.lowercased(), object: object, blobs: blobs, digest: digest)
    }

    /// A step's input or output over this goes to a blob: lower than the run's own, as a run has many.
    static let stepInlineLimit = 4 * 1024
    /// A step's log lines sent, the newest; each line's length; an error's is four lines'.
    static let logLimit = 200
    static let lineLimit = 500
    /// Over this, the steps go without their logs and tool calls: under the sync core's 64 KB of app data a write.
    static let messageLimit = 48 * 1024

    /// `object` as JSON, in bytes.
    private static func encodedSize(_ object: [String: JSONValue]) -> Int {
        (try? JSONEncoder().encode(JSONValue.object(object)))?.count ?? 0
    }

    /// A step's entry without its log and tool calls, for a message that would be too big with them.
    private static func withoutLogsOrCalls(_ step: JSONValue) -> JSONValue {
        guard var entry = step.objectValue else { return step }
        entry["logs"] = nil
        entry["toolCalls"] = nil
        return .object(entry)
    }

    /// What the Mac's run view shows on opening a step (`WorkflowRunView.details`): its model, retries,
    /// tokens and time, its error, input and output (through `placed`, which may make either a blob), its
    /// log and its tool calls. Keyed by the card's step id (`SyncWorkflowCard`). Nil for a skipped step, which
    /// the phone doesn't list.
    static func step(_ node: NodeRun, placed: (String, JSONValue) -> JSONValue?) -> JSONValue? {
        guard node.status != .skipped else { return nil }
        var entry: [String: JSONValue] = [
            "id": .string(node.nodeID),
            "attempts": .number(Double(node.attempts)),
        ]
        if let model = node.model, !model.isEmpty { entry["model"] = .string(model) }
        if let ms = node.durationMs { entry["durationMs"] = .number(Double(ms)) }
        if let tokens = node.inputTokens { entry["inputTokens"] = .number(Double(tokens)) }
        if let tokens = node.outputTokens { entry["outputTokens"] = .number(Double(tokens)) }
        if let error = node.error, !error.isEmpty { entry["error"] = .string(String(error.prefix(lineLimit * 4))) }
        if let input = node.input, !isEmpty(input) { entry["input"] = placed("input", input) }
        if let output = node.output, !isEmpty(output) { entry["output"] = placed("output", output) }
        // The newest lines, each cut short: a step's log has no end of its own.
        if !node.logs.isEmpty {
            entry["logs"] = .array(node.logs.suffix(logLimit).map { .string(String($0.prefix(lineLimit))) })
        }
        if !node.toolCallRecords.isEmpty {
            entry["toolCalls"] = .array(
                node.toolCallRecords.map { record in
                    var call: [String: JSONValue] = ["name": .string(record.name), "isError": .bool(record.isError)]
                    if let ms = record.durationMs { call["durationMs"] = .number(Double(ms)) }
                    if let result = record.resultPreview, !result.isEmpty { call["result"] = .string(result) }
                    // As recorded: secrets already scrubbed (`SecretArgumentScrubber`); capped as the result is.
                    let arguments = String(record.arguments.prefix(WorkflowToolCallRecord.previewLimit))
                    if !arguments.isEmpty, arguments != "{}" { call["arguments"] = .string(arguments) }
                    return .object(call)
                })
        }
        return .object(entry)
    }

    /// Nothing to show: null, or an empty object or list (as the Mac's run view judges it).
    private static func isEmpty(_ value: JSONValue) -> Bool {
        switch value {
        case .null: return true
        case .object(let object): return object.isEmpty
        case .array(let array): return array.isEmpty
        default: return false
        }
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
        log.notice(
            "wrote output of run \(payload.runId, privacy: .public): \(bytes.count) bytes, \(payload.blobs.count) blobs"
        )
    }
}
