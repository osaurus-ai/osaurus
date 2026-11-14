//
//  WorkflowRegistryRecordStore.swift
//  osaurus
//
//  Which workflows and agent templates this Mac has published to the
//  registry, so a card can
//  show "Live", offer the link again, publish a newer version, change who
//  can see it, and take it down. One record per template per registry, in
//  `~/.osaurus/template-library/registry.json`. The registry stays the
//  source of truth; this is what the last publish, take-down, or refresh
//  said, plus the numbers the registry last reported (installs, latest
//  version, visibility, author handle) so the library reads them without
//  a network call.
//

import Combine
import Foundation

public struct WorkflowRegistryRecord: Codable, Equatable, Sendable {
    public var templateID: UUID
    /// The registry's workflow id.
    public var registryID: String
    public var slug: String
    /// The version this Mac last published.
    public var version: Int
    public var contentHash: String
    public var url: URL
    public var rawURL: URL
    public var deepLink: URL
    /// The Osaurus ID that published it (lowercase).
    public var address: String
    /// The registry API origin it was published to.
    public var registry: String
    public var sharedAt: Date

    // What the registry last reported. All optional so a `registry.json`
    // written before they existed still loads.

    public var visibility: WorkflowVisibility = .public
    /// The workspaces a `.workspace` listing is shared with; empty for
    /// every other visibility.
    public var workspaceIDs: [String] = []
    /// Records written before agent templates could be published are all
    /// workflows.
    public var kind: TemplateKind = .workflow
    /// Distinct verified installers.
    public var installCount: Int?
    /// The newest version the registry has (may be ahead of `version` when
    /// another Mac published).
    public var registryLatestVersion: Int?
    /// `@handle` or short address, as the registry shows it.
    public var authorHandle: String?
    public var statsFetchedAt: Date?
    /// First published, as the registry records it.
    public var publishedAt: Date?
    /// The registry's last change (publish, visibility, take-down).
    public var updatedAt: Date?
    /// Taken down by the owner (from any Mac) and not yet published again.
    public var takenDown: Bool = false
    /// Removed by the Osaurus team; publishing again is refused.
    public var removedByAdmin: Bool = false
    /// The agent template whose publish first gave this workflow its own
    /// page, when it wasn't published on its own.
    public var publishedWith: UUID?
    /// The name and description the listing shows instead of the
    /// template's; nil while it shows the template's own.
    public var listingName: String?
    public var listingSummary: String?
    /// Topic ids, in the registry's order.
    public var tags: [String] = []
    /// Example runs on the listing.
    public var exampleCount: Int?
    /// The listing's most recent review; nil when it never had one
    /// (Unlisted, Password, or a registry that predates review).
    public var review: WorkflowsRegistryReview?
    /// What store visitors get; behind `registryLatestVersion` while the
    /// newest upload waits for review.
    public var liveVersion: Int?
    /// What the registry last said about being in the store's lists.
    public var listed: Bool?
    /// The decision time the owner last looked at (the registry's clock,
    /// so a skewed Mac clock can't hide a decision).
    public var reviewSeenAt: Date?

    /// Live for everyone the visibility allows.
    public var isLive: Bool { !takenDown && !removedByAdmin }

    /// In the store's lists. Only Public listings are; Unlisted, Password,
    /// and Workspace never are. A Public listing is submitted unlisted: its
    /// link works right away, and it's listed once a version is approved.
    public var isListed: Bool {
        guard isLive, visibility == .public else { return false }
        if let listed { return listed }
        guard let review else { return true }
        switch review.status {
        case .pending, .rejected: return (liveVersion ?? review.version) < review.version
        case .approved, .superseded, .withdrawn: return true
        }
    }

    /// An approval or a change request the owner hasn't opened yet.
    public var hasUnseenDecision: Bool {
        guard isLive, let review, review.isDecision, let decided = review.decidedAt else { return false }
        // Seen times saved before the store kept fractional seconds are
        // whole seconds; the decision in that same second is the one seen.
        let decidedSecond = decided.timeIntervalSinceReferenceDate.rounded(.down)
        return decidedSecond > (reviewSeenAt ?? .distantPast).timeIntervalSinceReferenceDate
    }

    /// Takes `new` as the listing's review. The first review this Mac
    /// learns of counts as seen, so listings approved before this build (or
    /// decided while another Mac watched) don't light up all at once; only
    /// a decision that lands after a review this Mac knew about is new.
    public mutating func applyReview(_ new: WorkflowsRegistryReview?) {
        let previous = review
        review = new
        guard let new else { return }
        if previous == nil {
            reviewSeenAt = max(reviewSeenAt ?? .distantPast, new.decidedAt ?? new.submittedAt)
        }
    }

    /// The owner opened the decision.
    public mutating func markReviewSeen() {
        guard let decided = review?.decidedAt else { return }
        reviewSeenAt = max(reviewSeenAt ?? .distantPast, decided)
    }

    enum CodingKeys: String, CodingKey {
        case templateID = "template_id"
        case registryID = "registry_id"
        case slug, version
        case contentHash = "content_hash"
        case url
        case rawURL = "raw_url"
        case deepLink = "deep_link"
        case address, registry
        case sharedAt = "shared_at"
        case visibility, kind
        case workspaceIDs = "workspace_ids"
        case installCount = "install_count"
        case registryLatestVersion = "registry_latest_version"
        case authorHandle = "author_handle"
        case statsFetchedAt = "stats_fetched_at"
        case publishedAt = "published_at"
        case updatedAt = "updated_at"
        case takenDown = "taken_down"
        case removedByAdmin = "removed_by_admin"
        case publishedWith = "published_with"
        case listingName = "listing_name"
        case listingSummary = "listing_summary"
        case tags
        case exampleCount = "example_count"
        case review
        case liveVersion = "live_version"
        case listed
        case reviewSeenAt = "review_seen_at"
    }

    public init(
        templateID: UUID, registryID: String, slug: String, version: Int, contentHash: String, url: URL,
        rawURL: URL, deepLink: URL, address: String, registry: String, sharedAt: Date,
        visibility: WorkflowVisibility = .public, kind: TemplateKind = .workflow
    ) {
        self.templateID = templateID
        self.registryID = registryID
        self.slug = slug
        self.version = version
        self.contentHash = contentHash
        self.url = url
        self.rawURL = rawURL
        self.deepLink = deepLink
        self.address = address
        self.registry = registry
        self.sharedAt = sharedAt
        self.visibility = visibility
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        templateID = try c.decode(UUID.self, forKey: .templateID)
        registryID = try c.decode(String.self, forKey: .registryID)
        slug = try c.decode(String.self, forKey: .slug)
        version = try c.decode(Int.self, forKey: .version)
        contentHash = try c.decode(String.self, forKey: .contentHash)
        url = try c.decode(URL.self, forKey: .url)
        rawURL = try c.decode(URL.self, forKey: .rawURL)
        deepLink = try c.decode(URL.self, forKey: .deepLink)
        address = try c.decode(String.self, forKey: .address)
        registry = try c.decode(String.self, forKey: .registry)
        sharedAt = try c.decode(Date.self, forKey: .sharedAt)
        visibility = try c.decodeIfPresent(WorkflowVisibility.self, forKey: .visibility) ?? .public
        workspaceIDs = try c.decodeIfPresent([String].self, forKey: .workspaceIDs) ?? []
        kind = try c.decodeIfPresent(String.self, forKey: .kind).flatMap(TemplateKind.init(rawValue:)) ?? .workflow
        installCount = try c.decodeIfPresent(Int.self, forKey: .installCount)
        registryLatestVersion = try c.decodeIfPresent(Int.self, forKey: .registryLatestVersion)
        authorHandle = try c.decodeIfPresent(String.self, forKey: .authorHandle)
        statsFetchedAt = try c.decodeIfPresent(Date.self, forKey: .statsFetchedAt)
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        takenDown = try c.decodeIfPresent(Bool.self, forKey: .takenDown) ?? false
        removedByAdmin = try c.decodeIfPresent(Bool.self, forKey: .removedByAdmin) ?? false
        publishedWith = try c.decodeIfPresent(UUID.self, forKey: .publishedWith)
        listingName = try c.decodeIfPresent(String.self, forKey: .listingName)
        listingSummary = try c.decodeIfPresent(String.self, forKey: .listingSummary)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        exampleCount = try c.decodeIfPresent(Int.self, forKey: .exampleCount)
        review = (try? c.decodeIfPresent(WorkflowsRegistryReview.self, forKey: .review)) ?? nil
        liveVersion = try c.decodeIfPresent(Int.self, forKey: .liveVersion)
        listed = try c.decodeIfPresent(Bool.self, forKey: .listed)
        reviewSeenAt = try c.decodeIfPresent(Date.self, forKey: .reviewSeenAt)
    }

    /// The topics the listing shows.
    public var topics: [ListingTopic] { ListingTopic.normalized(tags) }

    /// Folds what the registry reported into the record. `version` (what
    /// this Mac published) is left alone; the registry's newest is kept
    /// beside it.
    public mutating func apply(_ detail: WorkflowsRegistryDetail, at now: Date) {
        visibility = detail.visibility
        if detail.visibility != .workspace {
            workspaceIDs = []
        } else if let ids = detail.workspaceIDs {
            workspaceIDs = ids
        }
        kind = detail.kind
        installCount = detail.installCount
        // A public read answers the approved version while a newer one
        // waits; versions only go up, so the newest anyone reported stands.
        registryLatestVersion = max(detail.latestVersion, registryLatestVersion ?? 0)
        if let live = detail.liveVersion { liveVersion = live }
        if let inStore = detail.listed { listed = inStore }
        if detail.carriesReview { applyReview(detail.review) }
        authorHandle = detail.author.handle
        publishedAt = detail.createdAt
        updatedAt = detail.updatedAt
        url = detail.url
        slug = detail.slug
        takenDown = detail.isRemoved && !detail.removedByAdmin
        removedByAdmin = detail.removedByAdmin
        listingName = detail.listingEdited ? detail.name : nil
        listingSummary = detail.listingEdited ? detail.summary : nil
        tags = detail.tags
        exampleCount = detail.exampleCount ?? exampleCount
        statsFetchedAt = now
    }

    /// Folds one review watch item into the record.
    public mutating func apply(_ watched: WorkflowsRegistryWatchedReview) {
        visibility = watched.visibility
        if watched.visibility != .workspace { workspaceIDs = [] }
        registryLatestVersion = max(watched.latestVersion, registryLatestVersion ?? 0)
        liveVersion = watched.liveVersion
        if let inStore = watched.listed { listed = inStore }
        let removed = watched.status == "removed"
        removedByAdmin = removed && watched.removedBy == "admin"
        takenDown = removed && !removedByAdmin
        applyReview(watched.review)
    }
}

@MainActor
public final class WorkflowRegistryRecordStore: ObservableObject {
    public static let shared = WorkflowRegistryRecordStore()

    @Published public private(set) var records: [WorkflowRegistryRecord] = []

    private struct File: Codable {
        var version = 1
        var records: [WorkflowRegistryRecord] = []
    }

    init() {
        reload()
    }

    public nonisolated static var fileURL: URL {
        OsaurusPaths.templateLibrary().appendingPathComponent("registry.json")
    }

    public func reload() {
        guard let data = try? Data(contentsOf: Self.fileURL) else {
            records = []
            return
        }
        records = (try? WorkflowsRegistryAPIClient.dateDecoder.decode(File.self, from: data))?.records ?? []
    }

    /// The record for `templateID` on `registry` (the registry this build
    /// talks to by default), so a share to staging never reads as shared
    /// on production.
    public func record(for templateID: UUID, registry: URL = WorkflowsRegistryAPIClient.defaultBaseURL)
        -> WorkflowRegistryRecord?
    {
        let key = Self.registryKey(registry)
        return records.first { $0.templateID == templateID && $0.registry == key }
    }

    /// Every record on `registry`, newest publish first.
    /// `kind` narrows to workflows or agent templates; nil is both.
    public func records(
        registry: URL = WorkflowsRegistryAPIClient.defaultBaseURL, kind: TemplateKind? = nil
    ) -> [WorkflowRegistryRecord] {
        let key = Self.registryKey(registry)
        return records.filter { $0.registry == key && (kind == nil || $0.kind == kind) }
            .sorted { $0.sharedAt > $1.sharedAt }
    }

    /// Live records whose newest submission waits for review.
    public func pendingReviewRecords(registry: URL = WorkflowsRegistryAPIClient.defaultBaseURL)
        -> [WorkflowRegistryRecord]
    {
        records(registry: registry).filter { $0.isLive && $0.review?.status == .pending }
    }

    /// Marks the decision on `templateID` as opened.
    public func markReviewSeen(templateID: UUID, registry: URL = WorkflowsRegistryAPIClient.defaultBaseURL) {
        guard record(for: templateID, registry: registry)?.hasUnseenDecision == true else { return }
        update(templateID: templateID, registry: registry) { $0.markReviewSeen() }
    }

    /// Records that are live (not taken down or removed) on `registry`.
    public func liveRecords(
        registry: URL = WorkflowsRegistryAPIClient.defaultBaseURL, kind: TemplateKind? = nil
    ) -> [WorkflowRegistryRecord] {
        records(registry: registry, kind: kind).filter(\.isLive)
    }

    /// The sum of what the registry last reported for live records.
    public func totalInstalls(
        registry: URL = WorkflowsRegistryAPIClient.defaultBaseURL, kind: TemplateKind? = nil
    ) -> Int {
        liveRecords(registry: registry, kind: kind).reduce(0) { $0 + ($1.installCount ?? 0) }
    }

    /// Workflows whose own page came with publishing `agentID`.
    public func records(
        publishedWith agentID: UUID, registry: URL = WorkflowsRegistryAPIClient.defaultBaseURL
    ) -> [WorkflowRegistryRecord] {
        records(registry: registry, kind: .workflow).filter { $0.publishedWith == agentID }
    }

    /// The author handle the registry last showed for any record.
    public func authorHandle(registry: URL = WorkflowsRegistryAPIClient.defaultBaseURL) -> String? {
        records(registry: registry).compactMap(\.authorHandle).first
    }

    public func set(_ record: WorkflowRegistryRecord) {
        records.removeAll { $0.templateID == record.templateID && $0.registry == record.registry }
        records.append(record)
        write()
    }

    /// Edits the record for `templateID` in place; no-op when there is none.
    public func update(
        templateID: UUID, registry: URL = WorkflowsRegistryAPIClient.defaultBaseURL,
        _ edit: (inout WorkflowRegistryRecord) -> Void
    ) {
        let key = Self.registryKey(registry)
        guard let index = records.firstIndex(where: { $0.templateID == templateID && $0.registry == key }) else {
            return
        }
        edit(&records[index])
        write()
    }

    public func remove(templateID: UUID, registry: URL = WorkflowsRegistryAPIClient.defaultBaseURL) {
        let key = Self.registryKey(registry)
        records.removeAll { $0.templateID == templateID && $0.registry == key }
        write()
    }

    nonisolated static func registryKey(_ url: URL) -> String {
        (WorkflowsRegistryAPIClient.origin(of: url) ?? url).absoluteString.lowercased()
    }

    private func write() {
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.templateLibrary())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Registry decision times carry fractional seconds; dropping them
        // made every saved review differ from the registry's on the next
        // launch and announced each approval again.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        guard let data = try? encoder.encode(File(records: records)) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
