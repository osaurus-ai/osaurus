//
//  SystemPermissionService.swift
//  osaurus
//
//  Service to check and manage macOS system permissions.
//

@preconcurrency import AppKit
import AVFoundation
import Contacts
import CoreGraphics
import CoreLocation
import EventKit
import Foundation

enum SystemPermissionProbe {
    struct FullDiskResource: Sendable {
        let relativePath: String
    }

    static let defaultFullDiskResources: [FullDiskResource] = [
        .init(relativePath: "Library/Application Support/com.apple.TCC/TCC.db"),
        .init(relativePath: "Library/Messages/chat.db"),
        .init(relativePath: "Library/Safari/Bookmarks.plist"),
        .init(relativePath: "Library/Safari/CloudTabs.db"),
    ]

    static func fullDiskAccessGranted(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        resources: [FullDiskResource] = defaultFullDiskResources
    ) -> Bool {
        resources.contains { resource in
            canReadProtectedFile(
                homeDirectory.appendingPathComponent(resource.relativePath),
                fileManager: fileManager
            )
        }
    }

    static func screenRecordingGranted(
        preflight: () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) -> Bool {
        preflight()
    }

    private static func canReadProtectedFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
            return true
        } catch {
            return false
        }
    }
}

@MainActor
final class SystemPermissionService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = SystemPermissionService()

    // `CLLocationManager()` performs a synchronous XPC handshake with locationd
    // on construction. Building it eagerly in `init` meant the first touch of the
    // `.shared` singleton — including permission gates for unrelated tools — paid
    // that cost on the main actor and could hang the UI for seconds. Build it
    // lazily so the handshake happens only when location is actually checked or
    // requested.
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()

    /// Published permission states for reactive UI updates
    @Published private(set) var permissionStates: [SystemPermission: Bool] = [:]

    private var refreshTimer: Timer?
    private let kPermissionStatesKey = "SystemPermissionStates"

    override private init() {
        super.init()
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

    /// Non-blocking granted lookup that returns the last-published cached state.
    ///
    /// Use this from view-update / layout paths. The live `isGranted(_:)` runs the
    /// authorization-status APIs synchronously, and EventKit's
    /// `EKEventStore.authorizationStatus(for:)` performs a synchronous XPC round-trip to
    /// the EventKit daemon that can hang the UI for seconds. The cache is kept fresh by
    /// `refreshAllPermissions()` / the periodic refresh, both of which probe off the main actor.
    func cachedIsGranted(_ permission: SystemPermission) -> Bool {
        permissionStates[permission] ?? false
    }

    /// Check if a system permission is currently granted
    func isGranted(_ permission: SystemPermission) -> Bool {
        switch permission {
        case .automation:
            return checkAutomationPermission()
        case .automationCalendar:
            return checkCalendarAutomationPermission()
        case .automationMail:
            return checkMailPermission()
        case .calendar:
            return checkCalendarPermission()
        case .reminders:
            return checkRemindersPermission()
        case .location:
            return checkLocationPermission()
        case .notes:
            return checkNotesPermission()
        case .maps:
            return checkMapsPermission()
        case .accessibility:
            return checkAccessibilityPermission()
        case .contacts:
            return checkContactsPermission()
        case .disk:
            return checkDiskPermission()
        case .microphone:
            return checkMicrophonePermission()
        case .screenRecording:
            return checkScreenRecordingPermission()
        }
    }

    /// Compute a permission's granted state without touching the main actor.
    ///
    /// The EventKit / Contacts / AVFoundation / CoreGraphics authorization-status APIs and the
    /// full-disk / screen-recording probes are all thread-safe, so they can be queried from a
    /// background thread. This matters because `EKEventStore.authorizationStatus(for:)` performs a
    /// *synchronous XPC round-trip* to the EventKit daemon; running that on the main thread can
    /// hang the UI for seconds.
    ///
    /// Returns `nil` for permissions whose state lives on the main actor (the location manager and
    /// the cached automation states); callers resolve those on the `MainActor`.
    nonisolated private static func isGrantedOffMain(_ permission: SystemPermission) -> Bool? {
        // In tests/CI, avoid touching TCC-backed status APIs that can block on
        // unavailable daemons (contactsd/EventKit/AVFoundation) and stall the suite.
        if RuntimeEnvironment.isUnderTests {
            switch permission {
            case .calendar, .reminders, .contacts, .microphone:
                return false
            default:
                break
            }
        }
        switch permission {
        case .calendar:
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .reminders:
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        case .accessibility:
            return AXIsProcessTrusted()
        case .contacts:
            return CNContactStore.authorizationStatus(for: .contacts) == .authorized
        case .disk:
            return SystemPermissionProbe.fullDiskAccessGranted()
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .screenRecording:
            return SystemPermissionProbe.screenRecordingGranted()
        case .location, .automation, .automationCalendar, .automationMail, .notes, .maps:
            return nil
        }
    }

    /// Refresh all permission states and publish updates
    func refreshAllPermissions() {
        // Perform the system checks off the main thread. Several of them (notably the EventKit
        // authorization status) make synchronous XPC calls that can block for seconds, which would
        // hang the UI if run on the main actor.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            var newStates: [SystemPermission: Bool] = [:]
            for permission in SystemPermission.allCases {
                if let granted = Self.isGrantedOffMain(permission) {
                    newStates[permission] = granted
                }
            }

            // Automation states and location use the last known cached value: automation
            // probes run AppleScript, and reading the location authorization makes a
            // synchronous XPC call to locationd that can block the main thread for seconds.
            // Location stays fresh via the CLLocationManager delegate callback.
            await MainActor.run {
                for permission in SystemPermission.allCases where permission.isAutomationBased {
                    newStates[permission] = self.permissionStates[permission]
                }
                newStates[.location] = self.permissionStates[.location]
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
        // This runs every couple of seconds from a timer while the Permissions pane is open.
        // Check off the main thread: `isGranted` can synchronously block on EventKit XPC, which
        // would hang the UI.
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }

            var results: [SystemPermission: Bool] = [:]
            for permission in SystemPermission.allCases where !permission.isAutomationBased {
                // Skip automation permissions - they require running AppleScript which can be
                // disruptive. We only check those when the user explicitly clicks "Grant"/"Test".
                if let granted = Self.isGrantedOffMain(permission) {
                    results[permission] = granted
                }
            }

            await MainActor.run {
                // Location is intentionally not probed here: the authorization read makes a
                // synchronous XPC call to locationd, and the delegate callback already keeps
                // the cached state fresh.
                // Only update if changed to avoid unnecessary saves.
                for (permission, granted) in results where self.permissionStates[permission] != granted {
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
        case .automationMail:
            requestMailPermission()
        case .calendar:
            requestCalendarPermission()
        case .reminders:
            requestRemindersPermission()
        case .location:
            requestLocationPermission()
        case .notes:
            requestNotesPermission()
        case .maps:
            requestMapsPermission()
        case .accessibility:
            requestAccessibilityPermission()
        case .contacts:
            requestContactsPermission()
        case .disk:
            requestDiskPermission()
        case .microphone:
            requestMicrophonePermission()
        case .screenRecording:
            requestScreenRecordingPermission()
        }
    }

    /// Trigger the macOS permission dialog and wait for the user's response.
    /// Returns `true` if the permission was granted, `false` otherwise.
    /// Permissions that require manual System Settings changes (disk, accessibility,
    /// screen recording) return `false` immediately.
    func requestPermissionAndWait(_ permission: SystemPermission) async -> Bool {
        // Under tests / headless CI there is no TCC UI and the backing
        // daemons (contactsd, EventKit, AVFoundation) may be absent — the
        // live request APIs below can then hang forever waiting on a service
        // that never answers. This is the documented 45-minute CI stall (see
        // `RuntimeEnvironment.isUnderTests`): the prior guard only covered the
        // singleton's `authorizationStatus` path, not this active-request one,
        // so a permissioned tool that reaches `ToolRegistry.runPermissionGate`
        // during tests could still hang the whole suite on `contactsd`. Deny
        // immediately without touching the system frameworks.
        if RuntimeEnvironment.isUnderTests { return false }
        let granted: Bool
        switch permission {
        case .calendar:
            granted = (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        case .reminders:
            granted = (try? await EKEventStore().requestFullAccessToReminders()) ?? false
        case .contacts:
            granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        case .microphone:
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        case .location:
            requestLocationPermission()
            return checkLocationPermission()
        case .automation, .automationCalendar, .automationMail, .notes, .maps:
            requestPermission(permission)
            return permissionStates[permission] ?? false
        case .accessibility, .disk, .screenRecording:
            return false
        }
        setPermission(permission, isGranted: granted)
        return granted
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
        if RuntimeEnvironment.isUnderTests { return false }
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
        if RuntimeEnvironment.isUnderTests { return false }
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
        if RuntimeEnvironment.isUnderTests { return false }
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

    private func checkMapsPermission() -> Bool {
        // Return cached state for Maps (Automation)
        return permissionStates[.maps] ?? false
    }

    private func checkMailPermission() -> Bool {
        // Return cached state for Mail (Automation)
        return permissionStates[.automationMail] ?? false
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
        if let error = errorInfo {
            let errorNumber = error[NSAppleScript.errorNumber] as? Int
            if errorNumber == -1743 {
                return false
            }
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
                guard self != nil else { return false }
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

    private func requestMapsPermission() {
        Task { @MainActor in
            let alreadyGranted = checkMapsPermission()
            if alreadyGranted {
                refreshAllPermissions()
                return
            }

            let granted: Bool = await Task.detached { [weak self] in
                guard self != nil else { return false }
                // Use debug test to trigger the prompt/check
                let result = SystemPermissionService.debugTestMapsAccess()
                return result.hasPrefix("SUCCESS")
            }.value

            setPermission(.maps, isGranted: granted)

            if !granted {
                self.openSystemSettings(for: .maps)
            }
        }
    }

    // MARK: - Mail Automation Permission

    private func requestMailPermission() {
        Task { @MainActor in
            let alreadyGranted = checkMailPermission()
            if alreadyGranted {
                refreshAllPermissions()
                return
            }

            let granted: Bool = await Task.detached { [weak self] in
                guard self != nil else { return false }
                let result = SystemPermissionService.debugTestMailAccess()
                return result.hasPrefix("SUCCESS")
            }.value

            setPermission(.automationMail, isGranted: granted)

            if !granted {
                self.openSystemSettings(for: .automationMail)
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
    nonisolated private func performFullCalendarAutomationCheck() async -> Bool {
        // Ensure Calendar is running using NSWorkspace
        let workspace = NSWorkspace.shared
        let calendarRunning = workspace.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.iCal"
        }

        if !calendarRunning {
            if let calendarURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false

                // Use async/await instead of blocking semaphore
                _ = try? await workspace.openApplication(at: calendarURL, configuration: config)
                // Give Calendar a moment to fully initialize
                try? await Task.sleep(nanoseconds: 2_000_000_000)
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

        if let error = errorInfo {
            let errorNumber = error[NSAppleScript.errorNumber] as? Int
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
            // We use a detached task to avoid blocking the main actor
            let granted: Bool = await Task.detached { [weak self] in
                guard let self = self else { return false }
                return await self.performFullCalendarAutomationCheck()
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
        SystemPermissionProbe.fullDiskAccessGranted()
    }

    private func requestDiskPermission() {
        // macOS doesn't allow programmatic FDA requests.
        // We can only open System Settings for the user to grant it manually.
        openSystemSettings(for: .disk)
    }

    // MARK: - Microphone Permission

    private func checkMicrophonePermission() -> Bool {
        if RuntimeEnvironment.isUnderTests { return false }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestMicrophonePermission() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                self.setPermission(.microphone, isGranted: granted)
                if granted {
                    // Refresh audio devices now that we have permission
                    AudioInputManager.shared.refreshDevices()
                }
            }
        }
    }

    // MARK: - Screen Recording Permission (for System Audio)

    private func checkScreenRecordingPermission() -> Bool {
        SystemPermissionProbe.screenRecordingGranted()
    }

    private func requestScreenRecordingPermission() {
        // macOS doesn't allow programmatic screen recording permission requests.
        // We can only open System Settings for the user to grant it manually.
        // Attempting to use ScreenCaptureKit will trigger the system prompt.
        openSystemSettings(for: .screenRecording)
    }

    // MARK: - Bulk Checks

    /// Check if all specified permissions are granted
    func areAllGranted(_ permissions: [SystemPermission]) -> Bool {
        return permissions.allSatisfy { isGranted($0) }
    }

    /// Get missing permissions from a list of required permissions.
    ///
    /// Resolved off the main actor: the live `isGranted` runs the
    /// authorization-status APIs synchronously, and EventKit's
    /// `EKEventStore.authorizationStatus(for:)` makes a synchronous XPC
    /// round-trip that can hang for seconds. This is reached from
    /// `ToolRegistry.runPermissionGate` on the main actor, so the thread-safe
    /// checks run in a detached task; the few permissions whose state lives on
    /// the main actor (location / automation) fall back to the cached state,
    /// which the periodic refresh and delegate callbacks keep fresh.
    func missingPermissions(from requirements: [String]) async -> [SystemPermission] {
        let systemPermissions = requirements.compactMap { SystemPermission(rawValue: $0) }
        guard !systemPermissions.isEmpty else { return [] }

        let offMain: [SystemPermission: Bool] = await Task.detached(priority: .userInitiated) {
            var states: [SystemPermission: Bool] = [:]
            for permission in systemPermissions {
                if let granted = Self.isGrantedOffMain(permission) {
                    states[permission] = granted
                }
            }
            return states
        }.value

        return systemPermissions.filter { permission in
            !(offMain[permission] ?? cachedIsGranted(permission))
        }
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
            return L("SUCCESS: \(resultValue)")
        }

        return L("NO RESULT")
    }

    // MARK: - Debug: Test Accessibility Access

    /// Debug function to test if Accessibility access is trusted.
    nonisolated static func debugTestAccessibilityAccess() -> String {
        let isTrusted = AXIsProcessTrusted()
        if isTrusted {
            return L("SUCCESS: Process is trusted for Accessibility.")
        } else {
            return
                L(
                    "ERROR: Process is NOT trusted for Accessibility. If enabled in System Settings, try removing and re-adding Osaurus to the list."
                )
        }
    }

    // MARK: - Debug: Test Calendar AppleScript

    /// Debug function to test if Calendar AppleScript works from this process.
    /// This will launch Calendar.app if not running.
    /// Marked nonisolated so it can be called from background threads.
    nonisolated static func debugTestCalendarAccess() async -> String {
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
                // Use async/await instead of blocking semaphore
                _ = try? await workspace.openApplication(at: calendarURL, configuration: config)
                // Give it a moment to fully initialize
                try? await Task.sleep(nanoseconds: 2_000_000_000)
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
            return L("SUCCESS: \(resultValue)")
        }

        return L("NO RESULT")
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
                return L("SUCCESS: Authorized (Found \(count)+ contacts)")
            } catch {
                return L("ERROR: Authorized but fetch failed: \(error.localizedDescription)")
            }
        case .denied:
            return L("ERROR: Access Denied")
        case .restricted:
            return L("ERROR: Access Restricted")
        case .notDetermined:
            return L("WARNING: Access Not Determined")
        @unknown default:
            return L("ERROR: Unknown Status")
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
                return L("SUCCESS: Authorized (Found \(calendars.count) calendars)")
            } else {
                return L("SUCCESS: Authorized (No calendars found)")
            }
        case .denied:
            return L("ERROR: Access Denied")
        case .restricted:
            return L("ERROR: Access Restricted")
        case .notDetermined:
            return L("WARNING: Access Not Determined")
        @unknown default:
            return L("ERROR: Unknown Status")
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
                return L("SUCCESS: Authorized (Found \(calendars.count) lists)")
            } else {
                return L("SUCCESS: Authorized (No lists found)")
            }
        case .denied:
            return L("ERROR: Access Denied")
        case .restricted:
            return L("ERROR: Access Restricted")
        case .notDetermined:
            return L("WARNING: Access Not Determined")
        @unknown default:
            return L("ERROR: Unknown Status")
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
            return L("SUCCESS: Authorized")
        case .denied:
            return L("ERROR: Access Denied")
        case .restricted:
            return L("ERROR: Access Restricted")
        case .notDetermined:
            return L("WARNING: Access Not Determined")
        @unknown default:
            return L("ERROR: Unknown Status")
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
            return L("SUCCESS: Connected to \(resultValue)")
        }

        return L("NO RESULT")
    }

    // MARK: - Debug: Test Maps Access

    /// Debug function to test if Maps access works via AppleScript.
    nonisolated static func debugTestMapsAccess() -> String {
        let script = NSAppleScript(
            source: """
                tell application "Maps"
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
            return L("SUCCESS: Connected to \(resultValue)")
        }

        return L("NO RESULT")
    }

    // MARK: - Debug: Test Mail Access

    /// Debug function to test if Mail access works via AppleScript.
    nonisolated static func debugTestMailAccess() -> String {
        let script = NSAppleScript(
            source: """
                tell application "Mail"
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
            return L("SUCCESS: Connected to \(resultValue)")
        }

        return L("NO RESULT")
    }

    /// Simple error wrapper for osascript results
    private struct OsascriptError: Error {
        let message: String
    }

    /// Run an AppleScript using osascript command
    nonisolated private static func runOsascript(_ script: String) -> Result<String, OsascriptError> {
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
