//
//  OsaurusRouterSupportTypes.swift
//  osaurus
//
//  Wire types for Help: bug reports the user sends to the Osaurus team and
//  the two-way thread behind each one.
//
//  Contract (see docs/osaurus-integration.md in osaurus-router):
//  - Every `/support/*` route is wallet-signed like `/credits/*`.
//  - `consent` must be the literal `true`; the app sets it only when the user
//    ticked the Terms and Privacy box for this report.
//  - Staff messages arrive as author `staff` with nothing about who wrote
//    them. Render them as the Osaurus team.
//

import Foundation

/// One bug report and its conversation. The list returns summaries
/// (`messages == nil`); the detail, create and reply calls include messages.
struct OsaurusRouterSupportThread: Decodable, Identifiable, Equatable, Sendable {
    /// Where the conversation stands. Raw strings on the wire so an unknown
    /// future status degrades to `.open` instead of failing the decode.
    enum Status: String, Sendable {
        /// Waiting for the team (the user wrote last).
        case open
        /// The team replied last.
        case answered
        /// Resolved. Writing again reopens it.
        case closed
    }

    let id: String
    /// First line of the description, at most 120 characters. Router-derived.
    let subject: String
    let statusRaw: String
    /// True when a staff message is newer than the last time the user read
    /// or answered the thread.
    let unread: Bool
    let lastUserMessageAt: String
    let lastStaffMessageAt: String?
    let createdAt: String
    let updatedAt: String
    let messages: [OsaurusRouterSupportMessage]?

    enum CodingKeys: String, CodingKey {
        case id
        case subject
        case statusRaw = "status"
        case unread
        case lastUserMessageAt = "last_user_message_at"
        case lastStaffMessageAt = "last_staff_message_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case messages
    }

    init(
        id: String,
        subject: String,
        statusRaw: String,
        unread: Bool,
        lastUserMessageAt: String,
        lastStaffMessageAt: String? = nil,
        createdAt: String,
        updatedAt: String,
        messages: [OsaurusRouterSupportMessage]? = nil
    ) {
        self.id = id
        self.subject = subject
        self.statusRaw = statusRaw
        self.unread = unread
        self.lastUserMessageAt = lastUserMessageAt
        self.lastStaffMessageAt = lastStaffMessageAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    var status: Status { Status(rawValue: statusRaw) ?? .open }
    /// Counts toward the router's cap of three reports that are not closed,
    /// and is what keeps the launch / foreground unread check running.
    var isOpen: Bool { status != .closed }

    var createdDate: Date? { OsaurusRouterSupportDate.parse(createdAt) }
    /// Most recent message from either side, for ordering and "updated" text.
    var lastActivityDate: Date? {
        let user = OsaurusRouterSupportDate.parse(lastUserMessageAt)
        let staff = lastStaffMessageAt.flatMap(OsaurusRouterSupportDate.parse)
        switch (user, staff) {
        case (let user?, let staff?): return max(user, staff)
        case (let user?, nil): return user
        case (nil, let staff?): return staff
        case (nil, nil): return createdDate
        }
    }

    /// The same thread without its messages, as the list endpoint returns it.
    var summary: OsaurusRouterSupportThread {
        OsaurusRouterSupportThread(
            id: id, subject: subject, statusRaw: statusRaw, unread: unread,
            lastUserMessageAt: lastUserMessageAt, lastStaffMessageAt: lastStaffMessageAt,
            createdAt: createdAt, updatedAt: updatedAt, messages: nil)
    }
}

struct OsaurusRouterSupportMessage: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    /// `user` or `staff`. Anything else is treated as the team.
    let author: String
    let body: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case author
        case body
        case createdAt = "created_at"
    }

    init(id: String, author: String, body: String, createdAt: String) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }

    var isFromUser: Bool { author == "user" }
    var createdDate: Date? { OsaurusRouterSupportDate.parse(createdAt) }
}

/// `GET /support/threads`: the user's reports, newest first.
struct OsaurusRouterSupportThreadsResponse: Decodable, Equatable, Sendable {
    let data: [OsaurusRouterSupportThread]
    /// Threads with an unread staff message: the badge number.
    let unreadCount: Int

    enum CodingKeys: String, CodingKey {
        case data
        case unreadCount = "unread_count"
    }

    init(data: [OsaurusRouterSupportThread], unreadCount: Int) {
        self.data = data
        self.unreadCount = unreadCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode([OsaurusRouterSupportThread].self, forKey: .data)
        // Older routers may omit the count; derive it rather than fail.
        unreadCount =
            try container.decodeIfPresent(Int.self, forKey: .unreadCount)
            ?? data.filter(\.unread).count
    }
}

/// `POST /support/threads`. Everything except `description` and `consent`
/// is optional on the wire; the app always sends all of it.
struct OsaurusRouterSupportReportBody: Encodable, Equatable, Sendable {
    struct App: Encodable, Equatable, Sendable {
        let version: String?
        let build: String?
        let osVersion: String?

        enum CodingKeys: String, CodingKey {
            case version
            case build
            case osVersion = "os_version"
        }
    }

    struct Hardware: Encodable, Equatable, Sendable {
        let model: String?
        let chip: String?
        let memoryGB: Int?

        enum CodingKeys: String, CodingKey {
            case model
            case chip
            case memoryGB = "memory_gb"
        }
    }

    let description: String
    /// Always `true` when sent: the request is only built after the user
    /// ticked the Terms and Privacy box.
    let consent: Bool
    let app: App
    let hardware: Hardware
    /// Metadata-only support bundle, already serialized so the preview the
    /// user saw and the bytes sent are the same value.
    let diagnostics: JSONValue?
}

enum OsaurusRouterSupportDate {
    /// Router timestamps are ISO 8601 with fractional seconds
    /// (`2026-11-13T21:22:28.955Z`); accept the plain form too.
    static func parse(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

/// Limits the router enforces, mirrored so the form can explain them before
/// a request is spent. The router stays the authority.
enum OsaurusRouterSupportLimits {
    static let minDescriptionLength = 10
    static let maxMessageLength = 5000
    static let maxDiagnosticsBytes = 200 * 1024
    static let maxOpenThreads = 3
}
