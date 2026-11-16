//
//  WorkflowsRegistryAPIClient.swift
//  osaurus
//
//  Transport for the store registry behind store.osaurus.ai: nonce
//  challenges, signed publish, unpublish, and visibility, signed install
//  receipts, and reads of a workflow's page data (unsigned for anyone,
//  owner-signed to see a taken-down or password-protected one). The
//  signing and the bytes uploaded are `WorkflowShareService`'s job; this
//  file only speaks HTTP and maps the registry's error envelope.
//
//  See osaurus-ai/workflows-registry (docs/API.md, docs/PUBLISH.md).
//

import Foundation

// MARK: - Public types

public struct WorkflowsRegistryPublishResult: Sendable, Equatable {
    public let id: String
    public let slug: String
    public let version: Int
    public let contentHash: String
    /// False for a new version or an identical re-upload.
    public let created: Bool
    /// The workflow's public page.
    public let url: URL
    /// The immutable template file for this version.
    public let rawURL: URL
    /// `osaurus://templates-import?url=<rawURL>`.
    public let deepLink: URL
    /// Who can see it. Registries that predate visibility answer `public`.
    public var visibility: WorkflowVisibility = .public
    /// Registries that predate agent templates answer nothing: `workflow`.
    public var kind: TemplateKind = .workflow
    /// What store visitors get. Behind `version` while that one waits for
    /// review. Nil from a registry that predates review.
    public var liveVersion: Int? = nil
    /// In the store's lists. A Public listing stays link-only (unlisted)
    /// until its first version is approved. Nil from a registry that
    /// predates review.
    public var listed: Bool? = nil
    /// The review of `version`: nil for Unlisted and Password (nothing to
    /// review) and from a registry that predates review.
    public var review: WorkflowsRegistryReview? = nil
}

/// The Osaurus team's decision on one submitted version of a public listing.
public struct WorkflowsRegistryReview: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        case pending, approved, rejected, superseded, withdrawn
    }

    public var status: Status
    public var version: Int
    /// What to fix when rejected (or a note left on approval). Plain text
    /// written by a person for the author.
    public var message: String?
    public var submittedAt: Date
    public var decidedAt: Date?
    /// While pending: how long a review usually takes.
    public var expectedWithinHours: Int?

    enum CodingKeys: String, CodingKey {
        case status, version, message
        case submittedAt = "submitted_at"
        case decidedAt = "decided_at"
        case expectedWithinHours = "expected_within_hours"
    }

    public init(
        status: Status, version: Int, message: String? = nil, submittedAt: Date, decidedAt: Date? = nil,
        expectedWithinHours: Int? = nil
    ) {
        self.status = status
        self.version = version
        self.message = message
        self.submittedAt = submittedAt
        self.decidedAt = decidedAt
        self.expectedWithinHours = expectedWithinHours
    }

    /// Approved or rejected: a decision the author hears about.
    public var isDecision: Bool { status == .approved || status == .rejected }

    /// The reviewer's message, trimmed; nil when empty.
    public var note: String? {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One listing's review state as `GET /me/reviews` reports it.
public struct WorkflowsRegistryWatchedReview: Sendable, Equatable, Decodable {
    public let id: String
    public let templateID: UUID
    public let slug: String
    public let visibility: WorkflowVisibility
    /// `removed` once taken down.
    public let status: String
    /// `owner` or `admin` while removed.
    public let removedBy: String?
    public let latestVersion: Int
    public let liveVersion: Int
    /// In the store's lists; false while a Public listing's first version
    /// waits for review.
    public let listed: Bool?
    public let review: WorkflowsRegistryReview

    enum CodingKeys: String, CodingKey {
        case id, slug, visibility, status, review, listed
        case removedBy = "removed_by"
        case templateID = "template_id"
        case latestVersion = "latest_version"
        case liveVersion = "live_version"
    }
}

/// `GET /me/reviews`: the owner's review states and the cursor to wait on.
public struct WorkflowsRegistryReviewWatch: Sendable, Equatable, Decodable {
    public let cursor: String
    public let changed: Bool
    public let items: [WorkflowsRegistryWatchedReview]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try c.decode(String.self, forKey: .cursor)
        changed = try c.decode(Bool.self, forKey: .changed)
        // A review with a status this build doesn't know is skipped, not fatal.
        items = try c.decode([LenientElement<WorkflowsRegistryWatchedReview>].self, forKey: .items)
            .compactMap(\.value)
    }

    enum CodingKeys: String, CodingKey { case cursor, changed, items }
}

/// Decodes `T` or nothing, so one unreadable element doesn't sink a list.
private struct LenientElement<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Signed request headers for one call, already computed by the service.
public struct WorkflowsRegistrySignature: Sendable, Equatable {
    public let address: String
    public let nonce: String
    public let timestamp: Int
    public let signature: String

    public init(address: String, nonce: String, timestamp: Int, signature: String) {
        self.address = address
        self.nonce = nonce
        self.timestamp = timestamp
        self.signature = signature
    }
}

public struct WorkflowsRegistryAuthor: Sendable, Equatable, Decodable {
    public let address: String
    /// The claimed Osaurus ID (without `@`), when the author has one.
    public let osaurusID: String?
    public let displayName: String?

    enum CodingKeys: String, CodingKey {
        case address
        case osaurusID = "osaurus_id"
        case displayName = "display_name"
    }

    public init(address: String, osaurusID: String?, displayName: String?) {
        self.address = address
        self.osaurusID = osaurusID
        self.displayName = displayName
    }

    /// `@handle` when claimed, otherwise the short address.
    public var handle: String {
        if let osaurusID, !osaurusID.isEmpty { return "@" + osaurusID }
        return SharedAgentIdentity.shortAddress(address)
    }
}

public struct WorkflowsRegistryVersion: Sendable, Equatable, Decodable {
    public let version: Int
    public let changelog: String
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case version, changelog
        case createdAt = "created_at"
    }
}

public struct WorkflowsRegistryRemoval: Sendable, Equatable, Decodable {
    public enum By: String, Decodable, Sendable { case owner, admin }
    public let by: By
    public let reason: String?
    public let at: Date
}

/// A workflow an agent's detail lists, in the agent's order. `listing` is
/// the workflow page the agent's page links to, when there is one.
public struct WorkflowsRegistryLinkedWorkflow: Sendable, Equatable, Decodable {
    public struct Listing: Sendable, Equatable, Decodable {
        public let id: String
        public let latestVersion: Int

        enum CodingKeys: String, CodingKey {
            case id
            case latestVersion = "latest_version"
        }
    }

    public let templateID: UUID
    public let listing: Listing?

    enum CodingKeys: String, CodingKey {
        case listing
        case templateID = "template_id"
    }
}

/// One workflow as the registry describes it: `GET /workflows/:id` (with
/// `versions`) or a row of `GET /me/workflows` (without).
public struct WorkflowsRegistryDetail: Sendable, Equatable, Decodable {
    public let id: String
    /// Workflow or agent template; its page is under /w/ or /a/ accordingly.
    public let kind: TemplateKind
    public let slug: String
    public let name: String
    public let summary: String
    public let templateID: UUID
    public let author: WorkflowsRegistryAuthor
    public let visibility: WorkflowVisibility
    /// `removed` only on owner-signed reads; public reads answer 410 instead.
    public let status: String
    public let removal: WorkflowsRegistryRemoval?
    public let latestVersion: Int
    public let installCount: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let url: URL
    /// The latest version's template file and install link; present on
    /// detail and owner-list rows.
    public let rawURL: URL?
    public let deepLink: URL?
    /// Newest first; empty for list rows.
    public let versions: [WorkflowsRegistryVersion]
    /// An agent's workflows on its detail; empty otherwise.
    public let workflows: [WorkflowsRegistryLinkedWorkflow]
    /// Topic ids, in the registry's vocabulary order.
    public let tags: [String]
    /// The example runs on its page; empty for list rows.
    public let examples: [ListingExample]
    /// How many example runs it has: `example_count` on list rows,
    /// `examples.count` on detail. Nil from a registry without examples.
    public let exampleCount: Int?
    /// Set while the owner's own name and description replace the
    /// template's on the listing.
    public let listingEditedAt: Date?
    /// What store visitors get; behind `latestVersion` on an owner read
    /// while the newest upload waits for review.
    public let liveVersion: Int?
    /// In the store's lists. Public reads always say so; owner reads too.
    public let listed: Bool?
    /// The listing's most recent review, on owner reads.
    public let review: WorkflowsRegistryReview?
    /// The workspaces a `workspace` listing is shared with, on owner-list
    /// rows; nil when the answer doesn't say.
    public let workspaceIDs: [String]?
    /// True when the read said anything about review (owner reads do, even
    /// `null`; public reads and older registries don't), so a public read
    /// never clears what an owner read learned.
    public let carriesReview: Bool

    public var isRemoved: Bool { status == "removed" }
    public var removedByAdmin: Bool { isRemoved && removal?.by == .admin }
    public var listingEdited: Bool { listingEditedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, kind, slug, name, summary, author, visibility, status, removal, url, versions, workflows, tags,
            examples
        case templateID = "template_id"
        case latestVersion = "latest_version"
        case installCount = "install_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case rawURL = "raw_url"
        case deepLink = "deep_link"
        case exampleCount = "example_count"
        case listingEditedAt = "listing_edited_at"
        case liveVersion = "live_version"
        case review, listed
        case workspaceIDs = "workspace_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind).flatMap(TemplateKind.init(rawValue:)) ?? .workflow
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        guard let template = UUID(uuidString: try c.decode(String.self, forKey: .templateID)) else {
            throw DecodingError.dataCorruptedError(forKey: .templateID, in: c, debugDescription: "not a UUID")
        }
        templateID = template
        author = try c.decode(WorkflowsRegistryAuthor.self, forKey: .author)
        visibility = try c.decodeIfPresent(WorkflowVisibility.self, forKey: .visibility) ?? .public
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "active"
        removal = try c.decodeIfPresent(WorkflowsRegistryRemoval.self, forKey: .removal)
        latestVersion = try c.decode(Int.self, forKey: .latestVersion)
        installCount = try c.decodeIfPresent(Int.self, forKey: .installCount) ?? 0
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        url = try c.decode(URL.self, forKey: .url)
        rawURL = try c.decodeIfPresent(URL.self, forKey: .rawURL)
        deepLink = try c.decodeIfPresent(URL.self, forKey: .deepLink)
        versions = try c.decodeIfPresent([WorkflowsRegistryVersion].self, forKey: .versions) ?? []
        workflows = (try? c.decodeIfPresent([WorkflowsRegistryLinkedWorkflow].self, forKey: .workflows)) ?? []
        tags = ((try? c.decodeIfPresent([String].self, forKey: .tags)) ?? nil) ?? []
        examples = ((try? c.decodeIfPresent([ListingExample].self, forKey: .examples)) ?? nil) ?? []
        exampleCount =
            try c.decodeIfPresent(Int.self, forKey: .exampleCount) ?? (c.contains(.examples) ? examples.count : nil)
        listingEditedAt = try c.decodeIfPresent(Date.self, forKey: .listingEditedAt)
        liveVersion = try c.decodeIfPresent(Int.self, forKey: .liveVersion)
        listed = try? c.decodeIfPresent(Bool.self, forKey: .listed)
        review = (try? c.decodeIfPresent(WorkflowsRegistryReview.self, forKey: .review)) ?? nil
        carriesReview = c.contains(.review)
        workspaceIDs = (try? c.decodeIfPresent([String].self, forKey: .workspaceIDs)) ?? nil
    }
}

/// One row of `GET /workspaces/:id/workflows`.
public struct WorkflowsRegistryWorkspaceItem: Sendable, Equatable, Decodable, Identifiable {
    public let id: String
    public let kind: TemplateKind
    public let slug: String
    public let name: String
    public let summary: String
    public let templateID: UUID
    public let author: WorkflowsRegistryAuthor
    public let latestVersion: Int
    public let sharedAt: Date?
    public let rawURL: URL
    public let deepLink: URL?

    enum CodingKeys: String, CodingKey {
        case id, kind, slug, name, summary, author
        case templateID = "template_id"
        case latestVersion = "latest_version"
        case sharedAt = "shared_at"
        case rawURL = "raw_url"
        case deepLink = "deep_link"
    }

    public init(
        id: String, kind: TemplateKind, slug: String, name: String, summary: String, templateID: UUID,
        author: WorkflowsRegistryAuthor, latestVersion: Int, sharedAt: Date?, rawURL: URL, deepLink: URL?
    ) {
        self.id = id
        self.kind = kind
        self.slug = slug
        self.name = name
        self.summary = summary
        self.templateID = templateID
        self.author = author
        self.latestVersion = latestVersion
        self.sharedAt = sharedAt
        self.rawURL = rawURL
        self.deepLink = deepLink
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind).flatMap(TemplateKind.init(rawValue:)) ?? .workflow
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        guard let template = UUID(uuidString: try c.decode(String.self, forKey: .templateID)) else {
            throw DecodingError.dataCorruptedError(forKey: .templateID, in: c, debugDescription: "not a UUID")
        }
        templateID = template
        author = try c.decode(WorkflowsRegistryAuthor.self, forKey: .author)
        latestVersion = try c.decode(Int.self, forKey: .latestVersion)
        sharedAt = try? c.decodeIfPresent(Date.self, forKey: .sharedAt)
        rawURL = try c.decode(URL.self, forKey: .rawURL)
        deepLink = try c.decodeIfPresent(URL.self, forKey: .deepLink)
    }
}

/// `GET /workspaces/:id/workflows`.
public struct WorkflowsRegistryWorkspacePage: Sendable, Equatable, Decodable {
    public let items: [WorkflowsRegistryWorkspaceItem]
    public let total: Int?
    public let nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case items, total
        case nextOffset = "next_offset"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([LenientElement<WorkflowsRegistryWorkspaceItem>].self, forKey: .items).compactMap(\.value)
        total = try c.decodeIfPresent(Int.self, forKey: .total)
        nextOffset = try c.decodeIfPresent(Int.self, forKey: .nextOffset)
    }
}

/// `GET /me/workflows`: everything the signer owns, whatever its status.
public struct WorkflowsRegistryOwnedPage: Sendable, Equatable, Decodable {
    public let author: WorkflowsRegistryAuthor
    public let banned: Bool
    public let items: [WorkflowsRegistryDetail]
    public let total: Int
    public let nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case author, banned, items, total
        case nextOffset = "next_offset"
    }
}

public struct WorkflowsRegistryIssue: Sendable, Equatable, Decodable {
    public let path: String
    public let message: String
}

/// The registry's documented `error` codes. Anything unrecognized lands in
/// `.server` so the UI can still show it.
public enum WorkflowsRegistryAPIError: LocalizedError, Sendable, Equatable {
    case addressBanned
    case authorMismatch
    case workflowRemovedByAdmin
    case versionNotNewer(latest: Int?)
    case quotaExceeded
    case concurrentPublish
    case invalidNonce
    case timestampOutOfWindow
    /// Any other request-signature rejection (missing headers, bad format,
    /// signature that does not verify).
    case authRejected(code: String)
    case rateLimited
    case bodyTooLarge
    /// The file did not pass the registry's checks: an app bug, not a user one.
    case templateRejected(code: String, issues: [WorkflowsRegistryIssue])
    case forbidden
    case notFound
    case removed
    /// Visibility changes: the body the app sent was wrong (an app bug).
    case invalidVisibility(code: String)
    /// The password is outside the registry's length bounds.
    case invalidPassword(min: Int?, max: Int?)
    /// A read of a password-protected workflow without a valid access token.
    case passwordRequired
    /// A read of a workspace listing without an attestation for one of its
    /// workspaces.
    case workspaceRequired
    /// The workspace's plan isn't active.
    case workspaceSuspended
    /// Viewers can install workspace workflows but not share them.
    case workspaceRole
    /// An attestation the registry couldn't verify or that names another
    /// wallet (expired, or a router key change).
    case workspaceAttestationRejected(code: String)
    /// Listing edits: the name, topics, or examples didn't pass the
    /// registry's checks.
    case invalidListing(code: String, issues: [WorkflowsRegistryIssue])
    /// The image isn't a PNG, JPEG, WebP, or GIF the registry can read.
    case unsupportedMedia
    /// The registry has nowhere to keep images right now.
    case mediaUnavailable
    case mediaUploadFailed
    /// The review watch token is unknown or revoked; the next signed call
    /// gets a new one.
    case watchTokenRejected
    /// A registry deployed before this build's features answered.
    case storeOutdated(StoreFeature)
    case server(code: String, message: String?, status: Int)

    public enum StoreFeature: Sendable, Equatable {
        /// A template format newer than the registry reads (today: agent steps).
        case newerFormat
        case workspaces
    }
    case transport(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidVisibility:
            return L("Osaurus couldn't update who can see this workflow.")
        case .invalidPassword(let min, let max):
            return L("The password must be \(min ?? 6) to \(max ?? 128) characters.")
        case .passwordRequired:
            return L("This workflow is password-protected.")
        case .workspaceRequired:
            return L("This workflow is shared with a workspace you're not a member of.")
        case .workspaceSuspended:
            return L("This workspace's plan isn't active, so its workflows are paused until the owner renews it.")
        case .workspaceRole:
            return L("Viewers can install a workspace's workflows but can't share their own.")
        case .workspaceAttestationRejected:
            return L("The store couldn't confirm your workspace membership. Try again.")
        case .invalidListing(let code, _):
            switch code {
            case "invalid_tags": return L("Pick up to 3 topics from the list.")
            case "invalid_examples": return L("The store couldn't accept these example runs.")
            default: return L("Check the name and description and try again.")
            }
        case .unsupportedMedia:
            return L("Images must be PNG, JPEG, WebP, or GIF.")
        case .mediaUnavailable:
            return L("The store can't save images right now.")
        case .mediaUploadFailed:
            return L("An image didn't upload. Try again.")
        case .watchTokenRejected:
            return L("Osaurus stopped hearing about reviews. Open a published workflow to resume.")
        case .storeOutdated(.newerFormat):
            return L("The store doesn't accept agent steps yet. Try again after the store updates.")
        case .storeOutdated(.workspaces):
            return L("The store doesn't support workspace sharing yet. Try again after the store updates.")
        case .addressBanned:
            return L("This Osaurus ID can't publish workflows.")
        case .authorMismatch:
            return L("The workflow is signed by a different Osaurus ID than the one sharing it.")
        case .workflowRemovedByAdmin:
            return L("This workflow was removed by the Osaurus team and can't be shared again.")
        case .versionNotNewer(let latest):
            if let latest { return L("Version \(latest) is already shared. Share this as version \(latest + 1).") }
            return L("This version is already shared with different content. Share it as a new version.")
        case .quotaExceeded:
            return L("You've published the maximum number of workflows. Take one down first.")
        case .concurrentPublish, .invalidNonce:
            return L("The registry was busy with another request. Try again.")
        case .timestampOutOfWindow:
            return L("Check your Mac's clock and try again.")
        case .authRejected:
            return L("The registry couldn't verify the request's signature.")
        case .rateLimited:
            return L("Too many shares in a row. Try again in a few minutes.")
        case .bodyTooLarge:
            return L("This workflow is too large to share (limit 2 MB).")
        case .templateRejected:
            return L("Osaurus couldn't prepare this workflow for sharing.")
        case .forbidden:
            return L("Only the Osaurus ID that shared this workflow can change it.")
        case .notFound:
            return L("The registry has no such workflow.")
        case .removed:
            return L("This workflow is no longer shared.")
        case .server(_, let message, let status):
            return message ?? L("The store registry answered HTTP \(status).")
        case .transport(let description):
            return description
        case .invalidResponse:
            return L("The store registry returned a response Osaurus couldn't read.")
        }
    }

    /// A short technical footnote for the UI.
    public var diagnosticHint: String? {
        switch self {
        case .authRejected(let code), .invalidVisibility(let code), .workspaceAttestationRejected(let code): return code
        case .templateRejected(let code, let issues), .invalidListing(let code, let issues):
            let first = issues.prefix(3).map { "\($0.path): \($0.message)" }
            return ([code] + first).joined(separator: "\n")
        case .server(let code, _, let status): return "\(code) (HTTP \(status))"
        default: return nil
        }
    }

    static func from(
        code: String, message: String?, status: Int, latestVersion: Int?, issues: [WorkflowsRegistryIssue],
        passwordBounds: (min: Int?, max: Int?) = (nil, nil)
    ) -> WorkflowsRegistryAPIError {
        switch code {
        case "invalid_visibility", "password_missing", "body_must_be_object", "not_password_protected",
            "workspace_attestations_missing":
            return .invalidVisibility(code: code)
        case "workspace_required": return .workspaceRequired
        case "workspace_suspended": return .workspaceSuspended
        case "workspace_role": return .workspaceRole
        case "invalid_workspace_attestation", "attestation_not_signer":
            return .workspaceAttestationRejected(code: code)
        case "invalid_password": return .invalidPassword(min: passwordBounds.min, max: passwordBounds.max)
        case "password_required": return .passwordRequired
        case "invalid_listing", "invalid_tags", "invalid_examples": return .invalidListing(code: code, issues: issues)
        case "unsupported_media": return .unsupportedMedia
        case "media_unavailable": return .mediaUnavailable
        case "media_upload_failed", "media_lookup_failed": return .mediaUploadFailed
        case "invalid_watch_token": return .watchTokenRejected
        case "address_banned": return .addressBanned
        case "author_mismatch": return .authorMismatch
        case "workflow_removed_by_admin": return .workflowRemovedByAdmin
        case "version_not_newer": return .versionNotNewer(latest: latestVersion)
        case "quota_exceeded": return .quotaExceeded
        case "concurrent_publish_retry": return .concurrentPublish
        case "invalid_nonce": return .invalidNonce
        case "timestamp_out_of_window": return .timestampOutOfWindow
        case "missing_auth_headers", "invalid_address", "invalid_signature_format", "invalid_timestamp",
            "signature_verification_failed":
            return .authRejected(code: code)
        case "rate_limited": return .rateLimited
        case "body_too_large": return .bodyTooLarge
        case "invalid_template"
        where issues.contains { $0.path.hasSuffix("format_version") && $0.message.contains("newer") }:
            return .storeOutdated(.newerFormat)
        case "empty_body", "invalid_utf8", "invalid_json", "template_must_be_object", "invalid_template",
            "content_hash_mismatch", "author_signature_invalid":
            return .templateRejected(code: code, issues: issues)
        case "forbidden": return .forbidden
        case "not_found", "version_not_found": return .notFound
        case "workflow_removed": return .removed
        default: return .server(code: code, message: message, status: status)
        }
    }
}

// MARK: - Client

public actor WorkflowsRegistryAPIClient {

    public static let productionBaseURL = URL(string: "https://api.store.osaurus.ai")!
    public static let productionWebURL = URL(string: "https://store.osaurus.ai")!
    public static let stagingBaseURL = URL(string: "https://osaurus-registry.fly.dev")!
    public static let stagingWebURL = URL(string: "https://workflows-registry.vercel.app")!

    public static let baseURLDefaultsKey = "ai.osaurus.workflowsRegistry.baseURL"

    /// Matches the registry's body cap and the importer's.
    public static let maxBodyBytes = 2 * 1024 * 1024

    /// The registry API origin. Publishing is master-key-signed and the
    /// deep link trusts this host, so the override that points a
    /// development build at staging or a local registry is DEBUG-only;
    /// release builds always talk to production.
    public static var defaultBaseURL: URL {
        #if DEBUG
            if let raw = UserDefaults.standard.string(forKey: baseURLDefaultsKey),
                let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                url.host?.isEmpty == false
            {
                return url
            }
        #endif
        return productionBaseURL
    }

    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = WorkflowsRegistryAPIClient.defaultBaseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.session = session ?? Self.makeSession()
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        // Public reads come back `Cache-Control: public, max-age=30`. The
        // app reads right after it writes (publish, visibility, take down),
        // and a signed owner read shares its URL with the public one, so
        // nothing here may be answered from a cache.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return GlobalProxySettings.makeSession(base: config)
    }

    // MARK: - Registry template links

    // swiftlint:disable:next force_try
    private static let templatePath = try! NSRegularExpression(
        pattern: "^/workflows/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/versions/([1-9][0-9]{0,6})/template\\.json$",
        options: [.caseInsensitive])

    /// True only for a versioned template file on `registry`: same scheme,
    /// host, and port, the exact path shape, and nothing else (no fragment
    /// or credentials; the only query allowed is the single `access` token
    /// a password-protected workflow's link carries). Plain http is
    /// accepted only for a loopback registry in development.
    public static func isRegistryTemplateURL(_ url: URL, registry: URL = defaultBaseURL) -> Bool {
        registryTemplate(from: url, registry: registry) != nil
    }

    /// The workflow id in a registry template URL, or nil when the URL is
    /// not one.
    public static func registryWorkflowID(from url: URL, registry: URL = defaultBaseURL) -> UUID? {
        registryTemplate(from: url, registry: registry)?.id
    }

    /// The access-token query a password-protected link carries: exactly
    /// one `access` item with a non-empty value, or nothing.
    private static func hasOnlyAccessQuery(_ url: URL) -> Bool {
        guard url.query != nil else { return true }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            items.count == 1, items[0].name == "access", let value = items[0].value, !value.isEmpty
        else { return false }
        return true
    }

    /// The workflow id and version a registry template URL names, or nil
    /// when the URL is not one.
    public static func registryTemplate(from url: URL, registry: URL = defaultBaseURL) -> (id: UUID, version: Int)? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty,
            scheme == registry.scheme?.lowercased(), host == registry.host?.lowercased(),
            url.port == registry.port,
            scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
            url.user == nil, url.password == nil, url.fragment == nil, hasOnlyAccessQuery(url)
        else { return nil }
        let path = url.path
        let range = NSRange(path.startIndex..., in: path)
        guard let match = templatePath.firstMatch(in: path, range: range),
            let idRange = Range(match.range(at: 1), in: path),
            let versionRange = Range(match.range(at: 2), in: path),
            let id = UUID(uuidString: String(path[idRange])),
            let version = Int(path[versionRange])
        else { return nil }
        return (id, version)
    }

    /// The registry origin a template URL was served from.
    public static func origin(of url: URL) -> URL? {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        return components.url
    }

    // MARK: - POST /auth/challenge

    /// A single-use nonce bound to `address`, valid for 60 seconds.
    public func requestNonce(address: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/challenge"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["address": address])
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        struct Challenge: Decodable { let nonce: String }
        return try Self.decode(Challenge.self, from: data).nonce
    }

    // MARK: - POST /workflows

    /// Uploads `body` byte for byte. The signature must already cover its
    /// SHA-256; this method does not look inside it. `visibility` rides
    /// along as `X-Workflow-Visibility` when it is `hidden`: the registry
    /// honours it only for a brand-new listing (or one coming back from a
    /// take-down), never to make an existing one more visible. A password
    /// needs the signed `setVisibility` afterwards.
    public func publish(
        body: Data, address: String, nonce: String, timestamp: Int, signature: String,
        visibility: WorkflowVisibility = .public
    ) async throws -> WorkflowsRegistryPublishResult {
        guard body.count <= Self.maxBodyBytes else { throw WorkflowsRegistryAPIError.bodyTooLarge }
        var request = URLRequest(url: baseURL.appendingPathComponent("workflows"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if visibility != .public {
            request.setValue(WorkflowVisibility.hidden.rawValue, forHTTPHeaderField: "X-Workflow-Visibility")
        }
        Self.sign(&request, address: address, nonce: nonce, timestamp: timestamp, signature: signature)
        request.httpBody = body
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)

        struct Published: Decodable {
            let id: String
            let slug: String
            let version: Int
            let content_hash: String
            let created: Bool
            let visibility: WorkflowVisibility?
            let kind: String?
            let url: String
            let raw_url: String
            let deep_link: String
            let live_version: Int?
            let listed: Bool?
        }
        let decoded = try Self.decode(Published.self, from: data)
        guard let url = URL(string: decoded.url), let raw = URL(string: decoded.raw_url),
            let deepLink = URL(string: decoded.deep_link)
        else { throw WorkflowsRegistryAPIError.invalidResponse }
        return WorkflowsRegistryPublishResult(
            id: decoded.id, slug: decoded.slug, version: decoded.version, contentHash: decoded.content_hash,
            created: decoded.created, url: url, rawURL: raw, deepLink: deepLink,
            visibility: decoded.visibility ?? .public,
            kind: decoded.kind.flatMap(TemplateKind.init(rawValue:)) ?? .workflow,
            liveVersion: decoded.live_version, listed: decoded.listed, review: Self.review(in: data))
    }

    /// The `review` object of an answer, or nil when it has none (or one
    /// with a status this build doesn't know).
    nonisolated static func review(in data: Data) -> WorkflowsRegistryReview? {
        struct Envelope: Decodable { let review: WorkflowsRegistryReview? }
        return (try? dateDecoder.decode(Envelope.self, from: data))?.review
    }

    // MARK: - DELETE /workflows/:id

    public func unpublish(id: String, address: String, nonce: String, timestamp: Int, signature: String)
        async throws
    {
        var request = URLRequest(url: baseURL.appendingPathComponent("workflows").appendingPathComponent(id))
        request.httpMethod = "DELETE"
        Self.sign(&request, address: address, nonce: nonce, timestamp: timestamp, signature: signature)
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
    }

    // MARK: - PUT /workflows/:id/visibility

    /// The exact bytes the service signs and this method sends.
    /// `workspaceAttestations` (one per workspace) only rides with
    /// `.workspace`, and replaces the set it's shared with.
    nonisolated public static func visibilityBody(
        _ visibility: WorkflowVisibility, password: String?, workspaceAttestations: [String] = []
    ) throws -> Data {
        var object: [String: Any] = ["visibility": visibility.rawValue]
        if visibility == .password, let password { object["password"] = password }
        if visibility == .workspace { object["workspace_attestations"] = workspaceAttestations }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// What a visibility change answers. Going Public submits the latest
    /// version for review; leaving Public withdraws a pending one.
    public struct VisibilityAnswer: Sendable, Equatable {
        public let visibility: WorkflowVisibility
        public let liveVersion: Int?
        public let listed: Bool?
        public let review: WorkflowsRegistryReview?
        /// False from a registry that predates review.
        public let carriesReview: Bool
        /// The workspaces a `.workspace` listing is shared with now.
        public var workspaceIDs: [String] = []
    }

    /// Sets who can see workflow `id`. `body` comes from `visibilityBody`;
    /// the signature must already cover its SHA-256.
    public func setVisibility(id: String, body: Data, signed: WorkflowsRegistrySignature) async throws
        -> VisibilityAnswer
    {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("workflows").appendingPathComponent(id)
                .appendingPathComponent("visibility"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.sign(&request, signed)
        request.httpBody = body
        let (data, response) = try await perform(request)
        do {
            try ensureOK(data: data, response: response)
        } catch WorkflowsRegistryAPIError.invalidVisibility("invalid_visibility") where Self.requestsWorkspace(body) {
            throw WorkflowsRegistryAPIError.storeOutdated(.workspaces)
        }
        struct Answer: Decodable {
            let visibility: WorkflowVisibility
            let live_version: Int?
            let listed: Bool?
            let workspace_ids: [String]?
        }
        let answer = try Self.decode(Answer.self, from: data)
        let carries = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys.contains("review") ?? false
        return VisibilityAnswer(
            visibility: answer.visibility, liveVersion: answer.live_version, listed: answer.listed,
            review: Self.review(in: data),
            carriesReview: carries, workspaceIDs: answer.workspace_ids ?? [])
    }

    /// A registry that predates workspaces knows no `workspace` visibility,
    /// so its `invalid_visibility` for one means "too old", not "bad body".
    nonisolated static func requestsWorkspace(_ body: Data) -> Bool {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return object?["visibility"] as? String == WorkflowVisibility.workspace.rawValue
    }

    // MARK: - Workspaces

    /// `GET /workspaces/:id/workflows`: the listings shared with one
    /// workspace, newest share first. `attestation` is a fresh one for that
    /// workspace; it only travels as `X-Workspace-Attestation`.
    public func fetchWorkspaceWorkflows(
        workspaceID: String, attestation: String, offset: Int = 0, limit: Int = 200
    ) async throws -> WorkflowsRegistryWorkspacePage {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("workspaces").appendingPathComponent(workspaceID)
                .appendingPathComponent("workflows"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit)),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(attestation, forHTTPHeaderField: WorkspaceAttestationProvider.header)
        let (data, response) = try await perform(request)
        do {
            try ensureOK(data: data, response: response)
        } catch WorkflowsRegistryAPIError.notFound, WorkflowsRegistryAPIError.server("method_not_allowed", _, _) {
            // The route only 404s for a malformed id, which this never sends.
            throw WorkflowsRegistryAPIError.storeOutdated(.workspaces)
        }
        return try Self.decode(WorkflowsRegistryWorkspacePage.self, from: data)
    }

    /// `DELETE /workspaces/:wid/workflows/:id` (`osaurus-workflow-unshare`).
    /// The listing's owner needs no attestation; a workspace owner or
    /// admin removing someone else's sends theirs. Answers the workspaces
    /// it is still shared with.
    public func unshareFromWorkspace(
        workspaceID: String, id: String, signed: WorkflowsRegistrySignature, attestation: String? = nil
    ) async throws -> [String] {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("workspaces").appendingPathComponent(workspaceID)
                .appendingPathComponent("workflows").appendingPathComponent(id))
        request.httpMethod = "DELETE"
        Self.sign(&request, signed)
        if let attestation { request.setValue(attestation, forHTTPHeaderField: WorkspaceAttestationProvider.header) }
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        struct Answer: Decodable { let workspace_ids: [String]? }
        return try Self.decode(Answer.self, from: data).workspace_ids ?? []
    }

    // MARK: - Review watch

    /// A read-only token for `watchReviews`, signed with
    /// `osaurus-review-watch`.
    public func issueReviewWatchToken(signed: WorkflowsRegistrySignature) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("me").appendingPathComponent("review-watch"))
        request.httpMethod = "POST"
        Self.sign(&request, signed)
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        struct Answer: Decodable { let token: String }
        return try Self.decode(Answer.self, from: data).token
    }

    /// The owner's review states. With `since` (the last cursor) the
    /// registry holds the request up to `wait` seconds until they change.
    public func watchReviews(token: String, since: String?, wait: Int) async throws -> WorkflowsRegistryReviewWatch {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("me").appendingPathComponent("reviews"), resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "wait", value: String(max(0, wait)))]
        if let since { query.append(URLQueryItem(name: "since", value: since)) }
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = TimeInterval(max(0, wait) + 20)
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        return try Self.decode(WorkflowsRegistryReviewWatch.self, from: data)
    }

    /// Revokes a watch token. Best effort.
    public func revokeReviewWatchToken(_ token: String) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("me").appendingPathComponent("review-watch"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await perform(request)
    }

    // MARK: - Listing edits

    public struct ListingAnswer: Sendable, Equatable, Decodable {
        public let name: String
        public let summary: String
        public let edited: Bool
    }

    /// `{"name", "summary"}`, or `{"reset": true}` for the template's own.
    nonisolated public static func listingBody(_ details: ListingEdits.Details) throws -> Data {
        let object: [String: Any]
        switch details {
        case .set(let name, let summary): object = ["name": name, "summary": summary]
        case .reset: object = ["reset": true]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    nonisolated public static func tagsBody(_ topics: [ListingTopic]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tags": topics.map(\.rawValue)], options: [.sortedKeys])
    }

    /// One example as `PUT /workflows/:id/examples` takes it.
    public struct ExampleUpload: Sendable, Equatable, Encodable {
        public struct Image: Sendable, Equatable, Encodable {
            public var path: String
            public var caption: String?
            public var size: Int?
            public var width: Int?
            public var height: Int?
        }

        public var title: String
        public var templateVersion: Int?
        public var status: ListingExample.Status
        public var durationMs: Int?
        public var input: JSONValue
        public var output: JSONValue?
        public var error: String?
        public var images: [Image]

        enum CodingKeys: String, CodingKey {
            case title, status, input, output, error, images
            case templateVersion = "template_version"
            case durationMs = "duration_ms"
        }
    }

    nonisolated public static func examplesBody(_ examples: [ExampleUpload]) throws -> Data {
        struct Body: Encodable { let examples: [ExampleUpload] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Body(examples: examples))
    }

    private func listingRequest(id: String, path: String, method: String = "PUT") -> URLRequest {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("workflows").appendingPathComponent(id).appendingPathComponent(path))
        request.httpMethod = method
        return request
    }

    /// Sets (or resets) the name and description the listing shows. `body`
    /// comes from `listingBody`.
    public func setListing(id: String, body: Data, signed: WorkflowsRegistrySignature) async throws -> ListingAnswer {
        var request = listingRequest(id: id, path: "listing")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.sign(&request, signed)
        request.httpBody = body
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        return try Self.decode(ListingAnswer.self, from: data)
    }

    /// Sets the listing's topics. `body` comes from `tagsBody`.
    public func setTags(id: String, body: Data, signed: WorkflowsRegistrySignature) async throws -> [String] {
        var request = listingRequest(id: id, path: "tags")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.sign(&request, signed)
        request.httpBody = body
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        struct Answer: Decodable { let tags: [String] }
        return try Self.decode(Answer.self, from: data).tags
    }

    /// Stores one image for the listing's examples. It shows nowhere until
    /// `setExamples` names its path. The signature covers the bytes' SHA-256.
    public func uploadExampleImage(id: String, data image: Data, mime: String, signed: WorkflowsRegistrySignature)
        async throws -> ListingExample.Image
    {
        guard image.count <= WorkflowsRegistryAPIClient.maxImageBytes else {
            throw WorkflowsRegistryAPIError.bodyTooLarge
        }
        var request = listingRequest(id: id, path: "examples/images", method: "POST")
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        Self.sign(&request, signed)
        request.httpBody = image
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        return try Self.decode(ListingExample.Image.self, from: data)
    }

    /// Replaces the listing's examples. `body` comes from `examplesBody`.
    public func setExamples(id: String, body: Data, signed: WorkflowsRegistrySignature) async throws
        -> [ListingExample]
    {
        var request = listingRequest(id: id, path: "examples")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.sign(&request, signed)
        request.httpBody = body
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        struct Answer: Decodable { let examples: [ListingExample] }
        return try Self.decode(Answer.self, from: data).examples
    }

    /// Matches the registry's per-image cap.
    public static let maxImageBytes = 2 * 1024 * 1024

    // MARK: - GET /workflows/:id

    /// One workflow's page data. Unsigned, it answers like the web page
    /// (404 unknown, 410 taken down, 403 password-protected). Owner-signed
    /// (`osaurus-workflow-read` over `id`), the owner sees it whatever its
    /// status or visibility.
    public func fetchDetail(id: String, signed: WorkflowsRegistrySignature? = nil) async throws
        -> WorkflowsRegistryDetail
    {
        var request = URLRequest(url: baseURL.appendingPathComponent("workflows").appendingPathComponent(id))
        request.httpMethod = "GET"
        if let signed { Self.sign(&request, signed) }
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        return try Self.decode(WorkflowsRegistryDetail.self, from: data)
    }

    // MARK: - GET /me/workflows

    /// Everything the signer owns (`osaurus-workflow-list`), newest first,
    /// taken-down ones included. One page; follow `nextOffset`.
    public func fetchOwned(signed: WorkflowsRegistrySignature, offset: Int = 0, limit: Int = 200) async throws
        -> WorkflowsRegistryOwnedPage
    {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("me").appendingPathComponent("workflows"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit)),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        Self.sign(&request, signed)
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        return try Self.decode(WorkflowsRegistryOwnedPage.self, from: data)
    }

    // MARK: - POST /workflows/:id/installs

    /// Sends a signed install receipt for `version` of workflow `id`. The
    /// registry counts one install per workflow per Osaurus ID; later
    /// receipts from the same ID land on that install. Returns `counted`.
    public func recordInstall(
        id: UUID, version: Int, address: String, nonce: String, timestamp: Int, signature: String
    ) async throws -> Bool {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("workflows")
                .appendingPathComponent(id.uuidString.lowercased())
                .appendingPathComponent("installs"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.sign(&request, address: address, nonce: nonce, timestamp: timestamp, signature: signature)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["version": version])
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        struct Receipt: Decodable { let counted: Bool }
        return try Self.decode(Receipt.self, from: data).counted
    }

    // MARK: - Internal

    private static func sign(
        _ request: inout URLRequest, address: String, nonce: String, timestamp: Int, signature: String
    ) {
        request.setValue(address, forHTTPHeaderField: "X-Agent-Address")
        request.setValue(nonce, forHTTPHeaderField: "X-Nonce")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")
    }

    private static func sign(_ request: inout URLRequest, _ s: WorkflowsRegistrySignature) {
        sign(&request, address: s.address, nonce: s.nonce, timestamp: s.timestamp, signature: s.signature)
    }

    /// Registry dates are ISO 8601 with fractional seconds.
    nonisolated static let dateDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: raw) ?? plain.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date"))
        }
        return decoder
    }()

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            return try await session.data(for: request)
        } catch {
            throw WorkflowsRegistryAPIError.transport(error.localizedDescription)
        }
    }

    private func ensureOK(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw WorkflowsRegistryAPIError.invalidResponse }
        if (200 ..< 300).contains(http.statusCode) { return }

        struct Envelope: Decodable {
            let error: String?
            let message: String?
            let latest_version: Int?
            let issues: [WorkflowsRegistryIssue]?
            let min_length: Int?
            let max_length: Int?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data), let code = envelope.error {
            if let issues = envelope.issues, !issues.isEmpty {
                print("[WorkflowsRegistry] \(http.url?.path ?? "") \(code): \(issues)")
            }
            throw WorkflowsRegistryAPIError.from(
                code: code, message: envelope.message, status: http.statusCode,
                latestVersion: envelope.latest_version, issues: envelope.issues ?? [],
                passwordBounds: (envelope.min_length, envelope.max_length))
        }
        switch http.statusCode {
        case 404: throw WorkflowsRegistryAPIError.notFound
        case 410: throw WorkflowsRegistryAPIError.removed
        case 413: throw WorkflowsRegistryAPIError.bodyTooLarge
        case 429: throw WorkflowsRegistryAPIError.rateLimited
        default:
            throw WorkflowsRegistryAPIError.server(code: "http_\(http.statusCode)", message: nil, status: http.statusCode)
        }
    }

    nonisolated static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.dateDecoder.decode(type, from: data)
        } catch {
            print("[WorkflowsRegistry] undecodable response: \(error)")
            throw WorkflowsRegistryAPIError.invalidResponse
        }
    }
}
