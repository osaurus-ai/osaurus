//
//  SyncConversationMapper.swift
//  osaurus
//
//  Maps Osaurus sessions and turns to sync conversations and messages, per
//  the app data contract in osaurus-sync's docs/app-data.md: native fields
//  for what every client shows, `ai.osaurus.session/1` and
//  `ai.osaurus.turn/1` app data for the rest.
//

import CryptoKit
import Foundation
import OsaurusSync
import os

typealias SyncMessage = OsaurusSync.Message
typealias SyncMessageRole = OsaurusSync.MessageRole
typealias JSONObject = [String: Any]

extension SessionSource {
    /// Interactive sessions follow the user to their other devices, and so
    /// do the chats this Mac served for teammates, invite-link callers and
    /// the paired iPhone. Headless ones (plugins, API callers, channels,
    /// automations, delegation) stay on the device that ran them.
    var syncsAcrossDevices: Bool {
        switch self {
        case .chat, .imported, .workspace: return true
        case .plugin, .http, .channel, .schedule, .watcher, .webhook, .email, .automation, .selfSchedule,
            .delegation:
            return false
        }
    }
}

enum SyncConversationMapper {
    private static let log = Logger(subsystem: "ai.osaurus", category: "sync.mapper")
    static let sessionNamespace = "ai.osaurus.session/1"
    static let turnNamespace = "ai.osaurus.turn/1"
    /// Values larger than this move from turn app data into blobs.
    static let blobThreshold = 16 * 1024
    /// The core's per-write app data limit.
    static let maxAppDataBytes = 64 * 1024
    /// Name of the blob the core appends when it shortens a long tool result.
    static let toolOutputBlobName = "tool-output.txt"

    enum TagKey {
        static let session = "osaurus.session"
        static let source = "source"
        static let agentId = "agentId"
        static let projectId = "projectId"
        static let externalSessionKey = "externalSessionKey"
        static let dispatchTaskId = "dispatchTaskId"
        static let hostDevice = "hostDevice"
        /// The Mac that served a `.workspace` chat. Written by that Mac when
        /// the conversation is created or promoted; every other writer keeps it.
        static let servedBy = "servedBy"
        /// Marks conversations the app keeps for itself, which aren't chats.
        static let kind = "ai.osaurus.kind"
        static let device = "device"
    }

    /// Conversations that aren't sessions, such as a device's agent directory.
    static func isAppInternal(_ conversation: Conversation) -> Bool {
        conversation.tag(TagKey.kind) != nil
    }

    /// Session fields stored natively, or never synced.
    private static let sessionNonAppDataKeys = ["title", "createdAt", "turns", "archived", "pinned", "folderBookmark"]
    /// Session app data fields this version writes. Everything else in a
    /// stored object belongs to another writer and is kept as it is.
    static let sessionOwnedKeys: Set<String> = [
        "v", "id", "source", "automationKind", "sourcePluginId", "externalSessionKey", "dispatchTaskId",
        "agentId", "projectId", "selectedModel", "capabilities", "folderPath", "conversationSummary",
        "workspace", "parkedWorkflowRuns", "sessionState", "hostDevice", "updatedAt", "truncated",
    ]
    /// Turn app data fields this version writes.
    static let turnOwnedKeys: Set<String> = [
        "v", "id", "role", "thinking", "thinkingDuration", "toolCalls", "toolResults", "toolCallDurations",
        "attachments", "sharedArtifacts", "createdAt", "completedAt", "lastOutputAt", "requestedAt",
        "generationTokenCount", "inputTokenCount", "cachedInputTokenCount", "timeToFirstToken",
        "generationTokensPerSecond", "modelLoadSeconds", "terminalStopReason", "reasoningItemId",
        "reasoningEncrypted", "responsesOutputItems", "modelContextExcluded", "routerBilling",
        "injectedContextPrefix", "author", "remoteParticipantMessageId", "hostRun", "truncated",
        "origin", "runLocation",
    ]
    /// Turn fields dropped, in this order, when a turn still doesn't fit.
    static let turnDropOrder = ["injectedContextPrefix", "responsesOutputItems", "reasoningEncrypted", "thinking"]

    // MARK: - JSON

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func jsonObject<T: Encodable>(_ value: T) throws -> JSONObject {
        let data = try makeEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "not a JSON object"))
        }
        return object
    }

    static func serialize(_ value: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )
    }

    static func parseObject(_ data: Data?) -> JSONObject? {
        guard let data, !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
    }

    static func decode<T: Decodable>(_ type: T.Type, from object: JSONObject) throws -> T {
        try makeDecoder().decode(type, from: try serialize(object))
    }

    static let sessionRequiredKeys: Set<String> = [
        "id", "title", "createdAt", "updatedAt", "turns", "archived", "pinned", "source",
    ]
    static let turnRequiredKeys: Set<String> = ["id", "role", "content", "attachments", "toolCallId", "createdAt"]

    /// Decodes `object`, leaving out any field another client wrote in a shape
    /// this version can't read rather than losing the whole object.
    static func decodeTolerantly<T: Decodable>(_ type: T.Type, from object: JSONObject, keeping required: Set<String>)
        -> T?
    {
        if let decoded = try? decode(type, from: object) { return decoded }
        var accepted = object.filter { required.contains($0.key) }
        guard (try? decode(type, from: accepted)) != nil else { return nil }
        for key in object.keys.sorted() where !required.contains(key) {
            var candidate = accepted
            candidate[key] = object[key]
            if (try? decode(type, from: candidate)) != nil {
                accepted = candidate
            } else {
                log.info("ignoring unreadable \(String(describing: type), privacy: .public).\(key, privacy: .public)")
            }
        }
        return try? decode(type, from: accepted)
    }

    private static func lowercaseUUIDStrings(_ object: inout JSONObject, keys: [String]) {
        for key in keys {
            if let value = object[key] as? String, UUID(uuidString: value) != nil {
                object[key] = value.lowercased()
            }
        }
    }

    // MARK: - Ids

    /// A stable session or turn id for a conversation or message written by
    /// a client that didn't record one.
    static func derivedUUID(from syncId: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(syncId.utf8)))
        var bytes = Array(digest[0..<16])
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }

    static func sessionId(of conversation: Conversation) -> UUID {
        if let tagged = conversation.tag(TagKey.session), let id = UUID(uuidString: tagged) { return id }
        if let object = parseObject(conversation.appData(sessionNamespace)),
            let raw = object["id"] as? String, let id = UUID(uuidString: raw)
        {
            return id
        }
        return derivedUUID(from: conversation.scope)
    }

    // MARK: - Sessions

    static func replication(for source: SessionSource) -> Replication {
        source.syncsAcrossDevices ? .synced : .deviceLocal
    }

    static let ownedTagKeys: Set<String> = [
        TagKey.session, TagKey.source, TagKey.agentId, TagKey.projectId, TagKey.externalSessionKey,
        TagKey.dispatchTaskId, TagKey.hostDevice,
    ]

    /// `session`'s tags, plus any tags in `existing` that another writer owns.
    static func tags(for session: ChatSessionData, existing: [Tag]) -> [Tag] {
        (tags(for: session) + existing.filter { !ownedTagKeys.contains($0.key) }).sorted { $0.key < $1.key }
    }

    static func tags(for session: ChatSessionData) -> [Tag] {
        var tags = [
            Tag(key: TagKey.session, value: session.id.uuidString.lowercased()),
            Tag(key: TagKey.source, value: session.source.rawValue),
        ]
        if let agentId = session.agentId {
            tags.append(Tag(key: TagKey.agentId, value: agentId.uuidString.lowercased()))
        }
        if let projectId = session.projectId {
            tags.append(Tag(key: TagKey.projectId, value: projectId.uuidString.lowercased()))
        }
        if let key = session.externalSessionKey, !key.isEmpty {
            tags.append(Tag(key: TagKey.externalSessionKey, value: key))
        }
        if let dispatchTaskId = session.dispatchTaskId {
            tags.append(Tag(key: TagKey.dispatchTaskId, value: dispatchTaskId.uuidString.lowercased()))
        }
        if let hostDevice = session.hostDevice, !hostDevice.isEmpty {
            tags.append(Tag(key: TagKey.hostDevice, value: hostDevice))
        }
        return tags.sorted { $0.key < $1.key }
    }

    /// The `ai.osaurus.session/1` object for `session`, merged over `existing`
    /// so fields written by other clients survive.
    static func sessionAppData(for session: ChatSessionData, existing: JSONObject? = nil) throws -> Data {
        var object = try jsonObject(session)
        for key in sessionNonAppDataKeys { object.removeValue(forKey: key) }
        lowercaseUUIDStrings(&object, keys: ["id", "agentId", "projectId", "dispatchTaskId"])
        if let capabilities = object["capabilities"] as? [String] {
            object["capabilities"] = capabilities.sorted()
        }
        if var summary = object["conversationSummary"] as? JSONObject {
            lowercaseUUIDStrings(&summary, keys: ["id"])
            if let covered = summary["coveredTurnIds"] as? [String] {
                summary["coveredTurnIds"] = covered.map { $0.lowercased() }
            }
            object["conversationSummary"] = summary
        }
        object["v"] = 1

        var merged = (existing ?? [:]).filter { !sessionOwnedKeys.contains($0.key) }
        merged.merge(object) { _, new in new }
        var data = try serialize(merged)
        if data.count > maxAppDataBytes {
            merged.removeValue(forKey: "conversationSummary")
            merged["truncated"] = true
            data = try serialize(merged)
        }
        return data
    }

    /// The session for `conversation`. Turns are left empty.
    static func session(from conversation: Conversation, local: SyncLocalSessionState? = nil) -> ChatSessionData {
        let id = sessionId(of: conversation)
        var object = parseObject(conversation.appData(sessionNamespace)) ?? [:]
        let activityMs = conversation.lastActivityHlc >> 16
        let recordedMs = (object["updatedAt"] as? NSNumber)?.uint64Value ?? 0
        // The activity clock can run a few ms ahead of the wall clock.
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let updatedMs = min(max(activityMs, recordedMs, conversation.createdMs), nowMs)
        object["id"] = id.uuidString
        object["title"] = conversation.title
        object["createdAt"] = conversation.createdMs
        object["updatedAt"] = updatedMs
        object["turns"] = [Any]()
        object["archived"] = conversation.archived
        object["pinned"] = conversation.pinned
        if object["source"] == nil {
            object["source"] = conversation.tag(TagKey.source) ?? SessionSource.chat.rawValue
        }

        var session: ChatSessionData
        if let decoded = decodeTolerantly(ChatSessionData.self, from: object, keeping: sessionRequiredKeys) {
            session = decoded
        } else {
            session = ChatSessionData(
                id: id,
                title: conversation.title,
                createdAt: Date(timeIntervalSince1970: Double(conversation.createdMs) / 1000),
                updatedAt: Date(timeIntervalSince1970: Double(updatedMs) / 1000),
                source: (object["source"] as? String).flatMap(SessionSource.init(rawValue:)) ?? .chat,
                archived: conversation.archived,
                pinned: conversation.pinned
            )
        }
        session.folderBookmark = local?.folderBookmark
        session.servedBy = conversation.tag(TagKey.servedBy)
        return session
    }

    // MARK: - Turns

    struct EncodedTurn {
        var role: SyncMessageRole
        var content: String
        var toolCallId: String?
        var toolName: String?
        /// The `ai.osaurus.turn/1` bytes, with blob references.
        var appData: Data
        /// Blob contents, in reference index order.
        var appDataBlobs: [(name: String, bytes: Data)]
        /// Files to attach natively, in `attachments[].index` order.
        var attachments: [Attachment]
        /// Fields that didn't fit the synced write; kept on this device.
        var overflow: JSONObject
        /// What only the device that ran the turn can say about it: its
        /// files and tool labels. Nil when there is nothing.
        var detail: DetailWrite? = nil
    }

    static func syncRole(for role: MessageRole) -> SyncMessageRole {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        case .system: return .system
        case .tool: return .toolResult
        }
    }

    static func osaurusRole(for role: SyncMessageRole) -> MessageRole {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        case .system: return .system
        case .toolCall, .toolResult: return .tool
        }
    }

    /// The tool name for a tool turn, from the assistant call it answers.
    static func toolName(for turn: ChatTurnData, in turns: [ChatTurnData]) -> String? {
        guard turn.role == .tool, let callId = turn.toolCallId else { return nil }
        for candidate in turns where candidate.role == .assistant {
            if let call = candidate.toolCalls?.first(where: { $0.id == callId }) {
                return call.function.name
            }
        }
        return nil
    }

    static func encode(turn: ChatTurnData, toolName: String?, existing: JSONObject? = nil) throws -> EncodedTurn {
        var stripped = turn
        stripped.attachments = []
        stripped.toolCallLogs = [:]
        var object = try jsonObject(stripped)
        object.removeValue(forKey: "content")
        object.removeValue(forKey: "toolCallId")
        object.removeValue(forKey: "toolCallLogs")
        object.removeValue(forKey: "attachments")
        lowercaseUUIDStrings(&object, keys: ["id"])
        if !turn.attachments.isEmpty {
            object["attachments"] = turn.attachments.enumerated().map { attachmentEntry($1, index: $0) }
        }
        object["v"] = 1

        var merged = (existing ?? [:]).filter { !turnOwnedKeys.contains($0.key) }
        merged.merge(object) { _, new in new }

        let role = syncRole(for: turn.role)
        var blobs: [(name: String, bytes: Data)] = []
        var overflow: JSONObject = [:]
        try fitTurnObject(&merged, blobs: &blobs, overflow: &overflow)

        return EncodedTurn(
            role: role,
            content: turn.content,
            toolCallId: turn.role == .tool ? turn.toolCallId : nil,
            toolName: turn.role == .tool ? (toolName ?? "tool") : nil,
            appData: try serialize(merged),
            appDataBlobs: blobs,
            attachments: turn.attachments,
            overflow: overflow,
            detail: try detailWrite(for: turn)
        )
    }

    /// Moves large values to blobs, then medium ones, until the object fits
    /// one app data write. Fields are dropped only when it still doesn't.
    static func fitTurnObject(
        _ object: inout JSONObject,
        blobs: inout [(name: String, bytes: Data)],
        overflow: inout JSONObject
    ) throws {
        /// What a top-level field held before it became a blob reference.
        var originals: JSONObject = [:]
        func reference(_ value: Any, name: String) throws -> JSONObject {
            let bytes = try serialize(value)
            blobs.append((name: name, bytes: bytes))
            return ["$blob": blobs.count - 1, "size": bytes.count]
        }
        func size(_ value: Any) -> Int { (try? serialize(value).count) ?? 0 }

        if var results = object["toolResults"] as? [String: Any] {
            for key in results.keys.sorted() {
                if let value = results[key], size(value) > blobThreshold {
                    results[key] = try reference(value, name: "toolResults.\(key)")
                }
            }
            object["toolResults"] = results
        }
        let fixed: Set<String> = ["v", "id", "role", "toolResults"]
        for key in object.keys.sorted() where !fixed.contains(key) {
            if let value = object[key], size(value) > blobThreshold {
                originals[key] = value
                object[key] = try reference(value, name: key)
            }
        }

        // Many medium values: the largest left goes to a blob until it fits.
        // Ties go to the first key in sorted order, so a turn encodes the same
        // way on every save.
        while size(object) > maxAppDataBytes {
            var largest: (key: String, sub: String?, size: Int)?
            if let results = object["toolResults"] as? [String: Any] {
                for key in results.keys.sorted() {
                    guard let value = results[key], !isBlobReference(value) else { continue }
                    let s = size(value)
                    if s > (largest?.size ?? 0) { largest = (key: "toolResults", sub: key, size: s) }
                }
            }
            for key in object.keys.sorted() where !fixed.contains(key) {
                guard let value = object[key], !isBlobReference(value) else { continue }
                let s = size(value)
                if s > (largest?.size ?? 0) { largest = (key: key, sub: nil, size: s) }
            }
            // A reference costs ~30 bytes; moving less than that never helps.
            guard let target = largest, target.size > 64 else { break }
            if let sub = target.sub, var results = object["toolResults"] as? [String: Any], let value = results[sub] {
                results[sub] = try reference(value, name: "toolResults.\(sub)")
                object["toolResults"] = results
            } else if let value = object[target.key] {
                originals[target.key] = value
                object[target.key] = try reference(value, name: target.key)
            }
        }

        // Still too big (only references and fixed fields left): drop fields.
        // Overflow keeps the value itself, never a reference to a blob that
        // is no longer written.
        var dropped = false
        for key in turnDropOrder where size(object) > maxAppDataBytes {
            guard let value = object.removeValue(forKey: key) else { continue }
            overflow[key] = originals[key] ?? value
            dropped = true
        }
        if dropped {
            object["truncated"] = true
            compactBlobs(&object, blobs: &blobs)
        }
    }

    /// Removes blobs `object` no longer references and renumbers the rest.
    private static func compactBlobs(_ object: inout JSONObject, blobs: inout [(name: String, bytes: Data)]) {
        var used: [Int] = []
        func collect(_ value: Any, depth: Int = 0) {
            guard depth < 8 else { return }
            if let entry = value as? JSONObject {
                if isBlobReference(entry), let index = (entry["$blob"] as? NSNumber)?.intValue {
                    used.append(index)
                } else {
                    entry.values.forEach { collect($0, depth: depth + 1) }
                }
            } else if let array = value as? [Any] {
                array.forEach { collect($0, depth: depth + 1) }
            }
        }
        collect(object)
        let kept = Array(Set(used)).sorted()
        guard kept.count < blobs.count else { return }
        let renumbered = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })
        func remap(_ value: Any, depth: Int = 0) -> Any {
            guard depth < 8 else { return value }
            if var entry = value as? JSONObject {
                if isBlobReference(entry), let index = (entry["$blob"] as? NSNumber)?.intValue {
                    entry["$blob"] = renumbered[index] ?? index
                    return entry
                }
                return entry.mapValues { remap($0, depth: depth + 1) }
            }
            if let array = value as? [Any] { return array.map { remap($0, depth: depth + 1) } }
            return value
        }
        object = remap(object) as? JSONObject ?? object
        blobs = kept.map { blobs[$0] }
    }

    // MARK: - Turn detail

    /// Message app data only the device that ran a turn writes: the files the
    /// turn made there (generated images, shared files) with their bytes as
    /// blobs, and the Mac chat's label for each tool call. Other devices
    /// can't reproduce either, so they never write it.
    static let turnDetailNamespace = "ai.osaurus.turn-detail/1"
    /// Larger files are listed as `skipped: "tooLarge"`, without bytes.
    static let maxFileBytes = 10 * 1024 * 1024
    static let maxTurnFileBytes = 32 * 1024 * 1024

    struct DetailWrite {
        var bytes: Data
        var blobs: [(name: String, url: URL, mediaType: String)]
    }

    static func detailWrite(for turn: ChatTurnData) throws -> DetailWrite? {
        guard turn.role == .assistant || turn.role == .tool else { return nil }
        var entries: [JSONObject] = []
        var blobs: [(name: String, url: URL, mediaType: String)] = []
        var seen = Set<String>()
        var total = 0
        func add(_ file: URL, _ fields: JSONObject) {
            guard seen.insert(file.path).inserted else { return }
            var entry = fields
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let filename = (entry["filename"] as? String) ?? file.lastPathComponent
            let mediaType = (entry["mimeType"] as? String) ?? SharedArtifact.mimeType(from: filename)
            entry["filename"] = filename
            entry["mimeType"] = mediaType
            entry["fileSize"] = size
            if size > maxFileBytes || total + size > maxTurnFileBytes {
                entry["skipped"] = "tooLarge"
            } else {
                total += size
                blobs.append((name: filename, url: file, mediaType: mediaType))
                entry["blob"] = blobs.count - 1
            }
            entries.append(entry)
        }
        for (link, file) in SessionTurnImages.generatedImageLinks(in: turn.content) {
            add(file, ["kind": "generatedImage", "link": link])
        }
        for artifact in turn.sharedArtifacts where !artifact.isDirectory && artifact.content == nil {
            guard let file = SessionTurnImages.artifactFile(contextId: artifact.contextId, filename: artifact.filename)
            else { continue }
            add(file, ["kind": "artifact", "id": artifact.id, "filename": artifact.filename, "mimeType": artifact.mimeType])
        }
        let results = turn.role == .tool ? [turn.toolCallId ?? "": turn.content] : turn.toolResults
        for key in results.keys.sorted() {
            guard let result = results[key], let file = SessionTurnImages.sharedImageFile(inToolResult: result)
            else { continue }
            add(file, ["kind": "artifact", "callId": key])
        }
        let display = toolCallDisplay(for: turn)
        guard !entries.isEmpty || display != nil else { return nil }
        var object: JSONObject = ["v": 1]
        if !entries.isEmpty { object["files"] = entries }
        if let display { object["toolCallDisplay"] = display }
        return DetailWrite(bytes: try serialize(object), blobs: blobs)
    }

    // MARK: - Tool call display

    /// The Mac chat's label, category and icon for each of the turn's tool
    /// calls, so another device can show them without the Mac's tables.
    static func toolCallDisplay(for turn: ChatTurnData) -> JSONObject? {
        guard let calls = turn.toolCalls, !calls.isEmpty else { return nil }
        var display: JSONObject = [:]
        for call in calls {
            let result = turn.toolResults[call.id]
            let failed = result.map(ToolEnvelope.isError) ?? false
            let (category, icon) = AgentToolTraceDetail.categoryAndIcon(call.function.name)
            var entry: JSONObject = [
                "label": ToolDisplayName.friendly(
                    for: call.function.name, running: result == nil, arguments: call.function.arguments,
                    failed: failed),
                "category": category,
                "icon": icon,
            ]
            if failed { entry["failed"] = true }
            // The run the call started, as its card last showed it (`workflow_runs`).
            if let card = SyncWorkflowCards.remembered(forCall: call.id)?.settled(by: result).jsonObject {
                entry["workflow"] = card
            }
            display[call.id] = entry
        }
        return display
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isBlobReference(_ value: Any) -> Bool {
        guard let object = value as? JSONObject, object.count == 2 else { return false }
        return object["$blob"] is NSNumber && object["size"] is NSNumber
    }

    private static func attachmentEntry(_ attachment: Attachment, index: Int) -> JSONObject {
        var entry: JSONObject = ["id": attachment.id.uuidString.lowercased(), "index": index]
        switch attachment.kind {
        case .image(let data):
            entry["kind"] = "image"
            entry["fileSize"] = data.count
            entry["sha256"] = AttachmentBlobStore.contentHash(data)
        case .imageRef(let hash, let byteCount):
            entry["kind"] = "image"
            entry["fileSize"] = byteCount
            entry["sha256"] = hash
        case .document(let filename, let content, let fileSize):
            entry["kind"] = "document"
            entry["filename"] = filename
            entry["fileSize"] = fileSize
            entry["sha256"] = AttachmentBlobStore.contentHash(string: content)
        case .documentRef(let filename, let hash, let fileSize):
            entry["kind"] = "document"
            entry["filename"] = filename
            entry["fileSize"] = fileSize
            entry["sha256"] = hash
        case .audio(let data, let format, let filename):
            entry["kind"] = "audio"
            entry["format"] = format
            entry["fileSize"] = data.count
            entry["sha256"] = AttachmentBlobStore.contentHash(data)
            if let filename { entry["filename"] = filename }
        case .audioRef(let hash, let byteCount, let format, let filename):
            entry["kind"] = "audio"
            entry["format"] = format
            entry["fileSize"] = byteCount
            entry["sha256"] = hash
            if let filename { entry["filename"] = filename }
        case .video(let data, let filename):
            entry["kind"] = "video"
            entry["fileSize"] = data.count
            entry["sha256"] = AttachmentBlobStore.contentHash(data)
            if let filename { entry["filename"] = filename }
        case .videoRef(let hash, let byteCount, let filename):
            entry["kind"] = "video"
            entry["fileSize"] = byteCount
            entry["sha256"] = hash
            if let filename { entry["filename"] = filename }
        }
        if let metadata = attachment.structuredDocumentMetadata, let object = try? jsonObject(metadata) {
            entry["structuredDocumentMetadata"] = object
        }
        return entry
    }

    /// The bytes and file metadata to attach natively for `attachment`.
    static func nativeFile(for attachment: Attachment) -> (bytes: Data, mediaType: String, name: String)? {
        let fallbackName = attachment.id.uuidString.lowercased()
        switch attachment.kind {
        case .image(let data):
            return (data, imageMediaType(data), "\(fallbackName).\(imageExtension(data))")
        case .imageRef(let hash, _):
            guard let data = try? AttachmentBlobStore.read(hash) else { return nil }
            return (data, imageMediaType(data), "\(fallbackName).\(imageExtension(data))")
        case .document(let filename, let content, _):
            return (Data(content.utf8), "text/plain", filename)
        case .documentRef(let filename, let hash, _):
            guard let data = try? AttachmentBlobStore.read(hash) else { return nil }
            return (data, "text/plain", filename)
        case .audio(let data, let format, let filename):
            return (data, "audio/\(format)", filename ?? "\(fallbackName).\(format)")
        case .audioRef(let hash, _, let format, let filename):
            guard let data = try? AttachmentBlobStore.read(hash) else { return nil }
            return (data, "audio/\(format)", filename ?? "\(fallbackName).\(format)")
        case .video(let data, let filename):
            return (data, "video/mp4", filename ?? "\(fallbackName).mp4")
        case .videoRef(let hash, _, let filename):
            guard let data = try? AttachmentBlobStore.read(hash) else { return nil }
            return (data, "video/mp4", filename ?? "\(fallbackName).mp4")
        }
    }

    private static func imageMediaType(_ data: Data) -> String {
        switch imageExtension(data) {
        case "jpg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return "image/png"
        }
    }

    private static func imageExtension(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "webp"
        }
        if bytes.count >= 12, bytes[4...7] == [0x66, 0x74, 0x79, 0x70] { return "heic" }
        return "png"
    }

    // MARK: - Reading turns

    /// Bytes behind a blob, or nil when they aren't on this device yet.
    typealias BlobReader = (Blob) -> Data?
    /// Bytes for a native attachment: inline when small, otherwise cached in
    /// `AttachmentBlobStore` under `sha256` and returned as its hash.
    enum MaterializedAttachment {
        case inline(Data)
        case cached(hash: String, byteCount: Int)
    }
    typealias AttachmentMaterializer = (_ blob: Blob, _ sha256: String?, _ inlineLimit: Int) -> MaterializedAttachment?

    struct DecodedTurn {
        var turn: ChatTurnData
        /// Fields other writers stored, kept for the next rewrite.
        var extras: JSONObject
    }

    static func turn(
        from message: SyncMessage,
        readBlob: BlobReader,
        materialize: AttachmentMaterializer,
        overflow: JSONObject? = nil
    ) -> DecodedTurn {
        let appData = message.appData(turnNamespace)
        var object = parseObject(appData?.bytes) ?? [:]
        if let appData {
            object = resolveBlobReferences(in: object, blobs: appData.blobs, readBlob: readBlob) as? JSONObject ?? object
        }
        let extras = object.filter { !turnOwnedKeys.contains($0.key) }
        for (key, value) in overflow ?? [:] where object[key] == nil {
            object[key] = value
        }

        let role =
            (object["role"] as? String).flatMap(MessageRole.init(rawValue:)) ?? osaurusRole(for: message.role)
        let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)) ?? derivedUUID(from: message.id)
        let entries = (object["attachments"] as? [JSONObject]) ?? []

        var content = message.content
        if message.role == .toolResult, let last = message.blobs.last, last.name == toolOutputBlobName,
            message.blobs.count > entries.count, let full = readBlob(last).flatMap({ String(data: $0, encoding: .utf8) })
        {
            content = full
        }

        object["id"] = id.uuidString
        object["role"] = role.rawValue
        object["content"] = content
        object["attachments"] = [Any]()
        if let toolCallId = message.toolCallId { object["toolCallId"] = toolCallId }
        if object["createdAt"] == nil { object["createdAt"] = message.timestampMs }
        object.removeValue(forKey: "v")
        object.removeValue(forKey: "truncated")

        var turn =
            decodeTolerantly(ChatTurnData.self, from: object, keeping: turnRequiredKeys)
            ?? ChatTurnData(
                id: id,
                role: role,
                content: content,
                toolCallId: message.toolCallId,
                createdAt: Date(timeIntervalSince1970: Double(message.timestampMs) / 1000)
            )

        if entries.isEmpty {
            let userBlobs = message.blobs.filter { !($0.name == toolOutputBlobName && message.role == .toolResult) }
            turn.attachments = userBlobs.compactMap { attachment(fromForeign: $0, materialize: materialize) }
        } else {
            turn.attachments = entries.compactMap { entry in
                guard let index = (entry["index"] as? NSNumber)?.intValue, message.blobs.indices.contains(index)
                else { return nil }
                return attachment(from: entry, blob: message.blobs[index], materialize: materialize)
            }
        }
        return DecodedTurn(turn: turn, extras: extras)
    }

    /// Ids of the attachments stored natively on `message`, named as
    /// `turn(from:)` names them. `object` is the message's turn app data.
    static func nativeAttachmentIds(of message: SyncMessage, object: JSONObject) -> Set<UUID> {
        let entries = (object["attachments"] as? [JSONObject]) ?? []
        guard !entries.isEmpty else {
            let userBlobs = message.blobs.filter { !($0.name == toolOutputBlobName && message.role == .toolResult) }
            return Set(userBlobs.map { derivedUUID(from: $0.hash) })
        }
        return Set(
            entries.compactMap { entry in
                guard let index = (entry["index"] as? NSNumber)?.intValue, message.blobs.indices.contains(index)
                else { return nil }
                return (entry["id"] as? String).flatMap(UUID.init(uuidString:))
                    ?? derivedUUID(from: message.blobs[index].hash)
            })
    }

    /// Replaces `{"$blob": i, "size": n}` references with the JSON they point to.
    static func resolveBlobReferences(in value: Any, blobs: [Blob], readBlob: BlobReader, depth: Int = 0) -> Any {
        guard depth < 8 else { return value }
        if let object = value as? JSONObject {
            if isBlobReference(object), let index = (object["$blob"] as? NSNumber)?.intValue,
                blobs.indices.contains(index)
            {
                guard let bytes = readBlob(blobs[index]),
                    let resolved = try? JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed)
                else { return NSNull() }
                return resolved
            }
            return object.mapValues { resolveBlobReferences(in: $0, blobs: blobs, readBlob: readBlob, depth: depth + 1) }
        }
        if let array = value as? [Any] {
            return array.map { resolveBlobReferences(in: $0, blobs: blobs, readBlob: readBlob, depth: depth + 1) }
        }
        return value
    }

    private static func attachment(from entry: JSONObject, blob: Blob, materialize: AttachmentMaterializer)
        -> Attachment?
    {
        let id = (entry["id"] as? String).flatMap(UUID.init(uuidString:)) ?? derivedUUID(from: blob.hash)
        let sha256 = entry["sha256"] as? String
        let filename = entry["filename"] as? String
        let fileSize = (entry["fileSize"] as? NSNumber)?.intValue ?? Int(blob.size)
        let metadata = (entry["structuredDocumentMetadata"] as? JSONObject).flatMap {
            try? decode(StructuredDocumentAttachmentMetadata.self, from: $0)
        }
        switch entry["kind"] as? String {
        case "image":
            switch materialize(blob, sha256, AttachmentBlobStore.spillThreshold) {
            case .inline(let data): return Attachment(id: id, kind: .image(data))
            case .cached(let hash, let count): return Attachment(id: id, kind: .imageRef(hash: hash, byteCount: count))
            case nil: return nil
            }
        case "document":
            let name = filename ?? blob.name
            switch materialize(blob, sha256, AttachmentBlobStore.spillThreshold) {
            case .inline(let data):
                return Attachment(
                    id: id,
                    kind: .document(filename: name, content: String(decoding: data, as: UTF8.self), fileSize: fileSize),
                    structuredDocumentMetadata: metadata
                )
            case .cached(let hash, _):
                return Attachment(
                    id: id,
                    kind: .documentRef(filename: name, hash: hash, fileSize: fileSize),
                    structuredDocumentMetadata: metadata
                )
            case nil: return nil
            }
        case "audio":
            let format = entry["format"] as? String ?? "wav"
            switch materialize(blob, sha256, Attachment.audioSpillThresholdBytes) {
            case .inline(let data): return Attachment(id: id, kind: .audio(data, format: format, filename: filename))
            case .cached(let hash, let count):
                return Attachment(id: id, kind: .audioRef(hash: hash, byteCount: count, format: format, filename: filename))
            case nil: return nil
            }
        case "video":
            switch materialize(blob, sha256, Attachment.videoSpillThresholdBytes) {
            case .inline(let data): return Attachment(id: id, kind: .video(data, filename: filename))
            case .cached(let hash, let count):
                return Attachment(id: id, kind: .videoRef(hash: hash, byteCount: count, filename: filename))
            case nil: return nil
            }
        default:
            return attachment(fromForeign: blob, materialize: materialize)
        }
    }

    /// An attachment another client sent without Osaurus app data.
    private static func attachment(fromForeign blob: Blob, materialize: AttachmentMaterializer) -> Attachment? {
        let id = derivedUUID(from: blob.hash)
        if blob.mediaType.hasPrefix("image/") {
            switch materialize(blob, nil, AttachmentBlobStore.spillThreshold) {
            case .inline(let data): return Attachment(id: id, kind: .image(data))
            case .cached(let hash, let count): return Attachment(id: id, kind: .imageRef(hash: hash, byteCount: count))
            case nil: return nil
            }
        }
        if blob.mediaType.hasPrefix("audio/") {
            let format = String(blob.mediaType.dropFirst("audio/".count))
            switch materialize(blob, nil, Attachment.audioSpillThresholdBytes) {
            case .inline(let data): return Attachment(id: id, kind: .audio(data, format: format, filename: blob.name))
            case .cached(let hash, let count):
                return Attachment(id: id, kind: .audioRef(hash: hash, byteCount: count, format: format, filename: blob.name))
            case nil: return nil
            }
        }
        if blob.mediaType.hasPrefix("video/") {
            switch materialize(blob, nil, Attachment.videoSpillThresholdBytes) {
            case .inline(let data): return Attachment(id: id, kind: .video(data, filename: blob.name))
            case .cached(let hash, let count):
                return Attachment(id: id, kind: .videoRef(hash: hash, byteCount: count, filename: blob.name))
            case nil: return nil
            }
        }
        switch materialize(blob, nil, AttachmentBlobStore.spillThreshold) {
        case .inline(let data):
            return Attachment(
                id: id,
                kind: .document(filename: blob.name, content: String(decoding: data, as: UTF8.self), fileSize: Int(blob.size))
            )
        case .cached(let hash, _):
            return Attachment(id: id, kind: .documentRef(filename: blob.name, hash: hash, fileSize: Int(blob.size)))
        case nil:
            return nil
        }
    }
}
