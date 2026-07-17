//
//  CloudVisionConsent.swift
//  OsaurusCore — Computer Use
//
//  The consent gate for the cloud-vision route (PR3). Sending a screenshot —
//  even a scrubbed one — to a cloud model is a trust-boundary crossing, so it
//  is OFF by default and never inferred. `CaptureRouter.cloudRoute(...)`
//  requires an explicit consent flag and refuses to build a cloud route without
//  it; combined with `ScrubbedFrame` being unconstructible outside
//  `FrameScrubber`, the two facts make an unconsented or unscrubbed cloud send
//  impossible to express.
//
//  The persisted opt-in survives relaunch. One-run grants are held inside the
//  active Computer Use run, not in this app-wide preference object.
//

import Combine
import Foundation

@MainActor
public final class CloudVisionConsent: ObservableObject {
    public static let shared = CloudVisionConsent()

    private let defaultsKey = "ai.osaurus.computeruse.cloudVisionConsent"
    private let piiOnlyKey = "ai.osaurus.computeruse.cloudVisionPIIOnly"
    private let defaults: UserDefaults

    /// Persisted opt-in. Default `false` — pixels never leave the device until
    /// the user explicitly allows it.
    @Published public private(set) var isPersistentlyGranted: Bool
    /// When `true`, a consented cloud screenshot masks only detected sensitive
    /// text (`.pii`) instead of every recognized region (`.allText`). Default
    /// `false` (`.allText`) so the safest redaction is the out-of-box behavior;
    /// the user opts into the less-strict mode knowingly.
    @Published public private(set) var masksOnlyDetectedPII: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isPersistentlyGranted = defaults.bool(forKey: defaultsKey)
        self.masksOnlyDetectedPII = defaults.bool(forKey: piiOnlyKey)
    }

    /// App-wide persisted opt-in. One-run grants are tracked inside the active
    /// Computer Use loop instead of this shared preference object.
    public var isGranted: Bool { isPersistentlyGranted }

    /// The redaction mode a consented cloud screenshot uses, derived from the
    /// user's preference. `.allText` by default (mask everything).
    public var scrubMode: ScrubMode { masksOnlyDetectedPII ? .pii : .allText }

    /// Bindable setter for the redaction-mode preference.
    public func setMasksOnlyDetectedPII(_ on: Bool) {
        masksOnlyDetectedPII = on
        defaults.set(on, forKey: piiOnlyKey)
    }

    public func grantPersistently() {
        isPersistentlyGranted = true
        defaults.set(true, forKey: defaultsKey)
    }

    /// Clear persisted consent. Active one-run grants are owned by their run and
    /// expire when that run ends.
    public func revoke() {
        isPersistentlyGranted = false
        defaults.set(false, forKey: defaultsKey)
    }

    /// Bindable convenience for the persisted toggle in settings.
    public func setPersistent(_ on: Bool) {
        if on { grantPersistently() } else { revoke() }
    }
}
