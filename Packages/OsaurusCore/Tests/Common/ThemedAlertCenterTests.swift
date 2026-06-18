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
}
