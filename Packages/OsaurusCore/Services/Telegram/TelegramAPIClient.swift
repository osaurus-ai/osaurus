//
//  TelegramAPIClient.swift
//  osaurus
//
//  Minimal Telegram Bot API client for the native agent channel.
//

import Foundation

struct TelegramUser: Codable, Equatable, Sendable {
    let id: Int64
    let isBot: Bool
    let firstName: String
    let lastName: String?
    let username: String?

    enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case firstName = "first_name"
        case lastName = "last_name"
        case username
    }

    var displayName: String {
        if let username, !username.isEmpty { return "@\(username)" }
        if let lastName, !lastName.isEmpty { return "\(firstName) \(lastName)" }
        return firstName
    }
}

struct TelegramChat: Codable, Equatable, Sendable {
    let id: Int64
    let type: String
    let title: String?
    let username: String?
    let firstName: String?
    let lastName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case username
        case firstName = "first_name"
        case lastName = "last_name"
    }

    var stableId: String { "\(id)" }

    var displayName: String {
        if let title, !title.isEmpty { return title }
        if let username, !username.isEmpty { return "@\(username)" }
        if let firstName, let lastName, !lastName.isEmpty { return "\(firstName) \(lastName)" }
        if let firstName, !firstName.isEmpty { return firstName }
        return stableId
    }
}

struct TelegramMessageReference: Codable, Equatable, Sendable {
    let messageId: Int

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
    }
}

struct TelegramMessage: Codable, Equatable, Sendable {
    let messageId: Int
    let date: Int
    let chat: TelegramChat
    let from: TelegramUser?
    let senderChat: TelegramChat?
    let text: String?
    let caption: String?
    let replyToMessage: TelegramMessageReference?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case date
        case chat
        case from
        case senderChat = "sender_chat"
        case text
        case caption
        case replyToMessage = "reply_to_message"
    }

    var contentText: String {
        text ?? caption ?? ""
    }
}

struct TelegramUpdate: Codable, Equatable, Sendable {
    let updateId: Int64
    let message: TelegramMessage?
    let editedMessage: TelegramMessage?
    let channelPost: TelegramMessage?
    let editedChannelPost: TelegramMessage?

    enum CodingKeys: String, CodingKey {
        case updateId = "update_id"
        case message
        case editedMessage = "edited_message"
        case channelPost = "channel_post"
        case editedChannelPost = "edited_channel_post"
    }

    var primaryMessage: TelegramMessage? {
        message ?? editedMessage ?? channelPost ?? editedChannelPost
    }
}

struct TelegramWebhookInfo: Codable, Equatable, Sendable {
    let url: String
    let pendingUpdateCount: Int?
    let lastErrorMessage: String?

    enum CodingKeys: String, CodingKey {
        case url
        case pendingUpdateCount = "pending_update_count"
        case lastErrorMessage = "last_error_message"
    }

    init(url: String, pendingUpdateCount: Int? = nil, lastErrorMessage: String? = nil) {
        self.url = url
        self.pendingUpdateCount = pendingUpdateCount
        self.lastErrorMessage = lastErrorMessage
    }

    /// Telegram reports an empty `url` when no webhook is registered.
    var isRegistered: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum TelegramDeliveryStatus: String, Codable, Equatable, Sendable {
    case accepted
    case sent
    case duplicate
    case ignored
    case unauthorized
    case failed
}

struct TelegramReadRequest: Equatable, Sendable {
    let chatId: String
    let limit: Int?
}

struct TelegramWriteRequest: Equatable, Sendable {
    let chatId: String
    let text: String
    let replyToMessageId: Int?
    let confirmSend: Bool
}

struct TelegramNormalizedInboundEvent: Equatable, Sendable {
    let providerEventId: String
    let roomId: String
    let providerMessageId: String
    let content: String
    let senderId: String?
    let authorName: String?
    let isBotMessage: Bool
    let isSelfMessage: Bool
    let providerTimestamp: String
    let payloadJSON: String
}

struct TelegramReceiveResult: Equatable, Sendable {
    let providerEventId: String
    let roomId: String?
    let providerMessageId: String?
    let status: TelegramDeliveryStatus
    let reason: String?
}

struct TelegramReceiveBatchResult: Equatable, Sendable {
    let source: String
    let received: Int
    let stored: Int
    let results: [TelegramReceiveResult]
}

enum TelegramAPIError: LocalizedError, Equatable, Sendable {
    case invalidToken
    case forbidden(String)
    case conflict(String)
    case notFound(String)
    case rateLimited(String, retryAfter: Int?)
    case invalidResponse(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Telegram rejected the bot token."
        case .rateLimited(let message, _):
            return message
        case .forbidden(let message),
            .conflict(let message),
            .notFound(let message),
            .invalidResponse(let message),
            .requestFailed(let message):
            return message
        }
    }
}

protocol TelegramAPIClientProtocol: Sendable {
    func getMe(token: String) async throws -> TelegramUser
    func getChat(chatId: String, token: String) async throws -> TelegramChat
    func getWebhookInfo(token: String) async throws -> TelegramWebhookInfo
    func deleteWebhook(token: String) async throws -> Bool
    func getUpdates(offset: Int64?, limit: Int, timeout: Int, token: String) async throws -> [TelegramUpdate]
    func sendMessage(
        chatId: String,
        text: String,
        replyToMessageId: Int?,
        token: String
    ) async throws -> TelegramMessage
}

final class TelegramAPIClient: TelegramAPIClientProtocol, @unchecked Sendable {
    private let baseURL: URL
    private let sessionProvider: @Sendable () -> URLSession

    init(
        baseURL: URL = URL(string: "https://api.telegram.org")!,
        sessionProvider: @escaping @Sendable () -> URLSession = { GlobalProxySettings.sharedSession() }
    ) {
        self.baseURL = baseURL
        self.sessionProvider = sessionProvider
    }

    func getMe(token: String) async throws -> TelegramUser {
        try await post(method: "getMe", token: token, body: [:])
    }

    func getChat(chatId: String, token: String) async throws -> TelegramChat {
        try await post(method: "getChat", token: token, body: ["chat_id": chatId])
    }

    func getWebhookInfo(token: String) async throws -> TelegramWebhookInfo {
        try await post(method: "getWebhookInfo", token: token, body: [:])
    }

    func deleteWebhook(token: String) async throws -> Bool {
        // Pending updates are preserved so they flow to getUpdates afterwards.
        try await post(method: "deleteWebhook", token: token, body: [:])
    }

    func getUpdates(offset: Int64?, limit: Int, timeout: Int, token: String) async throws -> [TelegramUpdate] {
        let boundedTimeout = TelegramConnectionConfiguration.clampLongPollingTimeoutSeconds(timeout)
        var body: [String: Any] = [
            "limit": TelegramConnectionConfiguration.clampLongPollingLimit(limit),
            "timeout": boundedTimeout,
            "allowed_updates": ["message", "edited_message", "channel_post", "edited_channel_post"],
        ]
        if let offset {
            body["offset"] = offset
        }
        return try await post(
            method: "getUpdates",
            token: token,
            body: body,
            timeoutInterval: TimeInterval(boundedTimeout + 10)
        )
    }

    func sendMessage(
        chatId: String,
        text: String,
        replyToMessageId: Int?,
        token: String
    ) async throws -> TelegramMessage {
        var body: [String: Any] = [
            "chat_id": chatId,
            "text": text,
            "disable_web_page_preview": true,
        ]
        if let replyToMessageId {
            body["reply_to_message_id"] = replyToMessageId
        }
        return try await post(method: "sendMessage", token: token, body: body)
    }

    private func post<T: Decodable>(
        method: String,
        token: String,
        body: [String: Any],
        timeoutInterval: TimeInterval? = nil
    ) async throws -> T {
        var request = try makeRequest(method: method, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .osaurusCanonical)
        return try await perform(request, token: token)
    }

    private func makeRequest(method: String, token: String) throws -> URLRequest {
        guard !method.contains("/") else {
            throw TelegramAPIError.invalidResponse("Telegram method name is invalid.")
        }
        let url = baseURL
            .appendingPathComponent("bot\(token)")
            .appendingPathComponent(method)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Osaurus Telegram Native Agent Channel", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest, token: String) async throws -> T {
        do {
            let (data, response) = try await sessionProvider().data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TelegramAPIError.invalidResponse("Telegram returned a non-HTTP response.")
            }
            let envelope = try decodeEnvelope(T.self, from: data, token: token)
            guard (200 ..< 300).contains(http.statusCode), envelope.ok, let result = envelope.result else {
                throw mapHTTPError(status: http.statusCode, envelope: envelope, token: token)
            }
            return result
        } catch let error as TelegramAPIError {
            throw error
        } catch {
            throw TelegramAPIError.requestFailed(
                TelegramSecurity.redact(error.localizedDescription, token: token)
            )
        }
    }

    private func decodeEnvelope<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        token: String
    ) throws -> TelegramAPIEnvelope<T> {
        do {
            return try JSONDecoder().decode(TelegramAPIEnvelope<T>.self, from: data)
        } catch {
            throw TelegramAPIError.invalidResponse(
                TelegramSecurity.redact("Telegram response could not be decoded.", token: token)
            )
        }
    }

    private func mapHTTPError<T>(
        status: Int,
        envelope: TelegramAPIEnvelope<T>,
        token: String
    ) -> TelegramAPIError {
        let message = TelegramSecurity.redact(
            envelope.description ?? "Telegram request failed with HTTP \(status).",
            token: token
        )
        switch status {
        case 401:
            return .invalidToken
        case 403:
            return .forbidden(message)
        case 409:
            return .conflict(message)
        case 404:
            return .notFound(message)
        case 429:
            return .rateLimited(message, retryAfter: envelope.parameters?.retryAfter)
        default:
            return .requestFailed(message)
        }
    }
}

private struct TelegramAPIEnvelope<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let description: String?
    let errorCode: Int?
    let parameters: TelegramResponseParameters?

    enum CodingKeys: String, CodingKey {
        case ok
        case result
        case description
        case errorCode = "error_code"
        case parameters
    }
}

private struct TelegramResponseParameters: Decodable {
    let retryAfter: Int?

    enum CodingKeys: String, CodingKey {
        case retryAfter = "retry_after"
    }
}
