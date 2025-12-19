//
//  SystemPermissionService.swift
//  osaurus
//
//  Service to check and manage macOS system permissions.
//

@preconcurrency import AppKit
import Foundation

@MainActor
final class SystemPermissionService: ObservableObject {
    static let shared = SystemPermissionService()

    /// Published permission states for reactive UI updates
    @Published private(set) var permissionStates: [SystemPermission: Bool] = [:]

    private var refreshTimer: Timer?

    private init() {
        refreshAllPermissions()
    }

    // MARK: - Permission Checking

    /// Check if a system permission is currently granted
    func isGranted(_ permission: SystemPermission) -> Bool {
        switch permission {
        case .automation:
            return checkAutomationPermission()
        case .accessibility:
            return checkAccessibilityPermission()
        case .disk:
            return checkDiskPermission()
        }
    }

    /// Refresh all permission states and publish updates
    func refreshAllPermissions() {
        for permission in SystemPermission.allCases {
            permissionStates[permission] = isGranted(permission)
        }
    }

    /// Start periodic refresh of permission states (useful when settings pane is open)
    func startPeriodicRefresh(interval: TimeInterval = 2.0) {
        stopPeriodicRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAllPermissions()
            }
        }
    }

    /// Stop periodic refresh
    func stopPeriodicRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Permission Requests

    /// Request a permission (triggers system dialog or opens settings)
    func requestPermission(_ permission: SystemPermission) {
        switch permission {
        case .automation:
            requestAutomationPermission()
        case .accessibility:
            requestAccessibilityPermission()
        case .disk:
            requestDiskPermission()
        }
    }

    /// Open System Settings to the relevant permission pane
    func openSystemSettings(for permission: SystemPermission) {
        guard let url = permission.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Accessibility Permission

    private func checkAccessibilityPermission() -> Bool {
        // AXIsProcessTrusted() checks if the app has accessibility permissions
        return AXIsProcessTrusted()
    }

    private func requestAccessibilityPermission() {
        // This will prompt the user if not already granted
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [promptKey: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Automation Permission

    private func checkAutomationPermission() -> Bool {
        // There's no direct API to check automation permission.
        // We attempt a benign AppleScript to check if we have permission.
        // This won't trigger a prompt, just returns false if not authorized.

        let script = NSAppleScript(
            source: """
                tell application "System Events"
                    return name of first process whose frontmost is true
                end tell
                """
        )

        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)

        // If there's an error with code -1743, it's a permission error
        if let error = errorInfo,
            let errorNumber = error[NSAppleScript.errorNumber] as? Int,
            errorNumber == -1743
        {
            return false
        }

        // If execution succeeded or had a different error, assume we have permission
        // (other errors might be app-specific, not permission-related)
        return errorInfo == nil
    }

    private func requestAutomationPermission() {
        // First, check if we already have permission
        let alreadyGranted = checkAutomationPermission()
        if alreadyGranted {
            refreshAllPermissions()
            return
        }

        // Execute a script that will trigger the permission prompt
        // Note: macOS only shows the permission dialog ONCE. If it was previously
        // dismissed or denied, this will fail silently and we need to open System Settings.
        let script = NSAppleScript(
            source: """
                tell application "System Events"
                    return name of first process whose frontmost is true
                end tell
                """
        )

        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)

        // Check if permission was granted after the prompt
        // Give a small delay for the system to register the permission change
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.refreshAllPermissions()

            // If still not granted, the dialog likely didn't appear (already shown before)
            // Open System Settings so the user can manually grant the permission
            if !self.checkAutomationPermission() {
                self.openSystemSettings(for: .automation)
            }
        }
    }

    // MARK: - Full Disk Access Permission

    private func checkDiskPermission() -> Bool {
        // Check Full Disk Access by attempting to access a protected file.
        // ~/Library/Safari/Bookmarks.plist is protected and requires FDA.
        // We attempt to get file attributes which will fail without FDA.
        let protectedPaths = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Safari/Bookmarks.plist"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Safari"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mail"),
        ]

        for path in protectedPaths {
            do {
                // Try to get attributes - this will fail without FDA
                _ = try FileManager.default.attributesOfItem(atPath: path.path)
                return true
            } catch let error as NSError {
                // Error code 257 = permission denied (no FDA)
                // Error code 4 = file not found (try next path)
                if error.code == 257 {
                    return false
                }
                // For other errors (like file not found), try the next path
                continue
            }
        }

        // If none of the protected paths exist or all failed, assume no FDA
        return false
    }

    private func requestDiskPermission() {
        // macOS doesn't allow programmatic FDA requests.
        // We can only open System Settings for the user to grant it manually.
        openSystemSettings(for: .disk)
    }

    // MARK: - Bulk Checks

    /// Check if all specified permissions are granted
    func areAllGranted(_ permissions: [SystemPermission]) -> Bool {
        return permissions.allSatisfy { isGranted($0) }
    }

    /// Get missing permissions from a list of required permissions
    func missingPermissions(from requirements: [String]) -> [SystemPermission] {
        let systemPermissions = requirements.compactMap { SystemPermission(rawValue: $0) }
        return systemPermissions.filter { !isGranted($0) }
    }

    /// Check if a requirement string represents a system permission
    static func isSystemPermission(_ requirement: String) -> Bool {
        return SystemPermission(rawValue: requirement) != nil
    }
}
