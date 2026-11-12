//
//  SyncManageDetail.swift
//  osaurus
//
//  What the iPhone's agent and model screens need beyond the manage state's
//  summary, as messages in this Mac's manage conversation: one carrying the
//  picker's model list and favourites (`ai.osaurus.manage-models/1`), and
//  one per agent carrying its system prompt, avatar image and tools
//  (`ai.osaurus.agent-detail/1`). Message app data can hold blobs where
//  conversation app data can't, and each message changes on its own.
//

import Combine
import CryptoKit
import Foundation
import OsaurusSync
import os

@MainActor
final class SyncManageDetail {
    static let shared = SyncManageDetail()

    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.manage-detail")
    private static let publishDebounce: Duration = .seconds(1)
    /// Values larger than this go to a blob.
    nonisolated static let inlineLimit = 16 * 1024
    /// Avatar images larger than this are left out.
    nonisolated static let avatarLimit = 2 * 1024 * 1024

    private var started = false
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var publishTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let schedule: () -> Void = { MainActor.assumeIsolated { SyncManageDetail.shared.schedulePublish() } }
        AgentManager.shared.$agents.receive(on: DispatchQueue.main).sink { _ in schedule() }.store(in: &cancellables)
        ModelPickerItemCache.shared.$items.receive(on: DispatchQueue.main).sink { _ in schedule() }
            .store(in: &cancellables)
        FavoriteModelsStore.shared.$favoriteKeys.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { _ in schedule() }.store(in: &cancellables)
        ToolRegistry.shared.objectWillChange.receive(on: DispatchQueue.main).sink { _ in schedule() }
            .store(in: &cancellables)
        SyncPhoneDevices.shared.$hasFeedReader.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { _ in schedule() }.store(in: &cancellables)
        observers += SyncService.shared.observeCore(
            attach: { _ in SyncManageDetail.shared.schedulePublish() },
            detach: {})
    }

    func schedulePublish() {
        guard started else { return }
        publishTask?.cancel()
        publishTask = Task { @MainActor in
            try? await Task.sleep(for: Self.publishDebounce)
            guard !Task.isCancelled else { return }
            await publishNow()
        }
    }

    func publishNow() async {
        guard SyncService.shared.core != nil, SyncPhoneDevices.shared.hasFeedReader else { return }
        let allItems = await ModelPickerItemCache.shared.currentItems()
        let payloads = Self.payloads(allItems: allItems)
        await Task.detached(priority: .utility) {
            do {
                try SyncConversationStore.shared.performWrite { core in try Self.write(payloads, core: core) }
            } catch SyncConversationStoreError.notOpen {
            } catch {
                Self.log.error("publish failed: \(error.syncLogDetail, privacy: .public)")
            }
        }.value
    }

    // MARK: - Payloads

    /// One message's app data: its JSON, the blobs it references, and the
    /// digest that says whether it changed.
    struct Payload: Sendable, Equatable {
        /// The agent's id; nil for the models message.
        var agentId: String?
        var object: Data
        var blobs: [Blob]
        var digest: String

        struct Blob: Sendable, Equatable {
            var name: String
            var bytes: Data
            var mediaType: String
        }
    }

    static func payloads(allItems: [ModelPickerItem]) -> [Payload] {
        let phoneItems = allItems.filter {
            $0.isLikelyChatCapable || $0.isPhoneImageModel || HTTPHandler.PickerCloudImageDTO($0) != nil
        }
        let models = HTTPHandler.pickerModels(phoneItems, allItems: allItems)
        var payloads = [modelsPayload(models: models, favorites: FavoriteModelsStore.shared.favoriteKeys)]
        let tools = ToolRegistry.shared.listTools()
        for agent in AgentManager.shared.agents where SyncHostRunner.canHost(agent) {
            payloads.append(agentPayload(agent, tools: tools.map { HTTPHandler.agentToolDTO(for: $0, agent: agent) }))
        }
        return payloads.compactMap { $0 }
    }

    nonisolated static func modelsPayload(models: [HTTPHandler.PickerModelDTO], favorites: [String]) -> Payload? {
        var builder = Builder()
        // One model that can't be encoded (a NaN, say) is left out, not the list.
        let encoder = JSONEncoder.osaurusCanonical()
        let rows = models.compactMap { model -> Any? in
            guard let bytes = try? encoder.encode(model) else { return nil }
            return try? JSONSerialization.jsonObject(with: bytes)
        }
        builder.object["favorites"] = favorites
        builder.set("models", rows)
        return builder.payload(agentId: nil)
    }

    nonisolated static func agentPayload(_ agent: Agent, tools: [HTTPHandler.AgentToolDTO]) -> Payload? {
        var builder = Builder()
        let id = agent.id.uuidString.lowercased()
        builder.object["agentId"] = id
        builder.object["name"] = agent.displayName
        builder.object["isDefault"] = agent.id == Agent.defaultId
        builder.object["toolsEnabled"] = agent.toolsEnabled
        builder.set("systemPrompt", agent.systemPrompt)
        if let rows = try? JSONSerialization.jsonObject(with: JSONEncoder.osaurusCanonical().encode(tools)) {
            builder.set("tools", rows)
        }
        // The agent's Action Bar, as `GET /agents` sends it: missing for an
        // agent on the built-in chat defaults, so the iPhone uses its own copy.
        if let actions = HTTPHandler.clientQuickActions(for: agent),
            let rows = try? JSONSerialization.jsonObject(with: JSONEncoder.osaurusCanonical().encode(actions))
        {
            builder.set("chatQuickActions", rows)
        }
        if let url = agent.customAvatarURL, let bytes = try? Data(contentsOf: url), bytes.count <= avatarLimit {
            builder.attach("avatarImage", bytes: bytes, mediaType: SharedArtifact.mimeType(from: url.lastPathComponent))
        }
        return builder.payload(agentId: id)
    }

    /// Builds a payload, moving large values to blobs.
    struct Builder {
        var object: [String: Any] = ["v": 1]
        var blobs: [Payload.Blob] = []

        mutating func set(_ key: String, _ value: Any) {
            guard let bytes = try? SyncConversationMapper.serialize(value) else { return }
            if bytes.count > SyncManageDetail.inlineLimit {
                blobs.append(.init(name: "\(key).json", bytes: bytes, mediaType: "application/json"))
                object[key] = ["$blob": blobs.count - 1, "size": bytes.count]
            } else {
                object[key] = value
            }
        }

        mutating func attach(_ key: String, bytes: Data, mediaType: String) {
            blobs.append(.init(name: key, bytes: bytes, mediaType: mediaType))
            object[key] = ["$blob": blobs.count - 1, "size": bytes.count, "mimeType": mediaType]
        }

        func payload(agentId: String?) -> Payload? {
            var hasher = SHA256()
            guard let body = try? SyncConversationMapper.serialize(object) else { return nil }
            hasher.update(data: body)
            for blob in blobs { hasher.update(data: blob.bytes) }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            var stamped = object
            stamped["digest"] = digest
            stamped["updatedMs"] = SyncHostedRunContract.nowMs()
            guard let bytes = try? SyncConversationMapper.serialize(stamped) else { return nil }
            return Payload(agentId: agentId, object: bytes, blobs: blobs, digest: digest)
        }
    }

    // MARK: - Writing

    /// Brings the manage conversation's detail messages in line with
    /// `payloads`: changed ones rewritten, new ones sent, a deleted agent's
    /// removed. Nothing happens before the manage state made the conversation.
    nonisolated static func write(_ payloads: [Payload], core: SyncCore) throws {
        guard
            let conversation = try SyncDeviceFeedContract.conversation(
                kind: SyncDeviceFeedContract.manageKind, device: core.deviceKey(), core: core)
        else { return }
        let scope = conversation.scope
        var existing: [String: (id: String, digest: String?)] = [:]
        var stale: [String] = []
        var cursor: PageCursor?
        repeat {
            let page = try core.messages(scope: scope, before: cursor, limit: 200)
            for message in page.messages {
                guard let (key, digest) = detailKey(of: message) else { continue }
                if existing[key] != nil { stale.append(message.id) } else { existing[key] = (message.id, digest) }
            }
            cursor = page.nextCursor
        } while cursor != nil

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-sync-detail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var changed = false
        var wanted = Set<String>()
        for payload in payloads {
            let key = payload.agentId ?? modelsKey
            wanted.insert(key)
            if existing[key]?.digest == payload.digest { continue }
            let write = try appDataWrite(payload, in: temporary)
            if let id = existing[key]?.id {
                try core.setMessageAppData(id: id, appData: [write])
            } else {
                let message = OutgoingMessage(
                    role: .system,
                    content: payload.agentId == nil
                        ? SyncDeviceFeedContract.modelsMessageContent : SyncDeviceFeedContract.agentDetailMessageContent,
                    attachments: [], replyTo: nil, asAgent: nil, toolCallId: nil, toolName: nil, appData: [write])
                _ = try core.sendMessage(scope: scope, message: message)
            }
            changed = true
        }
        for (key, entry) in existing where !wanted.contains(key) { stale.append(entry.id) }
        for id in stale {
            try? core.deleteMessage(id: id)
            changed = true
        }
        if changed { core.syncNow() }
    }

    nonisolated static let modelsKey = "models"

    /// `models`, or the agent's id, and the digest the message carries.
    nonisolated static func detailKey(of message: SyncMessage) -> (String, String?)? {
        if let data = message.appData(SyncDeviceFeedContract.manageModelsNamespace) {
            return (modelsKey, SyncConversationMapper.parseObject(data.bytes)?["digest"] as? String)
        }
        if let data = message.appData(SyncDeviceFeedContract.agentDetailNamespace),
            let object = SyncConversationMapper.parseObject(data.bytes),
            let agentId = object["agentId"] as? String
        {
            return (agentId, object["digest"] as? String)
        }
        return nil
    }

    nonisolated private static func appDataWrite(_ payload: Payload, in directory: URL) throws -> AppDataWrite {
        let files = try payload.blobs.map { blob -> AttachmentFile in
            let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(blob.name)
            try blob.bytes.write(to: file)
            return AttachmentFile(path: file.path, mediaType: blob.mediaType, name: blob.name)
        }
        let namespace =
            payload.agentId == nil
            ? SyncDeviceFeedContract.manageModelsNamespace : SyncDeviceFeedContract.agentDetailNamespace
        return AppDataWrite(namespace: namespace, bytes: payload.object, attachments: files)
    }

    #if DEBUG
        func _resetForTesting() {
            cancellables.removeAll()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            publishTask?.cancel()
            publishTask = nil
            started = false
        }
    #endif
}
