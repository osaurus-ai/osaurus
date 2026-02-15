//
//  ExpandedBlocksStore.swift
//  osaurus
//
//  Tracks which collapsible blocks (tool calls, thinking blocks, code
//  sections) are currently expanded. Stored per-session so that
//  expand/collapse state survives NSTableView cell reuse and SwiftUI
//  view recycling.
//
//  Injected via `.environmentObject()` so that SwiftUI views using
//  `@EnvironmentObject` properly subscribe to changes and re-render
//  when expand/collapse state changes.
//

import SwiftUI

/// Observable store of expanded block IDs.
///
/// Each expandable UI element registers a stable string key (e.g. the
/// tool call ID, thinking block content-block ID, or code section ID).
/// The store persists across cell reuse because it lives on the session,
/// not inside a SwiftUI `@State`.
final class ExpandedBlocksStore: ObservableObject, @unchecked Sendable {

    /// The set of currently expanded block keys.
    @Published var expandedIds: Set<String> = []

    func isExpanded(_ id: String) -> Bool {
        expandedIds.contains(id)
    }

    func toggle(_ id: String) {
        if expandedIds.contains(id) {
            expandedIds.remove(id)
        } else {
            expandedIds.insert(id)
        }
    }

    func expand(_ id: String) {
        expandedIds.insert(id)
    }

    func collapse(_ id: String) {
        expandedIds.remove(id)
    }
}
