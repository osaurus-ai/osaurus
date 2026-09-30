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
//    - ambiguous: multiple visible candidates; the model should choose a mark.
//    - reobserve: the target probably exists but this view can't pin it
//                 (out-of-range mark, stale mark, zero describe match). A
//                 fresh capture may help; the loop re-perceives and retries.
//    - deadEnd:   the target is unusable as given (empty), or repeated
//                 reobserve attempts still can't resolve it (decided by the
//                 loop via the consecutive-reobserve counter).
//

import Foundation

public enum TargetResolutionStrategy: String, Sendable, Equatable, Codable {
    case mark
    case exactLabel
    case exactValue
    case uniqueDescribe
}

public struct TargetResolutionEvidence: Sendable, Equatable, Codable {
    public let strategy: TargetResolutionStrategy
    /// 0...1 resolver confidence. This is a deterministic resolver score, not
    /// a model probability.
    public let confidence: Double
    public let matchedMarks: [Int]

    public init(strategy: TargetResolutionStrategy, confidence: Double, matchedMarks: [Int]) {
        self.strategy = strategy
        self.confidence = confidence
        self.matchedMarks = matchedMarks
    }
}

public struct TargetResolutionCandidate: Sendable, Equatable, Codable {
    public let mark: Int
    public let role: String
    public let label: String?
    public let value: String?
    public let confidence: Double
    public let reason: String

    public init(
        mark: Int,
        role: String,
        label: String?,
        value: String?,
        confidence: Double,
        reason: String
    ) {
        self.mark = mark
        self.role = role
        self.label = label
        self.value = value
        self.confidence = confidence
        self.reason = reason
    }
}

public enum TargetResolution: Sendable, Equatable {
    case resolved(elementId: String, element: CUElement, evidence: TargetResolutionEvidence)
    case ambiguous(reason: String, candidates: [TargetResolutionCandidate])
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
                    return .resolved(
                        elementId: element.id,
                        element: element,
                        evidence: TargetResolutionEvidence(
                            strategy: .mark,
                            confidence: 1.0,
                            matchedMarks: [mark]
                        )
                    )
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

        // Exact label match wins outright when unique (handles duplicate
        // substrings like "Save" vs "Save As"). Duplicate exact labels are
        // ambiguous and require the model to choose a mark.
        let exact = view.items.filter { ($0.label?.lowercased() == needle) }
        if exact.count == 1, let item = exact.first {
            guard let element = element(for: item.elementId, in: snapshot) else {
                return .reobserve(reason: "The exact match for \"\(describe)\" went stale. Re-observing.")
            }
            return .resolved(
                elementId: element.id,
                element: element,
                evidence: TargetResolutionEvidence(
                    strategy: .exactLabel,
                    confidence: 0.98,
                    matchedMarks: [item.mark]
                )
            )
        }
        if exact.count > 1 {
            return .ambiguous(
                reason: "\"\(describe)\" exactly matches \(exact.count) elements. Pick one by `mark`.",
                candidates: exact.map {
                    candidate(from: $0, confidence: 0.98, reason: "exact label")
                }
            )
        }

        // Conservative scored matching over label/value/role. A single match
        // resolves with evidence; multiple matches stay ambiguous rather than
        // guessing by score.
        let matches = view.items.compactMap { scoredCandidate(for: $0, needle: needle) }
            .sorted {
                if $0.confidence == $1.confidence { return $0.item.mark < $1.item.mark }
                return $0.confidence > $1.confidence
            }

        if matches.count == 1, let match = matches.first {
            let item = match.item
            guard let element = element(for: item.elementId, in: snapshot) else {
                return .reobserve(reason: "The match for \"\(describe)\" went stale. Re-observing.")
            }
            return .resolved(
                elementId: element.id,
                element: element,
                evidence: TargetResolutionEvidence(
                    strategy: match.strategy,
                    confidence: match.confidence,
                    matchedMarks: [item.mark]
                )
            )
        }

        if matches.count > 1 {
            let candidates = Array(matches.prefix(6))
            let marks = candidates.map { "\($0.item.mark)" }.joined(separator: ", ")
            let capNote = matches.count > candidates.count ? " Showing top \(candidates.count)." : ""
            return .ambiguous(
                reason: "\"\(describe)\" matches \(matches.count) elements (marks \(marks)).\(capNote) "
                    + "Pick one by `mark`.",
                candidates: candidates.map {
                    candidate(from: $0.item, confidence: $0.confidence, reason: $0.reason)
                }
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

    private struct ScoredCandidate {
        let item: AgentViewItem
        let confidence: Double
        let strategy: TargetResolutionStrategy
        let reason: String
    }

    private static func scoredCandidate(for item: AgentViewItem, needle: String) -> ScoredCandidate? {
        if let value = item.value?.lowercased(), value == needle {
            return ScoredCandidate(item: item, confidence: 0.92, strategy: .exactValue, reason: "exact value")
        }
        if let label = item.label?.lowercased(), label.hasPrefix(needle) {
            return ScoredCandidate(item: item, confidence: 0.82, strategy: .uniqueDescribe, reason: "label prefix")
        }
        if let label = item.label?.lowercased(), label.contains(needle) {
            return ScoredCandidate(item: item, confidence: 0.72, strategy: .uniqueDescribe, reason: "label contains")
        }
        if let value = item.value?.lowercased(), value.contains(needle) {
            return ScoredCandidate(item: item, confidence: 0.62, strategy: .uniqueDescribe, reason: "value contains")
        }
        if item.role.lowercased().contains(needle) {
            return ScoredCandidate(item: item, confidence: 0.42, strategy: .uniqueDescribe, reason: "role contains")
        }
        return nil
    }

    private static func candidate(
        from item: AgentViewItem,
        confidence: Double,
        reason: String
    ) -> TargetResolutionCandidate {
        TargetResolutionCandidate(
            mark: item.mark,
            role: item.role,
            label: item.label,
            value: item.value,
            confidence: confidence,
            reason: reason
        )
    }
}
