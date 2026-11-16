//
//  ListingEdits.swift
//  osaurus
//
//  What a publisher can change on a store listing without a new
//  template version: the name and description it shows, its topics, and
//  the example runs under it. All of it is listing data the registry keeps
//  beside the signed template, never inside it (older apps hash only the
//  keys they decode).
//

import Foundation

// MARK: - Topics

/// The registry's fixed topic vocabulary (workflows-registry `src/tags.ts`),
/// in its order. A listing has at most `maxSelected`.
public enum ListingTopic: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case writing, research, coding, data, design, media, marketing, productivity, education, finance, automation, fun

    public static let maxSelected = 3

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .writing: return L("Writing")
        case .research: return L("Research")
        case .coding: return L("Coding")
        case .data: return L("Data")
        case .design: return L("Design")
        case .media: return L("Media")
        case .marketing: return L("Marketing")
        case .productivity: return L("Productivity")
        case .education: return L("Education")
        case .finance: return L("Finance")
        case .automation: return L("Automation")
        case .fun: return L("Fun")
        }
    }

    /// Known ids only, in vocabulary order, at most `maxSelected`: what the
    /// registry would store for `ids`.
    public static func normalized<S: Sequence>(_ ids: S) -> [ListingTopic] where S.Element == String {
        let picked = Set(ids.compactMap { ListingTopic(rawValue: $0.lowercased()) })
        return Array(allCases.filter(picked.contains).prefix(maxSelected))
    }
}

// MARK: - Example runs, as the registry stores them

public struct ListingExample: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case succeeded, failed
    }

    public struct Image: Codable, Sendable, Equatable, Hashable {
        /// `<registry id>/<sha256>.<ext>` in the registry's media bucket.
        public var path: String
        public var url: URL?
        public var mime: String
        public var size: Int?
        public var width: Int?
        public var height: Int?
        public var caption: String?

        public init(
            path: String, url: URL? = nil, mime: String, size: Int? = nil, width: Int? = nil, height: Int? = nil,
            caption: String? = nil
        ) {
            self.path = path
            self.url = url
            self.mime = mime
            self.size = size
            self.width = width
            self.height = height
            self.caption = caption
        }
    }

    public var id: String
    public var title: String
    /// The template version that ran.
    public var templateVersion: Int?
    public var status: Status
    public var durationMs: Int?
    public var input: JSONValue
    public var output: JSONValue?
    public var error: String?
    public var images: [Image]
    public var createdAt: Date?

    public init(
        id: String, title: String, templateVersion: Int?, status: Status, durationMs: Int?, input: JSONValue,
        output: JSONValue?, error: String?, images: [Image], createdAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.templateVersion = templateVersion
        self.status = status
        self.durationMs = durationMs
        self.input = input
        self.output = output
        self.error = error
        self.images = images
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, status, input, output, error, images
        case templateVersion = "template_version"
        case durationMs = "duration_ms"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        templateVersion = try c.decodeIfPresent(Int.self, forKey: .templateVersion)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .succeeded
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        input = try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .null
        output = try c.decodeIfPresent(JSONValue.self, forKey: .output)
        if output == .null { output = nil }
        error = try c.decodeIfPresent(String.self, forKey: .error)
        images = try c.decodeIfPresent([Image].self, forKey: .images) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

// MARK: - Example runs, before they're shared

/// One run the publisher is choosing to show: already redacted, with each
/// image opted in or out on its own.
public struct ListingExampleDraft: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable, Hashable {
        /// A workflow run or Architect test run.
        case run(UUID)
        /// A conversation with an agent made from the template.
        case chat(UUID)
        /// An example already on the listing.
        case published(String)
    }

    public struct ImageDraft: Identifiable, Equatable, Sendable {
        public let id: String
        public var filename: String
        /// A file on this Mac, re-encoded without metadata before upload.
        public var fileURL: URL?
        /// An image already on the listing.
        public var uploaded: ListingExample.Image?
        public var included: Bool

        public init(id: String, filename: String, fileURL: URL? = nil, uploaded: ListingExample.Image? = nil, included: Bool = true) {
            self.id = id
            self.filename = filename
            self.fileURL = fileURL
            self.uploaded = uploaded
            self.included = included
        }
    }

    public var id: String { "\(source)" }
    public var source: Source
    public var title: String
    public var templateVersion: Int?
    public var status: ListingExample.Status
    public var durationMs: Int?
    public var input: JSONValue
    public var output: JSONValue?
    public var error: String?
    public var images: [ImageDraft]
    /// When it ran.
    public var date: Date

    public init(
        source: Source, title: String, templateVersion: Int?, status: ListingExample.Status, durationMs: Int?,
        input: JSONValue, output: JSONValue?, error: String?, images: [ImageDraft], date: Date
    ) {
        self.source = source
        self.title = title
        self.templateVersion = templateVersion
        self.status = status
        self.durationMs = durationMs
        self.input = input
        self.output = output
        self.error = error
        self.images = images
        self.date = date
    }

    public var includedImages: [ImageDraft] { images.filter(\.included) }

    /// Whether sharing it uploads anything new: a run from this Mac, or an
    /// image not on the listing yet.
    public var isNew: Bool {
        if case .published = source { return includedImages.contains { $0.uploaded == nil } }
        return true
    }
}

/// What a publish (or the dashboard) changes on the listing. `nil` leaves
/// that part as it is.
public struct ListingEdits: Equatable, Sendable {
    public enum Details: Equatable, Sendable {
        case set(name: String, summary: String)
        /// Back to the template's own name and summary.
        case reset
    }

    public var details: Details?
    public var topics: [ListingTopic]?
    /// The whole set; `[]` clears it.
    public var examples: [ListingExampleDraft]?

    public init(details: Details? = nil, topics: [ListingTopic]? = nil, examples: [ListingExampleDraft]? = nil) {
        self.details = details
        self.topics = topics
        self.examples = examples
    }

    public var isEmpty: Bool { details == nil && topics == nil && examples == nil }

    /// The parts of these edits that `result` says didn't save, to try again.
    public func failed(in result: ListingEditsResult) -> ListingEdits {
        ListingEdits(
            details: result.detailsError == nil ? nil : details,
            topics: result.topicsError == nil ? nil : topics,
            examples: result.examplesError == nil ? nil : examples)
    }

    /// Whether sharing these uploads a run or image that isn't public yet.
    public var sharesNewExamples: Bool { examples?.contains(where: \.isNew) ?? false }

    public static func isValid(name: String, summary: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxNameLength && !trimmed.contains(where: \.isNewline)
            && summary.count <= maxSummaryLength
    }

    /// The details change that takes the listing from what it shows now
    /// (`shownName`/`shownSummary`) to `name`/`summary`: nil when nothing
    /// changes, a reset when they match the template's own again.
    public static func details(
        name: String, summary: String, template: (name: String, summary: String),
        shown: (name: String, summary: String), edited: Bool
    ) -> Details? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == template.name && summary == template.summary { return edited ? .reset : nil }
        if name == shown.name && summary == shown.summary { return nil }
        return .set(name: name, summary: summary)
    }

    public static let maxExamples = 6
    public static let maxImagesPerExample = 6
    public static let maxNameLength = 200
    public static let maxSummaryLength = 2000
    public static let maxTitleLength = 120
}

/// How each part of `ListingEdits` went. A part that wasn't asked for, or
/// that saved, is nil.
public struct ListingEditsResult: Equatable, Sendable {
    public var detailsError: String?
    public var topicsError: String?
    public var examplesError: String?
    /// Examples saved without their images because the registry can't
    /// store images.
    public var imagesSkipped = false
    /// Images left out because they couldn't be read or made small enough.
    public var unreadableImages: [String] = []
    /// The examples as the registry stored them, when they saved.
    public var savedExamples: [ListingExample]?

    public init() {}

    public var hasFailures: Bool { detailsError != nil || topicsError != nil || examplesError != nil }
}
