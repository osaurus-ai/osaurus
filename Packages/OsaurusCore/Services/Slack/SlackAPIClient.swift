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
    let isChannel: Bool
    let isGroup: Bool
    let isIM: Bool
    let isMPIM: Bool
    let isPrivate: Bool
    let isArchived: Bool
    let isMember: Bool

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

    init(
        id: String,
        name: String? = nil,
        isChannel: Bool = false,
        isGroup: Bool = false,
        isIM: Bool = false,
        isMPIM: Bool = false,
        isPrivate: Bool = false,
        isArchived: Bool = false,
        isMember: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isChannel = isChannel
        self.isGroup = isGroup
        self.isIM = isIM
        self.isMPIM = isMPIM
        self.isPrivate = isPrivate
        self.isArchived = isArchived
        self.isMember = isMember
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            isChannel: try container.decodeIfPresent(Bool.self, forKey: .isChannel) ?? false,
            isGroup: try container.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false,
            isIM: try container.decodeIfPresent(Bool.self, forKey: .isIM) ?? false,
            isMPIM: try container.decodeIfPresent(Bool.self, forKey: .isMPIM) ?? false,
            isPrivate: try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false,
            isArchived: try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false,
            isMember: try container.decodeIfPresent(Bool.self, forKey: .isMember) ?? false
        )
    }

    var displayName: String {
        guard let name, !name.isEmpty else { return id }
        return name
    }

    var kind: String {
        if isIM { return "im" }
        if isMPIM { return "mpim" }
        if isGroup { return "private_channel" }
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

/// One page of `conversations.list` results plus the cursor for the next page.
struct SlackConversationPage: Equatable, Sendable {
    let conversations: [SlackConversation]
    /// Cursor for the next page; nil when Slack reported no further pages.
    let nextCursor: String?

    init(conversations: [SlackConversation], nextCursor: String? = nil) {
        self.conversations = conversations
        self.nextCursor = Self.normalizedCursor(nextCursor)
    }

    static func normalizedCursor(_ cursor: String?) -> String? {
        guard let trimmed = cursor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// One page of `conversations.history` / `conversations.replies` results.
struct SlackMessagePage: Equatable, Sendable {
    let messages: [SlackMessage]
    /// True when Slack reported more messages beyond this page.
    let hasMore: Bool
    /// Cursor for the next page; nil when Slack reported no further pages.
    let nextCursor: String?

    init(messages: [SlackMessage], hasMore: Bool = false, nextCursor: String? = nil) {
        self.messages = messages
        self.nextCursor = SlackConversationPage.normalizedCursor(nextCursor)
        self.hasMore = hasMore || self.nextCursor != nil
    }
}

struct SlackOutboundMessageRequest: Equatable, Sendable {
    let channelId: String
    let content: String
    let threadTs: String?
    let parse: String
    let linkNames: Bool
    let unfurlLinks: Bool
    let unfurlMedia: Bool
    let replyBroadcast: Bool

    init(
        channelId: String,
        content: String,
        threadTs: String? = nil,
        parse: String = "none",
        linkNames: Bool = false,
        unfurlLinks: Bool = false,
        unfurlMedia: Bool = false,
        replyBroadcast: Bool = false
    ) {
        self.channelId = channelId
        self.content = content
        self.threadTs = threadTs
        self.parse = parse
        self.linkNames = linkNames
        self.unfurlLinks = unfurlLinks
        self.unfurlMedia = unfurlMedia
        self.replyBroadcast = replyBroadcast
    }

    var jsonBody: [String: Any] {
        var body: [String: Any] = [
            "channel": channelId,
            "text": content,
            "parse": parse,
            "link_names": linkNames,
            "unfurl_links": unfurlLinks,
            "unfurl_media": unfurlMedia,
            "reply_broadcast": replyBroadcast,
        ]
        if let threadTs, !threadTs.isEmpty {
            body["thread_ts"] = threadTs
        }
        return body
    }
}

enum SlackAPIError: LocalizedError, Equatable, Sendable {
    case invalidToken
    case missingPermissions(String)
    case notFound(String)
    case rateLimited(String, retryAfter: TimeInterval?)
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
        case .rateLimited(let message, _):
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
    func openSocketModeConnection(appToken: String) async throws -> URL
    func conversations(token: String, limit: Int, cursor: String?) async throws -> SlackConversationPage
    func messages(channelId: String, token: String, limit: Int, cursor: String?) async throws -> SlackMessagePage
    func threadMessages(
        channelId: String,
        threadTs: String,
        token: String,
        limit: Int,
        cursor: String?
    ) async throws -> SlackMessagePage
    func sendMessage(_ request: SlackOutboundMessageRequest, token: String) async throws -> SlackMessage
}

final class SlackAPIClient: SlackAPIClientProtocol, @unchecked Sendable {
    private struct SocketModeConnectionPayload: Decodable {
        let url: String
    }

    private struct ResponseMetadataPayload: Decodable {
        let nextCursor: String?

        enum CodingKeys: String, CodingKey {
            case nextCursor = "next_cursor"
        }
    }

    private struct ConversationListPayload: Decodable {
        let channels: [SlackConversation]
        let responseMetadata: ResponseMetadataPayload?

        enum CodingKeys: String, CodingKey {
            case channels
            case responseMetadata = "response_metadata"
        }
    }

    private struct MessageListPayload: Decodable {
        let messages: [SlackMessage]
        let hasMore: Bool
        let responseMetadata: ResponseMetadataPayload?

        enum CodingKeys: String, CodingKey {
            case messages
            case hasMore = "has_more"
            case responseMetadata = "response_metadata"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            messages = try container.decode([SlackMessage].self, forKey: .messages)
            hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
            responseMetadata = try container.decodeIfPresent(
                ResponseMetadataPayload.self,
                forKey: .responseMetadata
            )
        }
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

    func openSocketModeConnection(appToken: String) async throws -> URL {
        let payload: SocketModeConnectionPayload = try await postForm(
            method: "apps.connections.open",
            token: appToken,
            form: [:]
        )
        guard let url = URL(string: payload.url),
              ["wss", "ws"].contains(url.scheme?.lowercased() ?? "")
        else {
            throw SlackAPIError.invalidResponse("Slack Socket Mode response did not include a WebSocket URL.")
        }
        return url
    }

    func conversations(token: String, limit: Int, cursor: String?) async throws -> SlackConversationPage {
        let safeLimit = SlackConnectionConfiguration.clampReadLimit(limit)
        var form = [
            "exclude_archived": "true",
            "limit": "\(safeLimit)",
            "types": "public_channel,private_channel,mpim,im",
        ]
        if let cursor = SlackConversationPage.normalizedCursor(cursor) {
            form["cursor"] = cursor
        }
        let payload: ConversationListPayload = try await postForm(
            method: "conversations.list",
            token: token,
            form: form
        )
        return SlackConversationPage(
            conversations: payload.channels,
            nextCursor: payload.responseMetadata?.nextCursor
        )
    }

    func messages(channelId: String, token: String, limit: Int, cursor: String?) async throws -> SlackMessagePage {
        try validateSlackId(channelId, label: "channel_id")
        let safeLimit = SlackConnectionConfiguration.clampReadLimit(limit)
        var form = [
            "channel": channelId,
            "inclusive": "true",
            "limit": "\(safeLimit)",
        ]
        if let cursor = SlackConversationPage.normalizedCursor(cursor) {
            form["cursor"] = cursor
        }
        let payload: MessageListPayload = try await postForm(
            method: "conversations.history",
            token: token,
            form: form
        )
        return SlackMessagePage(
            messages: payload.messages,
            hasMore: payload.hasMore,
            nextCursor: payload.responseMetadata?.nextCursor
        )
    }

    func threadMessages(
        channelId: String,
        threadTs: String,
        token: String,
        limit: Int,
        cursor: String?
    ) async throws -> SlackMessagePage {
        try validateSlackId(channelId, label: "channel_id")
        let safeLimit = SlackConnectionConfiguration.clampReadLimit(limit)
        var form = [
            "channel": channelId,
            "inclusive": "true",
            "limit": "\(safeLimit)",
            "ts": threadTs,
        ]
        if let cursor = SlackConversationPage.normalizedCursor(cursor) {
            form["cursor"] = cursor
        }
        let payload: MessageListPayload = try await postForm(
            method: "conversations.replies",
            token: token,
            form: form
        )
        return SlackMessagePage(
            messages: payload.messages,
            hasMore: payload.hasMore,
            nextCursor: payload.responseMetadata?.nextCursor
        )
    }

    func sendMessage(_ request: SlackOutboundMessageRequest, token: String) async throws -> SlackMessage {
        try validateSlackId(request.channelId, label: "channel_id")
        let payload: PostMessagePayload = try await postJSON(
            method: "chat.postMessage",
            token: token,
            body: request.jsonBody
        )
        if let message = payload.message {
            return message
        }
        if let ts = payload.ts {
            return SlackMessage(
                type: "message",
                user: nil,
                username: nil,
                botId: nil,
                text: request.content,
                ts: ts,
                threadTs: request.threadTs,
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
                let retryAfterHeader = http.value(forHTTPHeaderField: "Retry-After")
                let retryAfter = retryAfterHeader
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap(TimeInterval.init)
                    .map { max(0, $0) }
                let suffix = retryAfterHeader.map { " Retry after \($0) seconds." } ?? ""
                throw SlackAPIError.rateLimited(
                    "Slack rate limited this request.\(suffix)",
                    retryAfter: retryAfter
                )
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
            return .rateLimited(message, retryAfter: nil)
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
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct SlackStatusEnvelope: Decodable {
    let ok: Bool
    let error: String?
}
