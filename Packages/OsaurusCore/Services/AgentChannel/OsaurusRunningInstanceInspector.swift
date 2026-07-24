//
//  OsaurusRunningInstanceInspector.swift
//  osaurus
//
//  Detects duplicate running Osaurus instances. Providers that push events
//  to a single live connection (Slack Socket Mode) deliver each envelope to
//  only one instance, so a forgotten second copy (for example an Xcode debug
//  build next to the installed app) silently consumes the events the user is
//  waiting for.
//

import Foundation

#if os(macOS)
    import AppKit
#endif

enum OsaurusRunningInstanceInspector {
    /// Number of running applications sharing this app's bundle identifier.
    /// Returns 1 when the identifier is unavailable (e.g. test runners).
    static func runningInstanceCount() -> Int {
        #if os(macOS)
            guard let bundleId = Bundle.main.bundleIdentifier else { return 1 }
            let count = NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier == bundleId }
                .count
            return max(1, count)
        #else
            return 1
        #endif
    }

    static func duplicateInstanceWarning(instanceCount: Int) -> String? {
        guard instanceCount > 1 else { return nil }
        return "\(instanceCount) Osaurus instances are running. Slack delivers each Socket Mode event to only one connection, so the other instance may consume your messages. Quit the extra instance (for example an Xcode debug build) and try again."
    }
}
