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
    private let currentOnboardingVersion = 1

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

        let didDeleteAll = await Task.detached(priority: .userInitiated) { () -> Bool in
            var success = true

            // helper to delete a directory with robust logging and error handling
            let deleteDir = { (url: URL, label: String) -> Bool in
                do {
                    if fm.fileExists(atPath: url.path) {
                        try fm.removeItem(at: url)
                        print("[OnboardingService] Deleted \(label) directory: \(url.path)")
                    } else {
                        print("[OnboardingService] \(label.capitalized) directory did not exist: \(url.path)")
                    }
                    return true
                } catch CocoaError.fileNoSuchFile {
                    print("[OnboardingService] \(label.capitalized) directory did not exist: \(url.path)")
                    return true
                } catch {
                    print("[OnboardingService] Failed to delete \(label) directory at \(url.path): \(error)")
                    return false
                }
            }

            let rootDeleted = deleteDir(root, "root")
            let legacyDeleted = deleteDir(legacyRoot, "legacy")

            return rootDeleted && legacyDeleted
        }.value

        guard didDeleteAll else {
            print("[OnboardingService] Factory reset aborted: some data could not be wiped.")
            return
        }

        print("[OnboardingService] Factory reset complete. Terminating via normal flow...")

        // terminate the app normally so cleanup is handled correctly
        await MainActor.run {
            NSApplication.shared.terminate(nil)
        }
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
