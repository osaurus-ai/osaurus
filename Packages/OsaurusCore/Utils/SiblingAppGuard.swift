//
//  SiblingAppGuard.swift
//  osaurus
//
//  Osaurus and Osaurus Beta are separate apps that share `~/.osaurus` and
//  the default server port. Two processes writing the same databases can
//  damage them, and every automation would fire twice, so a launch that
//  finds the other app running waits until it has quit.
//

import AppKit

@MainActor
enum SiblingAppGuard {
    nonisolated static let stableBundleId = "com.dinoki.osaurus"
    nonisolated static let betaBundleId = "com.dinoki.osaurus.beta"

    /// The other app of the pair, or nil for builds outside it (dev and
    /// proof builds use their own bundle ids).
    nonisolated static func siblingBundleId(of bundleId: String?) -> String? {
        switch bundleId {
        case stableBundleId: betaBundleId
        case betaBundleId: stableBundleId
        default: nil
        }
    }

    /// Returns once the sibling app is not running, or false when the user
    /// chose to quit this app instead.
    static func waitForSiblingToQuit() -> Bool {
        // A custom data root shares nothing with the other app.
        if let root = ProcessEnvironment.value("OSAURUS_TEST_ROOT"),
            !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        guard let sibling = siblingBundleId(of: Bundle.main.bundleIdentifier) else { return true }

        let ownName = displayName(of: Bundle.main) ?? "Osaurus"
        while let running = runningApps(sibling).first {
            let otherName = running.localizedName ?? (sibling == betaBundleId ? "Osaurus Beta" : "Osaurus")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("\(otherName) is running")
            alert.informativeText = L(
                "\(ownName) and \(otherName) share the same data folder (~/.osaurus). Running both at once can damage chats and settings, and automations would run twice. Quit \(otherName) to continue."
            )
            alert.addButton(withTitle: L("Quit \(otherName)"))
            alert.addButton(withTitle: L("Quit \(ownName)"))
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return false }

            for app in runningApps(sibling) { app.terminate() }
            // The other app may ask to confirm its own quit; if it is still
            // running when this expires, the alert comes back.
            let deadline = Date().addingTimeInterval(15)
            while !runningApps(sibling).isEmpty, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
        }
        return true
    }

    private static func runningApps(_ bundleId: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).filter { !$0.isTerminated }
    }

    private static func displayName(of bundle: Bundle) -> String? {
        (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
    }
}
