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

struct DiscordChannel: Codable, Equatable, Sendable {
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

protocol DiscordAPIClientProtocol: Sendable {
    func currentUser(token: String) async throws -> DiscordBotIdentity
    func guild(id: String, token: String) async throws -> DiscordGuild
    func channels(guildId: String, token: String) async throws -> [DiscordChannel]
    func messages(channelId: String, token: String, limit: Int) async throws -> [DiscordMessage]
    func sendMessage(channelId: String, content: String, token: String) async throws -> DiscordMessage
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

    func guild(id: String, token: String) async throws -> DiscordGuild {
        try validateSnowflake(id, label: "guild_id")
        return try await get(["guilds", id], token: token)
    }

    func channels(guildId: String, token: String) async throws -> [DiscordChannel] {
        try validateSnowflake(guildId, label: "guild_id")
        return try await get(["guilds", guildId, "channels"], token: token)
    }

    func messages(channelId: String, token: String, limit: Int) async throws -> [DiscordMessage] {
        try validateSnowflake(channelId, label: "channel_id")
        let safeLimit = DiscordConnectionConfiguration.clampReadLimit(limit)
        return try await get(
            ["channels", channelId, "messages"],
            token: token,
            query: [
                URLQueryItem(name: "limit", value: "\(safeLimit)")
            ]
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
