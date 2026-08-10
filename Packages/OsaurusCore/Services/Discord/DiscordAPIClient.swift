//
//  DiscordAPIClient.swift
//  osaurus
//
//  Minimal Discord REST client for the native group interaction tools.
//

import Foundation

struct DiscordBotIdentity: Codable, Equatable, Sendable {
    let id: String
    let username: String
    let globalName: String?
    let bot: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case globalName = "global_name"
        case bot
    }

    init(id: String, username: String, globalName: String?, bot: Bool = false) {
        self.id = id
        self.username = username
        self.globalName = globalName
        self.bot = bot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        globalName = try container.decodeIfPresent(String.self, forKey: .globalName)
        bot = try container.decodeIfPresent(Bool.self, forKey: .bot) ?? false
    }
}

struct DiscordGuild: Codable, Equatable, Sendable {
    let id: String
    let name: String
}

struct DiscordGuildMember: Codable, Equatable, Sendable, Identifiable {
    var id: String { user.id }
    let user: DiscordMessageAuthor
    let nick: String?

    var displayName: String {
        if let nick, !nick.isEmpty { return nick }
        return user.displayName
    }
}

struct DiscordChannel: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let guildId: String?
    let name: String?
    let type: Int
    let parentId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case guildId = "guild_id"
        case name
        case type
        case parentId = "parent_id"
    }

    var displayName: String {
        guard let name, !name.isEmpty else { return id }
        return name
    }
}

struct DiscordMessageAuthor: Codable, Equatable, Sendable {
    let id: String
    let username: String
    let globalName: String?
    let bot: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case globalName = "global_name"
        case bot
    }

    init(id: String, username: String, globalName: String?, bot: Bool = false) {
        self.id = id
        self.username = username
        self.globalName = globalName
        self.bot = bot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        globalName = try container.decodeIfPresent(String.self, forKey: .globalName)
        bot = try container.decodeIfPresent(Bool.self, forKey: .bot) ?? false
    }

    var displayName: String {
        if let globalName, !globalName.isEmpty { return globalName }
        return username
    }
}

struct DiscordAttachment: Codable, Equatable, Sendable {
    let id: String
    let filename: String
    let url: String?
    let contentType: String?
    let size: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case filename
        case url
        case contentType = "content_type"
        case size
    }
}

struct DiscordMessage: Codable, Equatable, Sendable {
    let id: String
    let channelId: String
    let content: String
    let timestamp: String
    let author: DiscordMessageAuthor
    let attachments: [DiscordAttachment]

    enum CodingKeys: String, CodingKey {
        case id
        case channelId = "channel_id"
        case content
        case timestamp
        case author
        case attachments
    }
}

enum DiscordAPIError: LocalizedError, Equatable, Sendable {
    case invalidToken
    case missingPermissions(String)
    case notFound(String)
    case rateLimited(String)
    case invalidResponse(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Discord rejected the bot token."
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

struct DiscordGatewayInfo: Codable, Equatable, Sendable {
    let url: String
}

protocol DiscordAPIClientProtocol: Sendable {
    func currentUser(token: String) async throws -> DiscordBotIdentity
    func gatewayURL(token: String) async throws -> URL
    func guilds(token: String) async throws -> [DiscordGuild]
    func guild(id: String, token: String) async throws -> DiscordGuild
    func members(guildId: String, token: String) async throws -> [DiscordGuildMember]
    func channels(guildId: String, token: String) async throws -> [DiscordChannel]
    func messages(channelId: String, token: String, limit: Int) async throws -> [DiscordMessage]
    func messages(channelId: String, token: String, limit: Int, after: String?) async throws -> [DiscordMessage]
    func sendMessage(channelId: String, content: String, token: String) async throws -> DiscordMessage
    func updateMessage(channelId: String, messageId: String, content: String, token: String) async throws -> DiscordMessage
    func deleteMessage(channelId: String, messageId: String, token: String) async throws
    func addReaction(channelId: String, messageId: String, reaction: String, token: String) async throws
    func removeReaction(channelId: String, messageId: String, reaction: String, token: String) async throws
    func sendTyping(channelId: String, token: String) async throws
}

extension DiscordAPIClientProtocol {
    func messages(channelId: String, token: String, limit: Int, after _: String?) async throws -> [DiscordMessage] {
        try await messages(channelId: channelId, token: token, limit: limit)
    }
    func gatewayURL(token _: String) async throws -> URL {
        throw DiscordAPIError.invalidResponse("Discord Gateway discovery is not implemented by this client.")
    }
    func guilds(token _: String) async throws -> [DiscordGuild] {
        throw DiscordAPIError.invalidResponse("Discord server discovery is not implemented by this client.")
    }
    func members(guildId _: String, token _: String) async throws -> [DiscordGuildMember] {
        throw DiscordAPIError.invalidResponse("Discord member discovery is not implemented by this client.")
    }
    func updateMessage(
        channelId _: String,
        messageId _: String,
        content _: String,
        token _: String
    ) async throws -> DiscordMessage {
        throw DiscordAPIError.invalidResponse("Discord message editing is not implemented by this client.")
    }
    func deleteMessage(channelId _: String, messageId _: String, token _: String) async throws {
        throw DiscordAPIError.invalidResponse("Discord message deletion is not implemented by this client.")
    }
    func addReaction(channelId _: String, messageId _: String, reaction _: String, token _: String) async throws {
        throw DiscordAPIError.invalidResponse("Discord reactions are not implemented by this client.")
    }
    func removeReaction(channelId _: String, messageId _: String, reaction _: String, token _: String) async throws {
        throw DiscordAPIError.invalidResponse("Discord reactions are not implemented by this client.")
    }
    func sendTyping(channelId _: String, token _: String) async throws {
        throw DiscordAPIError.invalidResponse("Discord typing indicators are not implemented by this client.")
    }
}

final class DiscordAPIClient: DiscordAPIClientProtocol, @unchecked Sendable {
    private let baseURL: URL
    private let sessionProvider: @Sendable () -> URLSession

    init(
        baseURL: URL = URL(string: "https://discord.com/api/v10")!,
        sessionProvider: @escaping @Sendable () -> URLSession = { GlobalProxySettings.sharedSession() }
    ) {
        self.baseURL = baseURL
        self.sessionProvider = sessionProvider
    }

    func currentUser(token: String) async throws -> DiscordBotIdentity {
        try await get(["users", "@me"], token: token)
    }

    func gatewayURL(token: String) async throws -> URL {
        let info: DiscordGatewayInfo = try await get(["gateway", "bot"], token: token)
        guard var components = URLComponents(string: info.url),
              components.scheme == "wss"
        else {
            throw DiscordAPIError.invalidResponse("Discord returned an invalid Gateway URL.")
        }
        components.queryItems = [
            URLQueryItem(name: "v", value: "10"),
            URLQueryItem(name: "encoding", value: "json"),
        ]
        guard let url = components.url else {
            throw DiscordAPIError.invalidResponse("Discord Gateway URL could not be built.")
        }
        return url
    }

    func guilds(token: String) async throws -> [DiscordGuild] {
        try await get(["users", "@me", "guilds"], token: token)
    }

    func guild(id: String, token: String) async throws -> DiscordGuild {
        try validateSnowflake(id, label: "guild_id")
        return try await get(["guilds", id], token: token)
    }

    func members(guildId: String, token: String) async throws -> [DiscordGuildMember] {
        try validateSnowflake(guildId, label: "guild_id")
        return try await get(
            ["guilds", guildId, "members"],
            token: token,
            query: [URLQueryItem(name: "limit", value: "1000")]
        )
    }

    func channels(guildId: String, token: String) async throws -> [DiscordChannel] {
        try validateSnowflake(guildId, label: "guild_id")
        return try await get(["guilds", guildId, "channels"], token: token)
    }

    func messages(channelId: String, token: String, limit: Int) async throws -> [DiscordMessage] {
        try await messages(channelId: channelId, token: token, limit: limit, after: nil)
    }

    func messages(channelId: String, token: String, limit: Int, after: String?) async throws -> [DiscordMessage] {
        try validateSnowflake(channelId, label: "channel_id")
        let safeLimit = DiscordConnectionConfiguration.clampReadLimit(limit)
        var query = [URLQueryItem(name: "limit", value: "\(safeLimit)")]
        if let after, !after.isEmpty {
            try validateSnowflake(after, label: "after")
            query.append(URLQueryItem(name: "after", value: after))
        }
        return try await get(
            ["channels", channelId, "messages"],
            token: token,
            query: query
        )
    }

    func sendMessage(channelId: String, content: String, token: String) async throws -> DiscordMessage {
        try validateSnowflake(channelId, label: "channel_id")
        return try await post(
            ["channels", channelId, "messages"],
            token: token,
            body: [
                "content": content,
                "allowed_mentions": [
                    "parse": [] as [String]
                ],
            ]
        )
    }

    func updateMessage(
        channelId: String,
        messageId: String,
        content: String,
        token: String
    ) async throws -> DiscordMessage {
        try validateSnowflake(channelId, label: "channel_id")
        try validateSnowflake(messageId, label: "message_id")
        return try await requestJSON(
            ["channels", channelId, "messages", messageId],
            method: "PATCH",
            token: token,
            body: [
                "content": content,
                "allowed_mentions": ["parse": [] as [String]],
            ]
        )
    }

    func deleteMessage(channelId: String, messageId: String, token: String) async throws {
        try validateSnowflake(channelId, label: "channel_id")
        try validateSnowflake(messageId, label: "message_id")
        try await requestEmpty(
            ["channels", channelId, "messages", messageId],
            method: "DELETE",
            token: token
        )
    }

    func addReaction(channelId: String, messageId: String, reaction: String, token: String) async throws {
        try validateSnowflake(channelId, label: "channel_id")
        try validateSnowflake(messageId, label: "message_id")
        try await requestEmpty(
            ["channels", channelId, "messages", messageId, "reactions", reaction, "@me"],
            method: "PUT",
            token: token
        )
    }

    func removeReaction(channelId: String, messageId: String, reaction: String, token: String) async throws {
        try validateSnowflake(channelId, label: "channel_id")
        try validateSnowflake(messageId, label: "message_id")
        try await requestEmpty(
            ["channels", channelId, "messages", messageId, "reactions", reaction, "@me"],
            method: "DELETE",
            token: token
        )
    }

    func sendTyping(channelId: String, token: String) async throws {
        try validateSnowflake(channelId, label: "channel_id")
        try await requestEmpty(["channels", channelId, "typing"], method: "POST", token: token)
    }

    private func get<T: Decodable>(
        _ path: [String],
        token: String,
        query: [URLQueryItem] = []
    ) async throws -> T {
        var request = try makeRequest(path, token: token, query: query)
        request.httpMethod = "GET"
        return try await perform(request, token: token)
    }

    private func post<T: Decodable>(
        _ path: [String],
        token: String,
        body: [String: Any]
    ) async throws -> T {
        var request = try makeRequest(path, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .osaurusCanonical)
        return try await perform(request, token: token)
    }

    private func requestJSON<T: Decodable>(
        _ path: [String],
        method: String,
        token: String,
        body: [String: Any]
    ) async throws -> T {
        var request = try makeRequest(path, token: token)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .osaurusCanonical)
        return try await perform(request, token: token)
    }

    private func requestEmpty(_ path: [String], method: String, token: String) async throws {
        var request = try makeRequest(path, token: token)
        request.httpMethod = method
        do {
            let (data, response) = try await sessionProvider().data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DiscordAPIError.invalidResponse("Discord returned a non-HTTP response.")
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw mapHTTPError(status: http.statusCode, data: data, token: token)
            }
        } catch let error as DiscordAPIError {
            throw error
        } catch {
            throw DiscordAPIError.requestFailed(
                DiscordSecurity.redact(error.localizedDescription, token: token)
            )
        }
    }

    private func makeRequest(
        _ path: [String],
        token: String,
        query: [URLQueryItem] = []
    ) throws -> URLRequest {
        var url = baseURL
        for segment in path {
            url.appendPathComponent(segment)
        }
        if !query.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw DiscordAPIError.invalidResponse("Discord URL could not be built.")
            }
            components.queryItems = query
            guard let builtURL = components.url else {
                throw DiscordAPIError.invalidResponse("Discord URL query could not be built.")
            }
            url = builtURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Osaurus Discord Native Plugin", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest, token: String) async throws -> T {
        do {
            let (data, response) = try await sessionProvider().data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DiscordAPIError.invalidResponse("Discord returned a non-HTTP response.")
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw mapHTTPError(status: http.statusCode, data: data, token: token)
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw DiscordAPIError.invalidResponse("Discord response could not be decoded.")
            }
        } catch let error as DiscordAPIError {
            throw error
        } catch {
            throw DiscordAPIError.requestFailed(
                DiscordSecurity.redact(error.localizedDescription, token: token)
            )
        }
    }

    private func mapHTTPError(status: Int, data: Data, token: String) -> DiscordAPIError {
        let message = discordErrorMessage(from: data)
            .map { DiscordSecurity.redact($0, token: token) }
        switch status {
        case 401:
            return .invalidToken
        case 403:
            return .missingPermissions(message ?? "Discord denied access for this bot or channel.")
        case 404:
            return .notFound(message ?? "Discord resource was not found.")
        case 429:
            return .rateLimited(message ?? "Discord rate limited this request.")
        default:
            return .requestFailed(message ?? "Discord request failed with HTTP \(status).")
        }
    }

    private func discordErrorMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["message"] as? String,
            !message.isEmpty
        else { return nil }
        return message
    }

    private func validateSnowflake(_ id: String, label: String) throws {
        guard DiscordConnectionConfiguration.isValidSnowflake(id) else {
            throw DiscordAPIError.invalidResponse("Invalid Discord \(label): expected a numeric Discord ID.")
        }
    }
}
