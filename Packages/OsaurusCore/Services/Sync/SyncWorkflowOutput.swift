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
    /// as a file under `staging` and sent as a blob, and so is a copy of each file.
    static func payload(for run: WorkflowRun, staging: URL) -> Payload {
        var object: [String: JSONValue] = [
            "v": .number(1),
            "runId": .string(run.id.uuidString.lowercased()),
            "status": .string(run.status.rawValue),
        ]
        var blobs: [AttachmentFile] = []
        var hasher = SHA256()
        // Per payload: two requests for one run stage apart, and neither removes the other's files.
        let tag = UUID().uuidString.prefix(8)
        func stagedFile(_ key: String) -> URL {
            staging.appendingPathComponent("\(stagedPrefix)\(run.id.uuidString)-\(tag)-\(key)")
        }

        /// `value` as JSON bytes, hashed into the digest.
        func encoded(_ value: JSONValue) -> Data? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let bytes = try? encoder.encode(value) else { return nil }
            hasher.update(data: bytes)
            return bytes
        }
        /// `bytes` staged as a blob, referred to by its index in `into`, numbered from `base`.
        func blob(_ key: String, _ bytes: Data, into list: inout [AttachmentFile], base: Int) -> JSONValue? {
            let file = stagedFile("\(key).json")
            guard (try? bytes.write(to: file)) != nil else { return nil }
            list.append(AttachmentFile(path: file.path, mediaType: "application/json", name: "\(key).json"))
            return .object(["$blob": .number(Double(base + list.count - 1)), "size": .number(Double(bytes.count))])
        }
        /// `value` inline, or over `limit` staged as a blob.
        func placed(_ key: String, _ value: JSONValue, limit: Int = inlineLimit) -> JSONValue? {
            guard let bytes = encoded(value) else { return nil }
            guard bytes.count > limit else { return value }
            return blob(key, bytes, into: &blobs, base: 0)
        }
        object["input"] = placed("input", run.input)
        if let output = run.output { object["output"] = placed("output", output) }
        if let error = run.error?.reason { object["error"] = .string(String(error.prefix(lineLimit * 4))) }

        var total = 0
        var files: [JSONValue] = []
        for (index, artifact) in run.artifacts.filter({ !$0.isDirectory }).prefix(fileCountLimit).enumerated() {
            var entry: [String: JSONValue] = [
                "id": .string(String(artifact.id.prefix(200))),
                "filename": .string(String(artifact.filename.prefix(255))),
                "mimeType": .string(String(artifact.mimeType.prefix(200))),
                "fileSize": .number(Double(artifact.fileSize)),
            ]
            if let description = artifact.description, !description.isEmpty {
                entry["description"] = .string(String(description.prefix(lineLimit)))
            }
            // The file as it is now, not as the run recorded it, and copied from what was opened and
            // checked: a plain file (not a link, which could point anywhere on this Mac, `~/.ssh` say)
            // at its size now, which the caps are checked against. The core reads only the copy, so
            // the file swapped for a link after the check is never what's sent.
            let limit = min(fileLimit, totalLimit - total)
            let copy: Copy =
                artifact.problem == nil
                ? copyRegularFile(artifact.path, to: stagedFile("file\(index)"), limit: limit) : .missing
            switch copy {
            case .missing:
                entry["skipped"] = .string("missing")
            case .tooLarge:
                entry["skipped"] = .string("tooLarge")
            case .copied(let file, let size):
                total += size
                blobs.append(AttachmentFile(path: file.path, mediaType: artifact.mimeType, name: artifact.filename))
                entry["blob"] = .number(Double(blobs.count - 1))
            }
            hasher.update(data: Data("\(artifact.id)|\(artifact.fileSize)|\(entry["skipped"] == nil)".utf8))
            files.append(.object(entry))
        }
        if !files.isEmpty { object["files"] = .array(files) }

        // The message is app data, which the sync core caps at 64 KB a write: past it the write fails and the
        // phone never gets the output. Each fallback runs until the message fits under `messageLimit`:
        // the steps without their logs and tool calls; then every step input and output as a blob; then the
        // oldest steps without their details (id and status only, as the card has); then the run's own
        // input and output as blobs too; last, the files without their descriptions.
        let shown = run.nodes.filter { $0.status != .skipped }
        let base = blobs.count
        func steps(stepLimit: Int, lean: Bool, bare: Int) -> (steps: [JSONValue], blobs: [AttachmentFile]) {
            var stepBlobs: [AttachmentFile] = []
            let steps = shown.enumerated().compactMap { index, node -> JSONValue? in
                if index < bare { return .object(["id": .string(node.nodeID), "trimmed": .bool(true)]) }
                let entry = step(node) { name, value in
                    guard let bytes = encoded(value) else { return nil }
                    guard bytes.count > stepLimit else { return value }
                    return blob("step\(index)-\(name)", bytes, into: &stepBlobs, base: base)
                }
                return lean ? entry.map(Self.withoutLogsOrCalls) : entry
            }
            return (steps, stepBlobs)
        }
        func fits(_ steps: [JSONValue]) -> Bool {
            encodedSize(object.merging(["steps": .array(steps)]) { _, new in new }) <= messageLimit
        }
        var built = steps(stepLimit: stepInlineLimit, lean: false, bare: 0)
        if !fits(built.steps) { built = steps(stepLimit: stepInlineLimit, lean: true, bare: 0) }
        if !fits(built.steps) { built = steps(stepLimit: 0, lean: true, bare: 0) }
        var bare = 0
        while !fits(built.steps), bare < shown.count {
            bare = min(shown.count, max(bare * 2, 1))
            built = steps(stepLimit: 0, lean: true, bare: bare)
        }
        if !fits(built.steps) {
            // Only the run's own input and output left: they go as blobs too, after the steps' ones.
            for key in ["input", "output"] {
                guard let value = object[key], value.objectValue?["$blob"] == nil, let bytes = encoded(value)
                else { continue }
                object[key] = blob(key, bytes, into: &built.blobs, base: base)
            }
        }
        if !fits(built.steps), let listed = object["files"]?.arrayValue {
            object["files"] = .array(
                listed.map { file in
                    guard var entry = file.objectValue else { return file }
                    entry["description"] = nil
                    return .object(entry)
                })
        }
        // Whatever no longer referred to (a fallback replaced it) is removed now; the rest after the write.
        let kept = Set(built.blobs.map(\.path))
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        for name in staged where name.hasPrefix("\(stagedPrefix)\(run.id.uuidString)-\(tag)-step") {
            let path = staging.appendingPathComponent(name).path
            if !kept.contains(path) { try? FileManager.default.removeItem(atPath: path) }
        }
        blobs += built.blobs
        // Always, an empty list too: a message without it was written before steps were sent (`workflow_step_details`).
        object["steps"] = .array(built.steps)
        // The steps in the digest too, with a mark for this shape: a message written before steps were sent
        // would otherwise match and be kept, leaving the phone without them.
        hasher.update(data: Data("steps/1".utf8))
        _ = encoded(.array(built.steps))
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
    /// The message's JSON at most, under the sync core's 64 KB of app data a write.
    static let messageLimit = 48 * 1024
    /// Files listed at most: each is an entry in the message.
    static let fileCountLimit = 100

    /// `object` as JSON, in bytes.
    static func encodedSize(_ object: [String: JSONValue]) -> Int {
        (try? JSONEncoder().encode(JSONValue.object(object)))?.count ?? 0
    }

    /// A step's entry without its log and tool calls, for a message that would be too big with them.
    private static func withoutLogsOrCalls(_ step: JSONValue) -> JSONValue {
        guard var entry = step.objectValue else { return step }
        entry["logs"] = nil
        entry["toolCalls"] = nil
        return .object(entry)
    }

    enum Copy: Equatable {
        case copied(URL, size: Int)
        case missing
        case tooLarge
    }

    /// Opens `path` without following a link, checks that what was opened is a plain readable file
    /// of at most `limit` bytes, and copies it to `destination` from that same descriptor.
    nonisolated static func copyRegularFile(_ path: String, to destination: URL, limit: Int) -> Copy {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .missing }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .missing }
        let size = Int(info.st_size)
        guard size <= limit else { return .tooLarge }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
            let out = try? FileHandle(forWritingTo: destination)
        else { return .missing }
        defer { try? out.close() }
        var copied = 0
        while copied <= limit {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            copied += chunk.count
            guard copied <= limit, (try? out.write(contentsOf: chunk)) != nil else {
                try? FileManager.default.removeItem(at: destination)
                return copied > limit ? .tooLarge : .missing
            }
        }
        return .copied(destination, size: copied)
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

        let bytes = try SyncHostedRunContract.encode(JSONValue.object(payload.object))
        let write = AppDataWrite(
            namespace: SyncDeviceFeedContract.workflowOutputNamespace, bytes: bytes, attachments: payload.blobs)
        let message = OutgoingMessage(
            role: .system, content: SyncDeviceFeedContract.workflowOutputMessageContent,
            attachments: [], replyTo: nil, asAgent: nil, toolCallId: nil, toolName: nil, appData: [write])
        // Written first: a write that fails leaves the phone the output it had.
        _ = try core.sendMessage(scope: scope, message: message)
        for stale in mine { try? core.deleteMessage(id: stale.id) }
        let others = outputs.filter { $0.runId != payload.runId }
        for old in others.dropFirst(keep - 1) { try? core.deleteMessage(id: old.id) }
        core.syncNow()
        log.notice(
            "wrote output of run \(payload.runId, privacy: .public): \(bytes.count) bytes, \(payload.blobs.count) blobs"
        )
    }
}
