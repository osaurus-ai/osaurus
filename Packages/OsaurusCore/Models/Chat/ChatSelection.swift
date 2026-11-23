//
//  ChatSelection.swift
//  osaurus
//
//  The chats a window has marked for a batch action (archive, pin,
//  delete). Per window, never persisted. The sidebar and the All chats
//  page share one selection, so moving between them keeps it.
//

import Foundation

struct ChatSelection: Equatable {
    private(set) var selectedIds: Set<UUID> = []
    /// The chat a Shift-click range starts from: the last one toggled.
    private(set) var anchorId: UUID?
    /// Selection mode asked for from a menu (`Select chats`, `Select`)
    /// while nothing is ticked yet.
    private(set) var isModeRequested = false

    /// Every chat row shows its checkbox and hides its hover actions.
    var isActive: Bool { !selectedIds.isEmpty || isModeRequested }
    var count: Int { selectedIds.count }

    func contains(_ id: UUID) -> Bool { selectedIds.contains(id) }

    /// What a click on a chat row does. A plain click always opens the
    /// chat, even while other chats are selected.
    enum ClickOutcome: Equatable {
        case open
        case toggle
        case extendRange
    }

    static func clickOutcome(command: Bool, shift: Bool) -> ClickOutcome {
        if command { return .toggle }
        if shift { return .extendRange }
        return .open
    }

    mutating func toggle(_ id: UUID) {
        if selectedIds.remove(id) == nil { selectedIds.insert(id) }
        anchorId = id
    }

    mutating func select(_ ids: some Sequence<UUID>) {
        selectedIds.formUnion(ids)
    }

    mutating func deselect(_ ids: some Sequence<UUID>) {
        selectedIds.subtract(ids)
        if let anchorId, !selectedIds.contains(anchorId) { self.anchorId = nil }
    }

    /// Adds every row between the anchor (else `fallbackAnchor`, the chat
    /// on screen) and `id` in `visibleOrder`. With no anchor on screen it
    /// toggles `id` alone.
    mutating func selectRange(to id: UUID, visibleOrder: [UUID], fallbackAnchor: UUID?) {
        guard let anchor = anchorId ?? fallbackAnchor,
            let from = visibleOrder.firstIndex(of: anchor),
            let to = visibleOrder.firstIndex(of: id)
        else {
            toggle(id)
            return
        }
        selectedIds.formUnion(visibleOrder[min(from, to) ... max(from, to)])
        if anchorId == nil { anchorId = anchor }
    }

    mutating func requestMode() {
        isModeRequested = true
    }

    mutating func clear() {
        self = ChatSelection()
    }

    /// Drops chats that no longer exist (deleted in another window, or by
    /// sync) without leaving selection mode.
    mutating func prune(existing: Set<UUID>) {
        guard !selectedIds.isSubset(of: existing) else { return }
        selectedIds.formIntersection(existing)
        if let anchorId, !existing.contains(anchorId) { self.anchorId = nil }
    }

    /// Whether a row's menu acts on the selection or on the row alone.
    func menuScope(for rowId: UUID) -> ChatRowMenuScope {
        selectedIds.contains(rowId) && selectedIds.count > 1 ? .batch(selectedIds.count) : .single
    }
}

enum ChatRowMenuScope: Equatable {
    case single
    case batch(Int)
}
