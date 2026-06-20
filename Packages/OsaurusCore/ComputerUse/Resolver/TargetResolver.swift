//
//  TargetResolver.swift
//  OsaurusCore — Computer Use
//
//  Maps a model `AgentTarget` (a `mark` number or a `describe` phrase) to a
//  live driver element id against the current `AgentView` + `CUSnapshot`.
//  The model never handles `s7-12` ids; this is the one place mark→id
//  resolution happens, so staleness is handled in exactly one spot.
//
//  Three outcomes, mirroring the spec:
//    - resolved:  a confident unique element.
//    - reobserve: the target probably exists but this view can't pin it
//                 (out-of-range mark, ambiguous/zero describe match). A
//                 fresh capture may help; the loop re-perceives and retries.
//    - deadEnd:   the target is unusable as given (empty), or repeated
//                 reobserve attempts still can't resolve it (decided by the
//                 loop via the consecutive-reobserve counter).
//

import Foundation

public enum TargetResolution: Sendable, Equatable {
    case resolved(elementId: String, element: CUElement)
    case reobserve(reason: String)
    case deadEnd(reason: String)
}

public enum TargetResolver {

    /// Resolve `target` against the current view. Pure: the loop owns
    /// retry/escalation policy (consecutive reobserve → dead-end).
    public static func resolve(
        _ target: AgentTarget?,
        view: AgentView,
        snapshot: CUSnapshot
    ) -> TargetResolution {
        guard let target, !target.isEmpty else {
            return .deadEnd(reason: "No target given. Provide a `mark` number or a `describe` phrase.")
        }

        // Mark is the model's primary handle. An out-of-range mark almost
        // always means the view changed under it → reobserve.
        if let mark = target.mark {
            if let item = view.item(mark: mark) {
                if let element = element(for: item.elementId, in: snapshot) {
                    return .resolved(elementId: element.id, element: element)
                }
                // Mark exists in the view but the snapshot no longer has the id:
                // the view is stale relative to the live tree.
                return .reobserve(reason: "Mark \(mark) is stale. Re-observing for a fresh view.")
            }
            // Out-of-range mark, but a describe fallback may still rescue it.
            if let describe = target.describe, !describe.isEmpty {
                return resolveDescribe(describe, view: view, snapshot: snapshot, markWasStale: true)
            }
            return .reobserve(
                reason: "Mark \(mark) isn't in the current view (\(view.items.count) elements). "
                    + "Re-observing."
            )
        }

        // Describe-only target.
        if let describe = target.describe, !describe.isEmpty {
            return resolveDescribe(describe, view: view, snapshot: snapshot, markWasStale: false)
        }

        return .deadEnd(reason: "Target has neither a `mark` nor a `describe`.")
    }

    // MARK: - Describe matching

    private static func resolveDescribe(
        _ describe: String,
        view: AgentView,
        snapshot: CUSnapshot,
        markWasStale: Bool
    ) -> TargetResolution {
        let needle = describe.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return .reobserve(reason: "Empty describe. Re-observing.")
        }

        // Exact label match wins outright (handles duplicate substrings like
        // "Save" vs "Save As").
        let exact = view.items.filter { ($0.label?.lowercased() == needle) }
        if exact.count == 1, let item = exact.first,
            let element = element(for: item.elementId, in: snapshot)
        {
            return .resolved(elementId: element.id, element: element)
        }

        // Substring over label/value/role.
        let matches = view.items.filter { item in
            if let label = item.label?.lowercased(), label.contains(needle) { return true }
            if let value = item.value?.lowercased(), value.contains(needle) { return true }
            if item.role.lowercased().contains(needle) { return true }
            return false
        }

        if matches.count == 1, let item = matches.first,
            let element = element(for: item.elementId, in: snapshot)
        {
            return .resolved(elementId: element.id, element: element)
        }

        if matches.count > 1 {
            let marks = matches.prefix(6).map { "\($0.mark)" }.joined(separator: ", ")
            return .reobserve(
                reason: "\"\(describe)\" matches \(matches.count) elements (marks \(marks)). "
                    + "Pick one by `mark`."
            )
        }

        // Zero matches. If a stale mark led us here, a fresh view is the right
        // move; otherwise the description likely doesn't match anything visible.
        if markWasStale {
            return .reobserve(reason: "Couldn't find \"\(describe)\" after the mark went stale. Re-observing.")
        }
        return .reobserve(
            reason: "Nothing matches \"\(describe)\" in the current view. Re-observing in case it loads."
        )
    }

    private static func element(for id: String, in snapshot: CUSnapshot) -> CUElement? {
        snapshot.elements.first { $0.id == id }
    }
}
