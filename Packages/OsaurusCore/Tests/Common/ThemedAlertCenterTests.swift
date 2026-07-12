//
//  ThemedAlertCenterTests.swift
//  osaurusTests
//
//  Covers the single-slot-per-scope contract of `ThemedAlertCenter`.
//  A scope holds at most one alert, so presenting a new alert replaces
//  whatever is already showing. The regression guarded here: when the
//  replacement has a different id (e.g. the async sandbox-cleanup notice
//  landing while an agent's delete-confirmation is open), the clobbered
//  presenter must be reset via its `onDismiss`. Before the fix it was
//  silently dropped, leaving the source view's `isPresented` `@State`
//  wedged at `true` so its `onChange`-driven re-present never fired again
//  — which is why agent deletion stopped working after a few deletes.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ThemedAlertCenterTests {

    // Each test uses a fresh UUID-backed scope so the shared singleton
    // can't leak state between (parallel) tests.

    @Test func presentReplacingDifferentIdResetsPriorPresenter() {
        let center = ThemedAlertCenter.shared
        let scope = ThemedAlertScope.chat(UUID())

        var firstDismissed = false
        let first = ThemedAlertRequest(
            title: "First",
            message: nil,
            buttons: [],
            onDismiss: { firstDismissed = true }
        )
        let second = ThemedAlertRequest(
            title: "Second",
            message: nil,
            buttons: [],
            onDismiss: {}
        )

        center.present(first, scope: scope)
        #expect(center.active(for: scope)?.id == first.id)
        #expect(firstDismissed == false)

        center.present(second, scope: scope)
        #expect(
            firstDismissed,
            "Replacing an alert with a different id must reset the clobbered presenter"
        )
        #expect(center.active(for: scope)?.id == second.id)

        center.dismiss(scope: scope, id: second.id)
    }

    @Test func presentSameIdDoesNotResetPresenter() {
        let center = ThemedAlertCenter.shared
        let scope = ThemedAlertScope.chat(UUID())

        var dismissed = false
        let request = ThemedAlertRequest(
            title: "Only",
            message: nil,
            buttons: [],
            onDismiss: { dismissed = true }
        )

        center.present(request, scope: scope)
        center.present(request, scope: scope)

        #expect(
            dismissed == false,
            "Re-presenting the same alert id must not reset its binding"
        )
        #expect(center.active(for: scope)?.id == request.id)

        center.dismiss(scope: scope, id: request.id)
    }

    // MARK: - Cross-scope occupancy

    /// `hasAnyActiveAlert` is the read-only "is anything showing anywhere"
    /// signal the Product Hunt launch dialog uses to avoid stacking. It must
    /// flip on for an alert in ANY scope and off again once every scope is
    /// clear.
    @Test func hasAnyActiveAlert_reflects_occupancy_across_scopes() {
        let center = ThemedAlertCenter.shared
        let chatScope = ThemedAlertScope.chat(UUID())
        let permissionScope = ThemedAlertScope.toolPermission(UUID())

        let first = ThemedAlertRequest(title: "First", message: nil, buttons: [], onDismiss: {})
        let second = ThemedAlertRequest(title: "Second", message: nil, buttons: [], onDismiss: {})

        center.present(first, scope: chatScope)
        #expect(center.hasAnyActiveAlert)

        // A second alert in a DIFFERENT scope keeps occupancy on even after
        // the first is dismissed.
        center.present(second, scope: permissionScope)
        center.dismiss(scope: chatScope, id: first.id)
        #expect(center.hasAnyActiveAlert)
        #expect(center.active(for: chatScope) == nil)

        center.dismiss(scope: permissionScope, id: second.id)
        #expect(center.active(for: permissionScope) == nil)
        #expect(!center.hasAnyActiveAlert)
    }

    /// The new occupancy accessor and header-artwork fields must not disturb
    /// the existing single-slot contract: defaulted header fields stay nil
    /// and present/dismiss behaves exactly as before.
    @Test func headerArtwork_defaults_nil_and_slot_contract_holds() {
        let center = ThemedAlertCenter.shared
        let scope = ThemedAlertScope.chat(UUID())

        let plain = ThemedAlertRequest(title: "Plain", message: "Body", buttons: [], onDismiss: {})
        #expect(plain.headerImageName == nil)
        #expect(plain.headerImageAccessibilityLabel == nil)

        let artwork = ThemedAlertRequest(
            title: "Launch",
            message: "Body",
            headerImageName: "osaurus-thanks",
            headerImageAccessibilityLabel: "Osaurus dinosaur saying thank you",
            buttons: [],
            onDismiss: {}
        )
        #expect(artwork.headerImageName == "osaurus-thanks")

        center.present(artwork, scope: scope)
        #expect(center.active(for: scope)?.headerImageName == "osaurus-thanks")
        center.dismiss(scope: scope, id: artwork.id)
        #expect(center.active(for: scope) == nil)
    }
}
