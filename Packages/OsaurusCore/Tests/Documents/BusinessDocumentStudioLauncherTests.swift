//
//  BusinessDocumentStudioLauncherTests.swift
//  osaurusTests
//
//  Focused coverage for Business Document Studio window identity state.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Business document studio launcher")
struct BusinessDocumentStudioLauncherTests {

    @Test func rekeyMovesWindowIdentityAndCloseRemovesCurrentSource() {
        let cache = BusinessDocumentStudioWindowCache<WindowToken>()
        let window = WindowToken()
        let first = URL(fileURLWithPath: "/tmp/first.pdf")
        let second = URL(fileURLWithPath: "/tmp/second.pdf")

        guard case .claimed = cache.claim(first, for: window) else {
            Issue.record("Expected the first source claim to succeed")
            return
        }
        guard case .claimed = cache.claim(second, for: window) else {
            Issue.record("Expected the replacement source claim to succeed")
            return
        }

        #expect(cache.window(for: first) == nil)
        #expect(cache.window(for: second) === window)
        #expect(cache.sourceURL(for: window) == second.standardizedFileURL)

        cache.remove(window)

        #expect(cache.window(for: second) == nil)
        #expect(cache.sourceURL(for: window) == nil)
    }

    @Test func selfReimportSucceedsAndCollisionPreservesBothExistingIdentities() {
        let cache = BusinessDocumentStudioWindowCache<WindowToken>()
        let firstWindow = WindowToken()
        let secondWindow = WindowToken()
        let firstSource = URL(fileURLWithPath: "/tmp/first.pdf")
        let secondSource = URL(fileURLWithPath: "/tmp/second.pdf")

        _ = cache.claim(firstSource, for: firstWindow)
        _ = cache.claim(secondSource, for: secondWindow)

        guard case .claimed = cache.claim(firstSource, for: firstWindow) else {
            Issue.record("Expected a window to reclaim its current source")
            return
        }
        guard case .occupied(let owner) = cache.claim(firstSource, for: secondWindow) else {
            Issue.record("Expected the other window source claim to be rejected")
            return
        }

        #expect(owner === firstWindow)
        #expect(cache.window(for: firstSource) === firstWindow)
        #expect(cache.window(for: secondSource) === secondWindow)
        #expect(cache.sourceURL(for: secondWindow) == secondSource.standardizedFileURL)
    }

    @Test func sourceAndSymlinkAliasShareOneWindowIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("business-document-source-\(UUID().uuidString)", isDirectory: true)
        let source = directory.appendingPathComponent("report.pdf")
        let alias = directory.appendingPathComponent("report-alias.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = BusinessDocumentStudioWindowCache<WindowToken>()
        let sourceWindow = WindowToken()
        let aliasWindow = WindowToken()
        guard case .claimed = cache.claim(source, for: sourceWindow) else {
            Issue.record("Expected the source window claim to succeed")
            return
        }
        guard case .occupied(let owner) = cache.claim(alias, for: aliasWindow) else {
            Issue.record("Expected the symlink alias to resolve to the existing owner")
            return
        }

        #expect(owner === sourceWindow)
        #expect(cache.window(for: alias) === sourceWindow)
        #expect(cache.sourceURL(for: sourceWindow) == source.resolvingSymlinksInPath().standardizedFileURL)
        #expect(BusinessDocumentStudioSourceIdentity.standardized(alias) == source.resolvingSymlinksInPath())
    }

    @Test func sourceTransitionRequiresClaimBeforeReturningAcceptedURL() {
        let selected = URL(fileURLWithPath: "/tmp/folder/../report.pdf")
        var claimedURL: URL?

        let accepted = BusinessDocumentStudioSourceIdentity.acceptedSourceURL(selected) { sourceURL in
            claimedURL = sourceURL
            return true
        }
        let rejected = BusinessDocumentStudioSourceIdentity.acceptedSourceURL(selected) { _ in false }

        #expect(accepted == selected.standardizedFileURL)
        #expect(claimedURL == selected.standardizedFileURL)
        #expect(rejected == nil)
        #expect(
            BusinessDocumentStudioSourceIdentity.windowTitle(for: selected, fallback: "Workbench")
                == "report.pdf"
        )
    }
}

private final class WindowToken {}
