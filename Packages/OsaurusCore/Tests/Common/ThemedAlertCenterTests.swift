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

    // MARK: - Nested alerts over a container dialog

    /// A request flagged `hostsNestedAlerts` (the chat History dialog) is
    /// NOT replaced by an alert presented while it is on top: the new one
    /// stacks above it, the container keeps its presenter, and dismissing
    /// the nested alert brings the container back as the active request.
    @Test func nestedAlertStacksOverHostingContainerAndPopsBack() {
        let center = ThemedAlertCenter.shared
        let scope = ThemedAlertScope.chat(UUID())

        var containerDismissed = false
        let container = ThemedAlertRequest(
            title: "History",
            message: nil,
            buttons: [],
            hostsNestedAlerts: true,
            onDismiss: { containerDismissed = true }
        )
        let nested = ThemedAlertRequest(
            title: "Delete Conversation?",
            message: nil,
            buttons: [],
            onDismiss: {}
        )

        center.present(container, scope: scope)
        center.present(nested, scope: scope)
        #expect(containerDismissed == false, "The container must survive a nested alert")
        #expect(center.active(for: scope)?.id == nested.id)
        #expect(center.stack(for: scope).map(\.id) == [container.id, nested.id])

        center.dismiss(scope: scope, id: nested.id)
        #expect(center.active(for: scope)?.id == container.id)
        #expect(center.stack(for: scope).count == 1)

        center.dismiss(scope: scope, id: container.id)
        #expect(center.active(for: scope) == nil)
    }

    /// The single-slot rule still applies ABOVE the container: a second
    /// nested alert replaces the first nested one (resetting its presenter)
    /// rather than growing the stack, and the container stays underneath.
    @Test func secondNestedAlertReplacesFirstNestedNotContainer() {
        let center = ThemedAlertCenter.shared
        let scope = ThemedAlertScope.chat(UUID())

        let container = ThemedAlertRequest(
            title: "History", message: nil, buttons: [], hostsNestedAlerts: true, onDismiss: {}
        )
        var firstNestedDismissed = false
        let firstNested = ThemedAlertRequest(
            title: "Export", message: nil, buttons: [], onDismiss: { firstNestedDismissed = true }
        )
        let secondNested = ThemedAlertRequest(
            title: "Exporting…", message: nil, buttons: [], onDismiss: {}
        )

        center.present(container, scope: scope)
        center.present(firstNested, scope: scope)
        center.present(secondNested, scope: scope)
        #expect(firstNestedDismissed)
        #expect(center.stack(for: scope).map(\.id) == [container.id, secondNested.id])

        center.dismiss(scope: scope, id: secondNested.id)
        #expect(center.active(for: scope)?.id == container.id)
        center.dismiss(scope: scope, id: container.id)
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
        #expect(plain.headerImageNames.isEmpty)
        #expect(plain.headerImageAccessibilityLabel == nil)

        let artwork = ThemedAlertRequest(
            title: "Launch",
            message: "Body",
            headerImageNames: ["osaurus-thanks", "ph-cat"],
            headerImageAccessibilityLabel: "Osaurus dinosaur and the Product Hunt kitty saying thank you",
            buttons: [],
            onDismiss: {}
        )
        #expect(artwork.headerImageNames == ["osaurus-thanks", "ph-cat"])

        center.present(artwork, scope: scope)
        #expect(center.active(for: scope)?.headerImageNames == ["osaurus-thanks", "ph-cat"])
        center.dismiss(scope: scope, id: artwork.id)
        #expect(center.active(for: scope) == nil)
    }
}
