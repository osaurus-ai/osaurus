//
//  AgentChannelCustomJSONRunner.swift
//  osaurus
//
//  Safe configuration-only HTTP runner for custom JSON Agent Channels.
//

import Foundation

struct AgentChannelHTTPResponseTooLargeError: Error, Equatable, Sendable {
    let maxBytes: Int
}

protocol AgentChannelHTTPClient {
    func agentChannelData(for request: URLRequest) async throws -> (Data, URLResponse)
    func agentChannelData(for request: URLRequest, maxResponseBytes: Int) async throws -> (Data, URLResponse)
}

extension AgentChannelHTTPClient {
    func agentChannelData(for request: URLRequest, maxResponseBytes: Int) async throws -> (Data, URLResponse) {
        let (data, response) = try await agentChannelData(for: request)
        guard data.count <= maxResponseBytes else {
            throw AgentChannelHTTPResponseTooLargeError(maxBytes: maxResponseBytes)
        }
        return (data, response)
    }
}

extension URLSession: AgentChannelHTTPClient {
    func agentChannelData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }

    func agentChannelData(for request: URLRequest, maxResponseBytes: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await bytes(for: request)
        var data = Data()
        data.reserveCapacity(min(maxResponseBytes, 65_536))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxResponseBytes {
                throw AgentChannelHTTPResponseTooLargeError(maxBytes: maxResponseBytes)
            }
        }
        return (data, response)
    }
}

protocol AgentChannelSecretResolving {
    func secret(named name: String, keychainId: String, connection: AgentChannelConnection) -> String?
}

struct KeychainAgentChannelSecretResolver: AgentChannelSecretResolving {
    static let pluginIdPrefix = "osaurus.agent-channel"

    func secret(named name: String, keychainId: String, connection: AgentChannelConnection) -> String? {
        let pluginId = "\(Self.pluginIdPrefix).\(connection.id)"
        return ToolSecretsKeychain.getSecret(id: keychainId, for: pluginId, agentId: Agent.defaultId)
            ?? ToolSecretsKeychain.getSecret(id: name, for: pluginId, agentId: Agent.defaultId)
    }
}

enum AgentChannelCustomJSONAuthorizationMode: Sendable {
    case read
    case write
}

struct AgentChannelCustomJSONAuthorizationRequest: Sendable {
    var connectionId: String
    var action: AgentChannelAction
    var mode: AgentChannelCustomJSONAuthorizationMode
    var spaceId: String?
    var roomId: String?
    var threadId: String?
    var roomIds: [String]
}

protocol AgentChannelCustomJSONAuthorizationPolicy: Sendable {
    func authorize(_ request: AgentChannelCustomJSONAuthorizationRequest) throws
}

struct PermissiveAgentChannelCustomJSONAuthorizationPolicy: AgentChannelCustomJSONAuthorizationPolicy {
    func authorize(_: AgentChannelCustomJSONAuthorizationRequest) throws {}
}

protocol AgentChannelCustomJSONRunning {
    func diagnostics(connection: AgentChannelConnection) async -> [String: Any]
    func listSpaces(connection: AgentChannelConnection) async throws -> [[String: Any]]
    func listRooms(connection: AgentChannelConnection, spaceId: String) async throws -> [[String: Any]]
    func readMessages(connection: AgentChannelConnection, roomId: String, limit: Int?) async throws -> [String: Any]
    func readThread(connection: AgentChannelConnection, threadId: String, limit: Int?) async throws -> [String: Any]
    func searchMessages(
        connection: AgentChannelConnection,
        query: String,
        roomIds: [String]?,
        limitPerRoom: Int?,
        maxMatches: Int?
    ) async throws -> [String: Any]
    func draftMessage(connection: AgentChannelConnection, roomId: String, content: String) throws -> [String: Any]
    func sendMessage(
        connection: AgentChannelConnection,
        roomId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any]
    func replyThread(
        connection: AgentChannelConnection,
        threadId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any]
}

enum AgentChannelCustomJSONRunnerError: LocalizedError, Equatable, Sendable {
    case missingConfiguration(String)
    case actionNotConfigured(action: AgentChannelAction, connectionId: String)
    case methodNotAllowed(method: String, allowed: [String])
    case blockedURL(String)
    case invalidRequest(String)
    case invalidTemplate(String)
    case missingInput(String)
    case missingSecret(String)
    case spaceNotAllowlisted(spaceId: String, connectionId: String)
    case roomNotReadable(roomId: String, connectionId: String)
    case roomNotWritable(roomId: String, connectionId: String)
    case writeDisabled(String)
    case sendConfirmationRequired
    case emptyMessage
    case httpStatus(statusCode: Int, body: String, partialWriteStatus: String?)
    case invalidResponse(String, partialWriteStatus: String?)
    case transport(String, partialWriteStatus: String?)
    case cancelled(partialWriteStatus: String?)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let connectionId):
            return "Custom JSON channel `\(connectionId)` has no custom_http configuration."
        case .actionNotConfigured(let action, let connectionId):
            return "Custom JSON channel `\(connectionId)` has no request template for `\(action.rawValue)`."
        case .methodNotAllowed(let method, let allowed):
            return "HTTP method `\(method)` is not allowlisted for this custom JSON channel. Allowed: \(allowed.joined(separator: ", "))."
        case .blockedURL(let reason):
            return "Custom JSON channel request URL was blocked: \(reason)."
        case .invalidRequest(let message):
            return "Custom JSON channel request is invalid: \(message)"
        case .invalidTemplate(let message):
            return "Custom JSON channel template is invalid: \(message)"
        case .missingInput(let name):
            return "Custom JSON channel template references missing input `\(name)`."
        case .missingSecret(let name):
            return "Custom JSON channel secret `\(name)` is not available in Keychain."
        case .spaceNotAllowlisted(let spaceId, let connectionId):
            return "Custom JSON channel `\(connectionId)` space `\(spaceId)` is not allowlisted."
        case .roomNotReadable(let roomId, let connectionId):
            return "Custom JSON channel `\(connectionId)` room `\(roomId)` is not allowlisted for read access."
        case .roomNotWritable(let roomId, let connectionId):
            return "Custom JSON channel `\(connectionId)` room `\(roomId)` is not allowlisted for write access."
        case .writeDisabled(let connectionId):
            return "Custom JSON channel `\(connectionId)` write access is disabled."
        case .sendConfirmationRequired:
            return "`confirm_send` must be true before Osaurus posts through a custom JSON channel."
        case .emptyMessage:
            return "Custom JSON channel message content must not be empty."
        case .httpStatus(let statusCode, let body, _):
            return "Custom JSON channel HTTP request failed with status \(statusCode): \(body)"
        case .invalidResponse(let message, _):
            return "Custom JSON channel response is invalid: \(message)"
        case .transport(let message, _):
            return "Custom JSON channel transport failed: \(message)"
        case .cancelled(let partialWriteStatus):
            if let partialWriteStatus {
                return "Custom JSON channel write was cancelled after dispatch; delivery status is `\(partialWriteStatus)`."
            }
            return "Custom JSON channel request was cancelled."
        }
    }

    var partialWriteStatus: String? {
        switch self {
        case .httpStatus(_, _, let status),
            .invalidResponse(_, let status),
            .transport(_, let status),
            .cancelled(let status):
            return status
        case .missingConfiguration, .actionNotConfigured, .methodNotAllowed, .blockedURL,
            .invalidRequest, .invalidTemplate, .missingInput, .missingSecret,
            .spaceNotAllowlisted, .roomNotReadable, .roomNotWritable, .writeDisabled,
            .sendConfirmationRequired, .emptyMessage:
            return nil
        }
    }
}

final class AgentChannelCustomJSONRunner: AgentChannelCustomJSONRunning, @unchecked Sendable {
    static let defaultMaxRequestBytes = 262_144
    private static let maxMappedRows = 100

    private let httpClient: any AgentChannelHTTPClient
    private let secretResolver: any AgentChannelSecretResolving
    private let authorizationPolicy: any AgentChannelCustomJSONAuthorizationPolicy
    private let idempotencyLedger: AgentChannelCustomJSONIdempotencyLedger

    init(
        httpClient: any AgentChannelHTTPClient = AgentChannelCustomJSONRunner.makeDefaultHTTPClient(),
        secretResolver: any AgentChannelSecretResolving = KeychainAgentChannelSecretResolver(),
        authorizationPolicy: any AgentChannelCustomJSONAuthorizationPolicy =
            PermissiveAgentChannelCustomJSONAuthorizationPolicy(),
        idempotencyLedger: AgentChannelCustomJSONIdempotencyLedger = AgentChannelCustomJSONIdempotencyLedger()
    ) {
        self.httpClient = httpClient
        self.secretResolver = secretResolver
        self.authorizationPolicy = authorizationPolicy
        self.idempotencyLedger = idempotencyLedger
    }

    func diagnostics(connection: AgentChannelConnection) async -> [String: Any] {
        guard let customHTTP = connection.customHTTP else {
            return [
                "connection_id": connection.id,
                "kind": connection.kind.rawValue,
                "status": "not_configured",
                "failures": [AgentChannelCustomJSONRunnerError.missingConfiguration(connection.id).localizedDescription],
            ]
        }

        let baseURLStatus = Self.diagnosticURLStatus(configuration: customHTTP)
        let actionRows = customHTTP.actions.keys.sorted().map { key -> [String: Any] in
            let action = customHTTP.actions[key] ?? AgentChannelCustomHTTPAction(path: "/")
            let templates = [action.path] + Array(action.query.values) + Array(action.headers.values)
                + [action.bodyTemplate].compactMap { $0 }
            let placeholders = AgentChannelTemplateRenderer.placeholders(in: templates)
            return [
                "action": key,
                "method": action.method,
                "path_template": action.path,
                "query_keys": action.query.keys.sorted(),
                "header_names": action.headers.keys.sorted(),
                "body_template_configured": action.bodyTemplate != nil,
                "required_inputs": placeholders.inputs.sorted(),
                "secret_references": placeholders.secrets.sorted(),
                "idempotency_configured": action.idempotency != nil,
                "response_mapping_configured": action.responseMapping != AgentChannelCustomHTTPResponseMapping(),
                "success_status_codes": action.successStatusCodes,
                "dry_run": true,
            ]
        }

        var failures = baseURLStatus.failures
        for (key, action) in customHTTP.actions {
            if !customHTTP.allowedMethods.contains(action.method) {
                failures.append("Action `\(key)` method `\(action.method)` is not in allowedMethods.")
            }
            failures.append(contentsOf: Self.headerValidationFailures(action.headers.keys.sorted(), actionName: key))
        }

        return [
            "connection_id": connection.id,
            "kind": connection.kind.rawValue,
            "status": failures.isEmpty ? "configured_dry_run" : "invalid_configuration",
            "enabled": connection.enabled,
            "write_enabled": connection.writeEnabled,
            "base_url": baseURLStatus.redactedBaseURL,
            "allowed_hosts": Self.effectiveAllowedHosts(configuration: customHTTP),
            "allowed_methods": customHTTP.allowedMethods,
            "max_response_bytes": customHTTP.maxResponseBytes,
            "timeout_seconds": customHTTP.timeoutSeconds,
            "secret_names": connection.secrets.map(\.name),
            "actions": actionRows,
            "failures": failures,
        ]
    }

    func listSpaces(connection: AgentChannelConnection) async throws -> [[String: Any]] {
        let result = try await execute(.listSpaces, connection: connection, input: [:], mode: .read)
        return result["spaces"] as? [[String: Any]] ?? []
    }

    func listRooms(connection: AgentChannelConnection, spaceId: String) async throws -> [[String: Any]] {
        let normalizedSpaceId = AgentChannelConnection.normalizedId(spaceId)
        try requireSpace(normalizedSpaceId, connection: connection)
        let result = try await execute(
            .listRooms,
            connection: connection,
            input: ["space_id": .string(normalizedSpaceId)],
            mode: .read
        )
        return result["rooms"] as? [[String: Any]] ?? []
    }

    func readMessages(connection: AgentChannelConnection, roomId: String, limit: Int?) async throws -> [String: Any] {
        let normalizedRoomId = try requireReadableRoom(roomId, connection: connection)
        let safeLimit = AgentChannelConnection.clampReadLimit(limit ?? connection.defaultReadLimit)
        return try await execute(
            .readMessages,
            connection: connection,
            input: [
                "room_id": .string(normalizedRoomId),
                "limit": .int(safeLimit),
            ],
            mode: .read,
            targetRoomId: normalizedRoomId
        )
    }

    func readThread(connection: AgentChannelConnection, threadId: String, limit: Int?) async throws -> [String: Any] {
        let normalizedThreadId = try requireReadableRoom(threadId, connection: connection)
        let safeLimit = AgentChannelConnection.clampReadLimit(limit ?? connection.defaultReadLimit)
        return try await execute(
            .readMessages,
            connection: connection,
            input: [
                "thread_id": .string(normalizedThreadId),
                "room_id": .string(normalizedThreadId),
                "limit": .int(safeLimit),
            ],
            mode: .read,
            targetRoomId: normalizedThreadId,
            resultAction: .readMessages,
            standardKindOverride: "thread_messages"
        ).merging(["thread_id": normalizedThreadId]) { _, new in new }
    }

    func searchMessages(
        connection: AgentChannelConnection,
        query: String,
        roomIds: [String]?,
        limitPerRoom: Int?,
        maxMatches: Int?
    ) async throws -> [String: Any] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { throw AgentChannelCustomJSONRunnerError.emptyMessage }

        let candidateRooms = AgentChannelConnection.normalizedIds(roomIds ?? connection.readRoomAllowlist)
        guard !candidateRooms.isEmpty else {
            throw AgentChannelCustomJSONRunnerError.roomNotReadable(roomId: "", connectionId: connection.id)
        }
        for roomId in candidateRooms {
            _ = try requireReadableRoom(roomId, connection: connection)
        }

        let safeLimit = AgentChannelConnection.clampReadLimit(limitPerRoom ?? connection.defaultReadLimit)
        let safeMaxMatches = min(max(maxMatches ?? 25, 1), 50)
        return try await execute(
            .searchMessages,
            connection: connection,
            input: [
                "query": .string(trimmedQuery),
                "room_ids": .stringArray(candidateRooms),
                "limit_per_room": .int(safeLimit),
                "max_matches": .int(safeMaxMatches),
            ],
            mode: .read
        )
    }

    func draftMessage(connection: AgentChannelConnection, roomId: String, content: String) throws -> [String: Any] {
        let normalizedRoomId = try requireWritableRoom(roomId, connection: connection)
        let trimmedContent = try validateMessageContent(content)
        return try dryRunWriteAction(
            .draftMessage,
            connection: connection,
            input: [
                "room_id": .string(normalizedRoomId),
                "content": .string(trimmedContent),
            ],
            targetRoomId: normalizedRoomId,
            kind: "custom_json_message_draft"
        )
    }

    func sendMessage(
        connection: AgentChannelConnection,
        roomId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else { throw AgentChannelCustomJSONRunnerError.sendConfirmationRequired }
        let normalizedRoomId = try requireWritableRoom(roomId, connection: connection)
        let trimmedContent = try validateMessageContent(content)
        return try await execute(
            .sendMessage,
            connection: connection,
            input: [
                "room_id": .string(normalizedRoomId),
                "content": .string(trimmedContent),
                "confirm_send": .bool(true),
            ],
            mode: .write,
            targetRoomId: normalizedRoomId
        )
    }

    func replyThread(
        connection: AgentChannelConnection,
        threadId: String,
        content: String,
        confirmSend: Bool
    ) async throws -> [String: Any] {
        guard confirmSend else { throw AgentChannelCustomJSONRunnerError.sendConfirmationRequired }
        let normalizedThreadId = try requireWritableRoom(threadId, connection: connection)
        let trimmedContent = try validateMessageContent(content)
        return try await execute(
            .replyThread,
            connection: connection,
            input: [
                "thread_id": .string(normalizedThreadId),
                "room_id": .string(normalizedThreadId),
                "content": .string(trimmedContent),
                "confirm_send": .bool(true),
            ],
            mode: .write,
            targetRoomId: normalizedThreadId
        )
    }

    private func execute(
        _ action: AgentChannelAction,
        connection: AgentChannelConnection,
        input: [String: AgentChannelTemplateValue],
        mode: AgentChannelCustomJSONMode,
        targetRoomId: String? = nil,
        resultAction: AgentChannelAction? = nil,
        standardKindOverride: String? = nil
    ) async throws -> [String: Any] {
        let customHTTP = try requireConfiguration(connection)
        let customAction = try requireAction(action, connection: connection, configuration: customHTTP)
        try authorize(
            action,
            connection: connection,
            input: input,
            mode: mode == .write ? .write : .read
        )
        let redactor = AgentChannelSecretRedactor()
        let idempotencyKey = try idempotencyKey(
            for: customAction,
            action: action,
            connection: connection,
            input: input,
            redactor: redactor
        )

        var reservedIdempotencyKey: String?
        if mode == .write, let idempotencyKey {
            switch idempotencyLedger.reserve(idempotencyKey) {
            case .reserved:
                reservedIdempotencyKey = idempotencyKey
            case .completed(let cached):
                return duplicateResult(
                    from: cached,
                    status: (cached["partial_write"] as? Bool) == true
                        ? "duplicate_unconfirmed_suppressed"
                        : "duplicate_suppressed"
                )
            case .inFlight:
                return inFlightDuplicateResult(
                    action: action,
                    connection: connection,
                    input: input,
                    targetRoomId: targetRoomId,
                    idempotencyKey: idempotencyKey,
                    redactor: redactor
                )
            }
        }

        let prepared: AgentChannelPreparedHTTPRequest
        do {
            prepared = try prepareRequest(
                action: customAction,
                configuration: customHTTP,
                connection: connection,
                input: input,
                idempotencyKey: idempotencyKey,
                redactor: redactor
            )
        } catch {
            if let reservedIdempotencyKey {
                idempotencyLedger.finishFailure(for: reservedIdempotencyKey)
            }
            throw error
        }

        if Task.isCancelled {
            if let reservedIdempotencyKey {
                idempotencyLedger.finishFailure(for: reservedIdempotencyKey)
            }
            throw AgentChannelCustomJSONRunnerError.cancelled(partialWriteStatus: nil)
        }

        let responseLimit = customAction.maxResponseBytes ?? customHTTP.maxResponseBytes
        var dispatched = false
        let data: Data
        let response: URLResponse
        do {
            dispatched = true
            (data, response) = try await httpClient.agentChannelData(
                for: prepared.request,
                maxResponseBytes: responseLimit
            )
        } catch is CancellationError {
            let status = mode == .write && dispatched ? "cancelled_after_dispatch" : nil
            if let reservedIdempotencyKey {
                if let status {
                    finishUnconfirmedWrite(
                        action: action,
                        connection: connection,
                        input: input,
                        targetRoomId: targetRoomId,
                        idempotencyKey: reservedIdempotencyKey,
                        reason: status,
                        redactor: redactor
                    )
                } else {
                    idempotencyLedger.finishFailure(for: reservedIdempotencyKey)
                }
            }
            throw AgentChannelCustomJSONRunnerError.cancelled(partialWriteStatus: status)
        } catch let error as AgentChannelHTTPResponseTooLargeError {
            if let reservedIdempotencyKey {
                finishUnconfirmedWrite(
                    action: action,
                    connection: connection,
                    input: input,
                    targetRoomId: targetRoomId,
                    idempotencyKey: reservedIdempotencyKey,
                    reason: "Response exceeded \(error.maxBytes) bytes.",
                    redactor: redactor
                )
            }
            throw AgentChannelCustomJSONRunnerError.invalidResponse(
                "Response exceeded \(error.maxBytes) bytes.",
                partialWriteStatus: mode == .write ? "response_too_large_unconfirmed" : nil
            )
        } catch {
            let status = mode == .write && dispatched ? "transport_unconfirmed" : nil
            if let reservedIdempotencyKey {
                if status != nil {
                    finishUnconfirmedWrite(
                        action: action,
                        connection: connection,
                        input: input,
                        targetRoomId: targetRoomId,
                        idempotencyKey: reservedIdempotencyKey,
                        reason: error.localizedDescription,
                        redactor: redactor
                    )
                } else {
                    idempotencyLedger.finishFailure(for: reservedIdempotencyKey)
                }
            }
            throw AgentChannelCustomJSONRunnerError.transport(
                redactor.redact(error.localizedDescription),
                partialWriteStatus: status
            )
        }

        if Task.isCancelled {
            let status = mode == .write ? "cancelled_after_response" : nil
            if let reservedIdempotencyKey {
                finishUnconfirmedWrite(
                    action: action,
                    connection: connection,
                    input: input,
                    targetRoomId: targetRoomId,
                    idempotencyKey: reservedIdempotencyKey,
                    reason: status ?? "cancelled",
                    redactor: redactor
                )
            }
            throw AgentChannelCustomJSONRunnerError.cancelled(partialWriteStatus: status)
        }

        guard let http = response as? HTTPURLResponse else {
            if let reservedIdempotencyKey {
                finishUnconfirmedWrite(
                    action: action,
                    connection: connection,
                    input: input,
                    targetRoomId: targetRoomId,
                    idempotencyKey: reservedIdempotencyKey,
                    reason: "Transport did not return an HTTP response.",
                    redactor: redactor
                )
            }
            throw AgentChannelCustomJSONRunnerError.invalidResponse(
                "Transport did not return an HTTP response.",
                partialWriteStatus: mode == .write ? "response_unconfirmed" : nil
            )
        }

        guard data.count <= responseLimit else {
            if let reservedIdempotencyKey {
                finishUnconfirmedWrite(
                    action: action,
                    connection: connection,
                    input: input,
                    targetRoomId: targetRoomId,
                    idempotencyKey: reservedIdempotencyKey,
                    reason: "Response exceeded \(responseLimit) bytes.",
                    redactor: redactor
                )
            }
            throw AgentChannelCustomJSONRunnerError.invalidResponse(
                "Response exceeded \(responseLimit) bytes.",
                partialWriteStatus: mode == .write ? "response_too_large_unconfirmed" : nil
            )
        }

        guard customAction.successStatusCodes.contains(http.statusCode) else {
            let bodyText = String(bytes: data.prefix(600), encoding: .utf8) ?? ""
            let body = redactor.redact(bodyText)
            if let reservedIdempotencyKey {
                finishUnconfirmedWrite(
                    action: action,
                    connection: connection,
                    input: input,
                    targetRoomId: targetRoomId,
                    idempotencyKey: reservedIdempotencyKey,
                    statusCode: http.statusCode,
                    reason: body,
                    redactor: redactor
                )
            }
            throw AgentChannelCustomJSONRunnerError.httpStatus(
                statusCode: http.statusCode,
                body: body,
                partialWriteStatus: mode == .write ? "http_status_unconfirmed" : nil
            )
        }

        let json: Any
        var result: [String: Any]
        do {
            json = try parseJSON(data, mode: mode)
            result = try mapResult(
                json,
                action: resultAction ?? action,
                connection: connection,
                customAction: customAction,
                statusCode: http.statusCode,
                input: input,
                targetRoomId: targetRoomId,
                idempotencyKey: idempotencyKey,
                redactor: redactor,
                standardKindOverride: standardKindOverride
            )
        } catch {
            if let reservedIdempotencyKey {
                idempotencyLedger.finishUnconfirmed(
                    unconfirmedWriteResult(
                        action: action,
                        connection: connection,
                        input: input,
                        targetRoomId: targetRoomId,
                        idempotencyKey: reservedIdempotencyKey,
                        statusCode: http.statusCode,
                        reason: error.localizedDescription,
                        redactor: redactor
                    ),
                    for: reservedIdempotencyKey
                )
            }
            throw error
        }

        if mode == .write {
            result["delivery_status"] = "confirmed"
            if let reservedIdempotencyKey {
                idempotencyLedger.finishSuccess(result, for: reservedIdempotencyKey)
            }
        }
        return result
    }

    private func finishUnconfirmedWrite(
        action: AgentChannelAction,
        connection: AgentChannelConnection,
        input: [String: AgentChannelTemplateValue],
        targetRoomId: String?,
        idempotencyKey: String,
        statusCode: Int = 0,
        reason: String,
        redactor: AgentChannelSecretRedactor
    ) {
        idempotencyLedger.finishUnconfirmed(
            unconfirmedWriteResult(
                action: action,
                connection: connection,
                input: input,
                targetRoomId: targetRoomId,
                idempotencyKey: idempotencyKey,
                statusCode: statusCode,
                reason: reason,
                redactor: redactor
            ),
            for: idempotencyKey
        )
    }

    private func dryRunWriteAction(
        _ action: AgentChannelAction,
        connection: AgentChannelConnection,
        input: [String: AgentChannelTemplateValue],
        targetRoomId: String,
        kind: String
    ) throws -> [String: Any] {
        let customHTTP = try requireConfiguration(connection)
        let customAction = try requireAction(action, connection: connection, configuration: customHTTP)
        try authorize(
            action,
            connection: connection,
            input: input,
            mode: .write
        )
        let redactor = AgentChannelSecretRedactor()
        let idempotencyKey = try idempotencyKey(
            for: customAction,
            action: action,
            connection: connection,
            input: input,
            redactor: redactor
        )
        let prepared = try prepareRequest(
            action: customAction,
            configuration: customHTTP,
            connection: connection,
            input: input,
            idempotencyKey: idempotencyKey,
            redactor: redactor
        )
        return [
            "kind": kind,
            "channel_id": targetRoomId,
            "content": input["content"]?.rawString ?? "",
            "requires_send_confirmation": true,
            "dry_run": true,
            "request": prepared.redactedSummary,
        ]
    }

    private func prepareRequest(
        action: AgentChannelCustomHTTPAction,
        configuration: AgentChannelCustomHTTPConfiguration,
        connection: AgentChannelConnection,
        input: [String: AgentChannelTemplateValue],
        idempotencyKey: String?,
        redactor: AgentChannelSecretRedactor
    ) throws -> AgentChannelPreparedHTTPRequest {
        guard configuration.allowedMethods.contains(action.method) else {
            throw AgentChannelCustomJSONRunnerError.methodNotAllowed(
                method: action.method,
                allowed: configuration.allowedMethods
            )
        }
        try Self.validateHTTPMethodToken(action.method)

        let context = AgentChannelTemplateContext(
            input: input,
            connection: connection,
            secretResolver: secretResolver,
            redactor: redactor,
            idempotencyKey: idempotencyKey
        )
        let url = try Self.renderedURL(
            configuration: configuration,
            action: action,
            context: context
        )

        var request = URLRequest(url: url)
        request.httpMethod = action.method
        request.timeoutInterval = action.timeoutSeconds ?? configuration.timeoutSeconds

        var renderedHeaders: [String: String] = [:]
        for (name, valueTemplate) in action.headers {
            try Self.validateHeaderName(name)
            let rendered = try AgentChannelTemplateRenderer.render(
                valueTemplate,
                context: context,
                mode: .rawString
            )
            try Self.validateHeaderValue(rendered)
            request.setValue(rendered, forHTTPHeaderField: name)
            renderedHeaders[name] = redactor.redact(rendered)
        }

        if let header = action.idempotency?.header, let idempotencyKey {
            try Self.validateHeaderName(header)
            try Self.validateHeaderValue(idempotencyKey)
            if request.value(forHTTPHeaderField: header) == nil {
                request.setValue(idempotencyKey, forHTTPHeaderField: header)
                renderedHeaders[header] = redactor.redact(idempotencyKey)
            }
        }

        if let bodyTemplate = action.bodyTemplate {
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
            let renderMode: AgentChannelTemplateMode = Self.isJSONContentType(contentType) ? .jsonBody : .rawString
            if renderMode != .jsonBody,
                Self.bodyTemplateContainsPlaceholders(bodyTemplate) {
                throw AgentChannelCustomJSONRunnerError.invalidRequest(
                    "Non-JSON body templates must not contain placeholders."
                )
            }
            let renderedBody = try AgentChannelTemplateRenderer.render(
                bodyTemplate,
                context: context,
                mode: renderMode
            )
            if renderMode == .jsonBody {
                try Self.validateJSONBody(renderedBody)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    renderedHeaders["Content-Type"] = "application/json"
                }
            }
            let bodyData = Data(renderedBody.utf8)
            guard bodyData.count <= Self.defaultMaxRequestBytes else {
                throw AgentChannelCustomJSONRunnerError.invalidRequest(
                    "Request body exceeded \(Self.defaultMaxRequestBytes) bytes."
                )
            }
            request.httpBody = bodyData
        }

        let redactedBody = request.httpBody.flatMap { bodyData -> String? in
            guard let body = String(bytes: bodyData, encoding: .utf8) else { return nil }
            return redactor.redact(body)
        }
        return AgentChannelPreparedHTTPRequest(
            request: request,
            redactedSummary: [
                "method": action.method,
                "url": redactor.redact(url.absoluteString),
                "headers": renderedHeaders,
                "body": redactedBody ?? NSNull(),
            ]
        )
    }

    private func mapResult(
        _ json: Any,
        action: AgentChannelAction,
        connection: AgentChannelConnection,
        customAction: AgentChannelCustomHTTPAction,
        statusCode: Int,
        input: [String: AgentChannelTemplateValue],
        targetRoomId: String?,
        idempotencyKey: String?,
        redactor: AgentChannelSecretRedactor,
        standardKindOverride: String?
    ) throws -> [String: Any] {
        switch action {
        case .listSpaces:
            let rows = try mapListItems(
                json,
                defaultItemsPath: "spaces",
                mapping: customAction.responseMapping,
                connection: connection,
                kind: "space",
                redactor: redactor
            )
            return [
                "connection_id": connection.id,
                "standard_kind": "spaces",
                "spaces": rows,
                "provider_status_code": statusCode,
            ]
        case .listRooms:
            let rows = try mapListItems(
                json,
                defaultItemsPath: "rooms",
                mapping: customAction.responseMapping,
                connection: connection,
                kind: "room",
                redactor: redactor
            )
            return [
                "connection_id": connection.id,
                "space_id": input["space_id"]?.rawString ?? "",
                "standard_kind": "rooms",
                "rooms": rows,
                "provider_status_code": statusCode,
            ]
        case .readMessages:
            return try mapMessagesResult(
                json,
                defaultItemsPath: "messages",
                mapping: customAction.responseMapping,
                connection: connection,
                roomId: targetRoomId ?? input["room_id"]?.rawString ?? "",
                standardKind: standardKindOverride ?? "channel_messages",
                resultKind: standardKindOverride == "thread_messages"
                    ? "custom_json_thread_messages" : "custom_json_recent_messages",
                limit: input["limit"]?.intValue,
                statusCode: statusCode,
                redactor: redactor
            )
        case .searchMessages:
            var result = try mapMessagesResult(
                json,
                defaultItemsPath: "messages",
                mapping: customAction.responseMapping,
                connection: connection,
                roomId: "",
                standardKind: "message_search",
                resultKind: "custom_json_message_search",
                limit: input["max_matches"]?.intValue,
                statusCode: statusCode,
                redactor: redactor
            )
            result["query"] = input["query"]?.rawString ?? ""
            result["room_ids"] = input["room_ids"]?.stringArrayValue ?? []
            result["match_count"] = (result["messages"] as? [[String: Any]])?.count ?? 0
            return result
        case .sendMessage, .replyThread:
            var mapping = customAction.responseMapping
            if mapping.idPath == nil, let responseIdPath = customAction.idempotency?.responseIdPath {
                mapping.idPath = responseIdPath
            }
            let message = try mapSingleMessage(
                json,
                mapping: mapping,
                fallbackRoomId: targetRoomId ?? input["room_id"]?.rawString ?? "",
                fallbackContent: input["content"]?.rawString,
                fallbackMessageId: idempotencyKey.map { redactor.redact($0) },
                redactor: redactor
            )
            var result: [String: Any] = [
                "connection_id": connection.id,
                "kind": action == .replyThread ? "custom_json_thread_reply_sent" : "custom_json_message_sent",
                "standard_kind": action == .replyThread ? "thread_reply_sent" : "message_sent",
                "channel_id": targetRoomId ?? input["room_id"]?.rawString ?? "",
                "message": message,
                "provider_status_code": statusCode,
                "partial_write": false,
            ]
            if action == .replyThread {
                result["thread_id"] = targetRoomId ?? input["thread_id"]?.rawString ?? ""
            }
            if let idempotencyKey {
                result["idempotency_key"] = redactor.redact(idempotencyKey)
            }
            return result
        case .diagnostics, .draftMessage:
            throw AgentChannelCustomJSONRunnerError.invalidResponse(
                "`\(action.rawValue)` is not a network response mapping action.",
                partialWriteStatus: nil
            )
        }
    }

    private func mapListItems(
        _ json: Any,
        defaultItemsPath: String,
        mapping: AgentChannelCustomHTTPResponseMapping,
        connection: AgentChannelConnection,
        kind: String,
        redactor: AgentChannelSecretRedactor
    ) throws -> [[String: Any]] {
        let array = try Self.arrayValue(json, path: mapping.itemsPath ?? defaultItemsPath)
        return try array.prefix(Self.maxMappedRows).enumerated().map { index, item in
            let id = try Self.stringValue(item, path: mapping.idPath ?? "id") ?? "\(index)"
            let name = try Self.stringValue(item, path: mapping.namePath ?? "name") ?? ""
            return [
                "id": id,
                "name": name,
                "kind": kind,
                "connection_id": connection.id,
                "raw": redactor.redactJSON(item),
            ]
        }
    }

    private func mapMessagesResult(
        _ json: Any,
        defaultItemsPath: String,
        mapping: AgentChannelCustomHTTPResponseMapping,
        connection: AgentChannelConnection,
        roomId: String,
        standardKind: String,
        resultKind: String,
        limit: Int?,
        statusCode: Int,
        redactor: AgentChannelSecretRedactor
    ) throws -> [String: Any] {
        let array = try Self.arrayValue(json, path: mapping.itemsPath ?? defaultItemsPath)
        let rowLimit = min(limit ?? Self.maxMappedRows, Self.maxMappedRows)
        let messages = try array.prefix(rowLimit).enumerated().map { index, item in
            try mapMessage(
                item,
                mapping: mapping,
                fallbackRoomId: roomId,
                fallbackMessageId: "\(index)",
                redactor: redactor
            )
        }
        return [
            "connection_id": connection.id,
            "kind": resultKind,
            "standard_kind": standardKind,
            "room_id": roomId,
            "limit": limit ?? messages.count,
            "partial": true,
            "messages": messages,
            "provider_status_code": statusCode,
        ]
    }

    private func mapSingleMessage(
        _ json: Any,
        mapping: AgentChannelCustomHTTPResponseMapping,
        fallbackRoomId: String,
        fallbackContent: String?,
        fallbackMessageId: String?,
        redactor: AgentChannelSecretRedactor
    ) throws -> [String: Any] {
        guard let object = json as? [String: Any] else {
            throw AgentChannelCustomJSONRunnerError.invalidResponse(
                "Write response must be a JSON object.",
                partialWriteStatus: "malformed_write_response"
            )
        }
        return try mapMessage(
            object,
            mapping: mapping,
            fallbackRoomId: fallbackRoomId,
            fallbackMessageId: fallbackMessageId,
            fallbackContent: fallbackContent,
            redactor: redactor
        )
    }

    private func mapMessage(
        _ item: [String: Any],
        mapping: AgentChannelCustomHTTPResponseMapping,
        fallbackRoomId: String,
        fallbackMessageId: String?,
        fallbackContent: String? = nil,
        redactor: AgentChannelSecretRedactor
    ) throws -> [String: Any] {
        [
            "id": try Self.stringValue(item, path: mapping.idPath ?? "id") ?? fallbackMessageId ?? "",
            "room_id": try Self.stringValue(item, path: mapping.roomIdPath ?? "room_id") ?? fallbackRoomId,
            "thread_id": try Self.stringValue(item, path: mapping.threadIdPath ?? "thread_id") ?? "",
            "content": redactor.redact(try Self.stringValue(item, path: mapping.contentPath ?? "content") ?? fallbackContent ?? ""),
            "author_id": try Self.stringValue(item, path: mapping.authorIdPath ?? "author_id") ?? "",
            "author_name": try Self.stringValue(item, path: mapping.authorNamePath ?? "author_name") ?? "",
            "timestamp": try Self.stringValue(item, path: mapping.timestampPath ?? "timestamp") ?? "",
            "raw": redactor.redactJSON(item),
        ]
    }

    private func parseJSON(_ data: Data, mode: AgentChannelCustomJSONMode) throws -> Any {
        guard !data.isEmpty else {
            return [:]
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AgentChannelCustomJSONRunnerError.invalidResponse(
                "Response body was not valid JSON.",
                partialWriteStatus: mode == .write ? "malformed_write_response" : nil
            )
        }
    }

    private func idempotencyKey(
        for actionConfig: AgentChannelCustomHTTPAction,
        action: AgentChannelAction,
        connection: AgentChannelConnection,
        input: [String: AgentChannelTemplateValue],
        redactor: AgentChannelSecretRedactor
    ) throws -> String? {
        guard actionConfig.idempotency != nil else { return nil }
        if let template = actionConfig.idempotency?.keyTemplate {
            let context = AgentChannelTemplateContext(
                input: input,
                connection: connection,
                secretResolver: secretResolver,
                redactor: redactor,
                idempotencyKey: nil
            )
            return try AgentChannelTemplateRenderer.render(template, context: context, mode: .rawString)
        }
        let target = input["room_id"]?.rawString ?? input["thread_id"]?.rawString ?? ""
        let content = input["content"]?.rawString ?? ""
        return "\(connection.id):\(action.rawValue):\(target):\(Self.stableHash(content))"
    }

    private func requireConfiguration(_ connection: AgentChannelConnection) throws -> AgentChannelCustomHTTPConfiguration {
        guard let configuration = connection.customHTTP else {
            throw AgentChannelCustomJSONRunnerError.missingConfiguration(connection.id)
        }
        return configuration
    }

    private func requireAction(
        _ action: AgentChannelAction,
        connection: AgentChannelConnection,
        configuration: AgentChannelCustomHTTPConfiguration
    ) throws -> AgentChannelCustomHTTPAction {
        if let configured = configuration.actions[action.rawValue] {
            return configured
        }
        throw AgentChannelCustomJSONRunnerError.actionNotConfigured(action: action, connectionId: connection.id)
    }

    private func authorize(
        _ action: AgentChannelAction,
        connection: AgentChannelConnection,
        input: [String: AgentChannelTemplateValue],
        mode: AgentChannelCustomJSONAuthorizationMode
    ) throws {
        do {
            try authorizationPolicy.authorize(
                AgentChannelCustomJSONAuthorizationRequest(
                    connectionId: connection.id,
                    action: action,
                    mode: mode,
                    spaceId: input["space_id"]?.rawString,
                    roomId: input["room_id"]?.rawString,
                    threadId: input["thread_id"]?.rawString,
                    roomIds: input["room_ids"]?.stringArrayValue ?? []
                )
            )
        } catch let error as AgentChannelCustomJSONRunnerError {
            throw error
        } catch {
            throw AgentChannelCustomJSONRunnerError.invalidRequest(
                "Authorization denied: \(error.localizedDescription)"
            )
        }
    }

    private func duplicateResult(from cached: [String: Any], status: String) -> [String: Any] {
        var duplicate = cached
        duplicate["duplicate"] = true
        duplicate["delivery_status"] = status
        return duplicate
    }

    private func inFlightDuplicateResult(
        action: AgentChannelAction,
        connection: AgentChannelConnection,
        input: [String: AgentChannelTemplateValue],
        targetRoomId: String?,
        idempotencyKey: String,
        redactor: AgentChannelSecretRedactor
    ) -> [String: Any] {
        var result: [String: Any] = [
            "connection_id": connection.id,
            "kind": action == .replyThread ? "custom_json_thread_reply_sent" : "custom_json_message_sent",
            "standard_kind": action == .replyThread ? "thread_reply_sent" : "message_sent",
            "channel_id": targetRoomId ?? input["room_id"]?.rawString ?? "",
            "provider_status_code": NSNull(),
            "partial_write": true,
            "duplicate": true,
            "delivery_status": "duplicate_in_flight_suppressed",
            "idempotency_key": redactor.redact(idempotencyKey),
        ]
        if action == .replyThread {
            result["thread_id"] = targetRoomId ?? input["thread_id"]?.rawString ?? ""
        }
        return result
    }

    private func unconfirmedWriteResult(
        action: AgentChannelAction,
        connection: AgentChannelConnection,
        input: [String: AgentChannelTemplateValue],
        targetRoomId: String?,
        idempotencyKey: String,
        statusCode: Int,
        reason: String,
        redactor: AgentChannelSecretRedactor
    ) -> [String: Any] {
        var result: [String: Any] = [
            "connection_id": connection.id,
            "kind": action == .replyThread ? "custom_json_thread_reply_sent" : "custom_json_message_sent",
            "standard_kind": action == .replyThread ? "thread_reply_sent" : "message_sent",
            "channel_id": targetRoomId ?? input["room_id"]?.rawString ?? "",
            "provider_status_code": statusCode,
            "partial_write": true,
            "delivery_status": "unconfirmed_after_response_mapping_failure",
            "idempotency_key": redactor.redact(idempotencyKey),
            "failure": redactor.redact(reason),
        ]
        if action == .replyThread {
            result["thread_id"] = targetRoomId ?? input["thread_id"]?.rawString ?? ""
        }
        return result
    }

    private func requireSpace(_ spaceId: String, connection: AgentChannelConnection) throws {
        let normalized = AgentChannelConnection.normalizedId(spaceId)
        guard !normalized.isEmpty, connection.spaceAllowlist.contains(normalized) else {
            throw AgentChannelCustomJSONRunnerError.spaceNotAllowlisted(
                spaceId: normalized,
                connectionId: connection.id
            )
        }
    }

    private func requireReadableRoom(_ roomId: String, connection: AgentChannelConnection) throws -> String {
        let normalized = AgentChannelConnection.normalizedId(roomId)
        guard !normalized.isEmpty, connection.readRoomAllowlist.contains(normalized) else {
            throw AgentChannelCustomJSONRunnerError.roomNotReadable(roomId: normalized, connectionId: connection.id)
        }
        return normalized
    }

    private func requireWritableRoom(_ roomId: String, connection: AgentChannelConnection) throws -> String {
        let normalized = AgentChannelConnection.normalizedId(roomId)
        guard connection.writeEnabled else {
            throw AgentChannelCustomJSONRunnerError.writeDisabled(connection.id)
        }
        guard !normalized.isEmpty, connection.writeRoomAllowlist.contains(normalized) else {
            throw AgentChannelCustomJSONRunnerError.roomNotWritable(roomId: normalized, connectionId: connection.id)
        }
        return normalized
    }

    private func validateMessageContent(_ content: String) throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgentChannelCustomJSONRunnerError.emptyMessage }
        guard trimmed.utf8.count <= Self.defaultMaxRequestBytes else {
            throw AgentChannelCustomJSONRunnerError.invalidRequest("Message content is too large.")
        }
        return trimmed
    }

    private static func makeDefaultHTTPClient() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration,
            delegate: AgentChannelNoRedirectDelegate(),
            delegateQueue: nil
        )
    }
}

private enum AgentChannelCustomJSONMode {
    case read
    case write
}

private struct AgentChannelPreparedHTTPRequest {
    let request: URLRequest
    let redactedSummary: [String: Any]
}

final class AgentChannelCustomJSONIdempotencyLedger: @unchecked Sendable {
    enum Reservation {
        case reserved
        case inFlight
        case completed([String: Any])
    }

    private enum Entry {
        case inFlight
        case completed([String: Any])
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func reserve(_ key: String) -> Reservation {
        lock.withLock {
            switch entries[key] {
            case .completed(let result):
                return .completed(result)
            case .inFlight:
                return .inFlight
            case nil:
                entries[key] = .inFlight
                return .reserved
            }
        }
    }

    func finishSuccess(_ result: [String: Any], for key: String) {
        lock.withLock { entries[key] = .completed(result) }
    }

    func finishUnconfirmed(_ result: [String: Any], for key: String) {
        lock.withLock { entries[key] = .completed(result) }
    }

    func finishFailure(for key: String) {
        lock.withLock {
            if case .inFlight? = entries[key] {
                entries.removeValue(forKey: key)
            }
        }
    }
}

private final class AgentChannelNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class AgentChannelSecretRedactor: @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func register(name: String, value: String) {
        guard value.count >= SecretScrubber.minimumValueLength else { return }
        lock.withLock {
            secrets[name] = value
            if let pathEncoded = value.addingPercentEncoding(withAllowedCharacters: .agentChannelPathSegmentAllowed),
                pathEncoded != value {
                secrets["\(name)_url_path"] = pathEncoded
            }
            if let queryEncoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                queryEncoded != value {
                secrets["\(name)_url_query"] = queryEncoded
            }
            if let strictQueryEncoded = value.addingPercentEncoding(
                withAllowedCharacters: .agentChannelQueryValueAllowed
            ), strictQueryEncoded != value {
                secrets["\(name)_url_query_strict"] = strictQueryEncoded
            }
        }
    }

    func redact(_ text: String) -> String {
        lock.withLock { SecretScrubber.scrub(text, secrets: secrets) }
    }

    func redactJSON(_ value: Any) -> Any {
        if let string = value as? String {
            return redact(string)
        }
        if let dict = value as? [String: Any] {
            var redacted: [String: Any] = [:]
            for (key, value) in dict {
                redacted[key] = redactJSON(value)
            }
            return redacted
        }
        if let array = value as? [Any] {
            return array.map { redactJSON($0) }
        }
        return value
    }
}

private struct AgentChannelTemplateContext {
    var input: [String: AgentChannelTemplateValue]
    var connection: AgentChannelConnection
    var secretResolver: any AgentChannelSecretResolving
    var redactor: AgentChannelSecretRedactor
    var idempotencyKey: String?
}

private enum AgentChannelTemplateValue: Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case stringArray([String])

    var rawString: String {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .stringArray(let value):
            return value.joined(separator: ",")
        }
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var stringArrayValue: [String]? {
        if case .stringArray(let value) = self { return value }
        return nil
    }

    func replacement(for mode: AgentChannelTemplateMode) throws -> String {
        switch mode {
        case .pathSegment:
            return rawString.addingPercentEncoding(withAllowedCharacters: .agentChannelPathSegmentAllowed) ?? ""
        case .rawString:
            return rawString
        case .jsonBody:
            return try jsonReplacement()
        }
    }

    private func jsonReplacement() throws -> String {
        switch self {
        case .string(let value):
            let data = try JSONSerialization.data(withJSONObject: [value], options: [])
            guard let encoded = String(bytes: data, encoding: .utf8) else {
                throw AgentChannelCustomJSONRunnerError.invalidRequest("JSON string encoding failed.")
            }
            return String(encoded.dropFirst().dropLast())
        case .int(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .stringArray(let value):
            let data = try JSONSerialization.data(withJSONObject: value, options: [])
            guard let encoded = String(bytes: data, encoding: .utf8) else {
                throw AgentChannelCustomJSONRunnerError.invalidRequest("JSON array encoding failed.")
            }
            return encoded
        }
    }
}

private enum AgentChannelTemplateMode {
    case pathSegment
    case rawString
    case jsonBody
}

private enum AgentChannelTemplateRenderer {
    struct PlaceholderSummary {
        var inputs = Set<String>()
        var secrets = Set<String>()
    }

    static func placeholders(in templates: [String]) -> PlaceholderSummary {
        var summary = PlaceholderSummary()
        for template in templates {
            var searchStart = template.startIndex
            while let open = template.range(of: "{{", range: searchStart..<template.endIndex),
                let close = template.range(of: "}}", range: open.upperBound..<template.endIndex) {
                let token = template[open.upperBound..<close.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if token.hasPrefix("input.") {
                    summary.inputs.insert(String(token.dropFirst("input.".count)))
                } else if token.hasPrefix("secret.") {
                    summary.secrets.insert(String(token.dropFirst("secret.".count)))
                }
                searchStart = close.upperBound
            }
        }
        return summary
    }

    static func render(
        _ template: String,
        context: AgentChannelTemplateContext,
        mode: AgentChannelTemplateMode
    ) throws -> String {
        var rendered = ""
        var searchStart = template.startIndex
        while let open = template.range(of: "{{", range: searchStart..<template.endIndex) {
            rendered += String(template[searchStart..<open.lowerBound])
            guard let close = template.range(of: "}}", range: open.upperBound..<template.endIndex) else {
                throw AgentChannelCustomJSONRunnerError.invalidTemplate("Unclosed placeholder.")
            }
            let token = template[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rendered += try replacement(for: token, context: context, mode: mode)
            searchStart = close.upperBound
        }
        rendered += String(template[searchStart..<template.endIndex])
        if rendered.contains("}}") {
            throw AgentChannelCustomJSONRunnerError.invalidTemplate("Unexpected closing placeholder marker.")
        }
        return rendered
    }

    private static func replacement(
        for token: String,
        context: AgentChannelTemplateContext,
        mode: AgentChannelTemplateMode
    ) throws -> String {
        guard token.range(of: #"^[A-Za-z][A-Za-z0-9_]*\.[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
        else {
            throw AgentChannelCustomJSONRunnerError.invalidTemplate("Unsupported placeholder `\(token)`.")
        }
        let parts = token.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw AgentChannelCustomJSONRunnerError.invalidTemplate("Unsupported placeholder `\(token)`.")
        }
        switch parts[0] {
        case "input":
            guard let value = context.input[parts[1]] else {
                throw AgentChannelCustomJSONRunnerError.missingInput(parts[1])
            }
            return try value.replacement(for: mode)
        case "connection":
            let value: AgentChannelTemplateValue
            switch parts[1] {
            case "id":
                value = .string(context.connection.id)
            case "name":
                value = .string(context.connection.name)
            case "kind":
                value = .string(context.connection.kind.rawValue)
            default:
                throw AgentChannelCustomJSONRunnerError.invalidTemplate("Unknown connection field `\(parts[1])`.")
            }
            return try value.replacement(for: mode)
        case "secret":
            guard let reference = context.connection.secrets.first(where: { $0.name == parts[1] }) else {
                throw AgentChannelCustomJSONRunnerError.missingSecret(parts[1])
            }
            guard let secret = context.secretResolver.secret(
                named: reference.name,
                keychainId: reference.keychainId,
                connection: context.connection
            ) else {
                throw AgentChannelCustomJSONRunnerError.missingSecret(parts[1])
            }
            context.redactor.register(name: reference.name, value: secret)
            return try AgentChannelTemplateValue.string(secret).replacement(for: mode)
        case "idempotency":
            guard parts[1] == "key", let idempotencyKey = context.idempotencyKey else {
                throw AgentChannelCustomJSONRunnerError.missingInput(token)
            }
            return try AgentChannelTemplateValue.string(idempotencyKey).replacement(for: mode)
        default:
            throw AgentChannelCustomJSONRunnerError.invalidTemplate("Unsupported placeholder namespace `\(parts[0])`.")
        }
    }
}

extension AgentChannelCustomJSONRunner {
    private enum BlockedURLMessage {
        static let baseURLNotAbsolute = "baseURL is not an absolute HTTP URL"
        static let userinfoNotAllowed = "userinfo in URLs is not allowed"
        static let actionPathNotRelative = "action path must be a relative path"
        static let missingSchemeOrHost = "missing scheme or host"
        static let plainHTTPDisabled = "plain HTTP is disabled for this channel"

        static func schemeNotAllowed(_ scheme: String) -> String {
            "scheme `\(scheme)` is not allowed"
        }

        static func hostNotAllowed(_ host: String) -> String {
            "host `\(host)` is not in allowedHosts"
        }
    }

    private static func renderedURL(
        configuration: AgentChannelCustomHTTPConfiguration,
        action: AgentChannelCustomHTTPAction,
        context: AgentChannelTemplateContext
    ) throws -> URL {
        guard let base = URL(string: configuration.baseURL),
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
            let baseHost = components.host?.lowercased()
        else {
            throw AgentChannelCustomJSONRunnerError.blockedURL(BlockedURLMessage.baseURLNotAbsolute)
        }
        guard components.user == nil, components.password == nil else {
            throw AgentChannelCustomJSONRunnerError.blockedURL(BlockedURLMessage.userinfoNotAllowed)
        }
        try validateURL(base, configuration: configuration)

        let renderedPath = try AgentChannelTemplateRenderer.render(
            action.path,
            context: context,
            mode: .pathSegment
        )
        guard renderedPath.hasPrefix("/") else {
            throw AgentChannelCustomJSONRunnerError.invalidRequest("Action path must start with `/`.")
        }
        guard !renderedPath.hasPrefix("//"),
            !renderedPath.contains("://"),
            !renderedPath.contains("?"),
            !renderedPath.contains("#"),
            renderedPath.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw AgentChannelCustomJSONRunnerError.blockedURL(BlockedURLMessage.actionPathNotRelative)
        }

        let basePath = components.percentEncodedPath
        let combinedPath =
            basePath.isEmpty || basePath == "/"
            ? renderedPath
            : basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + renderedPath
        components.percentEncodedPath = combinedPath.hasPrefix("/") ? combinedPath : "/" + combinedPath

        var queryItems = components.percentEncodedQueryItems ?? []
        for key in action.query.keys.sorted() {
            guard key.rangeOfCharacter(from: .newlines) == nil else {
                throw AgentChannelCustomJSONRunnerError.invalidRequest("Query key contains a newline.")
            }
            let value = try AgentChannelTemplateRenderer.render(
                action.query[key] ?? "",
                context: context,
                mode: .rawString
            )
            queryItems.append(
                URLQueryItem(
                    name: try percentEncodedQueryComponent(key, label: "query key"),
                    value: try percentEncodedQueryComponent(value, label: "query value")
                )
            )
        }
        components.percentEncodedQueryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw AgentChannelCustomJSONRunnerError.invalidRequest("Could not build request URL.")
        }
        try validateURL(url, configuration: configuration, baseHost: baseHost)
        return url
    }

    private static func validateURL(
        _ url: URL,
        configuration: AgentChannelCustomHTTPConfiguration,
        baseHost: String? = nil
    ) throws {
        guard let scheme = url.scheme?.lowercased(), let rawHost = url.host else {
            throw AgentChannelCustomJSONRunnerError.blockedURL(BlockedURLMessage.missingSchemeOrHost)
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if let blocked = blockedHostReason(host) {
            throw AgentChannelCustomJSONRunnerError.blockedURL(blocked)
        }
        if scheme == "http" && !configuration.allowInsecureHTTP {
            throw AgentChannelCustomJSONRunnerError.blockedURL(BlockedURLMessage.plainHTTPDisabled)
        }
        guard scheme == "https" || (scheme == "http" && configuration.allowInsecureHTTP) else {
            throw AgentChannelCustomJSONRunnerError.blockedURL(BlockedURLMessage.schemeNotAllowed(scheme))
        }
        let allowedHosts = effectiveAllowedHosts(configuration: configuration, baseHost: baseHost ?? host)
        guard allowedHosts.contains(host) else {
            throw AgentChannelCustomJSONRunnerError.blockedURL(BlockedURLMessage.hostNotAllowed(host))
        }
    }

    static func validateConfigurationURL(_ configuration: AgentChannelCustomHTTPConfiguration) throws {
        guard let url = URL(string: configuration.baseURL) else {
            throw AgentChannelCustomJSONRunnerError.blockedURL(BlockedURLMessage.baseURLNotAbsolute)
        }
        try validateURL(url, configuration: configuration)
    }

    private static func effectiveAllowedHosts(
        configuration: AgentChannelCustomHTTPConfiguration,
        baseHost: String? = nil
    ) -> [String] {
        if !configuration.allowedHosts.isEmpty {
            return configuration.allowedHosts
        }
        guard let baseHost else {
            guard let host = URL(string: configuration.baseURL)?.host else { return [] }
            return [host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()]
        }
        return [baseHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()]
    }

    private static func diagnosticURLStatus(
        configuration: AgentChannelCustomHTTPConfiguration
    ) -> (redactedBaseURL: String, failures: [String]) {
        guard let url = URL(string: configuration.baseURL) else {
            return (configuration.baseURL, ["baseURL is not a valid URL."])
        }
        do {
            try validateURL(url, configuration: configuration)
            return (url.absoluteString, [])
        } catch {
            return (url.absoluteString, [error.localizedDescription])
        }
    }

    private static func blockedHostReason(_ host: String) -> String? {
        if host == "localhost" || host == "ip6-localhost" || host == "ip6-loopback" {
            return "localhost is blocked"
        }
        if host.contains(":") {
            if host == "::1" { return "loopback IPv6 is blocked" }
            if host == "::" { return "unspecified IPv6 is blocked" }
            if host.hasPrefix("fe80:") { return "link-local IPv6 is blocked" }
            if host.hasPrefix("fc") || host.hasPrefix("fd") { return "unique-local IPv6 is blocked" }
            if let v4 = embeddedIPv4(in: host), let blocked = blockedIPv4Reason(v4) {
                return "IPv6-mapped \(blocked)"
            }
            return nil
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if labels.count == 1, isNonCanonicalIPv4Literal(labels[0]) {
            return "non-canonical IPv4 literal \(host) is blocked"
        }
        let octets: [UInt8]
        if labels.count == 4 {
            var parsed: [UInt8] = []
            for label in labels {
                guard isCanonicalDecimalIPv4Octet(label), let octet = UInt8(label) else {
                    return "non-canonical IPv4 literal \(host) is blocked"
                }
                parsed.append(octet)
            }
            octets = parsed
        } else {
            guard labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
            return "non-canonical IPv4 literal \(host) is blocked"
        }
        return blockedIPv4Reason(octets)
    }

    private static func isCanonicalDecimalIPv4Octet(_ label: String) -> Bool {
        guard !label.isEmpty, label.allSatisfy(\.isNumber) else { return false }
        guard label == "0" || !label.hasPrefix("0") else { return false }
        return UInt8(label) != nil
    }

    private static func isNonCanonicalIPv4Literal(_ host: String) -> Bool {
        if host.allSatisfy(\.isNumber) { return true }
        if host.lowercased().hasPrefix("0x") { return true }
        return false
    }

    private static func embeddedIPv4(in host: String) -> [UInt8]? {
        guard let lastColon = host.lastIndex(of: ":") else { return nil }
        let tail = String(host[host.index(after: lastColon)...])
        let octets = tail.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }

    private static func blockedIPv4Reason(_ octets: [UInt8]) -> String? {
        let (a, b) = (octets[0], octets[1])
        let dotted = "\(octets[0]).\(octets[1]).\(octets[2]).\(octets[3])"
        if a == 127 { return "IPv4 loopback \(dotted) is blocked" }
        if a == 10 { return "RFC1918 10.0.0.0/8 \(dotted) is blocked" }
        if a == 172 && b >= 16 && b <= 31 { return "RFC1918 172.16.0.0/12 \(dotted) is blocked" }
        if a == 192 && b == 168 { return "RFC1918 192.168.0.0/16 \(dotted) is blocked" }
        if a == 0 { return "RFC1122 0.0.0.0/8 \(dotted) is blocked" }
        if a == 169 && b == 254 { return "link-local/cloud metadata \(dotted) is blocked" }
        if a == 100 && b >= 64 && b <= 127 { return "carrier-grade NAT \(dotted) is blocked" }
        if a >= 224 && a <= 239 { return "multicast \(dotted) is blocked" }
        return nil
    }

    private static func validateHTTPMethodToken(_ method: String) throws {
        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard !method.isEmpty,
            method.rangeOfCharacter(from: allowedCharacters.inverted) == nil
        else {
            throw AgentChannelCustomJSONRunnerError.invalidRequest("HTTP method must be an uppercase token.")
        }
    }

    private static func validateHeaderName(_ name: String) throws {
        let forbidden = ["host", "content-length", "connection", "transfer-encoding"]
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")
        guard !name.isEmpty,
            name.rangeOfCharacter(from: allowed.inverted) == nil,
            !forbidden.contains(name.lowercased())
        else {
            throw AgentChannelCustomJSONRunnerError.invalidRequest("Header `\(name)` is not allowed.")
        }
    }

    private static func headerValidationFailures(_ names: [String], actionName: String) -> [String] {
        names.compactMap { name in
            do {
                try validateHeaderName(name)
                return nil
            } catch {
                return "Action `\(actionName)` \(error.localizedDescription)"
            }
        }
    }

    private static func validateHeaderValue(_ value: String) throws {
        guard value.rangeOfCharacter(from: .newlines) == nil else {
            throw AgentChannelCustomJSONRunnerError.invalidRequest("Header values must not contain newlines.")
        }
    }

    private static func percentEncodedQueryComponent(_ value: String, label: String) throws -> String {
        guard value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw AgentChannelCustomJSONRunnerError.invalidRequest("\(label) contains control characters.")
        }
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: .agentChannelQueryValueAllowed) else {
            throw AgentChannelCustomJSONRunnerError.invalidRequest("\(label) could not be percent encoded.")
        }
        return encoded
    }

    private static func isJSONContentType(_ value: String) -> Bool {
        value.lowercased().contains("json")
    }

    private static func bodyTemplateContainsPlaceholders(_ value: String) -> Bool {
        value.contains("{{")
    }

    private static func validateJSONBody(_ body: String) throws {
        guard let data = body.data(using: .utf8) else {
            throw AgentChannelCustomJSONRunnerError.invalidRequest("Body is not UTF-8.")
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AgentChannelCustomJSONRunnerError.invalidTemplate("Rendered JSON body is not valid JSON.")
        }
    }

    private static func arrayValue(_ json: Any, path: String) throws -> [[String: Any]] {
        try AgentChannelCustomHTTPResponseMapping.validatePath(path)
        guard let value = value(in: json, path: path) else {
            throw AgentChannelCustomJSONRunnerError.invalidResponse(
                "Missing array at response mapping path `\(path)`.",
                partialWriteStatus: nil
            )
        }
        if let array = value as? [[String: Any]] {
            return array
        }
        if let array = value as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        throw AgentChannelCustomJSONRunnerError.invalidResponse(
            "Response mapping path `\(path)` was not an array.",
            partialWriteStatus: nil
        )
    }

    private static func stringValue(_ json: Any, path: String) throws -> String? {
        try AgentChannelCustomHTTPResponseMapping.validatePath(path)
        guard let value = value(in: json, path: path) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func value(in json: Any, path: String) -> Any? {
        if path == "$" || path.isEmpty { return json }
        var current: Any? = json
        let normalizedPath = path.hasPrefix("$.") ? String(path.dropFirst(2)) : path
        for rawPart in normalizedPath.split(separator: ".").map(String.init) {
            guard let value = current else { return nil }
            if let dict = value as? [String: Any] {
                current = dict[rawPart]
            } else if let array = value as? [Any], let index = Int(rawPart), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

extension CharacterSet {
    fileprivate static let agentChannelPathSegmentAllowed =
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    fileprivate static let agentChannelQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return allowed
    }()
}
