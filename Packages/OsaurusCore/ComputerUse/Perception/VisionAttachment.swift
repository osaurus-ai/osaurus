//
//  VisionAttachment.swift
//  OsaurusCore — Computer Use
//
//  The integration glue between the capture ladder and the model request. When
//  perception escalates past `ax` and a target still won't resolve, the loop
//  has pixels in hand (`CUSnapshot.image`); this type decides whether — and
//  how — those pixels may reach the model. It is the single place the
//  local-vs-cloud trust boundary is decided:
//
//    • A local (on-device) model receives the frame as-is — the pixels never
//      leave the machine, the same trust posture as the AX text we already
//      send.
//    • A remote/cloud model may receive a frame ONLY when the user granted
//      cloud-vision consent (`CloudVisionConsent`) AND only after
//      `FrameScrubber` produces a `ScrubbedFrame` (enforced downstream by
//      `CaptureRouter.cloudRoute`). Absent consent the harness stays local.
//
//  `decide(...)` is a pure, synchronous function so it is fully unit-testable
//  without a live model or driver; the async scrub + the actual message
//  attachment stay in `ComputerUseLoop`.
//

import Foundation

/// The model/consent context a run carries for vision escalation. Resolved
/// once at run start by `ComputerUseTool` (the active model and the consent
/// state can't change under a running loop), so the decision stays stable for
/// the whole run.
public struct VisionContext: Sendable, Equatable {
    /// Whether the active model can accept image input at all.
    public let modelAcceptsImages: Bool
    /// Whether the active model runs on-device (pixels never leave the machine).
    public let modelIsLocal: Bool
    /// Whether the user granted cloud-vision consent. Only consulted for remote
    /// models — a local model never crosses the trust boundary.
    public let cloudConsent: Bool
    /// How a screenshot bound for a cloud model is redacted. Defaults to
    /// `.allText` (mask every recognized region — nothing readable leaves the
    /// device); a user can opt into `.pii` (mask only detected sensitive text)
    /// from Settings → Computer Use. Resolved once at run start so it can't
    /// change under a running loop. Ignored for on-device models.
    public let cloudScrubMode: ScrubMode

    public init(
        modelAcceptsImages: Bool,
        modelIsLocal: Bool,
        cloudConsent: Bool,
        cloudScrubMode: ScrubMode = .allText
    ) {
        self.modelAcceptsImages = modelAcceptsImages
        self.modelIsLocal = modelIsLocal
        self.cloudConsent = cloudConsent
        self.cloudScrubMode = cloudScrubMode
    }

    /// A copy with cloud-vision consent overridden — used when a run obtains
    /// just-in-time consent mid-loop (the snapshot taken at run start stays
    /// otherwise unchanged).
    public func withConsent(_ granted: Bool) -> VisionContext {
        VisionContext(
            modelAcceptsImages: modelAcceptsImages,
            modelIsLocal: modelIsLocal,
            cloudConsent: granted,
            cloudScrubMode: cloudScrubMode
        )
    }

    /// A context that never attaches pixels — the safe default for non-chat
    /// callers (HTTP / eval) where no model or consent state has been resolved.
    public static let none = VisionContext(
        modelAcceptsImages: false,
        modelIsLocal: false,
        cloudConsent: false
    )
}

public enum VisionAttachment {
    /// What the loop should do with a freshly captured frame.
    public enum Plan: Sendable, Equatable {
        /// Don't attach any pixels — work from the AX text only.
        case none
        /// Attach the frame directly; it stays on-device (local model).
        case localFrame(CUImage)
        /// The frame must be scrubbed (`FrameScrubber`) and routed through
        /// `CaptureRouter.cloudRoute` before it can be attached to a cloud model.
        case needsScrubForCloud(CUImage)
    }

    /// Decide how a captured frame may reach the model. Pure + synchronous so
    /// it's trivially testable; the loop performs the async scrub for the
    /// `.needsScrubForCloud` case and only then attaches the scrubbed frame.
    public static func decide(
        image: CUImage?,
        context: VisionContext,
        availability: MacDriverAvailability
    ) -> Plan {
        // No pixels available, or the model can't read images — nothing to attach.
        guard let image, context.modelAcceptsImages else { return .none }
        // On-device model: the frame never crosses a trust boundary, so it goes
        // through unscrubbed (same posture as the AX text already sent).
        if context.modelIsLocal { return .localFrame(image) }
        // Remote model: permitted only with consent (+ Screen Recording), and even
        // then only as a scrubbed frame — the loop scrubs next.
        guard
            CaptureRouter.cloudVisionPermitted(
                consentGranted: context.cloudConsent,
                availability: availability
            )
        else { return .none }
        return .needsScrubForCloud(image)
    }

    /// Whether this frame WOULD reach a cloud model if the user granted consent.
    /// True only when pixels exist, the model is remote + image-capable, and
    /// Screen Recording is on — i.e. consent is the only thing standing between
    /// the run and a (scrubbed) cloud-vision attach. The loop uses this to offer
    /// a just-in-time "enable Cloud vision" prompt instead of silently staying
    /// AX-only. Pure + synchronous for testability.
    public static func wouldAttachWithConsent(
        image: CUImage?,
        context: VisionContext,
        availability: MacDriverAvailability
    ) -> Bool {
        guard image != nil, context.modelAcceptsImages, !context.modelIsLocal else { return false }
        guard !context.cloudConsent else { return false }
        return availability.screenRecording
    }
}
