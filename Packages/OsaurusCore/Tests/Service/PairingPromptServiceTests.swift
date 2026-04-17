//
//  PairingPromptServiceTests.swift
//  OsaurusCoreTests
//

import Testing

@testable import OsaurusCore

struct PairingPromptServiceTests {
    @Test func enterShortcutPreservesPermanentChoice() {
        let temporary = PairingPromptService.shortcutAction(for: 36, isPermanent: false)
        #expect(temporary == .allow(isPermanent: false))

        let permanent = PairingPromptService.shortcutAction(for: 36, isPermanent: true)
        #expect(permanent == .allow(isPermanent: true))
    }

    @Test func escapeShortcutDenies() {
        #expect(PairingPromptService.shortcutAction(for: 53, isPermanent: true) == .deny)
    }

    @Test func unrelatedShortcutDoesNothing() {
        #expect(PairingPromptService.shortcutAction(for: 0, isPermanent: true) == .none)
    }
}
