//
//  ListingExampleBuilder.swift
//  osaurus
//
//  Turns what ran on this Mac into example runs a publisher can show on
//  a listing: a workflow's runs (Architect test runs included) or, for an
//  agent template, conversations with agents made from it. Everything is
//  redacted the way an exported template is (secret inputs dropped, home
//  paths shortened, credential-looking strings replaced) before the
//  publisher sees it, so the preview is exactly what leaves the Mac.
//  Images are re-encoded without their metadata (EXIF, GPS) and made
//  small enough for the registry.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ListingExampleBuilder {
    /// The registry's cap on an example's `input` and `output`.
    static let maxPayloadBytes = 48 * 1024
    static let maxErrorLength = 4000
    /// A chat message longer than this is cut.
    static let maxMessageLength = 20_000
    /// Long strings are cut to this when a payload is over the cap.
    static let trimmedStringLength = 2000
    static let trimmedArrayCount = 50

    // MARK: - Candidates

    /// Finished runs of `template` on this Mac, newest first: its installs'
    /// runs and the test runs of drafts built from it.
    @MainActor
    static func runCandidates(for template: Template, limit: Int = 20) -> [ListingExampleDraft] {
        let secretKeys = template.workflow.map(TemplateExportSanitizer.secretFieldKeys) ?? []
        let runs = WorkflowRunStore.shared
        var byID: [UUID: WorkflowRun] = [:]
        let installs = InstalledWorkflowStore.shared.workflows.filter { $0.templateID == template.id }
        for install in installs {
            for run in runs.runs(workflowID: install.id, limit: limit) { byID[run.id] = run }
        }
        for draft in WorkflowDraftStore.shared.drafts(templateID: template.id) {
            for run in runs.runs(workflowID: draft.id, limit: limit) { byID[run.id] = run }
            for id in draft.testRunIDs where byID[id] == nil {
                if let run = runs.run(id: id) { byID[id] = run }
            }
        }
        return
            byID.values
            .filter { $0.status == .completed || $0.status == .failed }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)
            .map { draft(from: $0, secretKeys: secretKeys) }
    }

    /// Recent conversations with agents made from (or saved as) `template`,
    /// newest first, each as its first request and the reply it got.
    @MainActor
    static func chatCandidates(for template: Template, limit: Int = 20) async -> [ListingExampleDraft] {
        let agentIDs = Set(
            AgentManager.shared.agents.filter { agent in
                agent.sourceTemplateID == template.id
                    || Template.slug(for: agent.sourceTemplateName ?? agent.name) == template.slug
            }.map(\.id))
        guard !agentIDs.isEmpty else { return [] }
        let sessions = ChatSessionStore.loadAll()
            .filter { session in session.agentId.map(agentIDs.contains) ?? false }
            .prefix(limit)
        var drafts: [ListingExampleDraft] = []
        for meta in sessions {
            guard let session = await ChatSessionStore.loadAsync(id: meta.id),
                let draft = draft(fromChat: session, templateVersion: template.version)
            else { continue }
            drafts.append(draft)
        }
        return drafts
    }

    // MARK: - Drafts

    static func draft(from run: WorkflowRun, secretKeys: Set<String>) -> ListingExampleDraft {
        let images = run.artifacts
            .filter { $0.isImage && $0.isAvailable && !$0.isDirectory }
            .enumerated()
            .map { index, artifact in
                ListingExampleDraft.ImageDraft(
                    id: artifact.id, filename: artifact.filename, fileURL: URL(fileURLWithPath: artifact.path),
                    included: index < ListingEdits.maxImagesPerExample)
            }
        let duration = run.finishedAt.map { Int(($0.timeIntervalSince(run.startedAt) * 1000).rounded()) }
        let failed = run.status == .failed
        let input = redacted(run.input, secretKeys: secretKeys)
        return ListingExampleDraft(
            source: .run(run.id),
            title: defaultTitle(input: input, date: run.startedAt),
            templateVersion: run.templateVersion,
            status: failed ? .failed : .succeeded,
            durationMs: duration.map { max(0, $0) },
            input: input,
            output: failed ? nil : run.output.map { redacted($0, secretKeys: secretKeys) },
            error: failed ? run.error.map { String(redactedText($0.reason).prefix(maxErrorLength)) } : nil,
            images: images,
            date: run.startedAt)
    }

    /// The conversation's first request and the last reply before the next
    /// request, with the images the agent shared in between. Nil when it
    /// has no reply yet.
    static func draft(fromChat session: ChatSessionData, templateVersion: Int?) -> ListingExampleDraft? {
        let turns = session.turns
        guard let first = turns.firstIndex(where: { $0.role == .user && !$0.content.isBlank }) else { return nil }
        let rest = turns[(first + 1)...]
        let end = rest.firstIndex(where: { $0.role == .user }) ?? turns.endIndex
        let exchange = turns[(first + 1) ..< end]
        guard let reply = exchange.last(where: { $0.role == .assistant && !$0.content.isBlank }) else { return nil }
        let request = redactedText(String(turns[first].content.prefix(maxMessageLength)))
        var seen: Set<String> = []
        let images = exchange.flatMap(\.sharedArtifacts)
            .filter { $0.mimeType.hasPrefix("image/") && !$0.isDirectory && !$0.hostPath.isEmpty }
            .filter { seen.insert($0.hostPath).inserted }
            .enumerated()
            .map { index, artifact in
                ListingExampleDraft.ImageDraft(
                    id: artifact.id, filename: artifact.filename, fileURL: URL(fileURLWithPath: artifact.hostPath),
                    included: index < ListingEdits.maxImagesPerExample)
            }
        let started = turns[first].createdAt ?? session.createdAt
        let finished = reply.completedAt ?? reply.lastOutputAt
        return ListingExampleDraft(
            source: .chat(session.id),
            title: oneLine(request, limit: 60) ?? defaultTitle(input: .null, date: started),
            templateVersion: templateVersion,
            status: .succeeded,
            durationMs: finished.map { max(0, Int(($0.timeIntervalSince(started) * 1000).rounded())) },
            input: fitted(.string(request)),
            output: fitted(.string(redactedText(String(reply.content.prefix(maxMessageLength))))),
            error: nil,
            images: images,
            date: started)
    }

    /// An example already on the listing, to keep, reorder, or drop.
    static func draft(from example: ListingExample) -> ListingExampleDraft {
        ListingExampleDraft(
            source: .published(example.id),
            title: example.title,
            templateVersion: example.templateVersion,
            status: example.status,
            durationMs: example.durationMs,
            input: example.input,
            output: example.output,
            error: example.error,
            images: example.images.map {
                ListingExampleDraft.ImageDraft(
                    id: $0.path, filename: ($0.path as NSString).lastPathComponent, uploaded: $0)
            },
            date: example.createdAt ?? Date())
    }

    // MARK: - Upload shape

    /// What the registry gets for `draft`, given its uploaded images.
    static func upload(_ draft: ListingExampleDraft, images: [ListingExample.Image], index: Int)
        -> WorkflowsRegistryAPIClient.ExampleUpload
    {
        let title = oneLine(draft.title, limit: ListingEdits.maxTitleLength) ?? L("Example \(index + 1)")
        return WorkflowsRegistryAPIClient.ExampleUpload(
            title: title,
            templateVersion: draft.templateVersion.flatMap { $0 >= 1 ? $0 : nil },
            status: draft.status,
            durationMs: draft.durationMs.flatMap { $0 >= 0 ? $0 : nil },
            input: fitted(draft.input),
            output: draft.output.map { fitted($0) },
            error: draft.error.map { String($0.prefix(maxErrorLength)) },
            images: images.prefix(ListingEdits.maxImagesPerExample).map {
                .init(
                    path: $0.path, caption: $0.caption.flatMap { oneLine($0, limit: 200) }, size: $0.size,
                    width: $0.width, height: $0.height)
            })
    }

    // MARK: - Redaction

    /// Secret inputs dropped; paths, URLs, and credential-looking strings
    /// made safe to show.
    static func redacted(_ value: JSONValue, secretKeys: Set<String>) -> JSONValue {
        fitted(scrub(TemplateExportSanitizer.strip(value, keys: secretKeys)))
    }

    private static func scrub(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let o): return .object(o.mapValues(scrub))
        case .array(let list): return .array(list.map(scrub))
        case .string(let s): return .string(scrubString(s))
        default: return value
        }
    }

    private static func scrubString(_ s: String) -> String {
        if s.hasPrefix("http://") || s.hasPrefix("https://"), !s.contains(where: \.isWhitespace) {
            return TemplateExportSanitizer.portableURL(s)
        }
        if TemplateExportSanitizer.looksLikeCredential(s) { return TemplateExportSanitizer.redacted }
        return redactedText(s)
    }

    // swiftlint:disable:next force_try
    private static let tokenPattern = try! NSRegularExpression(pattern: "[A-Za-z0-9_\\-]{20,}")
    // swiftlint:disable:next force_try
    private static let bearerPattern = try! NSRegularExpression(
        pattern: "(?i)\\b(bearer|basic)\\s+[A-Za-z0-9._~+/=\\-]{8,}")

    /// Free text with the home folder shortened to `~` and credential-looking
    /// runs replaced.
    static func redactedText(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var out = home.count > 1 ? text.replacingOccurrences(of: home, with: "~") : text
        let whole = NSRange(out.startIndex..., in: out)
        out = bearerPattern.stringByReplacingMatches(
            in: out, range: whole, withTemplate: "$1 \(TemplateExportSanitizer.redacted)")
        let matches = tokenPattern.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed()
        for match in matches {
            guard let range = Range(match.range, in: out),
                TemplateExportSanitizer.looksLikeCredential(String(out[range]))
            else { continue }
            out.replaceSubrange(range, with: TemplateExportSanitizer.redacted)
        }
        return out
    }

    // MARK: - Size

    static func encodedSize(_ value: JSONValue) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value).count) ?? Int.max
    }

    /// `value` within the registry's payload cap: long strings and arrays
    /// cut first, and a note in its place when that isn't enough.
    static func fitted(_ value: JSONValue) -> JSONValue {
        guard encodedSize(value) > maxPayloadBytes else { return value }
        let trimmed = trim(value)
        guard encodedSize(trimmed) > maxPayloadBytes else { return trimmed }
        return .string(L("Too large to show here."))
    }

    private static func trim(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let o): return .object(o.mapValues(trim))
        case .array(let list):
            var kept = list.prefix(trimmedArrayCount).map(trim)
            if list.count > trimmedArrayCount { kept.append(.string("… \(list.count - trimmedArrayCount) more")) }
            return .array(kept)
        case .string(let s) where s.count > trimmedStringLength:
            return .string(String(s.prefix(trimmedStringLength)) + "…")
        default: return value
        }
    }

    // MARK: - Titles

    /// The first readable string of an already redacted input, else when it ran.
    static func defaultTitle(input: JSONValue, date: Date) -> String {
        func line(_ s: String) -> String? {
            s == TemplateExportSanitizer.redacted ? nil : oneLine(s, limit: 60)
        }
        if case .object(let o) = input {
            for key in o.keys.sorted() {
                if case .string(let s) = o[key], let title = line(s) { return title }
            }
        } else if case .string(let s) = input, let title = line(s) {
            return title
        }
        return L("Run on \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    /// The first line, trimmed and cut to `limit`; nil when empty.
    static func oneLine(_ text: String, limit: Int) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(clean)).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Images

/// Re-encodes an image for a listing: orientation applied, metadata
/// dropped, at most `maxPixelSize` on its long edge, and within the
/// registry's per-image cap. PNG when that fits, JPEG otherwise.
enum ListingImageEncoder {
    struct Encoded: Equatable {
        let data: Data
        let mime: String
        let width: Int
        let height: Int
    }

    enum Failure: Error, Equatable {
        case unreadable
        case tooLarge
    }

    static let maxPixelSize = 2048

    static func encode(contentsOf url: URL, maxBytes: Int = WorkflowsRegistryAPIClient.maxImageBytes) throws
        -> Encoded
    {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw Failure.unreadable }
        return try encode(source: source, maxBytes: maxBytes)
    }

    static func encode(data: Data, maxBytes: Int = WorkflowsRegistryAPIClient.maxImageBytes) throws -> Encoded {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw Failure.unreadable }
        return try encode(source: source, maxBytes: maxBytes)
    }

    private static func encode(source: CGImageSource, maxBytes: Int) throws -> Encoded {
        guard CGImageSourceGetCount(source) > 0 else { throw Failure.unreadable }
        for edge in [maxPixelSize, 1600, 1200, 800] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw Failure.unreadable
            }
            if let png = write(image, type: .png, quality: nil), png.count <= maxBytes {
                return Encoded(data: png, mime: "image/png", width: image.width, height: image.height)
            }
            for quality in [0.85, 0.7] {
                if let jpeg = write(image, type: .jpeg, quality: quality), jpeg.count <= maxBytes {
                    return Encoded(data: jpeg, mime: "image/jpeg", width: image.width, height: image.height)
                }
            }
        }
        throw Failure.tooLarge
    }

    private static func write(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
