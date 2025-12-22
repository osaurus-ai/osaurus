//
//  SystemPermissionService.swift
//  osaurus
//
//  Service to check and manage macOS system permissions.
//

@preconcurrency import AppKit
import Contacts
import CoreLocation
import EventKit
import Foundation

@MainActor
final class SystemPermissionService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = SystemPermissionService()

    private let locationManager = CLLocationManager()

    /// Published permission states for reactive UI updates
    @Published private(set) var permissionStates: [SystemPermission: Bool] = [:]

    private var refreshTimer: Timer?
    private let kPermissionStatesKey = "SystemPermissionStates"

    private override init() {
        super.init()
        locationManager.delegate = self
        loadPermissionStates()
        refreshAllPermissions()
    }

    // MARK: - Persistence

    private func savePermissionStates() {
        let rawStates = Dictionary(uniqueKeysWithValues: permissionStates.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(rawStates, forKey: kPermissionStatesKey)
    }

    private func loadPermissionStates() {
        guard let rawStates = UserDefaults.standard.dictionary(forKey: kPermissionStatesKey) as? [String: Bool] else {
            return
        }

        var loadedStates: [SystemPermission: Bool] = [:]
        for (key, value) in rawStates {
            if let permission = SystemPermission(rawValue: key) {
                loadedStates[permission] = value
            }
        }
        self.permissionStates = loadedStates
    }

    /// Centralized helper to set permission and persist state
    private func setPermission(_ permission: SystemPermission, isGranted: Bool) {
        permissionStates[permission] = isGranted
        savePermissionStates()
    }

    /// Batch update permissions and persist
    private func setPermissions(_ states: [SystemPermission: Bool]) {
        for (permission, isGranted) in states {
            permissionStates[permission] = isGranted
        }
        savePermissionStates()
    }

    // MARK: - Permission Checking

    /// Check if a system permission is currently granted
    func isGranted(_ permission: SystemPermission) -> Bool {
        switch permission {
        case .automation:
            return checkAutomationPermission()
        case .automationCalendar:
            return checkCalendarAutomationPermission()
        case .calendar:
            return checkCalendarPermission()
        case .reminders:
            return checkRemindersPermission()
        case .location:
            return checkLocationPermission()
        case .notes:
            return checkNotesPermission()
        case .accessibility:
            return checkAccessibilityPermission()
        case .contacts:
            return checkContactsPermission()
        case .disk:
            return checkDiskPermission()
        }
    }

    /// Refresh all permission states and publish updates
    func refreshAllPermissions() {
        // Run checks in background to avoid blocking main thread
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            // Perform checks
            var newStates: [SystemPermission: Bool] = [:]

            for permission in SystemPermission.allCases {
                if permission == .automationCalendar || permission == .automation {
                    // Skip Automation to avoid launching apps/running scripts automatically
                    // Use last known state
                    await MainActor.run {
                        newStates[permission] = self.permissionStates[permission]
                    }
                    continue
                }

                // Other checks need to be on MainActor? Accessibility/Disk usually safe on background
                // but let's be careful. AXIsProcessTrusted is thread-safe.
                // FileManager checks are thread-safe.
                await MainActor.run {
                    newStates[permission] = self.isGranted(permission)
                }
            }

            // Update state on MainActor
            await MainActor.run {
                self.setPermissions(newStates)
            }
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
    /// Automation checks (Calendar & General) are excluded because they run AppleScript
    private func refreshNonDisruptivePermissions() {
        for permission in SystemPermission.allCases {
            // Skip Automation checks - they require running AppleScript which can be disruptive
            // We only check these when the user explicitly clicks "Grant" or "Test"
            if permission == .automationCalendar || permission == .automation {
                continue
            }

            // For other permissions (Accessibility, Disk), the checks are cheap/safe
            let granted = isGranted(permission)
            Task { @MainActor in
                // Only update if changed to avoid unnecessary saves, although setPermission handles it efficiently enough
                if self.permissionStates[permission] != granted {
                    self.setPermission(permission, isGranted: granted)
                }
            }
        }
    }

    /// Update any permission state directly (used after diagnostic test)
    func updatePermissionState(_ permission: SystemPermission, isGranted: Bool) {
        setPermission(permission, isGranted: isGranted)
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
        case .calendar:
            requestCalendarPermission()
        case .reminders:
            requestRemindersPermission()
        case .location:
            requestLocationPermission()
        case .notes:
            requestNotesPermission()
        case .accessibility:
            requestAccessibilityPermission()
        case .contacts:
            requestContactsPermission()
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

    // MARK: - Contacts Permission

    private func checkContactsPermission() -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return status == .authorized
    }

    private func requestContactsPermission() {
        Task { @MainActor in
            let store = CNContactStore()
            do {
                let granted = try await store.requestAccess(for: .contacts)
                setPermission(.contacts, isGranted: granted)
                if !granted {
                    openSystemSettings(for: .contacts)
                }
            } catch {
                print("Error requesting contacts permission: \(error)")
                setPermission(.contacts, isGranted: false)
                openSystemSettings(for: .contacts)
            }
        }
    }

    // MARK: - Calendar Permission (EventKit)

    private func checkCalendarPermission() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .fullAccess
    }

    private func requestCalendarPermission() {
        Task { @MainActor in
            let store = EKEventStore()
            do {
                let granted = try await store.requestFullAccessToEvents()
                setPermission(.calendar, isGranted: granted)
                if !granted {
                    openSystemSettings(for: .calendar)
                }
            } catch {
                print("Error requesting calendar permission: \(error)")
                setPermission(.calendar, isGranted: false)
                openSystemSettings(for: .calendar)
            }
        }
    }

    // MARK: - Reminders Permission (EventKit)

    private func checkRemindersPermission() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return status == .fullAccess
    }

    private func requestRemindersPermission() {
        Task { @MainActor in
            let store = EKEventStore()
            do {
                let granted = try await store.requestFullAccessToReminders()
                setPermission(.reminders, isGranted: granted)
                if !granted {
                    openSystemSettings(for: .reminders)
                }
            } catch {
                print("Error requesting reminders permission: \(error)")
                setPermission(.reminders, isGranted: false)
                openSystemSettings(for: .reminders)
            }
        }
    }

    // MARK: - Location Permission

    private func checkLocationPermission() -> Bool {
        let status = locationManager.authorizationStatus
        return status == .authorizedAlways
    }

    private func requestLocationPermission() {
        locationManager.requestAlwaysAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            let granted = status == .authorizedAlways
            self.setPermission(.location, isGranted: granted)
        }
    }

    // MARK: - Automation Permission

    private func checkAutomationPermission() -> Bool {
        // Return cached state to avoid running AppleScript on main thread during view updates
        return permissionStates[.automation] ?? false
    }

    private func checkNotesPermission() -> Bool {
        // Return cached state for Notes (Automation)
        return permissionStates[.notes] ?? false
    }

    /// Perform full Automation check (runs AppleScript against System Events)
    /// This is called only on explicit user request, not during periodic refresh
    nonisolated private func performFullAutomationCheck() -> Bool {
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
        return errorInfo == nil
    }

    private func requestAutomationPermission() {
        // Run on MainActor to ensure TCC prompts attach correctly
        Task { @MainActor in
            // First, check if we already have permission
            let alreadyGranted = checkAutomationPermission()
            if alreadyGranted {
                refreshAllPermissions()
                return
            }

            // Perform full check
            let granted: Bool = await Task.detached { [weak self] in
                guard let self = self else { return false }
                return self.performFullAutomationCheck()
            }.value

            setPermission(.automation, isGranted: granted)

            // If not granted, the dialog likely didn't appear (already shown before)
            // Open System Settings so the user can manually grant the permission
            if !granted {
                self.openSystemSettings(for: .automation)
            }
        }
    }

    private func requestNotesPermission() {
        Task { @MainActor in
            let alreadyGranted = checkNotesPermission()
            if alreadyGranted {
                refreshAllPermissions()
                return
            }

            let granted: Bool = await Task.detached { [weak self] in
                guard let self = self else { return false }
                // Use debug test to trigger the prompt/check
                let result = SystemPermissionService.debugTestNotesAccess()
                return result.hasPrefix("SUCCESS")
            }.value

            setPermission(.notes, isGranted: granted)

            if !granted {
                self.openSystemSettings(for: .notes)
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

            setPermission(.automationCalendar, isGranted: granted)

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

    // MARK: - Debug: Test Automation Access

    /// Debug function to test general Automation access (System Events)
    nonisolated static func debugTestAutomationAccess() -> String {
        let script = NSAppleScript(
            source: """
                tell application "System Events"
                    return name of first process whose frontmost is true
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
            }

            return "ERROR [\(errorNumber)]: \(errorMessage)\(guidance)"
        }

        if let resultValue = result?.stringValue {
            return "SUCCESS: \(resultValue)"
        }

        return "NO RESULT"
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

    // MARK: - Debug: Test Contacts Access

    /// Debug function to test if Contacts access works.
    nonisolated static func debugTestContactsAccess() -> String {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            // Try to actually fetch a contact to verify
            let store = CNContactStore()
            let keys = [CNContactGivenNameKey as CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.predicate = nil
            // Just fetch one to test
            var count = 0
            do {
                try store.enumerateContacts(with: request) { _, stop in
                    count += 1
                    stop.pointee = true
                }
                return "SUCCESS: Authorized (Found \(count)+ contacts)"
            } catch {
                return "ERROR: Authorized but fetch failed: \(error.localizedDescription)"
            }
        case .denied:
            return "ERROR: Access Denied"
        case .restricted:
            return "ERROR: Access Restricted"
        case .notDetermined:
            return "WARNING: Access Not Determined"
        @unknown default:
            return "ERROR: Unknown Status"
        }
    }

    // MARK: - Debug: Test Calendar (EventKit) Access

    /// Debug function to test if Calendar access works via EventKit.
    nonisolated static func debugTestCalendarEventKitAccess() -> String {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .writeOnly:  // writeOnly shouldn't happen for us but covering it
            let store = EKEventStore()
            // Try to fetch calendars to verify
            let calendars = store.calendars(for: .event)
            if !calendars.isEmpty {
                return "SUCCESS: Authorized (Found \(calendars.count) calendars)"
            } else {
                return "SUCCESS: Authorized (No calendars found)"
            }
        case .denied:
            return "ERROR: Access Denied"
        case .restricted:
            return "ERROR: Access Restricted"
        case .notDetermined:
            return "WARNING: Access Not Determined"
        @unknown default:
            return "ERROR: Unknown Status"
        }
    }

    // MARK: - Debug: Test Reminders (EventKit) Access

    /// Debug function to test if Reminders access works via EventKit.
    nonisolated static func debugTestRemindersAccess() -> String {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess, .writeOnly:
            let store = EKEventStore()
            let calendars = store.calendars(for: .reminder)
            if !calendars.isEmpty {
                return "SUCCESS: Authorized (Found \(calendars.count) lists)"
            } else {
                return "SUCCESS: Authorized (No lists found)"
            }
        case .denied:
            return "ERROR: Access Denied"
        case .restricted:
            return "ERROR: Access Restricted"
        case .notDetermined:
            return "WARNING: Access Not Determined"
        @unknown default:
            return "ERROR: Unknown Status"
        }
    }

    // MARK: - Debug: Test Location Access

    /// Debug function to test if Location access works.
    /// Note: This is tricky to test synchronously as location updates are async delegate callbacks.
    /// We just check auth status here.
    nonisolated static func debugTestLocationAccess() -> String {
        let manager = CLLocationManager()
        let status = manager.authorizationStatus

        switch status {
        case .authorizedAlways:
            return "SUCCESS: Authorized"
        case .denied:
            return "ERROR: Access Denied"
        case .restricted:
            return "ERROR: Access Restricted"
        case .notDetermined:
            return "WARNING: Access Not Determined"
        @unknown default:
            return "ERROR: Unknown Status"
        }
    }

    // MARK: - Debug: Test Notes Access

    /// Debug function to test if Notes access works via AppleScript.
    nonisolated static func debugTestNotesAccess() -> String {
        let script = NSAppleScript(
            source: """
                tell application "Notes"
                    return name
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
            }

            return "ERROR [\(errorNumber)]: \(errorMessage)\(guidance)"
        }

        if let resultValue = result?.stringValue {
            return "SUCCESS: Connected to \(resultValue)"
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
