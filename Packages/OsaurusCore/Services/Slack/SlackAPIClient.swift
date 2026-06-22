//
//  SlackAPIClient.swift
//  osaurus
//
//  Minimal Slack Web API client for the native Agent Channel adapter.
//

import Foundation

struct SlackAuthIdentity: Codable, Equatable, Sendable {
    let url: String?
    let team: String?
    let user: String?
    let teamId: String
    let userId: String?
    let botId: String?

    enum CodingKeys: String, CodingKey {
        case url
        case team
        case user
        case teamId = "team_id"
        case userId = "user_id"
        case botId = "bot_id"
    }
}

struct SlackConversation: Codable, Equatable, Sendable {
    let id: String
    let name: String?
    let isChannel: Bool?
    let isGroup: Bool?
    let isIM: Bool?
    let isMPIM: Bool?
    let isPrivate: Bool?
    let isArchived: Bool?
    let isMember: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isChannel = "is_channel"
        case isGroup = "is_group"
        case isIM = "is_im"
        case isMPIM = "is_mpim"
        case isPrivate = "is_private"
        case isArchived = "is_archived"
        case isMember = "is_member"
    }

    var displayName: String {
        guard let name, !name.isEmpty else { return id }
        return name
    }

    var kind: String {
        if isIM == true { return "im" }
        if isMPIM == true { return "mpim" }
        if isGroup == true { return "private_channel" }
        return "channel"
    }
}

struct SlackMessage: Codable, Equatable, Sendable {
    let type: String?
    let user: String?
    let username: String?
    let botId: String?
    let text: String?
    let ts: String
    let threadTs: String?
    let replyCount: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case user
        case username
        case botId = "bot_id"
        case text
        case ts
        case threadTs = "thread_ts"
        case replyCount = "reply_count"
    }
}

enum SlackAPIError: LocalizedError, Equatable, Sendable {
    case invalidToken
    case missingPermissions(String)
    case notFound(String)
    case rateLimited(String)
    case invalidResponse(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Slack rejected the bot token."
        case .missingPermissions(let message):
            return message
        case .notFound(let message):
            return message
        case .rateLimited(let message):
            return message
        case .invalidResponse(let message):
            return message
        case .requestFailed(let message):
            return message
        }
    }
}

protocol SlackAPIClientProtocol: Sendable {
    func authTest(token: String) async throws -> SlackAuthIdentity
    func conversations(token: String, limit: Int) async throws -> [SlackConversation]
    func messages(channelId: String, token: String, limit: Int) async throws -> [SlackMessage]
    func threadMessages(channelId: String, threadTs: String, token: String, limit: Int) async throws -> [SlackMessage]
    func sendMessage(channelId: String, content: String, threadTs: String?, token: String) async throws -> SlackMessage
}

final class SlackAPIClient: SlackAPIClientProtocol, @unchecked Sendable {
    private struct ConversationListPayload: Decodable {
        let channels: [SlackConversation]
    }

    private struct MessageListPayload: Decodable {
        let messages: [SlackMessage]
    }

    private struct PostMessagePayload: Decodable {
        let message: SlackMessage?
        let ts: String?
        let channel: String?
    }

    private let baseURL: URL
    private let sessionProvider: @Sendable () -> URLSession

    init(
        baseURL: URL = URL(string: "https://slack.com/api")!,
        sessionProvider: @escaping @Sendable () -> URLSession = { GlobalProxySettings.sharedSession() }
    ) {
        self.baseURL = baseURL
        self.sessionProvider = sessionProvider
    }

    func authTest(token: String) async throws -> SlackAuthIdentity {
        try await postForm(method: "auth.test", token: token, form: [:])
    }

    func conversations(token: String, limit: Int) async throws -> [SlackConversation] {
        let safeLimit = SlackConnectionConfiguration.clampReadLimit(limit)
        let payload: ConversationListPayload = try await postForm(
            method: "conversations.list",
            token: token,
            form: [
                "exclude_archived": "true",
                "limit": "\(safeLimit)",
                "types": "public_channel,private_channel,mpim,im",
            ]
        )
        return payload.channels
    }

    func messages(channelId: String, token: String, limit: Int) async throws -> [SlackMessage] {
        try validateSlackId(channelId, label: "channel_id")
        let safeLimit = SlackConnectionConfiguration.clampReadLimit(limit)
        let payload: MessageListPayload = try await postForm(
            method: "conversations.history",
            token: token,
            form: [
                "channel": channelId,
                "inclusive": "true",
                "limit": "\(safeLimit)",
            ]
        )
        return payload.messages
    }

    func threadMessages(channelId: String, threadTs: String, token: String, limit: Int) async throws -> [SlackMessage] {
        try validateSlackId(channelId, label: "channel_id")
        let safeLimit = SlackConnectionConfiguration.clampReadLimit(limit)
        let payload: MessageListPayload = try await postForm(
            method: "conversations.replies",
            token: token,
            form: [
                "channel": channelId,
                "inclusive": "true",
                "limit": "\(safeLimit)",
                "ts": threadTs,
            ]
        )
        return payload.messages
    }

    func sendMessage(channelId: String, content: String, threadTs: String?, token: String) async throws -> SlackMessage {
        try validateSlackId(channelId, label: "channel_id")
        var body: [String: Any] = [
            "channel": channelId,
            "text": content,
            "parse": "none",
            "link_names": false,
            "unfurl_links": false,
            "unfurl_media": false,
            "reply_broadcast": false,
        ]
        if let threadTs, !threadTs.isEmpty {
            body["thread_ts"] = threadTs
        }
        let payload: PostMessagePayload = try await postJSON(method: "chat.postMessage", token: token, body: body)
        if let message = payload.message {
            return message
        }
        if let ts = payload.ts {
            return SlackMessage(
                type: "message",
                user: nil,
                username: nil,
                botId: nil,
                text: content,
                ts: ts,
                threadTs: threadTs,
                replyCount: nil
            )
        }
        throw SlackAPIError.invalidResponse("Slack postMessage response did not include a message timestamp.")
    }

    private func postForm<Payload: Decodable>(
        method: String,
        token: String,
        form: [String: String]
    ) async throws -> Payload {
        var request = makeRequest(method: method, token: token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { key, value in
                "\(Self.urlEncode(key))=\(Self.urlEncode(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8)
        return try await perform(request, token: token)
    }

    private func postJSON<Payload: Decodable>(
        method: String,
        token: String,
        body: [String: Any]
    ) async throws -> Payload {
        var request = makeRequest(method: method, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .osaurusCanonical)
        return try await perform(request, token: token)
    }

    private func makeRequest(method: String, token: String) -> URLRequest {
        let url = baseURL.appendingPathComponent(method)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Osaurus Slack Native Agent Channel", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return request
    }

    private func perform<Payload: Decodable>(_ request: URLRequest, token: String) async throws -> Payload {
        do {
            let (data, response) = try await sessionProvider().data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SlackAPIError.invalidResponse("Slack returned a non-HTTP response.")
            }
            guard http.statusCode != 429 else {
                throw SlackAPIError.rateLimited("Slack rate limited this request.")
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw mapHTTPError(status: http.statusCode, data: data, token: token)
            }
            do {
                let status = try JSONDecoder().decode(SlackStatusEnvelope.self, from: data)
                guard status.ok else {
                    throw mapSlackError(status.error, token: token)
                }
                return try JSONDecoder().decode(Payload.self, from: data)
            } catch let error as SlackAPIError {
                throw error
            } catch {
                throw SlackAPIError.invalidResponse("Slack response could not be decoded.")
            }
        } catch let error as SlackAPIError {
            throw error
        } catch {
            throw SlackAPIError.requestFailed(
                SlackSecurity.redact(error.localizedDescription, token: token)
            )
        }
    }

    private func mapHTTPError(status: Int, data: Data, token: String) -> SlackAPIError {
        let message = slackErrorMessage(from: data)
            .map { SlackSecurity.redact($0, token: token) }
        switch status {
        case 401:
            return .invalidToken
        case 403:
            return .missingPermissions(message ?? "Slack denied access for this bot or channel.")
        case 404:
            return .notFound(message ?? "Slack resource was not found.")
        default:
            return .requestFailed(message ?? "Slack request failed with HTTP \(status).")
        }
    }

    private func mapSlackError(_ error: String?, token: String) -> SlackAPIError {
        let code = error ?? "unknown_error"
        let message = SlackSecurity.redact("Slack API returned `\(code)`.", token: token)
        switch code {
        case "invalid_auth", "not_authed", "account_inactive", "token_revoked":
            return .invalidToken
        case "missing_scope", "no_permission", "not_in_channel", "is_archived", "restricted_action":
            return .missingPermissions(message)
        case "channel_not_found", "user_not_found", "team_not_found", "thread_not_found":
            return .notFound(message)
        case "ratelimited":
            return .rateLimited(message)
        default:
            return .requestFailed(message)
        }
    }

    private func slackErrorMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? String,
            !error.isEmpty
        else { return nil }
        return "Slack API returned `\(error)`."
    }

    private func validateSlackId(_ id: String, label: String) throws {
        guard SlackConnectionConfiguration.isValidSlackId(id) else {
            throw SlackAPIError.invalidResponse("Invalid Slack \(label).")
        }
    }

    private static func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

private struct SlackStatusEnvelope: Decodable {
    let ok: Bool
    let error: String?
}
