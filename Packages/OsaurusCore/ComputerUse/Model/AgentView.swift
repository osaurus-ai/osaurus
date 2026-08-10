//
//  AgentView.swift
//  OsaurusCore — Computer Use
//
//  The model's compact, id-free picture of an app. The driver speaks
//  `s7-12` element ids; the model must never see or invent those (they
//  rotate per snapshot and tempt the model to fabricate them). Instead the
//  harness renders a numbered `mark` per actionable element and keeps the
//  mark→id mapping on its side (`TargetResolver`).
//
//  `changed` is the verify signal: after an action the loop builds a fresh
//  view against the previous one and flags which marks moved/changed value/
//  appeared, so the model (and the feed) can confirm the action landed
//  without trusting a self-report.
//

import Foundation

// MARK: - Item

/// One actionable element as the model sees it: a number, what it is, and
/// whether it just changed. The `elementId` is harness-internal — never
/// rendered to the model.
public struct AgentViewItem: Sendable, Equatable {
    public let mark: Int
    /// Harness-internal live driver id (`s7-12`). Not shown to the model.
    public let elementId: String
    /// Harness-internal window identity used to keep duplicate controls from
    /// different app windows separate across verify captures.
    public let windowId: Int?
    /// Human-readable window context rendered only when the app exposes more
    /// than one window in the current view.
    public let windowTitle: String?
    public let windowFocused: Bool
    public let role: String
    public let label: String?
    public let value: String?
    public let enabled: Bool
    /// True when this element is new or changed value vs the previous view.
    public let changed: Bool

    public init(
        mark: Int,
        elementId: String,
        windowId: Int? = nil,
        windowTitle: String? = nil,
        windowFocused: Bool = false,
        role: String,
        label: String?,
        value: String?,
        enabled: Bool,
        changed: Bool
    ) {
        self.mark = mark
        self.elementId = elementId
        self.windowId = windowId
        self.windowTitle = windowTitle
        self.windowFocused = windowFocused
        self.role = role
        self.label = label
        self.value = value
        self.enabled = enabled
        self.changed = changed
    }
}

// MARK: - View

public struct AgentView: Sendable, Equatable {
    public let snapshotId: Int
    public let app: String
    public let focusedWindow: String?
    public let tier: CaptureTier
    public let truncated: Bool
    public let items: [AgentViewItem]
    /// Number of elements present in the previous view but gone from this
    /// one — a verify signal (a dialog closed, a row deleted).
    public let removedCount: Int

    public init(
        snapshotId: Int,
        app: String,
        focusedWindow: String?,
        tier: CaptureTier,
        truncated: Bool,
        items: [AgentViewItem],
        removedCount: Int
    ) {
        self.snapshotId = snapshotId
        self.app = app
        self.focusedWindow = focusedWindow
        self.tier = tier
        self.truncated = truncated
        self.items = items
        self.removedCount = removedCount
    }

    /// Whether anything changed vs the previous view (verify signal).
    public var hasChanges: Bool { removedCount > 0 || items.contains { $0.changed } }

    /// Look up an item by its 1-based mark.
    public func item(mark: Int) -> AgentViewItem? {
        items.first { $0.mark == mark }
    }

    // MARK: Builder

    /// Build a fresh view from a snapshot, computing the `changed` delta
    /// against `previous`. Elements are matched across snapshots by
    /// (role, label) since the live `s…` ids rotate every capture.
    public static func build(from snapshot: CUSnapshot, previous: AgentView?) -> AgentView {
        // Index the previous view's values by a stable (role|label) key so we
        // can detect new/changed elements. A nil previous means first capture:
        // nothing is "changed" because there's no baseline.
        var previousValues: [String: [String?]] = [:]
        if let previous {
            for item in previous.items {
                previousValues[
                    matchKey(windowId: item.windowId, role: item.role, label: item.label),
                    default: []
                ].append(
                    item.value
                )
            }
        }

        var items: [AgentViewItem] = []
        items.reserveCapacity(snapshot.elements.count)
        var consumed: [String: Int] = [:]  // how many of each key we've matched
        let windowsById = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.id, $0) })

        for (index, element) in snapshot.elements.enumerated() {
            let key = matchKey(windowId: element.windowId, role: element.role, label: element.label)
            let window = element.windowId.flatMap { windowsById[$0] }
            let visibleValue = visibleValue(for: element)
            let changed: Bool
            if previous == nil {
                changed = false
            } else if let candidates = previousValues[key] {
                let already = consumed[key, default: 0]
                if already < candidates.count {
                    let prevValue = candidates[already]
                    consumed[key] = already + 1
                    changed = normalize(prevValue) != normalize(visibleValue)
                } else {
                    // More of this element than before → an extra one appeared.
                    changed = true
                }
            } else {
                changed = true  // element not present in the previous view
            }

            items.append(
                AgentViewItem(
                    mark: index + 1,
                    elementId: element.id,
                    windowId: element.windowId,
                    windowTitle: window?.title,
                    windowFocused: window?.focused ?? false,
                    role: element.role,
                    label: element.label,
                    value: visibleValue,
                    enabled: element.enabled,
                    changed: changed
                )
            )
        }

        // Removed = previous elements that have no surviving match this view.
        var removedCount = 0
        if let previous {
            var currentCounts: [String: Int] = [:]
            for element in snapshot.elements {
                currentCounts[
                    matchKey(windowId: element.windowId, role: element.role, label: element.label),
                    default: 0
                ] += 1
            }
            var prevCounts: [String: Int] = [:]
            for item in previous.items {
                prevCounts[
                    matchKey(windowId: item.windowId, role: item.role, label: item.label),
                    default: 0
                ] += 1
            }
            for (key, prevCount) in prevCounts {
                let nowCount = currentCounts[key, default: 0]
                if prevCount > nowCount { removedCount += (prevCount - nowCount) }
            }
        }

        return AgentView(
            snapshotId: snapshot.snapshotId,
            app: snapshot.app,
            focusedWindow: snapshot.focusedWindow,
            tier: snapshot.tier,
            truncated: snapshot.truncated,
            items: items,
            removedCount: removedCount
        )
    }

    private static func matchKey(windowId: Int?, role: String, label: String?) -> String {
        String(windowId ?? -1) + "|" + role.lowercased() + "|" + (label?.lowercased() ?? "")
    }

    private static func normalize(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func visibleValue(for element: CUElement) -> String? {
        // Secure fields are never diffed by value; a change marker would reveal
        // that secret input changed even when the value itself is hidden.
        CUSecureFieldRole.contains(element.role) ? nil : element.value
    }

    // MARK: Model rendering

    /// Render the view as compact text for the model — id-free, one line per
    /// element, with a `*` marking elements that just changed (verify hint).
    public func renderForModel(maxItems: Int = 120) -> String {
        var lines: [String] = []
        var header = "App: \(app)"
        if let focusedWindow, !focusedWindow.isEmpty { header += " — window \"\(focusedWindow)\"" }
        header += " [tier: \(tier.rawValue)]"
        lines.append(header)
        if removedCount > 0 {
            lines.append("(\(removedCount) element\(removedCount == 1 ? "" : "s") disappeared since last view)")
        }

        let shown = items.prefix(maxItems)
        let hasMultipleWindows = Set(items.compactMap(\.windowId)).count > 1
        for item in shown {
            var line = item.changed ? "* [" : "  ["
            line += "\(item.mark)] \(item.role)"
            if hasMultipleWindows {
                if let title = item.windowTitle, !title.isEmpty {
                    line += " [window \"\(title)\"\(item.windowFocused ? ", focused" : "")]"
                } else if let windowId = item.windowId {
                    line += " [window \(windowId)\(item.windowFocused ? ", focused" : "")]"
                }
            }
            if let label = item.label, !label.isEmpty { line += " \"\(label)\"" }
            if let value = item.value, !value.isEmpty {
                let clipped = value.count > 60 ? String(value.prefix(60)) + "…" : value
                line += " = \"\(clipped)\""
            }
            if !item.enabled { line += " (disabled)" }
            lines.append(line)
        }
        if items.count > shown.count {
            lines.append("… \(items.count - shown.count) more elements (use find to narrow).")
        }
        if items.isEmpty {
            lines.append("(no actionable elements found)")
        }
        return lines.joined(separator: "\n")
    }
}
