//
//  RedactionReviewState.swift
//  osaurus / PrivacyFilter
//
//  ObservableObject backing the redaction review sheet. Created by
//  `PrivacyReviewService` with a continuation; the sheet flips
//  per-row `approved` flags and calls `resolve(_:)` exactly once
//  (Approve, Skip All, Cancel, or the lifecycle dismiss fallback).
//

import Foundation

@MainActor
final class RedactionReviewState: ObservableObject, Identifiable {
    let id = UUID()
    let sessionId: String

    @Published var entities: [DetectedEntity]
    @Published var alwaysApprove: Bool = false
    /// The entity currently focused in the right-hand context pane.
    /// Mutated by row taps; `nil` only briefly before the first
    /// auto-select fires. Stored as the entity's `id` (not an
    /// index) so reorder / filter changes can't accidentally
    /// point at the wrong row.
    @Published var selectedEntityID: UUID?

    /// Single-shot resolver. The continuation behind it is finished
    /// in `resolve(_:)`; we guard with a flag because SwiftUI may
    /// fire both a button action and a sheet dismissal in quick
    /// succession.
    var onResolve: ((PrivacyReviewOutcome) -> Void)?
    private var resolved = false

    init(detections: [DetectedEntity], sessionId: String) {
        self.sessionId = sessionId
        self.entities = detections
        // Auto-focus the first detection so the right pane has
        // content the moment the sheet appears.
        self.selectedEntityID = detections.first?.id
    }

    var approvedCount: Int { entities.filter(\.approved).count }
    var skippedCount: Int { entities.count - approvedCount }

    /// Convenience accessor used by the right-hand context pane.
    /// Returns `nil` only if the list is empty or the selection
    /// somehow points at a removed entity (defensive — we never
    /// remove rows in practice).
    var selectedEntity: DetectedEntity? {
        guard let id = selectedEntityID else { return entities.first }
        return entities.first(where: { $0.id == id }) ?? entities.first
    }

    /// Move focus to `entity` in the right-hand context pane.
    /// Idempotent — re-selecting the same row is a no-op so SwiftUI
    /// doesn't churn the detail view on every render.
    func select(_ entity: DetectedEntity) {
        guard selectedEntityID != entity.id else { return }
        selectedEntityID = entity.id
    }

    func toggleApproval(_ entity: DetectedEntity) {
        guard let idx = entities.firstIndex(where: { $0.id == entity.id }) else { return }
        entities[idx].approved.toggle()
    }

    /// Set approval to an explicit value. Preferred over `toggleApproval`
    /// from SwiftUI bindings — using the binding's `newValue` (instead
    /// of toggling whatever the current state happens to be) keeps the
    /// UI and model in lock-step even if SwiftUI fires `set` twice per
    /// interaction (e.g. during transition animations).
    func setApproval(_ entity: DetectedEntity, to value: Bool) {
        guard let idx = entities.firstIndex(where: { $0.id == entity.id }) else { return }
        if entities[idx].approved != value {
            entities[idx].approved = value
        }
    }

    func approveAll() {
        for idx in entities.indices {
            entities[idx].approved = true
        }
    }

    func skipAll() {
        for idx in entities.indices {
            entities[idx].approved = false
        }
    }

    func confirm() {
        guard !resolved else { return }
        resolved = true
        // Mirror the toggle's final state to the session store so a
        // user who turns it off mid-review actually gets review again
        // on the next send (previously this only ever wrote `true`).
        let desired = alwaysApprove
        Task { await SessionRedactionStore.shared.setAutoApprove(sessionId, enabled: desired) }
        onResolve?(.approved(entities))
    }

    func cancel() {
        guard !resolved else { return }
        resolved = true
        onResolve?(.canceled)
    }

    /// Fallback when the sheet is dismissed without an explicit
    /// button press (e.g. user hits Escape). Treated as cancel so the
    /// pending send doesn't silently fire with unreviewed redactions.
    func sheetDismissed() {
        cancel()
    }
}
