//
//  OnboardingService.swift
//  osaurus
//
//  Service managing onboarding state and first-launch detection.
//

import AppKit
import Foundation

/// Ordered, observable progress of a factory reset, mirroring the sandbox
/// provisioning journey: one row per wipe phase with a live status icon.
public struct FactoryResetJourney: Equatable, Sendable {
    public enum StepID: String, CaseIterable, Sendable {
        case browser
        case keychain
        case preferences
        case data
        case quit
    }

    public enum Status: Equatable, Sendable {
        case pending
        case inProgress
        case completed
        case failed
    }

    public struct Step: Identifiable, Equatable, Sendable {
        public let id: StepID
        public var status: Status
    }

    public var steps: [Step] = StepID.allCases.map { Step(id: $0, status: .pending) }

    public subscript(_ id: StepID) -> Status {
        get { steps.first(where: { $0.id == id })?.status ?? .pending }
        set {
            if let index = steps.firstIndex(where: { $0.id == id }) {
                steps[index].status = newValue
            }
        }
    }
}

/// Service managing onboarding state and first-launch detection
@MainActor
public final class OnboardingService: ObservableObject {
    public static let shared = OnboardingService()

    /// Non-nil while a factory reset is running; drives the journey UI in
    /// the settings overlay. Never reset to nil — the app terminates at the
    /// end of the flow.
    @Published public private(set) var resetJourney: FactoryResetJourney?

    /// Non-nil when the wipe left data behind and the user must acknowledge
    /// before the app quits. Presented as a `themedAlert` by the settings
    /// overlay; cleared by `acknowledgeWipeFailure()`.
    @Published public private(set) var wipeFailureMessage: String?
    private var wipeFailureAcknowledgment: CheckedContinuation<Void, Never>?

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
        resetJourney = FactoryResetJourney()

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
        setStep(.browser, .inProgress)
        let browserWipeCompleted = await runWithDeadline(seconds: 10) {
            await BrowserSessionManager.shared.resetAllSessions()
        }
        if !browserWipeCompleted {
            print("[OnboardingService] Browser session wipe timed out; continuing reset.")
        }
        setStep(.browser, browserWipeCompleted ? .completed : .failed)

        // wipe all Osaurus items from the Keychain
        setStep(.keychain, .inProgress)
        await journeyBeat()
        wipeKeychain()
        setStep(.keychain, .completed)

        // clear all UserDefaults keys
        setStep(.preferences, .inProgress)
        await journeyBeat()
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        setStep(.preferences, .completed)
        setStep(.data, .inProgress)

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
        setStep(.data, wipeFailures.isEmpty ? .completed : .failed)
        if !wipeFailures.isEmpty {
            print(
                "[OnboardingService] Factory reset incomplete: some data could not be wiped; notifying user."
            )
            await awaitWipeFailureAcknowledgment(wipeFailures)
        } else {
            print("[OnboardingService] Factory reset complete. Terminating via normal flow...")
        }
        setStep(.quit, .inProgress)
        await journeyBeat()

        // terminate the app normally so cleanup is handled correctly.
        // The synchronous termination teardown can block the main thread for a
        // couple of seconds, but it's a deliberate, app-ending operation — not a
        // defect — so pause hang tracking around it to avoid a false-positive
        // app-hang report. (No resume needed; the process is exiting.)
        // Schedule the terminate as a plain run-loop callout, NOT from this
        // task. This function runs as a MainActor job — a block on the main
        // dispatch queue — and `NSApplication.terminate` does not return for
        // `.terminateLater`: AppKit spins a nested run loop until
        // `reply(toApplicationShouldTerminate:)`. GCD's main-queue drain is
        // not reentrant, so a nested run loop entered from inside a
        // main-queue block can never run further main-queue work — and the
        // quit teardown chain, its 22s watchdog, and the reply are all
        // MainActor tasks (main-queue blocks). Calling terminate from here
        // deadlocks the entire quit (the "Quitting Osaurus" hang). From a
        // run-loop callout, AppKit's nested wait still drains the main
        // queue and the teardown completes normally.
        RunLoop.main.perform(inModes: [.common]) {
            CrashReportingService.shared.withAppHangTrackingPaused {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// Update one journey step's status (animated by the observing view).
    private func setStep(_ id: FactoryResetJourney.StepID, _ status: FactoryResetJourney.Status) {
        resetJourney?[id] = status
    }

    /// Brief pause so near-instant steps (Keychain, UserDefaults) are
    /// visible as distinct rows in the journey UI instead of flashing by.
    private func journeyBeat() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    /// A directory the factory reset could not fully remove.
    /// `dataRemains == true` means the tree is untouched at its original
    /// path; `false` means it was renamed out of the way (the app resets
    /// cleanly) but the orphaned copy still occupies disk at `path`.
    private struct WipeFailure: Sendable {
        let path: String
        let dataRemains: Bool
    }

    /// Suspends until the user acknowledges the wipe-failure notice. The
    /// message is published for the settings overlay to present as a
    /// `themedAlert`; `acknowledgeWipeFailure()` resumes us so termination
    /// proceeds only after the user has seen what was left behind.
    private func awaitWipeFailureAcknowledgment(_ failures: [WipeFailure]) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            wipeFailureAcknowledgment = cont
            wipeFailureMessage = Self.wipeFailureMessage(for: failures)
        }
    }

    /// Resume `performFactoryReset` after the wipe-failure alert is
    /// dismissed. Safe to call when no notice is pending (preview flow).
    public func acknowledgeWipeFailure() {
        wipeFailureMessage = nil
        wipeFailureAcknowledgment?.resume()
        wipeFailureAcknowledgment = nil
    }

    private static func wipeFailureMessage(for failures: [WipeFailure]) -> String {
        // The path is joined outside the localized string: catalog keys must
        // stay newline-free (the i18n CI check compares Swift literals with
        // escapes preserved, so a `\n` in a key can never match the catalog).
        var lines: [String] = []
        for failure in failures {
            if failure.dataRemains {
                lines.append(
                    L("Your data could not be removed and remains at:") + "\n" + failure.path
                )
            } else {
                lines.append(
                    L("The app was reset, but a copy of your old data could not be deleted and remains at:")
                        + "\n" + failure.path
                )
            }
        }
        lines.append(
            L("Osaurus will now quit. You can delete the listed items manually in Finder.")
        )
        return lines.joined(separator: "\n\n")
    }

    /// Clear all known Osaurus Keychain services. The list lives in
    /// `OsaurusKeychainServices` next to the wrappers so a newly added
    /// secret store can't be silently missed by factory reset.
    private func wipeKeychain() {
        for service in OsaurusKeychainServices.all {
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
