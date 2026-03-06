//
//  VsockHostAPIServer.swift
//  osaurus
//
//  Listens on vsock for Host API requests from the osaurus-host shim running
//  inside a VM. Routes JSON-RPC methods to the appropriate Host API
//  implementations, scoped to the owning agent.
//

import Foundation
import Virtualization

actor VsockHostAPIServer {
    private let agentId: UUID
    private let socketDevice: VZVirtioSocketDevice
    private var vsockListener: VZVirtioSocketListener?
    private var listenerDelegate: ListenerDelegate?
    private var isListening = false

    init(agentId: UUID, socketDevice: VZVirtioSocketDevice) {
        self.agentId = agentId
        self.socketDevice = socketDevice
    }

    func start() {
        guard !isListening else { return }
        let listener = VZVirtioSocketListener()
        let delegate = ListenerDelegate(server: self)
        listener.delegate = delegate
        socketDevice.setSocketListener(listener, forPort: vsockVMToHost)
        self.vsockListener = listener
        self.listenerDelegate = delegate
        isListening = true
    }

    func stop() {
        if vsockListener != nil {
            socketDevice.removeSocketListener(forPort: vsockVMToHost)
            vsockListener = nil
            listenerDelegate = nil
        }
        isListening = false
    }

    // MARK: - Request Handling

    func handleConnection(fileDescriptor fd: Int32) {
        let agentId = self.agentId
        Task.detached {
            await Self.processConnection(fileDescriptor: fd, agentId: agentId)
        }
    }

    private static func processConnection(fileDescriptor fd: Int32, agentId: UUID) async {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)

        while true {
            do {
                let lengthData = try readExactly(from: handle, count: 4)
                let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                let requestData = try readExactly(from: handle, count: Int(length))

                let responseData = await handleRequest(requestData, agentId: agentId)

                var responseLength = UInt32(responseData.count).bigEndian
                let responseLengthData = Data(bytes: &responseLength, count: 4)
                try handle.write(contentsOf: responseLengthData + responseData)
            } catch {
                break
            }
        }
    }

    private static func handleRequest(_ data: Data, agentId: UUID) async -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String,
              let id = json["id"]
        else {
            return errorResponse(id: NSNull(), code: -32600, message: "Invalid request")
        }

        let params = json["params"] as? [String: Any] ?? [:]
        let result = await dispatch(method: method, params: params, agentId: agentId)

        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }

    // MARK: - Method Dispatch

    private static func dispatch(method: String, params: [String: Any], agentId: UUID) async -> Any {
        switch method {
        case "secrets.get":
            return secretsGet(params: params, agentId: agentId)

        case "config.get":
            return configGet(params: params, agentId: agentId)

        case "config.set":
            return configSet(params: params, agentId: agentId)

        case "log":
            return logMessage(params: params)

        case "inference.chat":
            return await inferenceChat(params: params, agentId: agentId)

        case "agent.dispatch":
            return await agentDispatch(params: params, agentId: agentId)

        case "memory.query":
            return await memoryQuery(params: params, agentId: agentId)

        case "memory.store":
            return await memoryStore(params: params, agentId: agentId)

        case "events.emit":
            return await eventsEmit(params: params)

        case "events.subscribe":
            return ["error": "subscribe not supported over vsock (use polling)"]

        case "plugin.create":
            return await pluginCreate(params: params, agentId: agentId)

        case "plugin.list":
            return await pluginList(agentId: agentId)

        case "plugin.remove":
            return await pluginRemove(params: params, agentId: agentId)

        case "identity.address":
            return await identityAddress(agentId: agentId)

        case "identity.sign":
            return identitySign()

        default:
            return ["error": "unknown_method", "message": "Method not found: \(method)"]
        }
    }

    // MARK: - Method Implementations

    private static func secretsGet(params: [String: Any], agentId: UUID) -> Any {
        guard let name = params["name"] as? String,
              let pluginName = params["plugin"] as? String
        else { return ["error": "missing_params"] }
        let value = ToolSecretsKeychain.getSecret(id: name, for: pluginName, agentId: agentId)
        return ["value": value as Any]
    }

    private static func configGet(params: [String: Any], agentId: UUID) -> Any {
        guard let key = params["key"] as? String,
              let pluginName = params["plugin"] as? String
        else { return ["error": "missing_params"] }
        let value = ToolSecretsKeychain.getSecret(id: key, for: pluginName, agentId: agentId)
        return ["value": value as Any]
    }

    private static func configSet(params: [String: Any], agentId: UUID) -> Any {
        guard let key = params["key"] as? String,
              let value = params["value"] as? String,
              let pluginName = params["plugin"] as? String
        else { return ["error": "missing_params"] }
        ToolSecretsKeychain.saveSecret(value, id: key, for: pluginName, agentId: agentId)
        return ["status": "ok"]
    }

    private static func logMessage(params: [String: Any]) -> Any {
        let level = params["level"] as? String ?? "info"
        let message = params["message"] as? String ?? ""
        NSLog("[VM] [%@] %@", level.uppercased(), message)
        return ["status": "ok"]
    }

    private static func inferenceChat(params: [String: Any], agentId: UUID) async -> Any {
        guard let requestData = try? JSONSerialization.data(withJSONObject: params) else {
            return ["error": "invalid_request"]
        }
        guard let request = try? JSONDecoder().decode(ChatCompletionRequest.self, from: requestData) else {
            return ["error": "invalid_request", "message": "Failed to parse chat completion request"]
        }

        let engine = ChatEngine(source: .plugin)
        do {
            let response = try await engine.completeChat(request: request)
            if let data = try? JSONEncoder().encode(response),
               let json = try? JSONSerialization.jsonObject(with: data) {
                return json
            }
            return ["error": "serialization_error"]
        } catch {
            return ["error": "inference_error", "message": error.localizedDescription]
        }
    }

    private static func agentDispatch(params: [String: Any], agentId: UUID) async -> Any {
        guard let task = params["task"] as? String else {
            return ["error": "missing_params", "message": "Missing required field: task"]
        }

        let targetAgent = params["agent"] as? String
        let targetAgentId: UUID? = await MainActor.run {
            if let targetAgent {
                return AgentManager.shared.agents.first(where: {
                    $0.name.lowercased() == targetAgent.lowercased()
                    || $0.agentAddress == targetAgent
                    || $0.id.uuidString == targetAgent
                })?.id
            }
            return agentId
        }

        let request = DispatchRequest(
            id: UUID(),
            mode: .work,
            prompt: task,
            agentId: targetAgentId,
            showToast: true,
            sourcePluginId: "vm-agent"
        )

        let handle = await TaskDispatcher.shared.dispatch(request)
        if handle != nil {
            return ["id": request.id.uuidString, "status": "running"]
        } else {
            return ["error": "task_limit_reached"]
        }
    }

    private static func memoryQuery(params: [String: Any], agentId: UUID) async -> Any {
        let query = params["query"] as? String ?? ""
        let topK = params["top_k"] as? Int ?? 10
        guard !query.isEmpty else { return ["error": "missing_query"] }

        let entries = await MemorySearchService.shared.searchMemoryEntries(
            query: query,
            agentId: agentId.uuidString,
            topK: topK
        )
        let results: [[String: Any]] = entries.map { e in
            ["id": e.id, "agent_id": e.agentId, "content": e.content, "type": e.type.rawValue]
        }
        return ["results": results]
    }

    private static func memoryStore(params: [String: Any], agentId: UUID) async -> Any {
        let content = params["content"] as? String ?? ""
        guard !content.isEmpty else { return ["error": "missing_content"] }

        let now = ISO8601DateFormatter().string(from: Date())
        let entry = MemoryEntry(
            id: UUID().uuidString,
            agentId: agentId.uuidString,
            type: .fact,
            content: content,
            confidence: 0.9,
            model: "vm-agent",
            sourceConversationId: nil,
            tagsJSON: nil,
            status: "active",
            supersededBy: nil,
            createdAt: now,
            lastAccessed: now,
            accessCount: 0,
            validFrom: now,
            validUntil: nil
        )

        do {
            try MemoryDatabase.shared.insertMemoryEntry(entry)
            return ["id": entry.id, "status": "stored"]
        } catch {
            return ["error": "storage_error", "message": error.localizedDescription]
        }
    }

    private static func eventsEmit(params: [String: Any]) async -> Any {
        guard let eventType = params["event_type"] as? String else { return ["error": "missing_event_type"] }
        let payload: String
        if let p = params["payload"] as? String {
            payload = p
        } else if let p = params["payload"],
                  let data = try? JSONSerialization.data(withJSONObject: p) {
            payload = String(data: data, encoding: .utf8) ?? "{}"
        } else {
            payload = "{}"
        }
        await EventBus.shared.emit(eventType: eventType, payload: payload)
        return ["status": "ok"]
    }

    private static func pluginCreate(params: [String: Any], agentId: UUID) async -> Any {
        guard let pluginObj = params["plugin"],
              let pluginData = try? JSONSerialization.data(withJSONObject: pluginObj),
              let _ = try? JSONDecoder().decode(SandboxPlugin.self, from: pluginData)
        else { return ["error": "invalid_plugin_json"] }

        do {
            try await SandboxPluginManager.shared.install(jsonData: pluginData, for: agentId)
            return ["status": "ok"]
        } catch {
            return ["error": "install_error", "message": error.localizedDescription]
        }
    }

    private static func pluginList(agentId: UUID) async -> Any {
        let plugins = await SandboxPluginManager.shared.listPlugins(for: agentId)
        return ["plugins": plugins.map { ["name": $0.name, "description": $0.description] }]
    }

    private static func pluginRemove(params: [String: Any], agentId: UUID) async -> Any {
        guard let name = params["name"] as? String else { return ["error": "missing_name"] }
        do {
            try await SandboxPluginManager.shared.uninstall(name: name, for: agentId)
            return ["status": "ok"]
        } catch {
            return ["error": "remove_error", "message": error.localizedDescription]
        }
    }

    private static func identityAddress(agentId: UUID) async -> Any {
        let agent: Agent? = await MainActor.run {
            AgentManager.shared.agents.first(where: { $0.id == agentId })
        }
        return ["address": agent?.agentAddress as Any]
    }

    private static func identitySign() -> Any {
        return [
            "error": "not_supported",
            "message": "Identity signing requires biometric authentication and is not available from within a VM.",
        ]
    }

    // MARK: - Helpers

    private static func readExactly(from handle: FileHandle, count: Int) throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let chunk = try handle.read(upToCount: count - buffer.count) ?? Data()
            if chunk.isEmpty {
                throw NSError(domain: "VsockServer", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: "Connection closed"])
            }
            buffer.append(chunk)
        }
        return buffer
    }

    private static func errorResponse(id: Any, code: Int, message: String) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ]
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }
}

// MARK: - Listener Delegate

private final class ListenerDelegate: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    weak var server: VsockHostAPIServer?

    init(server: VsockHostAPIServer) {
        self.server = server
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        guard let server else { return false }
        let fd = connection.fileDescriptor
        Task { await server.handleConnection(fileDescriptor: fd) }
        return true
    }
}
