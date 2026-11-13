//
//  SettingsAbilityRowAccessoryTests.swift
//  osaurusTests
//
//  An unlabeled trailing closure on `SettingsAbilityRow` must become the
//  accessory. Under forward-scan matching it used to bind to
//  `onPausedNoteTap` / `onConfigure`, which hid the Working Folder picker
//  and the Knowledge collection grants (#3394) without a compile error.
//

import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
struct SettingsAbilityRowAccessoryTests {
    @Test func trailingClosureAfterIsActiveIsAccessory() {
        let row = SettingsAbilityRow(title: "Working Folder", isActive: true) {
            Text(verbatim: "picker")
        }
        #expect(type(of: row) == SettingsAbilityRow<Text>.self)
    }

    @Test func trailingClosureAfterPausedNoteTapIsAccessory() {
        let row = SettingsAbilityRow(
            title: "Knowledge",
            isOn: .constant(true),
            pausedNote: "Paused",
            onPausedNoteTap: {}
        ) {
            Text(verbatim: "collections")
        }
        #expect(type(of: row) == SettingsAbilityRow<Text>.self)
    }

    @Test func trailingClosureAfterOnConfigureIsAccessory() {
        let row = SettingsAbilityRow(
            title: "Database",
            isOn: .constant(true),
            pausedNote: "Paused",
            onPausedNoteTap: {},
            configureLabel: "Open",
            onConfigure: {}
        ) {
            Text(verbatim: "hint")
        }
        #expect(type(of: row) == SettingsAbilityRow<Text>.self)
    }

    @Test func noClosureHasNoAccessory() {
        let row = SettingsAbilityRow(title: "Tools", isOn: .constant(true), onConfigure: {})
        #expect(type(of: row) == SettingsAbilityRow<EmptyView>.self)
    }
}
