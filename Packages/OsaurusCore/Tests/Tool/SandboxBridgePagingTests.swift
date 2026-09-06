//
//  SandboxBridgePagingTests.swift
//  osaurusTests
//
//  `/workspace/...` file_search calls route to the sandbox bridge, which has
//  no offset of its own; the bridge pages the returned match lines the way
//  the host route does. Before this, `offset` was read and dropped, so
//  every page was the first page.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SandboxBridgePagingTests {

    private let ten = (1...10).map { "src/file\($0).swift:1: match" }.joined(separator: "\n")

    @Test func middlePageDropsOffsetAndPointsAtTheNextOne() {
        let page = pageSandboxMatches(ten, offset: 3, maxResults: 4)
        #expect(page.returned == 4)
        #expect(page.available == 10)
        #expect(page.nextOffset == 7)
        #expect(page.text.hasPrefix("src/file4.swift"))
        #expect(page.text.contains("src/file7.swift"))
        #expect(!page.text.contains("src/file8.swift:"))
        #expect(page.text.contains("next_offset=7"))
        #expect(page.footer?.contains("`offset: 7`") == true)
    }

    @Test func lastPageHasNoFooter() {
        let page = pageSandboxMatches(ten, offset: 8, maxResults: 4)
        #expect(page.returned == 2)
        #expect(page.nextOffset == nil)
        #expect(page.footer == nil)
        #expect(!page.text.contains("next_offset"))
    }

    @Test func offsetPastTheEndIsEmptyAndSaysSo() {
        let page = pageSandboxMatches(ten, offset: 12, maxResults: 4)
        #expect(page.returned == 0)
        #expect(page.offsetPastEnd)
        #expect(page.text.isEmpty)
        let none = pageSandboxMatches("", offset: 0, maxResults: 4)
        #expect(none.returned == 0 && none.offsetPastEnd == false)
    }

    @Test func firstPageIsUnchangedShape() {
        let page = pageSandboxMatches(ten, offset: 0, maxResults: 50)
        #expect(page.returned == 10)
        #expect(page.nextOffset == nil)
        #expect(page.text == ten)
    }
}
