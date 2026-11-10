//
//  FeedParser.swift
//  osaurus
//
//  Reads RSS 2.0 (and RSS 1.0 / RDF), Atom and JSON Feed documents into
//  one item shape for the RSS automation. HTML in descriptions and content
//  is reduced to text, since it goes to prompts and workflow inputs.
//

import CryptoKit
import Foundation

struct FeedItem: Equatable, Sendable {
    /// Stable identity for dedupe: the guid / id, else the link, else a
    /// hash of title and date.
    var id: String
    var title: String
    var link: String?
    var published: Date?
    var author: String?
    var summary: String
    var content: String?
    var categories: [String]

    static func example(now: Date) -> FeedItem {
        FeedItem(
            id: "https://example.com/posts/1", title: L("A new post"), link: "https://example.com/posts/1",
            published: now, author: L("Alex"), summary: L("The first lines of the post."), content: nil,
            categories: [L("News")])
    }
}

struct FeedDocument: Equatable, Sendable {
    var title: String
    var link: String?
    /// In document order (feeds list newest first, usually).
    var items: [FeedItem]
}

enum FeedParseError: LocalizedError, Equatable {
    case notAFeed
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notAFeed: L("The URL did not return an RSS, Atom or JSON feed.")
        case .malformed(let detail): L("The feed could not be read: \(detail)")
        }
    }
}

enum FeedParser {
    static func parse(_ data: Data, contentType: String? = nil) throws -> FeedDocument {
        let type = contentType?.lowercased() ?? ""
        if type.contains("json") || firstByte(of: data) == UInt8(ascii: "{") {
            return try parseJSONFeed(data)
        }
        return try XMLFeedReader.read(data)
    }

    private static func firstByte(of data: Data) -> UInt8? {
        data.first { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D || $0 == 0xEF || $0 == 0xBB || $0 == 0xBF) }
    }

    // MARK: - JSON Feed

    static func parseJSONFeed(_ data: Data) throws -> FeedDocument {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), root.objectValue != nil else {
            throw FeedParseError.notAFeed
        }
        guard root.value(atPath: "version")?.stringValue?.contains("jsonfeed.org") == true
            || root.value(atPath: "items")?.arrayValue != nil
        else { throw FeedParseError.notAFeed }
        let items = (root.value(atPath: "items")?.arrayValue ?? []).map { item -> FeedItem in
            let title = item.value(atPath: "title")?.stringValue ?? ""
            let link = item.value(atPath: "url")?.stringValue ?? item.value(atPath: "external_url")?.stringValue
            let published = (item.value(atPath: "date_published") ?? item.value(atPath: "date_modified"))?
                .stringValue.flatMap(FeedDates.parse)
            let html = item.value(atPath: "content_html")?.stringValue
            let text = item.value(atPath: "content_text")?.stringValue
            let content = text ?? html.map(EmailMIME.htmlToText)
            let summary = item.value(atPath: "summary")?.stringValue ?? content ?? ""
            let author =
                item.value(atPath: "authors")?.arrayValue?.first?.value(atPath: "name")?.stringValue
                ?? item.value(atPath: "author.name")?.stringValue
            let tags = (item.value(atPath: "tags")?.arrayValue ?? []).compactMap(\.stringValue)
            return FeedItem(
                id: identity(guid: item.value(atPath: "id").map(EventTemplate.text(of:)), link: link, title: title,
                    published: published),
                title: title, link: link, published: published, author: author,
                summary: FeedText.clip(summary), content: content.map(FeedText.clip), categories: tags)
        }
        return FeedDocument(
            title: root.value(atPath: "title")?.stringValue ?? "",
            link: root.value(atPath: "home_page_url")?.stringValue, items: items)
    }

    static func identity(guid: String?, link: String?, title: String, published: Date?) -> String {
        if let guid = guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty { return guid }
        if let link = link?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty { return link }
        let seed = title + "|" + (published.map(EventPayload.iso8601) ?? "")
        return "sha256:" + SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum FeedText {
    static let maxChars = 20_000

    static func clip(_ text: String) -> String {
        text.count > maxChars ? String(text.prefix(maxChars)) : text
    }

    /// Text when `raw` looks like HTML, `raw` trimmed otherwise.
    static func plain(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("<") || trimmed.contains("&") else { return trimmed }
        return EmailMIME.htmlToText(trimmed)
    }
}

enum FeedDates {
    private static let rfc822Formats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm zzz",
        "EEE, dd MMM yyyy HH:mm Z", "EEE, dd MMM yyyy",
    ]

    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withFullDate]
        if let date = iso.date(from: trimmed) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in rfc822Formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}

// MARK: - XML (RSS / RDF / Atom)

private final class XMLFeedReader: NSObject, XMLParserDelegate {
    private enum Format { case unknown, rss, atom }

    private struct Draft {
        var guid: String?
        var title = ""
        var link: String?
        var published: String?
        var updated: String?
        var author: String?
        var summary: String?
        var content: String?
        var categories: [String] = []
    }

    private var format = Format.unknown
    private var stack: [String] = []
    private var text = ""
    private var feedTitle = ""
    private var feedLink: String?
    private var current: Draft?
    private var items: [FeedItem] = []
    private var authorDepth: Int?

    static func read(_ data: Data) throws -> FeedDocument {
        let reader = XMLFeedReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let ok = parser.parse()
        guard reader.format != .unknown else {
            if !ok, let error = parser.parserError { throw FeedParseError.malformed(error.localizedDescription) }
            throw FeedParseError.notAFeed
        }
        if !ok, reader.items.isEmpty, let error = parser.parserError {
            throw FeedParseError.malformed(error.localizedDescription)
        }
        return FeedDocument(title: reader.feedTitle, link: reader.feedLink, items: reader.items)
    }

    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map { String($0).lowercased() } ?? name.lowercased()
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        let local = Self.local(name)
        if stack.isEmpty {
            switch local {
            case "rss", "rdf": format = .rss
            case "feed": format = .atom
            default: break
            }
        }
        stack.append(name)
        text = ""
        if local == "item" || local == "entry" {
            current = Draft()
            return
        }
        if local == "author", current != nil { authorDepth = stack.count }
        if local == "link", format == .atom {
            let rel = attributeDict["rel"]?.lowercased() ?? "alternate"
            guard rel == "alternate", let href = attributeDict["href"] else { return }
            if current != nil {
                if current?.link == nil { current?.link = href }
            } else if feedLink == nil {
                feedLink = href
            }
        }
        if local == "category", current != nil, let term = attributeDict["term"], !term.isEmpty {
            current?.categories.append(term)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?)
    {
        let name = elementName.lowercased()
        let local = Self.local(name)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            if stack.last == name { stack.removeLast() }
            text = ""
        }
        if local == "item" || local == "entry", let draft = current {
            items.append(finish(draft))
            current = nil
            return
        }
        guard current != nil else {
            // Channel / feed level: the first title and link outside items.
            if local == "title", feedTitle.isEmpty, stack.count <= 3 { feedTitle = value }
            if local == "link", format == .rss, feedLink == nil, !value.isEmpty, name == "link" { feedLink = value }
            return
        }
        if let depth = authorDepth {
            if local == "name", stack.count == depth + 1 { current?.author = value }
            if local == "author", stack.count == depth {
                if current?.author == nil, !value.isEmpty { current?.author = value }
                authorDepth = nil
            }
            return
        }
        // Exact names: extension elements such as `media:title` or an empty
        // `media:content` must not overwrite the item's own fields.
        guard !value.isEmpty else { return }
        switch name {
        case "title": current?.title = FeedText.plain(value)
        case "link" where format == .rss: current?.link = value
        case "guid", "id": current?.guid = value
        case "pubdate", "published", "dc:date", "issued": current?.published = value
        case "updated", "modified": current?.updated = value
        case "dc:creator", "author": current?.author = value
        case "description", "summary": current?.summary = value
        case "content:encoded", "content": current?.content = value
        case "category": current?.categories.append(value)
        default: break
        }
    }

    private func finish(_ draft: Draft) -> FeedItem {
        let published = (draft.published ?? draft.updated).flatMap(FeedDates.parse)
        let content = draft.content.map(FeedText.plain).flatMap { $0.isEmpty ? nil : $0 }
        let summary = draft.summary.map(FeedText.plain) ?? content ?? ""
        return FeedItem(
            id: FeedParser.identity(guid: draft.guid, link: draft.link, title: draft.title, published: published),
            title: draft.title, link: draft.link, published: published, author: draft.author,
            summary: FeedText.clip(summary), content: content.map(FeedText.clip), categories: draft.categories)
    }
}
