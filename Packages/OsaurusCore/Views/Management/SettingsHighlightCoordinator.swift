//
//  SettingsHighlightCoordinator.swift
//  osaurus
//
//  Phase 2 of global settings search: after a search result navigates to its
//  tab, this coordinator publishes the target control's anchor id so the tab
//  can scroll to it and the control can glow. The pending id auto-clears after
//  a short window so the glow is a one-time landing cue.
//

import SwiftUI

@MainActor
final class SettingsHighlightCoordinator: ObservableObject {
    static let shared = SettingsHighlightCoordinator()

    /// Anchor id of the control to scroll to and glow. Matches `SettingsSearchEntry.id`.
    @Published var pending: String?

    private var clearTask: Task<Void, Never>?

    private init() {}

    /// Request a landing highlight for `anchorId`. Re-requesting the same id
    /// re-arms the glow (so selecting the same result twice flashes again).
    func request(_ anchorId: String) {
        clearTask?.cancel()
        // Drop then re-set so an identical id still publishes a change.
        pending = nil
        pending = anchorId
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            if self?.pending == anchorId { self?.pending = nil }
        }
    }
}

/// The coordinator's current pending anchor, propagated through the environment
/// so every tab's controls react uniformly. `ManagementView` injects this from
/// the (observed) coordinator; relying on an `@ObservedObject` inside the
/// landing modifier alone didn't re-render reliably for tabs that appear after
/// the pending id is set.
private struct SettingsLandingPendingKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsLandingPending: String? {
        get { self[SettingsLandingPendingKey.self] }
        set { self[SettingsLandingPendingKey.self] = newValue }
    }
}

extension View {
    /// Marks a settings control as the scroll target + glow recipient for the
    /// landing anchor `id`. Pairs `.id(id)` (so a `ScrollViewReader` can reach
    /// it) with a glow that fires while this id is the pending landing target.
    /// A `nil` id is a no-op, so untagged controls are unaffected.
    @ViewBuilder
    func settingsLandingAnchor(_ id: String?) -> some View {
        if let id {
            modifier(SettingsLandingAnchorModifier(anchorId: id))
        } else {
            self
        }
    }
}

private struct SettingsLandingAnchorModifier: ViewModifier {
    let anchorId: String
    @Environment(\.settingsLandingPending) private var pending

    func body(content: Content) -> some View {
        content
            .id(anchorId)
            .settingsSearchHighlight(pending == anchorId)
    }
}
