//
//  OsaurusRouterIDTypes.swift
//  OsaurusCore
//
//  Wire types for the router's Osaurus ID service (`/id/*` and the public
//  `/users/:osaurus_id`). Contract: osaurus-router/docs/OSAURUS_ID.md.
//
//  Naming note: in this codebase the `OsaurusID` typealias is the `0x…`
//  master address (the wallet that signs every router request). The types
//  here describe the *handle* a person claims for that address — the
//  URL-friendly `@rex-42` shown in workspace rosters, invites, and usage —
//  which the router also calls "Osaurus ID". Every type below carries the
//  `OsaurusID` prefix and refers to the handle, never the address.
//

import Foundation

// MARK: - Handle rules

/// Client-side mirror of the server's handle format rules, so the claim UI
/// can validate and sanitize as the user types instead of round-tripping
/// obviously invalid candidates. The server remains authoritative.
enum OsaurusIDValidator {
    static let minLength = 3
    static let maxLength = 20

    /// The server's format rule: 3–20 chars, `a-z` / `0-9`, single internal
    /// hyphens, starting and ending alphanumeric.
    static func isValid(_ candidate: String) -> Bool {
        candidate.range(
            of: "^[a-z0-9](-?[a-z0-9]){2,19}$",
            options: .regularExpression
        ) != nil
    }

    /// Live-typing sanitizer for the claim field: lowercases, maps spaces and
    /// underscores to hyphens, drops every other disallowed character,
    /// collapses hyphen runs, never starts with a hyphen, and caps the
    /// length. A trailing hyphen is kept while typing (the user may keep
    /// going); `isValid` still rejects it on submit.
    static func sanitizedInput(_ raw: String) -> String {
        var result = ""
        for character in raw.lowercased() {
            let isAllowed =
                ("a" ... "z").contains(character) || ("0" ... "9").contains(character)
            if isAllowed {
                result.append(character)
            } else if character == "-" || character == " " || character == "_" {
                guard !result.isEmpty, result.last != "-" else { continue }
                result.append("-")
            }
        }
        return String(result.prefix(maxLength))
    }
}

/// Client-side mirror of the server's display-name rule: up to 50 printable
/// characters (spaces, capitals, emoji all fine). Empty means "unset" —
/// clients fall back to the handle.
enum OsaurusIDDisplayName {
    static let maxLength = 50

    /// Trim edges, strip control characters (including newlines), cap at 50.
    static func sanitized(_ raw: String) -> String {
        let cleaned = raw.filter { character in
            !character.unicodeScalars.contains { scalar in
                scalar.properties.generalCategory == .control
            }
        }
        return String(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Client-side mirror of the server's bio rule: up to 500 characters.
/// Newlines are allowed (it's a paragraph); other control characters are
/// stripped.
enum OsaurusIDBio {
    static let maxLength = 500

    static func sanitized(_ raw: String) -> String {
        let cleaned = raw.filter { character in
            character == "\n"
                || !character.unicodeScalars.contains { scalar in
                    scalar.properties.generalCategory == .control
                }
        }
        return String(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Availability

enum OsaurusIDAvailabilityStatus: String, Equatable, Sendable {
    case available
    case taken
    case reserved
    case invalid
}

/// `GET /id/availability?osaurus_id=…` result.
struct OsaurusIDAvailability: Decodable, Equatable, Sendable {
    let osaurusID: String
    let status: OsaurusIDAvailabilityStatus

    private enum CodingKeys: String, CodingKey {
        case osaurusID = "osaurus_id"
        case status
    }

    init(osaurusID: String, status: OsaurusIDAvailabilityStatus) {
        self.osaurusID = osaurusID
        self.status = status
    }

    /// Lenient status decode: an unknown future status can never be claimed,
    /// so it reads as `invalid` rather than failing the whole response.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            osaurusID: try c.decode(String.self, forKey: .osaurusID),
            status: OsaurusIDAvailabilityStatus(
                rawValue: try c.decode(String.self, forKey: .status)
            ) ?? .invalid
        )
    }
}

// MARK: - Profile

/// The account's own profile (`GET /id/me`, claim response).
struct OsaurusIDProfile: Decodable, Equatable, Sendable {
    /// The immutable handle (`rex-42`), without the `@`.
    let osaurusID: String
    /// The renameable label shown in UIs. Empty means "unset" — display the
    /// handle instead.
    let displayName: String
    let email: String?
    let emailPublic: Bool
    let bio: String
    let createdAt: String?
    let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case email, bio
        case osaurusID = "osaurus_id"
        case displayName = "display_name"
        case emailPublic = "email_public"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        osaurusID: String,
        displayName: String = "",
        email: String? = nil,
        emailPublic: Bool = false,
        bio: String = "",
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.osaurusID = osaurusID
        self.displayName = displayName
        self.email = email
        self.emailPublic = emailPublic
        self.bio = bio
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            osaurusID: try c.decode(String.self, forKey: .osaurusID),
            displayName: try c.decodeIfPresent(String.self, forKey: .displayName) ?? "",
            email: try c.decodeIfPresent(String.self, forKey: .email),
            emailPublic: try c.decodeIfPresent(Bool.self, forKey: .emailPublic) ?? false,
            bio: try c.decodeIfPresent(String.self, forKey: .bio) ?? "",
            createdAt: try c.decodeIfPresent(String.self, forKey: .createdAt),
            updatedAt: try c.decodeIfPresent(String.self, forKey: .updatedAt)
        )
    }

    /// The name UIs should show: the display name when set, else the handle.
    var effectiveName: String {
        displayName.isEmpty ? osaurusID : displayName
    }

    /// The handle as users see it: `@rex-42`.
    var handle: String { "@" + osaurusID }
}

/// `PATCH /id/me` body: any subset of the mutable profile fields. Synthesized
/// encoding omits nil fields, so only set fields are patched. (Email editing
/// is not surfaced; clearing it would need an explicit `null`.)
struct OsaurusIDProfilePatch: Encodable, Equatable, Sendable {
    /// `""` clears the display name (fall back to the handle); nil omits the
    /// field from the patch entirely.
    var displayName: String?
    var bio: String?

    private enum CodingKeys: String, CodingKey {
        case bio
        case displayName = "display_name"
    }

    init(displayName: String? = nil, bio: String? = nil) {
        self.displayName = displayName
        self.bio = bio
    }
}

// MARK: - Sessions

/// One identity session (`osk_…` token metadata; the token value itself is
/// only ever returned at creation).
struct OsaurusIDSession: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let label: String?
    let status: String?
    let expiresAt: String?
    let createdAt: String?
    let lastUsedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, label, status
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }
}

/// `POST /id/sessions` result — the token appears exactly once here.
struct OsaurusIDSessionCreateResponse: Decodable, Equatable, Sendable {
    let token: String
    let session: OsaurusIDSession
}

struct OsaurusIDSessionListResponse: Decodable, Sendable {
    let data: [OsaurusIDSession]
}

// MARK: - Error refinement

extension OsaurusRouterAPIError {
    /// The router's 404 `NOT_FOUND` on `/id/me`: this account has no Osaurus
    /// ID yet. Routes the claim flow — not a failure.
    var isOsaurusIDNotFound: Bool {
        if case .server(let code, _, let status) = self {
            return status == 404 && code == "NOT_FOUND"
        }
        return false
    }

    /// 409 `INVALID_STATE` "this account already has an Osaurus ID": the
    /// wallet claimed on another machine. The client recovers by adopting
    /// `GET /id/me` instead of surfacing an error.
    var indicatesAccountAlreadyHasOsaurusID: Bool {
        if case .server(let code, let message, _) = self {
            return code == "INVALID_STATE"
                && message.lowercased().contains("already has an osaurus id")
        }
        return false
    }
}
