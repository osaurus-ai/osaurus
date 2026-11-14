//
//  FeedParserTests.swift
//  osaurusTests
//
//  RSS 2.0, RSS 1.0 / RDF, Atom and JSON Feed into one item shape: ids,
//  links, dates, authors, categories, HTML reduced to text, and the
//  order items are handed on in.
//

import Foundation
import Testing

@testable import OsaurusCore

struct FeedParserTests {
    private func parse(_ text: String, contentType: String? = nil) throws -> FeedDocument {
        try FeedParser.parse(Data(text.utf8), contentType: contentType)
    }

    @Test func readsRSS2() throws {
        let feed = try parse(
            """
            <?xml version="1.0"?>
            <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"
                 xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:atom="http://www.w3.org/2005/Atom">
              <channel>
                <title>Example News</title>
                <link>https://example.com</link>
                <atom:link href="https://example.com/feed.xml" rel="self"/>
                <image><title>Logo</title><url>https://example.com/logo.png</url></image>
                <item>
                  <title>Second &amp; newest</title>
                  <link>https://example.com/2</link>
                  <guid isPermaLink="false">post-2</guid>
                  <pubDate>Tue, 13 Oct 2026 09:30:00 GMT</pubDate>
                  <description><![CDATA[<p>Hello <b>world</b></p>]]></description>
                  <content:encoded><![CDATA[<p>Full text</p>]]></content:encoded>
                  <dc:creator>Sam</dc:creator>
                  <category>Swift</category>
                  <category>Apple</category>
                </item>
                <item>
                  <title>First</title>
                  <link>https://example.com/1</link>
                  <pubDate>Mon, 12 Oct 2026 09:30:00 +0000</pubDate>
                </item>
              </channel>
            </rss>
            """)
        #expect(feed.title == "Example News")
        #expect(feed.link == "https://example.com")
        #expect(feed.items.count == 2)
        let newest = feed.items[0]
        #expect(newest.id == "post-2")
        #expect(newest.title == "Second & newest")
        #expect(newest.link == "https://example.com/2")
        #expect(newest.summary.contains("Hello"))
        #expect(!newest.summary.contains("<"))
        #expect(newest.content?.contains("Full text") == true)
        #expect(newest.author == "Sam")
        #expect(newest.categories == ["Swift", "Apple"])
        #expect(newest.published == ISO8601DateFormatter().date(from: "2026-10-13T09:30:00Z"))
        #expect(feed.items[1].id == "https://example.com/1", "no guid: the link is the id")
    }

    @Test func readsAtom() throws {
        let feed = try parse(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
              <title>Atom Blog</title>
              <link href="https://blog.example.com/" rel="alternate"/>
              <link href="https://blog.example.com/atom.xml" rel="self"/>
              <id>urn:feed</id>
              <entry>
                <title>Hello Atom</title>
                <link href="https://blog.example.com/edit/1" rel="edit"/>
                <link href="https://blog.example.com/hello"/>
                <id>urn:entry:1</id>
                <updated>2026-10-14T08:00:00Z</updated>
                <author><name>Robin</name><email>r@example.com</email></author>
                <summary type="html">&lt;p&gt;A summary&lt;/p&gt;</summary>
                <category term="news"/>
                <media:group><media:title>Video title</media:title><media:content url="x"/></media:group>
              </entry>
            </feed>
            """)
        #expect(feed.title == "Atom Blog")
        #expect(feed.link == "https://blog.example.com/")
        let entry = try #require(feed.items.first)
        #expect(entry.id == "urn:entry:1")
        #expect(entry.title == "Hello Atom", "media:title must not replace the entry title")
        #expect(entry.link == "https://blog.example.com/hello")
        #expect(entry.author == "Robin")
        #expect(entry.summary == "A summary")
        #expect(entry.categories == ["news"])
        #expect(entry.published == ISO8601DateFormatter().date(from: "2026-10-14T08:00:00Z"))
    }

    @Test func readsRDF() throws {
        let feed = try parse(
            """
            <?xml version="1.0"?>
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/"
                     xmlns:dc="http://purl.org/dc/elements/1.1/">
              <channel rdf:about="https://example.org/"><title>RDF Feed</title></channel>
              <item rdf:about="https://example.org/a">
                <title>Item A</title>
                <link>https://example.org/a</link>
                <dc:date>2026-10-01T00:00:00Z</dc:date>
              </item>
            </rdf:RDF>
            """)
        #expect(feed.title == "RDF Feed")
        #expect(feed.items.map(\.id) == ["https://example.org/a"])
        #expect(feed.items.first?.published != nil)
    }

    @Test func readsJSONFeed() throws {
        let feed = try parse(
            """
            {"version": "https://jsonfeed.org/version/1.1", "title": "JSON Blog",
             "home_page_url": "https://json.example.com/",
             "items": [{"id": 7, "url": "https://json.example.com/7", "title": "Seven",
                        "content_html": "<p>Body</p>", "date_published": "2026-10-10T10:00:00Z",
                        "authors": [{"name": "Kai"}], "tags": ["a", "b"]}]}
            """, contentType: "application/feed+json")
        #expect(feed.title == "JSON Blog")
        let item = try #require(feed.items.first)
        #expect(item.id == "7")
        #expect(item.link == "https://json.example.com/7")
        #expect(item.content == "Body")
        #expect(item.summary == "Body")
        #expect(item.author == "Kai")
        #expect(item.categories == ["a", "b"])
    }

    @Test func identityFallsBackToAStableHash() {
        let a = FeedParser.identity(guid: nil, link: nil, title: "Untitled", published: nil)
        let b = FeedParser.identity(guid: " ", link: "", title: "Untitled", published: nil)
        #expect(a.hasPrefix("sha256:"))
        #expect(a == b)
        #expect(FeedParser.identity(guid: nil, link: nil, title: "Other", published: nil) != a)
    }

    @Test func htmlPageIsNotAFeed() {
        #expect(throws: FeedParseError.notAFeed) {
            try parse("<html><head><title>Hi</title></head><body></body></html>")
        }
        #expect(throws: FeedParseError.notAFeed) { try parse(#"{"hello": "world"}"#) }
    }

    @Test func datesInCommonFormats() {
        #expect(FeedDates.parse("2026-10-14T08:00:00.250Z") != nil)
        #expect(FeedDates.parse("2026-10-14") != nil)
        #expect(FeedDates.parse("Wed, 14 Oct 2026 08:00:00 PDT") != nil)
        #expect(FeedDates.parse("Wed, 4 Oct 2026 08:00:00 -0700") != nil)
        #expect(FeedDates.parse("yesterday") == nil)
    }

    @Test func oldestFirstUsesDatesWhenEveryItemHasOne() {
        let now = Date()
        func item(_ id: String, _ offset: TimeInterval?) -> FeedItem {
            FeedItem(
                id: id, title: id, link: nil, published: offset.map { now.addingTimeInterval($0) }, author: nil,
                summary: "", content: nil, categories: [])
        }
        #expect(RSSFeedState.oldestFirst([item("b", 10), item("a", 0), item("c", 20)]).map(\.id) == ["a", "b", "c"])
        #expect(
            RSSFeedState.oldestFirst([item("new", nil), item("mid", 5), item("old", nil)]).map(\.id)
                == ["old", "mid", "new"], "a missing date falls back to reversed document order")
    }
}
