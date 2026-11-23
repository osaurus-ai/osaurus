//
//  CLIAccessStoreTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct CLIAccessStoreTests {
    private func fileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cli-access-\(UUID().uuidString).json")
    }

    @Test func mintedTokenValidatesAndSurvivesReload() throws {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let token = CLIAccessStore(fileURL: url).mint(label: "list")
        #expect(token.hasPrefix("osc_"))
        let reloaded = CLIAccessStore(fileURL: url)
        #expect(reloaded.isValid(token))
        #expect(!reloaded.isValid(token + "x"))
        #expect(!reloaded.isValid(nil))
        #expect(!reloaded.isValid("osh_" + token.dropFirst(4)))
    }

    @Test func fileHoldsOnlyHashesAndIsOwnerOnly() throws {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let token = CLIAccessStore(fileURL: url).mint(label: "list")
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(!contents.contains(token))
        #expect(contents.contains(CLIAccessStore.hash(token)))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func revokeAllInvalidatesEveryToken() {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CLIAccessStore(fileURL: url)
        let a = store.mint(label: "a")
        let b = store.mint(label: "b")
        store.revokeAll()
        #expect(!store.isValid(a))
        #expect(!store.isValid(b))
        #expect(!CLIAccessStore(fileURL: url).isValid(a))
    }

    @Test func oldestApprovalsAreDroppedPastTheCap() {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CLIAccessStore(fileURL: url)
        let first = store.mint(label: "first")
        for index in 0 ..< CLIAccessStore.maxApprovals { _ = store.mint(label: "\(index)") }
        #expect(store.list().count == CLIAccessStore.maxApprovals)
        #expect(!store.isValid(first))
    }

    @Test func onePromptAtATimeAndCooldownAfterDeny() {
        let store = CLIAccessStore(fileURL: fileURL())
        let now = Date()
        #expect(store.beginPrompt(now: now) == .open)
        #expect(store.beginPrompt(now: now) == .promptAlreadyOpen)
        store.endPrompt(denied: true, now: now)
        #expect(store.beginPrompt(now: now.addingTimeInterval(1)) == .coolingDown(retryAfter: 29))
        #expect(store.beginPrompt(now: now.addingTimeInterval(CLIAccessStore.denyCooldown + 1)) == .open)
        store.endPrompt(denied: false, now: now)
        #expect(store.beginPrompt(now: now.addingTimeInterval(CLIAccessStore.denyCooldown + 2)) == .open)
    }

    @Test func labelIsSanitized() {
        #expect(CLIAccessStore.sanitizedLabel("workflow run \u{202E}evil\n") == "workflow run evil")
        #expect(CLIAccessStore.sanitizedLabel(String(repeating: "a", count: 100)).count == 48)
    }
}
