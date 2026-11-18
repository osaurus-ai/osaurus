//
//  RedactionReviewState.swift
//  osaurus / PrivacyFilter
//
//  ObservableObject backing the redaction review sheet. Created by
//  `PrivacyReviewService` with a continuation; the sheet flips
//  per-row `approved` flags and calls `resolve(_:)` exactly once
//  (Send, Cancel, or the lifecycle dismiss fallback).
//
//  Choices that outlive this send (the conversation policy, category
//  answers, Never Redact entries) are staged here and committed only on
//  Send, so Cancel leaves everything as it was.
//

import Foundation

@MainActor
final class RedactionReviewState: ObservableObject, Identifiable {
    let id = UUID()
    /// The privacy scope (root chat session) this review is for.
    let sessionId: String
    /// Display name of the provider the send is bound for, when known.
    let providerName: String?

    @Published var entities: [DetectedEntity]
    /// The entity currently focused for the context preview. Stored as
    /// the entity's `id` (not an index) so reorder / filter changes
    /// can't accidentally point at the wrong row.
    @Published var selectedEntityID: UUID?

    /// The conversation policy picked in the footer. Starts at the
    /// conversation's policy in force (`initialPolicy`).
    @Published private(set) var policy: ConversationPrivacyPolicy = .ask
    var initialPolicy: ConversationPrivacyPolicy = .ask {
        didSet { policy = initialPolicy }
    }

    /// Never Redact entries staged from row menus, keyed by the row
    /// that added them.
    @Published private(set) var neverRedactAdds: [UUID: NeverRedactEntry] = [:]
    /// Conversation-wide category answers staged from row menus.
    @Published private(set) var categoryAnswers: [EntityCategory: PrivacyCategoryDecision] = [:]

    /// Single-shot resolver. The continuation behind it is finished
    /// in `resolve(_:)`; we guard with a flag because SwiftUI may
    /// fire both a button action and a sheet dismissal in quick
    /// succession.
    var onResolve: ((PrivacyReviewOutcome) -> Void)?
    private(set) var resolved = false

    init(detections: [DetectedEntity], sessionId: String, providerName: String? = nil) {
        self.sessionId = sessionId
        self.providerName = providerName
        self.entities = detections
        // Auto-focus the first detection so the preview has content
        // the moment the sheet appears.
        self.selectedEntityID = detections.first?.id
    }

    var approvedCount: Int { entities.filter(\.approved).count }
    var skippedCount: Int { entities.count - approvedCount }

    /// `true` when every row is redacted, `false` when none is, `nil`
    /// when mixed. Drives the "Redact all" checkbox.
    var allApproved: Bool? {
        if approvedCount == entities.count { return true }
        if approvedCount == 0 { return false }
        return nil
    }

    /// Rows grouped by where their text came from, in first-seen order.
    var groups: [(origin: PrivacySegmentOrigin, entities: [DetectedEntity])] {
        var order: [PrivacySegmentOrigin] = []
        var buckets: [PrivacySegmentOrigin: [DetectedEntity]] = [:]
        for entity in entities {
            if buckets[entity.origin] == nil { order.append(entity.origin) }
            buckets[entity.origin, default: []].append(entity)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// Convenience accessor used by the context preview. Returns `nil`
    /// only if the list is empty.
    var selectedEntity: DetectedEntity? {
        guard let id = selectedEntityID else { return entities.first }
        return entities.first(where: { $0.id == id }) ?? entities.first
    }

    /// The Never Redact entry a row staged, if any.
    func neverRedactEntry(for entity: DetectedEntity) -> NeverRedactEntry? {
        neverRedactAdds[entity.id]
    }

    /// Move focus to `entity`. Idempotent — re-selecting the same row
    /// is a no-op so SwiftUI doesn't churn the preview on every render.
    func select(_ entity: DetectedEntity) {
        guard selectedEntityID != entity.id else { return }
        selectedEntityID = entity.id
    }

    /// Keyboard navigation: move the selection up (`-1`) or down (`+1`)
    /// in display (grouped) order.
    func moveSelection(by delta: Int) {
        let ordered = groups.flatMap(\.entities)
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex(where: { $0.id == selectedEntityID }) ?? 0
        let next = min(max(current + delta, 0), ordered.count - 1)
        selectedEntityID = ordered[next].id
    }

    func toggleSelected() {
        guard let entity = selectedEntity else { return }
        setApproval(entity, to: !entity.approved)
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

    /// Pick the conversation policy. Redact automatically ticks every
    /// row and Off unticks every row, so this send matches the choice.
    func setPolicy(_ newPolicy: ConversationPrivacyPolicy) {
        policy = newPolicy
        switch newPolicy {
        case .autoRedact: approveAll()
        case .off: skipAll()
        case .ask: break
        }
    }

    /// Stage a Never Redact entry from `entity`'s row and send every
    /// row it matches as written.
    func addNeverRedact(_ kind: NeverRedactEntry.Kind, for entity: DetectedEntity) {
        let text = kind == .domain ? (NeverRedactEntry.host(of: entity.original) ?? entity.original) : entity.original
        let entry = NeverRedactEntry(kind: kind, text: text)
        neverRedactAdds[entity.id] = entry
        for row in entities where entry.matches(row.original) {
            setApproval(row, to: false)
        }
    }

    func removeNeverRedact(for entity: DetectedEntity) {
        neverRedactAdds.removeValue(forKey: entity.id)
        setApproval(entity, to: true)
    }

    /// Stage (or clear, with `nil`) a conversation-wide answer for a
    /// category and apply it to this send's rows.
    func setCategoryAnswer(_ category: EntityCategory, _ decision: PrivacyCategoryDecision?) {
        categoryAnswers[category] = decision
        guard let decision else { return }
        for row in entities where row.category == category {
            setApproval(row, to: decision == .alwaysRedact)
        }
    }

    /// Commit the staged choices, then resolve. The commit lands before
    /// the pipeline continues, so the next queued review for this
    /// conversation already sees the new policy and answers.
    func confirm() {
        guard !resolved else { return }
        resolved = true
        let approved = entities
        Task { @MainActor in
            await commitChoices()
            onResolve?(.approved(approved))
        }
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

    private func commitChoices() async {
        let store = SessionRedactionStore.shared
        if policy != initialPolicy {
            await store.setPolicy(sessionId, policy)
        }
        for (category, decision) in categoryAnswers {
            await store.setCategoryDecision(sessionId, category, decision)
        }
        if !neverRedactAdds.isEmpty {
            var config = PrivacyFilterStore.snapshot()
            for entry in neverRedactAdds.values {
                config.addNeverRedact(entry)
            }
            PrivacyFilterStore.save(config)
        }
    }
}
