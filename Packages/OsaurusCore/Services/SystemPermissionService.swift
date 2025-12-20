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
        case .automationCalendar:
            return checkCalendarAutomationPermission()
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
            // Use DispatchQueue.main.async to avoid "Publishing changes from within view updates" warning
            DispatchQueue.main.async {
                self?.refreshNonDisruptivePermissions()
            }
        }
    }

    /// Refresh only permissions that don't require launching apps or disrupting user flow
    /// Calendar automation check is excluded because it launches Calendar.app
    private func refreshNonDisruptivePermissions() {
        for permission in SystemPermission.allCases {
            // Skip Calendar automation - it requires launching Calendar which is disruptive
            if permission == .automationCalendar {
                continue
            }
            permissionStates[permission] = isGranted(permission)
        }
    }

    /// Update the Calendar automation permission state directly (used after diagnostic test)
    func updateCalendarPermissionState(_ isGranted: Bool) {
        permissionStates[.automationCalendar] = isGranted
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
        case .automationCalendar:
            requestCalendarAutomationPermission()
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

    // MARK: - Calendar Automation Permission

    private func checkCalendarAutomationPermission() -> Bool {
        // For periodic checks, just return the last known state to avoid launching Calendar
        // The accurate check happens when user clicks "Test Calendar AppleScript" button
        // or when the permission is explicitly requested
        return permissionStates[.automationCalendar] ?? false
    }

    /// Perform a full Calendar automation check (may launch Calendar.app)
    /// This is called only on explicit user request, not during periodic refresh
    nonisolated private func performFullCalendarAutomationCheck() -> Bool {
        // Ensure Calendar is running using NSWorkspace
        let workspace = NSWorkspace.shared
        let calendarRunning = workspace.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.iCal"
        }

        if !calendarRunning {
            if let calendarURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false

                let semaphore = DispatchSemaphore(value: 0)
                workspace.openApplication(at: calendarURL, configuration: config) { _, _ in
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 5.0)
                Thread.sleep(forTimeInterval: 2.0)
            }
        }

        // Use NSAppleScript directly (not osascript) to ensure attribution to host app
        let script = NSAppleScript(
            source: """
                tell application id "com.apple.iCal"
                    return name of calendars as string
                end tell
                """
        )

        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)

        if let error = errorInfo,
            let errorNumber = error[NSAppleScript.errorNumber] as? Int
        {
            // -1743 = permission denied (not authorized to send Apple events)
            if errorNumber == -1743 {
                return false
            }
            // -600 = app not responding, treat as unknown/failed
            if errorNumber == -600 {
                return false
            }
        }

        // If execution succeeded, we have permission
        return errorInfo == nil
    }

    private func requestCalendarAutomationPermission() {
        // Run on MainActor to ensure TCC prompts attach correctly
        Task { @MainActor in
            // First, check if we already have permission
            let alreadyGranted = checkCalendarAutomationPermission()
            if alreadyGranted {
                refreshAllPermissions()
                return
            }

            // Perform full check which will launch Calendar and trigger permission prompt
            // running on main thread/queue is safer for TCC triggers
            // We use a detached task to avoid blocking the main thread during the 5s timeout
            let granted: Bool = await Task.detached { [weak self] in
                guard let self = self else { return false }
                return self.performFullCalendarAutomationCheck()
            }.value

            updateCalendarPermissionState(granted)

            // If not granted, the dialog likely didn't appear (already shown before)
            // Open System Settings so the user can manually grant the permission
            if !granted {
                self.openSystemSettings(for: .automationCalendar)
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

    // MARK: - Debug: Test Calendar AppleScript

    /// Debug function to test if Calendar AppleScript works from this process.
    /// This will launch Calendar.app if not running.
    /// Marked nonisolated so it can be called from background threads.
    nonisolated static func debugTestCalendarAccess() -> String {
        // Ensure Calendar is running using NSWorkspace
        let workspace = NSWorkspace.shared
        let calendarRunning = workspace.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.iCal"
        }

        var diagnostics = ""

        if !calendarRunning {
            if let calendarURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                let semaphore = DispatchSemaphore(value: 0)
                workspace.openApplication(at: calendarURL, configuration: config) { _, _ in
                    semaphore.signal()
                }
                // Wait up to 5 seconds for launch
                _ = semaphore.wait(timeout: .now() + 5.0)
                // Give it a moment to fully initialize
                Thread.sleep(forTimeInterval: 2.0)
            } else {
                diagnostics += " | Calendar.app not found"
            }
        }

        // Use bundle ID for reliable resolution
        let script = NSAppleScript(
            source: """
                tell application id "com.apple.iCal"
                    return name of calendars as string
                end tell
                """
        )

        var errorInfo: NSDictionary?
        let result = script?.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? -1
            let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"

            var guidance = ""
            if errorNumber == -1743 {
                guidance = " → Permission denied. Grant in System Settings → Privacy & Security → Automation"
            } else if errorNumber == -600 {
                guidance = " → App communication failed. Try restarting your Mac if this persists."
            }

            return "ERROR [\(errorNumber)]: \(errorMessage)\(guidance)\(diagnostics.isEmpty ? "" : " | \(diagnostics)")"
        }

        if let resultValue = result?.stringValue {
            return "SUCCESS: \(resultValue)"
        }

        return "NO RESULT"
    }

    /// Simple error wrapper for osascript results
    private struct OsascriptError: Error {
        let message: String
    }

    /// Run an AppleScript using osascript command
    private nonisolated static func runOsascript(_ script: String) -> Result<String, OsascriptError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output =
                String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput =
                String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus == 0 {
                return .success(output)
            } else {
                return .failure(
                    OsascriptError(message: errorOutput.isEmpty ? "exit \(process.terminationStatus)" : errorOutput)
                )
            }
        } catch {
            return .failure(OsascriptError(message: error.localizedDescription))
        }
    }
}
