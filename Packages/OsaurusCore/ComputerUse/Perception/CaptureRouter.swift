//
//  CaptureRouter.swift
//  OsaurusCore — Computer Use
//
//  The local-first perception router (PR3). It decides which capture tier to
//  use and — crucially — whether a frame is allowed to leave the device.
//
//  The ladder is ax → som → vision, escalated only when the accessibility
//  tree can't carry the step (a target won't resolve, the tree is empty, or
//  pixels are explicitly needed). Each rung past `ax` needs Screen Recording;
//  without it the router stays on `ax` and the loop must work with what the
//  AX tree provides (or `give_up`).
//
//  Routes split into:
//    • `.local(tier)` — everything is processed on-device (AX, on-device OCR).
//    • `.cloudVision(ScrubbedFrame)` — a frame may be sent to a cloud model,
//      but ONLY a `ScrubbedFrame` (produced solely by `FrameScrubber`) can be
//      attached, and the route can only be built when consent is granted.
//      Together those two facts make "cloud vision without consent + scrub"
//      unrepresentable in the type system, not merely discouraged.
//

import Foundation

/// Why the harness wants to escalate past the current tier.
public enum EscalationReason: String, Sendable, Equatable {
    /// The `TargetResolver` couldn't map the model's target to an element.
    case targetUnresolved
    /// The accessibility tree came back empty/near-empty (Electron, custom-drawn UI).
    case axEmpty
    /// A recipe or the model explicitly needs the pixels (charts, canvases).
    case pixelsRequested
}

/// Where a perceived frame is processed.
public enum CaptureRoute: Sendable, Equatable {
    /// On-device only — AX tree and/or local Vision OCR. The default.
    case local(CaptureTier)
    /// A scrubbed frame may be sent to a cloud model. Unconstructible without a
    /// `ScrubbedFrame` (see `FrameScrubber`) AND consent (see `cloudRoute`).
    case cloudVision(ScrubbedFrame)
}

public enum CaptureRouter {

    /// The next tier to capture at, one rung up the ladder. Returns `.ax`
    /// unchanged whenever Screen Recording is missing — pixels are simply not
    /// available, so there is nothing to escalate to.
    public static func nextTier(
        current: CaptureTier,
        reason: EscalationReason,
        availability: MacDriverAvailability
    ) -> CaptureTier {
        guard availability.screenRecording else { return .ax }
        switch current {
        case .ax: return .som
        case .som: return .vision
        case .vision: return .vision
        }
    }

    /// Whether escalation past `current` is even possible right now. False when
    /// already at `vision` or when Screen Recording isn't granted.
    public static func canEscalate(
        from current: CaptureTier,
        availability: MacDriverAvailability
    ) -> Bool {
        guard availability.screenRecording else { return false }
        return current != .vision
    }

    /// Decide whether an empty / near-empty AX view should escalate the capture
    /// tier — the Electron / custom-drawn-UI case where the accessibility tree
    /// carries nothing to act on. Returns the tier to capture at next, or `nil`
    /// to stay put. Honors the `axEmpty` escalation reason and the same
    /// Screen-Recording gate as `canEscalate`: with no pixels available there is
    /// nothing to climb to, so the loop must work with the AX tree (or surface a
    /// clear message). `threshold` is the minimum actionable element count; the
    /// default of 1 escalates only on a truly empty view, which avoids
    /// over-escalating legitimately simple screens.
    public static func escalateForEmptyAX(
        currentTier: CaptureTier,
        itemCount: Int,
        availability: MacDriverAvailability,
        threshold: Int = 1
    ) -> CaptureTier? {
        guard itemCount < max(0, threshold) else { return nil }
        guard canEscalate(from: currentTier, availability: availability) else { return nil }
        return nextTier(current: currentTier, reason: .axEmpty, availability: availability)
    }

    /// Whether the cloud-vision route is permitted at all. Requires explicit
    /// consent and Screen Recording (no pixels, no cloud vision). This is the
    /// FIRST half of the hard rule; the second half is that the route can only
    /// carry a `ScrubbedFrame`.
    public static func cloudVisionPermitted(
        consentGranted: Bool,
        availability: MacDriverAvailability
    ) -> Bool {
        consentGranted && availability.screenRecording
    }

    /// Build the cloud-vision route. Returns `nil` unless consent is granted,
    /// so the harness physically cannot reach `cloudVision` without BOTH a
    /// scrubbed frame (the only thing this accepts) and consent. Callers that
    /// get `nil` must stay local or `give_up`.
    public static func cloudRoute(
        scrubbed: ScrubbedFrame,
        consentGranted: Bool,
        availability: MacDriverAvailability
    ) -> CaptureRoute? {
        guard cloudVisionPermitted(consentGranted: consentGranted, availability: availability) else {
            return nil
        }
        return .cloudVision(scrubbed)
    }
}
