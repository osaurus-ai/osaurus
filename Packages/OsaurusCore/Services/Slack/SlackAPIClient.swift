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

struct SlackConversation: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String?
    /// For direct messages (`is_im`), the Slack user id of the person on the
    /// other side. DMs have no `name`, so this is the only way to label them.
    let user: String?
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
        case user
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
        user: String? = nil,
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
        self.user = user
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
            user: try container.decodeIfPresent(String.self, forKey: .user),
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

    /// Human name resolved against a `[userId: displayName]` map so direct
    /// messages read as the person's name instead of a raw `D…` id.
    func resolvedDisplayName(userNames: [String: String]) -> String {
        if let name, !name.isEmpty { return name }
        if isIM, let user, let personName = userNames[user], !personName.isEmpty {
            return personName
        }
        return id
    }

    var kind: String {
        if isIM { return "im" }
        if isMPIM { return "mpim" }
        if isGroup { return "private_channel" }
        return "channel"
    }
}

struct SlackUserProfile: Codable, Equatable, Sendable {
    let displayName: String?
    let realName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case realName = "real_name"
    }
}

struct SlackUser: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let teamId: String?
    let name: String?
    let realName: String?
    let profile: SlackUserProfile?
    let deleted: Bool
    let isBot: Bool
    let isAppUser: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case teamId = "team_id"
        case name
        case realName = "real_name"
        case profile
        case deleted
        case isBot = "is_bot"
        case isAppUser = "is_app_user"
    }

    init(
        id: String,
        teamId: String? = nil,
        name: String? = nil,
        realName: String? = nil,
        profile: SlackUserProfile? = nil,
        deleted: Bool = false,
        isBot: Bool = false,
        isAppUser: Bool = false
    ) {
        self.id = id
        self.teamId = teamId
        self.name = name
        self.realName = realName
        self.profile = profile
        self.deleted = deleted
        self.isBot = isBot
        self.isAppUser = isAppUser
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            teamId: try container.decodeIfPresent(String.self, forKey: .teamId),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            realName: try container.decodeIfPresent(String.self, forKey: .realName),
            profile: try container.decodeIfPresent(SlackUserProfile.self, forKey: .profile),
            deleted: try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false,
            isBot: try container.decodeIfPresent(Bool.self, forKey: .isBot) ?? false,
            isAppUser: try container.decodeIfPresent(Bool.self, forKey: .isAppUser) ?? false
        )
    }

    var displayName: String {
        for candidate in [profile?.displayName, realName, profile?.realName, name] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return id
    }
}

struct SlackFile: Codable, Equatable, Sendable {
    let id: String
    let name: String?
    let mimetype: String?
    let size: Int?
    let urlPrivate: String?
    let urlPrivateDownload: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case mimetype
        case size
        case urlPrivate = "url_private"
        case urlPrivateDownload = "url_private_download"
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
    let files: [SlackFile]

    enum CodingKeys: String, CodingKey {
        case type
        case user
        case username
        case botId = "bot_id"
        case text
        case ts
        case threadTs = "thread_ts"
        case replyCount = "reply_count"
        case files
    }

    init(
        type: String?,
        user: String?,
        username: String?,
        botId: String?,
        text: String?,
        ts: String,
        threadTs: String?,
        replyCount: Int?,
        files: [SlackFile] = []
    ) {
        self.type = type
        self.user = user
        self.username = username
        self.botId = botId
        self.text = text
        self.ts = ts
        self.threadTs = threadTs
        self.replyCount = replyCount
        self.files = files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try container.decodeIfPresent(String.self, forKey: .type),
            user: try container.decodeIfPresent(String.self, forKey: .user),
            username: try container.decodeIfPresent(String.self, forKey: .username),
            botId: try container.decodeIfPresent(String.self, forKey: .botId),
            text: try container.decodeIfPresent(String.self, forKey: .text),
            ts: try container.decode(String.self, forKey: .ts),
            threadTs: try container.decodeIfPresent(String.self, forKey: .threadTs),
            replyCount: try container.decodeIfPresent(Int.self, forKey: .replyCount),
            files: try container.decodeIfPresent([SlackFile].self, forKey: .files) ?? []
        )
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

struct SlackUserPage: Equatable, Sendable {
    let users: [SlackUser]
    let nextCursor: String?

    init(users: [SlackUser], nextCursor: String? = nil) {
        self.users = users
        self.nextCursor = SlackConversationPage.normalizedCursor(nextCursor)
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
    /// When true (the default for agent sends) the content is posted through
    /// `markdown_text`, so Slack renders standard Markdown natively instead of
    /// showing literal `**bold**` markup. `parse` only applies to the plain
    /// `text` mode.
    let useMarkdownText: Bool

    init(
        channelId: String,
        content: String,
        threadTs: String? = nil,
        parse: String = "none",
        linkNames: Bool = false,
        unfurlLinks: Bool = false,
        unfurlMedia: Bool = false,
        replyBroadcast: Bool = false,
        useMarkdownText: Bool = true
    ) {
        self.channelId = channelId
        self.content = content
        self.threadTs = threadTs
        self.parse = parse
        self.linkNames = linkNames
        self.unfurlLinks = unfurlLinks
        self.unfurlMedia = unfurlMedia
        self.replyBroadcast = replyBroadcast
        self.useMarkdownText = useMarkdownText
    }

    var jsonBody: [String: Any] {
        var body: [String: Any] = [
            "channel": channelId,
            "link_names": linkNames,
            "unfurl_links": unfurlLinks,
            "unfurl_media": unfurlMedia,
            "reply_broadcast": replyBroadcast,
        ]
        if useMarkdownText {
            body["markdown_text"] = content
        } else {
            body["text"] = content
            body["parse"] = parse
        }
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
    func users(token: String, limit: Int, cursor: String?) async throws -> SlackUserPage
    func messages(channelId: String, token: String, limit: Int, cursor: String?) async throws -> SlackMessagePage
    func threadMessages(
        channelId: String,
        threadTs: String,
        token: String,
        limit: Int,
        cursor: String?
    ) async throws -> SlackMessagePage
    func sendMessage(_ request: SlackOutboundMessageRequest, token: String) async throws -> SlackMessage
    func updateMessage(channelId: String, messageId: String, content: String, token: String) async throws -> SlackMessage
    func deleteMessage(channelId: String, messageId: String, token: String) async throws
    func addReaction(channelId: String, messageId: String, reaction: String, token: String) async throws
    func removeReaction(channelId: String, messageId: String, reaction: String, token: String) async throws
}

extension SlackAPIClientProtocol {
    func updateMessage(
        channelId _: String,
        messageId _: String,
        content _: String,
        token _: String
    ) async throws -> SlackMessage {
        throw SlackAPIError.invalidResponse("Slack message editing is not implemented by this client.")
    }

    func deleteMessage(channelId _: String, messageId _: String, token _: String) async throws {
        throw SlackAPIError.invalidResponse("Slack message deletion is not implemented by this client.")
    }

    func addReaction(
        channelId _: String,
        messageId _: String,
        reaction _: String,
        token _: String
    ) async throws {
        throw SlackAPIError.invalidResponse("Slack reactions are not implemented by this client.")
    }

    func removeReaction(
        channelId _: String,
        messageId _: String,
        reaction _: String,
        token _: String
    ) async throws {
        throw SlackAPIError.invalidResponse("Slack reactions are not implemented by this client.")
    }
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

    private struct UserListPayload: Decodable {
        let members: [SlackUser]
        let responseMetadata: ResponseMetadataPayload?

        enum CodingKeys: String, CodingKey {
            case members
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

    private struct EmptyPayload: Decodable {}

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

    func users(token: String, limit: Int, cursor: String?) async throws -> SlackUserPage {
        let safeLimit = min(max(limit, 1), 200)
        var form = ["limit": "\(safeLimit)"]
        if let cursor = SlackConversationPage.normalizedCursor(cursor) {
            form["cursor"] = cursor
        }
        let payload: UserListPayload = try await postForm(
            method: "users.list",
            token: token,
            form: form
        )
        return SlackUserPage(
            users: payload.members,
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

    func updateMessage(
        channelId: String,
        messageId: String,
        content: String,
        token: String
    ) async throws -> SlackMessage {
        try validateSlackId(channelId, label: "channel_id")
        let payload: PostMessagePayload = try await postJSON(
            method: "chat.update",
            token: token,
            body: [
                "channel": channelId,
                "ts": messageId,
                "markdown_text": content,
                "link_names": false,
            ]
        )
        if let message = payload.message { return message }
        return SlackMessage(
            type: "message",
            user: nil,
            username: nil,
            botId: nil,
            text: content,
            ts: payload.ts ?? messageId,
            threadTs: nil,
            replyCount: nil
        )
    }

    func deleteMessage(channelId: String, messageId: String, token: String) async throws {
        try validateSlackId(channelId, label: "channel_id")
        let _: EmptyPayload = try await postJSON(
            method: "chat.delete",
            token: token,
            body: ["channel": channelId, "ts": messageId]
        )
    }

    func addReaction(channelId: String, messageId: String, reaction: String, token: String) async throws {
        try validateSlackId(channelId, label: "channel_id")
        let _: EmptyPayload = try await postJSON(
            method: "reactions.add",
            token: token,
            body: ["channel": channelId, "timestamp": messageId, "name": reaction]
        )
    }

    func removeReaction(channelId: String, messageId: String, reaction: String, token: String) async throws {
        try validateSlackId(channelId, label: "channel_id")
        let _: EmptyPayload = try await postJSON(
            method: "reactions.remove",
            token: token,
            body: ["channel": channelId, "timestamp": messageId, "name": reaction]
        )
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
                    throw mapSlackError(
                        status.error,
                        needed: status.needed,
                        provided: status.provided,
                        token: token
                    )
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

    private func mapSlackError(
        _ error: String?,
        needed: String? = nil,
        provided: String? = nil,
        token: String
    ) -> SlackAPIError {
        let code = error ?? "unknown_error"
        var detail = "Slack API returned `\(code)`."
        if let needed, !needed.isEmpty {
            detail += " Required scope: \(needed)."
        }
        if let provided, !provided.isEmpty {
            detail += " Granted scopes: \(provided)."
        }
        let message = SlackSecurity.redact(detail, token: token)
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
    let needed: String?
    let provided: String?
}
