//
//  ScrubResult.swift
//  osaurus / PrivacyFilter
//
//  Detection-time data structures. `DetectedEntity` is what the engine
//  hands back to the review sheet; the sheet can flip `approved` per
//  row; `PrivacyFilterEngine.apply(_:to:)` walks the approved subset
//  and produces the scrubbed string captured in `ScrubResult`.
//

import Foundation

/// One detected PII span in an outbound message. `placeholder` is
/// pre-interned into the conversation's `RedactionMap` at detection
/// time so the review sheet can show stable tokens. If the user toggles
/// `approved = false`, the placeholder stays in the map but is never
/// substituted into the wire payload — cheap, and keeps category
/// indices monotonic regardless of approval order.
public struct DetectedEntity: Identifiable, Sendable {
    public let id: UUID
    public let category: EntityCategory
    public let original: String
    public let range: Range<String.Index>
    public let placeholder: Placeholder
    public var approved: Bool
    /// The full source segment this detection was extracted from
    /// (typically a single message's `content` or tool-call argument
    /// string). `nil` for callers that don't have the segment text
    /// handy — `PrivacyFilterPipeline.applyOutbound` stamps it
    /// during detection so the review sheet can surface surrounding
    /// context for documents the user pasted in. Stored as
    /// immutable so the struct stays trivially `Sendable`.
    public let containingText: String?

    public init(
        id: UUID = UUID(),
        category: EntityCategory,
        original: String,
        range: Range<String.Index>,
        placeholder: Placeholder,
        approved: Bool = true,
        containingText: String? = nil
    ) {
        self.id = id
        self.category = category
        self.original = original
        self.range = range
        self.placeholder = placeholder
        self.approved = approved
        self.containingText = containingText
    }

    /// Copy-with-context helper for the pipeline: detection runs
    /// per-segment, so the engine returns entities with `containingText = nil`
    /// and the caller stamps the segment text into a fresh copy
    /// before dedup. Kept here (rather than on the pipeline) so the
    /// invariant "containingText is set iff the producer had the
    /// segment in scope" lives next to the struct.
    public func withContainingText(_ text: String) -> DetectedEntity {
        DetectedEntity(
            id: id,
            category: category,
            original: original,
            range: range,
            placeholder: placeholder,
            approved: approved,
            containingText: text
        )
    }
}

extension DetectedEntity: Hashable {
    public static func == (lhs: DetectedEntity, rhs: DetectedEntity) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Snapshot returned after the user has confirmed redactions. `scrubbed`
/// is the text actually sent to the cloud; `entities` is the approved
/// subset (so callers can render a "we redacted N items" badge without
/// re-running detection).
public struct ScrubResult: Sendable {
    public let original: String
    public let scrubbed: String
    public let entities: [DetectedEntity]

    public init(original: String, scrubbed: String, entities: [DetectedEntity]) {
        self.original = original
        self.scrubbed = scrubbed
        self.entities = entities
    }
}
