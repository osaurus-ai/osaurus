//
//  OnboardingService.swift
//  osaurus
//
//  Service managing onboarding state and first-launch detection.
//

import AppKit
import Foundation

/// Service managing onboarding state and first-launch detection
@MainActor
public final class OnboardingService: ObservableObject {
    public static let shared = OnboardingService()

    private let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    private let onboardingVersionKey = "onboardingVersion"

    /// Current onboarding version - increment to force re-onboarding after major updates
    private let currentOnboardingVersion = 3

    /// Whether onboarding should be shown (first launch or version mismatch)
    public var shouldShowOnboarding: Bool {
        let completed = UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey)
        let version = UserDefaults.standard.integer(forKey: onboardingVersionKey)
        return !completed || version < currentOnboardingVersion
    }

    /// Whether this is a completely fresh install (never completed onboarding)
    public var isFreshInstall: Bool {
        !UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey)
    }

    private init() {}

    /// Mark onboarding as completed
    public func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: hasCompletedOnboardingKey)
        UserDefaults.standard.set(currentOnboardingVersion, forKey: onboardingVersionKey)
    }

    /// Reset onboarding state (for re-running via help button)
    public func resetOnboarding() {
        UserDefaults.standard.set(false, forKey: hasCompletedOnboardingKey)
        UserDefaults.standard.set(0, forKey: onboardingVersionKey)
    }

    /// Perform a full factory reset by deleting all data, preferences, and identity.
    /// This will terminate the application.
    public func performFactoryReset() async {
        print("[OnboardingService] Initiating factory reset...")

        // Wipe every native browser profile FIRST, while the session catalog
        // (in ~/.osaurus) still holds the WebKit profile UUIDs needed to open
        // each store. Deleting the root directory below removes the catalog
        // but NOT the WKWebsiteDataStore data under ~/Library — without this
        // step the authenticated stores would be orphaned on disk forever.
        // Bounded: `resetAllSessions` awaits WKWebsiteDataStore.removeData
        // completions that WebKit is not guaranteed to deliver (stale profile
        // UUIDs, wedged networking XPC). An unbounded await here pins the
        // "Resetting Osaurus" spinner forever; on timeout we proceed — the
        // root-directory deletion below removes the catalog regardless.
        let browserWipeCompleted = await runWithDeadline(seconds: 10) {
            await BrowserSessionManager.shared.resetAllSessions()
        }
        if !browserWipeCompleted {
            print("[OnboardingService] Browser session wipe timed out; continuing reset.")
        }

        // wipe all Osaurus items from the Keychain
        wipeKeychain()

        // clear all UserDefaults keys
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        // delete the ~/.osaurus root directory AND legacy App Support directory
        let root = OsaurusPaths.root()
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacyRoot = supportDir.appendingPathComponent("com.dinoki.osaurus", isDirectory: true)

        let wipeFailures = await Task.detached(priority: .userInitiated) { () -> [WipeFailure] in
            // helper to delete a directory with robust logging and error handling.
            //
            // Rename-then-delete: live services (server, SQLite WAL writers,
            // watchers) can still be writing into these trees. A file recreated
            // while `removeItem` walks the directory fails the whole removal
            // with "directory not empty". The rename is atomic, so writers
            // can't interrupt it; deleting the renamed tree then races nobody.
            let deleteDir = { (url: URL, label: String) -> WipeFailure? in
                guard fm.fileExists(atPath: url.path) else {
                    print("[OnboardingService] \(label.capitalized) directory did not exist: \(url.path)")
                    return nil
                }
                let doomed = url.deletingLastPathComponent()
                    .appendingPathComponent(
                        ".\(url.lastPathComponent).factory-reset-\(ProcessInfo.processInfo.processIdentifier)",
                        isDirectory: true
                    )
                do {
                    try fm.moveItem(at: url, to: doomed)
                } catch CocoaError.fileNoSuchFile {
                    print("[OnboardingService] \(label.capitalized) directory did not exist: \(url.path)")
                    return nil
                } catch {
                    // The tree is untouched at its original path — the worst
                    // failure: user data (chats, memory, identity keys) survives
                    // the reset. Must be surfaced to the user before quitting.
                    print("[OnboardingService] Failed to move \(label) directory at \(url.path): \(error)")
                    return WipeFailure(path: url.path, dataRemains: true)
                }
                do {
                    try fm.removeItem(at: doomed)
                    print("[OnboardingService] Deleted \(label) directory: \(url.path)")
                    return nil
                } catch {
                    // The rename succeeded, so the app is factory-fresh, but the
                    // old data still sits on disk under the hidden renamed path.
                    print("[OnboardingService] Failed to delete \(label) directory at \(doomed.path): \(error)")
                    return WipeFailure(path: doomed.path, dataRemains: false)
                }
            }

            return [deleteDir(root, "root"), deleteDir(legacyRoot, "legacy")].compactMap { $0 }
        }.value

        // Terminate even when a directory failed to delete — bailing out here
        // would leave the "Resetting Osaurus" spinner up forever, and the
        // Keychain and UserDefaults are already gone by this point. But a
        // failed wipe means user data (chats, memory, identity keys) survives
        // a reset the user believes completed, so block on a critical alert
        // telling them exactly what was left behind before quitting.
        if !wipeFailures.isEmpty {
            print(
                "[OnboardingService] Factory reset incomplete: some data could not be wiped; notifying user."
            )
            presentWipeFailureAlert(wipeFailures)
        } else {
            print("[OnboardingService] Factory reset complete. Terminating via normal flow...")
        }

        // terminate the app normally so cleanup is handled correctly.
        // The synchronous termination teardown can block the main thread for a
        // couple of seconds, but it's a deliberate, app-ending operation — not a
        // defect — so pause hang tracking around it to avoid a false-positive
        // app-hang report. (No resume needed; the process is exiting.)
        await MainActor.run {
            CrashReportingService.shared.withAppHangTrackingPaused {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// A directory the factory reset could not fully remove.
    /// `dataRemains == true` means the tree is untouched at its original
    /// path; `false` means it was renamed out of the way (the app resets
    /// cleanly) but the orphaned copy still occupies disk at `path`.
    private struct WipeFailure: Sendable {
        let path: String
        let dataRemains: Bool
    }

    /// Blocking critical alert shown when the wipe left data behind, so the
    /// user knows the reset was incomplete before the app quits. Runs modal
    /// on the main actor; termination proceeds once dismissed.
    private func presentWipeFailureAlert(_ failures: [WipeFailure]) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L("Factory Reset Incomplete")

        var lines: [String] = []
        for failure in failures {
            if failure.dataRemains {
                lines.append(
                    String(
                        format: L("Your data could not be removed and remains at:\n%@"),
                        failure.path
                    )
                )
            } else {
                lines.append(
                    String(
                        format: L(
                            "The app was reset, but a copy of your old data could not be deleted and remains at:\n%@"
                        ),
                        failure.path
                    )
                )
            }
        }
        lines.append(
            L("Osaurus will now quit. You can delete the listed items manually in Finder.")
        )
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: L("Quit"))
        alert.runModal()
    }

    /// Clear all known Osaurus Keychain services
    private func wipeKeychain() {
        let services = [
            // MasterKey
            "com.osaurus.account",

            // AgentSecretsKeychain
            "ai.osaurus.agent-secrets",

            // ToolSecretsKeychain
            "ai.osaurus.tools",

            // MCPProviderKeychain
            "ai.osaurus.mcp",

            // RemoteProviderKeychain
            "ai.osaurus.remote",
        ]

        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            ]

            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess {
                print("[OnboardingService] Wiped Keychain service: \(service)")
            } else if status != errSecItemNotFound {
                print("[OnboardingService] Failed to wipe Keychain service \(service): \(status)")
            }
        }
    }
}
