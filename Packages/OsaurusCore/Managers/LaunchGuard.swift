//
//  LaunchGuard.swift
//  osaurus
//
//  Detects repeated startup crashes and enters a *tiered* safe mode to break
//  crash loops. Uses UserDefaults to track whether the previous launch
//  completed successfully and how many consecutive launches crashed.
//
//  Tiering: rather than an all-or-nothing "skip plugins" switch, safe mode
//  escalates with the consecutive-crash count so a crash loop in any one
//  subsystem degrades gracefully — we disable the riskiest optional
//  subsystems first and only fall back to a near-bare server if crashes
//  continue:
//
//    crashes >= 3  → skip plugins
//    crashes >= 4  → also skip the Linux sandbox VM + background distillation
//    crashes >= 5  → also skip auto model-load (speech + core)
//
//  Auto-recovery: once the running app serves a clean `/health`, we treat the
//  process as healthy, reset the persisted crash counter immediately (so the
//  *next* launch isn't penalized even if this session is later force-quit),
//  and — if we launched degraded — post a recovery notification so the
//  AppDelegate can bring the skipped subsystems online in-session.
//

import Foundation

extension Notification.Name {
    /// Posted when a degraded (safe-mode) launch observes a clean `/health`,
    /// asking the AppDelegate to start the subsystems it skipped.
    public static let safeModeRecoveryRequested = Notification.Name("safeModeRecoveryRequested")
}

@MainActor
enum LaunchGuard {
    private static let startupInProgressKey = "LaunchGuard.startupInProgress"
    private static let crashCountKey = "LaunchGuard.consecutiveCrashCount"

    /// First tier: skip plugins. Matches the historical `crashThreshold`.
    private static let pluginsThreshold = 3
    /// Second tier: also skip sandbox VM + distillation.
    private static let sandboxDistillThreshold = 4
    /// Third tier: also skip auto model-load.
    private static let autoModelLoadThreshold = 5

    /// Optional subsystems that safe mode can disable, most-risky first.
    struct Feature: OptionSet, Sendable {
        let rawValue: Int
        static let plugins = Feature(rawValue: 1 << 0)
        static let sandbox = Feature(rawValue: 1 << 1)
        static let distillation = Feature(rawValue: 1 << 2)
        static let autoModelLoad = Feature(rawValue: 1 << 3)
    }

    /// Subsystems disabled for this session, derived from the crash count at
    /// launch. Empty when not in safe mode.
    private(set) static var disabledFeatures: Feature = []

    /// `true` when any subsystem is disabled (back-compat with the old flag).
    static var isSafeMode: Bool { !disabledFeatures.isEmpty }

    /// Whether a given subsystem should be skipped this session.
    static func shouldSkip(_ feature: Feature) -> Bool {
        disabledFeatures.contains(feature)
    }

    private static func features(forCrashCount count: Int) -> Feature {
        var features: Feature = []
        if count >= pluginsThreshold { features.insert(.plugins) }
        if count >= sandboxDistillThreshold {
            features.insert(.sandbox)
            features.insert(.distillation)
        }
        if count >= autoModelLoadThreshold { features.insert(.autoModelLoad) }
        return features
    }

    /// Call at the very start of `applicationDidFinishLaunching`, before any
    /// plugin or repository work.
    @discardableResult
    static func checkOnLaunch() -> Bool {
        let defaults = UserDefaults.standard

        if defaults.bool(forKey: startupInProgressKey) {
            let count = defaults.integer(forKey: crashCountKey) + 1
            defaults.set(count, forKey: crashCountKey)
            NSLog("[Osaurus] Previous launch did not complete (consecutive crashes: %d)", count)
            disabledFeatures = features(forCrashCount: count)
            if !disabledFeatures.isEmpty {
                NSLog(
                    "[Osaurus] Safe mode active — disabled features bitmask: %d",
                    disabledFeatures.rawValue
                )
            }
        }

        defaults.set(true, forKey: startupInProgressKey)
        defaults.synchronize()
        return isSafeMode
    }

    /// Call after startup completes successfully. Resets the crash counter.
    static func markStartupComplete() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: startupInProgressKey)
        defaults.set(0, forKey: crashCountKey)
        disabledFeatures = []
    }

    /// Called when the running app serves a clean `/health`. Treats the
    /// process as healthy: clears the persisted crash counter right away so a
    /// later force-quit can't re-trigger safe mode, and — if we launched
    /// degraded — clears in-session safe mode and asks the AppDelegate to
    /// bring the skipped subsystems online. Idempotent.
    static func noteHealthyHealthCheck() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: startupInProgressKey)
        defaults.set(0, forKey: crashCountKey)

        guard !disabledFeatures.isEmpty else { return }
        let recovered = disabledFeatures
        disabledFeatures = []
        NSLog(
            "[Osaurus] Clean /health observed — clearing safe mode (was bitmask %d) and requesting subsystem recovery",
            recovered.rawValue
        )
        NotificationCenter.default.post(
            name: .safeModeRecoveryRequested,
            object: nil,
            userInfo: ["recoveredFeatures": recovered.rawValue]
        )
    }
}
