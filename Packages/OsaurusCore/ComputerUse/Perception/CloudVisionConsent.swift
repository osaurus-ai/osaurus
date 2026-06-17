//
//  CloudVisionConsent.swift
//  OsaurusCore — Computer Use
//
//  The consent gate for the cloud-vision route (PR3). Sending a screenshot —
//  even a scrubbed one — to a cloud model is a trust-boundary crossing, so it
//  is OFF by default and never inferred. `CaptureRouter.cloudRoute(...)` reads
//  `isGranted` and refuses to build a cloud route without it; combined with
//  `ScrubbedFrame` being unconstructible outside `FrameScrubber`, the two
//  facts make an unconsented or unscrubbed cloud send impossible to express.
//
//  Two grant scopes: a persisted opt-in (survives relaunch) and a transient
//  this-launch-only grant. Revoke clears both.
//

import Combine
import Foundation

@MainActor
public final class CloudVisionConsent: ObservableObject {
    public static let shared = CloudVisionConsent()

    private let defaultsKey = "ai.osaurus.computeruse.cloudVisionConsent"
    private let defaults: UserDefaults

    /// Persisted opt-in. Default `false` — pixels never leave the device until
    /// the user explicitly allows it.
    @Published public private(set) var isPersistentlyGranted: Bool
    /// This-launch-only grant; never written to disk.
    @Published public private(set) var isSessionGranted: Bool = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isPersistentlyGranted = defaults.bool(forKey: defaultsKey)
    }

    /// The single value the router consults.
    public var isGranted: Bool { isPersistentlyGranted || isSessionGranted }

    public func grantPersistently() {
        isPersistentlyGranted = true
        defaults.set(true, forKey: defaultsKey)
    }

    public func grantForSession() {
        isSessionGranted = true
    }

    /// Clear all consent (both scopes). The user's "stop sharing" control.
    public func revoke() {
        isPersistentlyGranted = false
        isSessionGranted = false
        defaults.set(false, forKey: defaultsKey)
    }

    /// Bindable convenience for the persisted toggle in settings.
    public func setPersistent(_ on: Bool) {
        if on { grantPersistently() } else { revoke() }
    }
}
