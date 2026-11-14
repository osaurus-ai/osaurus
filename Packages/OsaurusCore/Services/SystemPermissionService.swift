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
        /// Where the sentinel lives. `.system` files (like the machine-wide
        /// TCC database under `/Library`) are absolute; `.home` files are
        /// resolved against the current user's home directory.
        enum Location: Sendable { case system, home }
        let location: Location
        let path: String

        func url(homeDirectory: URL) -> URL {
            switch location {
            case .system: return URL(fileURLWithPath: path)
            case .home: return homeDirectory.appendingPathComponent(path)
            }
        }
    }

    /// Sentinel files that are unconditionally Full Disk Access-protected.
    ///
    /// The authoritative gate is the SYSTEM TCC database under `/Library`:
    /// reading it requires Full Disk Access on every macOS version. The
    /// per-user TCC database (`~/Library/.../TCC.db`) is NOT a reliable gate —
    /// on some macOS versions the user's own processes can read it WITHOUT
    /// FDA, so a probe anchored on it reported a grant that did not exist, and
    /// toggling FDA off changed nothing (GitHub #2601). Messages' chat.db
    /// rides along for redundancy but may be absent when Messages was never
    /// used, so it cannot be the sole anchor. The old `~/Library/Safari`
    /// files are deliberately absent: Safari's live data moved into its
    /// container, and on upgraded Macs the legacy files can be left behind
    /// UNPROTECTED — a readable stale bookmark file made the probe report FDA
    /// as granted when it wasn't (GitHub #2523).
    static let defaultFullDiskResources: [FullDiskResource] = [
        .init(location: .system, path: "/Library/Application Support/com.apple.TCC/TCC.db"),
        .init(location: .home, path: "Library/Messages/chat.db"),
    ]

    static func fullDiskAccessGranted(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        resources: [FullDiskResource] = defaultFullDiskResources
    ) -> Bool {
        // Fail closed: only files that actually exist participate, and EVERY
        // one of them must be readable. With a real FDA grant all protected
        // files are readable, so any-readable added nothing except a
        // false-positive path through a file that lost its protection.
        let existing = resources
            .map { $0.url(homeDirectory: homeDirectory) }
            .filter { isRegularFile($0, fileManager: fileManager) }
        guard !existing.isEmpty else { return false }
        return existing.allSatisfy { canReadProtectedFile($0, fileManager: fileManager) }
    }

    static func screenRecordingGranted(
        preflight: () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) -> Bool {
        preflight()
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// The SQLite file header, present at byte 0 of every TCC.db / chat.db
    /// sentinel. A genuine Full Disk Access grant reads these exact bytes.
    private static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)  // 16 bytes

    private static func canReadProtectedFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard isRegularFile(url, fileManager: fileManager) else { return false }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // Actually READ the real bytes, don't just open — and require the
            // true SQLite header, not merely "a read that didn't throw". TCC
            // can permit open() on a protected file while denying the read, and
            // on some macOS versions that denial surfaces as an EOF/empty read
            // rather than an error (osaurus#2601, still reproduced on 15.7.9 in
            // #2613 despite the open→read fix). The sentinels — TCC.db /
            // chat.db — are real SQLite databases that always begin with this
            // header, so:
            //   • a blocked read throws            -> not granted
            //   • a blocked read returns empty/EOF -> not granted (the #2613 hole)
            //   • a substituted/garbage read       -> not granted
            //   • a real FDA grant                 -> header matches -> granted
            let data = try handle.read(upToCount: Self.sqliteHeader.count)
            return data == Self.sqliteHeader
        } catch {
            return false
        }
    }
}

/// Outcome of one permission probe (the Permissions tab "Test" button, the
/// tool gate's Automation pre-check, the Abilities toggle).
///
/// `isGranted` is the machine decision and is derived from the real signal
/// — the AppleScript error number, the framework authorization status, the
/// protected-file read. `message` is the localized human text for display
/// ONLY. Callers must branch on `isGranted`, never on the message: the
/// `SUCCESS:` prefix is translated (`ERFOLG:` in German, `성공:` in Korean,
/// `成功：` in Chinese), so a prefix test read every successful Mail / Notes
/// / Music / Messages probe on those locales as a denial and the tool gate
/// refused with `permission_denied` no matter what TCC said (GitHub #2858).
struct PermissionProbeResult: Sendable, Equatable {
    let isGranted: Bool
    let message: String

    static func granted(_ message: String) -> PermissionProbeResult {
        PermissionProbeResult(isGranted: true, message: message)
    }

    static func denied(_ message: String) -> PermissionProbeResult {
        PermissionProbeResult(isGranted: false, message: message)
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

    /// Centralized helper to set permission and persist state.
    /// Skips the no-op assignment: writing an unchanged `@Published` dict still
    /// fires the whole SwiftUI fan-out, and the periodic refresh calls this
    /// every 2s — observers (e.g. the composer card) would re-render each tick.
    private func setPermission(_ permission: SystemPermission, isGranted: Bool) {
        guard permissionStates[permission] != isGranted else { return }
        permissionStates[permission] = isGranted
        savePermissionStates()
    }

    /// Batch update permissions and persist. Same no-op guard as
    /// `setPermission` so the periodic refresh only publishes real changes.
    private func setPermissions(_ states: [SystemPermission: Bool]) {
        guard states.contains(where: { permissionStates[$0.key] != $0.value }) else { return }
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
        case .automation, .automationCalendar, .automationMail, .automationMessages, .automationMusic, .notes,
            .maps:
            // Cached: the live Automation check runs AppleScript (and may
            // launch the target app), which must not happen during view
            // updates. `requestAutomationPermissionAndWait` refreshes it.
            return permissionStates[permission] ?? false
        case .calendar:
            return checkCalendarPermission()
        case .reminders:
            return checkRemindersPermission()
        case .location:
            return checkLocationPermission()
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
        case .location, .automation, .automationCalendar, .automationMail, .automationMessages,
            .automationMusic, .notes, .maps:
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
        case .automation, .automationCalendar, .automationMail, .automationMessages, .automationMusic, .notes,
            .maps:
            requestAutomationPermission(permission)
        case .calendar:
            requestCalendarPermission()
        case .reminders:
            requestRemindersPermission()
        case .location:
            requestLocationPermission()
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
            let status = await requestLocationAuthorizationAndWait()
            return Self.isLocationAuthorized(status)
        case .automation, .automationCalendar, .automationMail, .automationMessages, .automationMusic, .notes,
            .maps:
            return await requestAutomationPermissionAndWait(permission)
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

    /// Longest `requestLocationAuthorizationAndWait` waits for the user to
    /// answer the system dialog. The dialog has no timeout of its own; this
    /// only bounds a caller whose user walked away.
    static let locationDialogTimeout: TimeInterval = 120

    /// `.authorized` is macOS's legacy spelling of `.authorizedAlways`.
    nonisolated static func isLocationAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways || status == .authorized
    }

    /// Current Location authorization via the single shared manager (no
    /// fresh `CLLocationManager()` — each one is a synchronous locationd
    /// handshake on the calling thread).
    var locationAuthorizationStatus: CLAuthorizationStatus {
        if RuntimeEnvironment.isUnderTests { return .denied }
        return locationManager.authorizationStatus
    }

    private func checkLocationPermission() -> Bool {
        Self.isLocationAuthorized(locationManager.authorizationStatus)
    }

    private func requestLocationPermission() {
        locationManager.requestAlwaysAuthorization()
    }

    /// Pending `requestLocationAuthorizationAndWait` callers, resumed by
    /// `locationManagerDidChangeAuthorization` once the status leaves
    /// `.notDetermined` (or by their own timeout).
    private var locationAuthorizationWaiters: [UUID: CheckedContinuation<CLAuthorizationStatus, Never>] = [:]

    /// Show the Location permission dialog (when the status is still
    /// `.notDetermined`) and wait for the user's answer instead of sampling
    /// the status right away. Returns the status after the user responded,
    /// or the current status when `timeout` elapsed with the dialog still
    /// open. Already-decided statuses return immediately.
    func requestLocationAuthorizationAndWait(timeout: TimeInterval = locationDialogTimeout) async -> CLAuthorizationStatus {
        if RuntimeEnvironment.isUnderTests { return .denied }
        let current = locationManager.authorizationStatus
        guard current == .notDetermined else { return current }
        let token = UUID()
        let status: CLAuthorizationStatus = await withCheckedContinuation { continuation in
            locationAuthorizationWaiters[token] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                guard let self, let pending = self.locationAuthorizationWaiters.removeValue(forKey: token) else { return }
                pending.resume(returning: self.locationManager.authorizationStatus)
            }
            requestLocationPermission()
        }
        setPermission(.location, isGranted: Self.isLocationAuthorized(status))
        return status
    }

    private func resumeLocationWaiters(with status: CLAuthorizationStatus) {
        guard status != .notDetermined, !locationAuthorizationWaiters.isEmpty else { return }
        let pending = locationAuthorizationWaiters
        locationAuthorizationWaiters.removeAll()
        for continuation in pending.values { continuation.resume(returning: status) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.setPermission(.location, isGranted: Self.isLocationAuthorized(status))
            self.resumeLocationWaiters(with: status)
        }
    }

    // MARK: - Automation Permissions (Apple Events)

    /// Fire-and-forget request for any Apple Events automation permission
    /// (System Events, Calendar, Mail, Messages, Music, Notes, Maps). Probes
    /// through `requestAutomationPermissionAndWait`; when the grant is still
    /// missing afterwards the macOS dialog was most likely already answered
    /// with "Don't Allow", so System Settings is opened for a manual fix.
    private func requestAutomationPermission(_ permission: SystemPermission) {
        Task { @MainActor in
            if permissionStates[permission] ?? false {
                refreshAllPermissions()
                return
            }
            let granted = await requestAutomationPermissionAndWait(permission)
            if !granted {
                openSystemSettings(for: permission)
            }
        }
    }

    /// Probe an Apple Events automation permission and wait for the answer.
    /// Unlike `requestPermission(_:)` (fire-and-forget, opens System Settings
    /// on denial) this returns the fresh result so a tool gate or an Abilities
    /// toggle can react to it. The first probe shows the macOS "wants access
    /// to control X" dialog; later probes just read the TCC decision.
    ///
    /// The decision is `PermissionProbeResult.isGranted` — derived from the
    /// AppleScript error number — never the localized probe message (#2858).
    func requestAutomationPermissionAndWait(_ permission: SystemPermission) async -> Bool {
        if RuntimeEnvironment.isUnderTests { return false }
        guard permission.isAutomationBased else { return permissionStates[permission] ?? false }
        // `tell application "X"` launches X if needed and would bring it to the
        // front; launching it ourselves first (activates = false) keeps the
        // probe from stealing focus from the chat window.
        if let bundleId = Self.automationProbeBundleIdentifier(for: permission) {
            _ = await AppleScriptBridge.ensureRunning(
                bundleIdentifier: bundleId, appName: permission.displayName
            )
        }
        let granted = await Self.probe(permission).isGranted
        setPermission(permission, isGranted: granted)
        return granted
    }

    /// Bundle id of the app an Automation probe targets, so it can be
    /// launched in the background first.
    nonisolated static func automationProbeBundleIdentifier(for permission: SystemPermission) -> String? {
        switch permission {
        case .automationMail: return "com.apple.mail"
        case .automationMessages: return "com.apple.MobileSMS"
        case .automationMusic: return "com.apple.Music"
        case .notes: return "com.apple.Notes"
        case .maps: return "com.apple.Maps"
        case .automationCalendar: return "com.apple.iCal"
        default: return nil
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

    // MARK: - Probes

    /// Run the diagnostic probe for `permission`: the same code path the
    /// Permissions tab "Test" button, the tool gate's Automation pre-check
    /// and the Abilities toggle use, so every consumer sees one decision.
    /// Automation probes send a real Apple Event and may show the macOS
    /// consent dialog; the others read the framework authorization status.
    nonisolated static func probe(_ permission: SystemPermission) async -> PermissionProbeResult {
        switch permission {
        case .automation: return await debugTestAutomationAccess()
        case .automationCalendar: return await debugTestCalendarAccess()
        case .automationMail: return await debugTestMailAccess()
        case .automationMessages: return await debugTestMessagesAccess()
        case .automationMusic: return await debugTestMusicAccess()
        case .notes: return await debugTestNotesAccess()
        case .maps: return await debugTestMapsAccess()
        case .calendar: return debugTestCalendarEventKitAccess()
        case .reminders: return debugTestRemindersAccess()
        case .contacts: return debugTestContactsAccess()
        case .location: return await debugTestLocationAccess()
        case .accessibility: return debugTestAccessibilityAccess()
        case .disk: return debugTestFullDiskAccess()
        case .microphone: return debugTestMicrophoneAccess()
        case .screenRecording: return debugTestScreenRecordingAccess()
        }
    }

    /// Longest an Automation probe waits for its Apple Event. The first
    /// probe blocks inside the OS consent dialog until the user answers, so
    /// this is a "user walked away" bound, not a script budget.
    nonisolated static let automationProbeTimeout: TimeInterval = 120

    /// Send one Apple Event probe through `AppleScriptExecutor` and map the
    /// outcome. The executor is the ONLY place `NSAppleScript` may execute:
    /// the OSA component deadlocks when two `executeAndReturnError` calls
    /// overlap on different threads, and a raw probe on a detached task
    /// could overlap a tool script from another chat or the iMessage
    /// channel. Going through it also gives the probe the executor's
    /// -1743 classification and main-runloop heartbeat.
    ///
    /// `isGranted` follows the executor status, never the text.
    nonisolated private static func probeAutomation(
        source: String,
        success: @Sendable (String) -> String
    ) async -> PermissionProbeResult {
        let result = await AppleScriptExecutor.run(source: source, timeout: automationProbeTimeout)
        switch result.status {
        case .success:
            return .granted(success(result.output ?? ""))
        case .permissionRequired:
            let number = result.errorNumber ?? AppleScriptExecutor.permissionDeniedErrorNumber
            let text = result.errorMessage ?? "Not authorized to send Apple events."
            return .denied(
                "ERROR [\(number)]: \(text) → Permission denied. Grant in System Settings → Privacy & Security → Automation"
            )
        case .timedOut:
            return .denied("ERROR: \(result.errorMessage ?? "The probe did not finish in time.")")
        case .compileError, .runtimeError:
            let number = result.errorNumber.map { "[\($0)]" } ?? ""
            let text = result.errorMessage ?? "Unknown error"
            let appGoneCodes = [
                AppleScriptBridge.ErrorNumber.appNotRunning,
                AppleScriptBridge.ErrorNumber.connectionInvalid,
            ]
            let appGone = result.errorNumber.map(appGoneCodes.contains) ?? false
            let guidance = appGone ? " → App communication failed. Open the app and try again." : ""
            return .denied("ERROR \(number): \(text)\(guidance)")
        }
    }

    /// Probe Automation for one scriptable app with a read-only `name`
    /// query — the same class of Apple Event the app tools send, so a
    /// grant here proves the TCC decision. `appName` is the AppleScript
    /// application name (`Mail`, `Notes`, …).
    nonisolated static func probeAppleEvents(appName: String) async -> PermissionProbeResult {
        await probeAutomation(
            source: """
                tell application "\(appName)"
                    return name
                end tell
                """
        ) { output in
            L("SUCCESS: Connected to \(output.isEmpty ? appName : output)")
        }
    }

    // MARK: - Debug: Test Automation Access

    /// Debug function to test general Automation access (System Events)
    nonisolated static func debugTestAutomationAccess() async -> PermissionProbeResult {
        await probeAutomation(
            source: """
                tell application "System Events"
                    return name of first process whose frontmost is true
                end tell
                """
        ) { output in
            output.isEmpty ? L("NO RESULT") : L("SUCCESS: \(output)")
        }
    }

    // MARK: - Debug: Test Accessibility Access

    /// Debug function to test if Accessibility access is trusted.
    nonisolated static func debugTestAccessibilityAccess() -> PermissionProbeResult {
        if AXIsProcessTrusted() {
            return .granted(L("SUCCESS: Process is trusted for Accessibility."))
        }
        return .denied(
            L(
                "ERROR: Process is NOT trusted for Accessibility. If enabled in System Settings, try removing and re-adding Osaurus to the list."
            )
        )
    }

    // MARK: - Debug: Test Calendar AppleScript

    /// Debug function to test if Calendar AppleScript works from this process.
    /// Launches Calendar.app in the background if it is not running.
    nonisolated static func debugTestCalendarAccess() async -> PermissionProbeResult {
        // Launch first (activates = false) so the Apple Event does not bring
        // Calendar to the front or race its scripting server on a cold start.
        let running = await AppleScriptBridge.ensureRunning(bundleIdentifier: "com.apple.iCal", appName: "Calendar")
        let diagnostics = running ? "" : " | Calendar.app not found or failed to launch"
        let result = await probeAutomation(
            source: """
                tell application id "com.apple.iCal"
                    return name of calendars as string
                end tell
                """
        ) { output in
            output.isEmpty ? L("NO RESULT") : L("SUCCESS: \(output)")
        }
        guard !result.isGranted, !diagnostics.isEmpty else { return result }
        return .denied(result.message + diagnostics)
    }

    // MARK: - Debug: Test Contacts Access

    /// Debug function to test if Contacts access works.
    nonisolated static func debugTestContactsAccess() -> PermissionProbeResult {
        if RuntimeEnvironment.isUnderTests { return .denied(L("ERROR: Access Denied")) }
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
                return .granted(L("SUCCESS: Authorized (Found \(count)+ contacts)"))
            } catch {
                // The grant exists; the fetch failing is a data problem, not
                // a permission one — the gate would let the tool run.
                return .granted(L("SUCCESS: Authorized (fetching a contact failed: \(error.localizedDescription))"))
            }
        case .denied:
            return .denied(L("ERROR: Access Denied"))
        case .restricted:
            return .denied(L("ERROR: Access Restricted"))
        case .notDetermined:
            return .denied(L("WARNING: Access Not Determined"))
        @unknown default:
            return .denied(L("ERROR: Unknown Status"))
        }
    }

    // MARK: - Debug: Test Calendar (EventKit) Access

    /// Debug function to test if Calendar access works via EventKit.
    /// Granted only for `.fullAccess`, matching `isGrantedOffMain` — a
    /// write-only grant would pass "Test" and then fail the tool gate.
    nonisolated static func debugTestCalendarEventKitAccess() -> PermissionProbeResult {
        if RuntimeEnvironment.isUnderTests { return .denied(L("ERROR: Access Denied")) }
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            let store = EKEventStore()
            // Try to fetch calendars to verify
            let calendars = store.calendars(for: .event)
            if !calendars.isEmpty {
                return .granted(
                    calendars.count == 1
                        ? L("SUCCESS: Authorized (Found 1 calendar)")
                        : L("SUCCESS: Authorized (Found \(calendars.count) calendars)")
                )
            }
            return .granted(L("SUCCESS: Authorized (No calendars found)"))
        case .writeOnly:
            return .denied(L("ERROR: Write-only access. Full access is required."))
        case .denied:
            return .denied(L("ERROR: Access Denied"))
        case .restricted:
            return .denied(L("ERROR: Access Restricted"))
        case .notDetermined:
            return .denied(L("WARNING: Access Not Determined"))
        @unknown default:
            return .denied(L("ERROR: Unknown Status"))
        }
    }

    // MARK: - Debug: Test Reminders (EventKit) Access

    /// Debug function to test if Reminders access works via EventKit.
    /// Granted only for `.fullAccess`, matching `isGrantedOffMain`.
    nonisolated static func debugTestRemindersAccess() -> PermissionProbeResult {
        if RuntimeEnvironment.isUnderTests { return .denied(L("ERROR: Access Denied")) }
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess:
            let store = EKEventStore()
            let calendars = store.calendars(for: .reminder)
            if !calendars.isEmpty {
                return .granted(
                    calendars.count == 1
                        ? L("SUCCESS: Authorized (Found 1 list)")
                        : L("SUCCESS: Authorized (Found \(calendars.count) lists)")
                )
            }
            return .granted(L("SUCCESS: Authorized (No lists found)"))
        case .writeOnly:
            return .denied(L("ERROR: Write-only access. Full access is required."))
        case .denied:
            return .denied(L("ERROR: Access Denied"))
        case .restricted:
            return .denied(L("ERROR: Access Restricted"))
        case .notDetermined:
            return .denied(L("WARNING: Access Not Determined"))
        @unknown default:
            return .denied(L("ERROR: Unknown Status"))
        }
    }

    // MARK: - Debug: Test Location Access

    /// Debug function to test if Location access works. Reads the shared
    /// manager's authorization (no fresh `CLLocationManager()` — each one is
    /// a synchronous locationd handshake) and accepts the legacy
    /// `.authorized` spelling like `isLocationAuthorized` does.
    nonisolated static func debugTestLocationAccess() async -> PermissionProbeResult {
        let status = await MainActor.run { SystemPermissionService.shared.locationAuthorizationStatus }
        if isLocationAuthorized(status) {
            return .granted(L("SUCCESS: Authorized"))
        }
        switch status {
        case .denied:
            return .denied(L("ERROR: Access Denied"))
        case .restricted:
            return .denied(L("ERROR: Access Restricted"))
        case .notDetermined:
            return .denied(L("WARNING: Access Not Determined"))
        default:
            return .denied(L("ERROR: Unknown Status"))
        }
    }

    // MARK: - Debug: Test Full Disk Access / Microphone / Screen Recording

    /// Debug function to test Full Disk Access with the real protected-file
    /// read `isGrantedOffMain` uses.
    nonisolated static func debugTestFullDiskAccess() -> PermissionProbeResult {
        if SystemPermissionProbe.fullDiskAccessGranted() {
            return .granted(L("SUCCESS: Protected files are readable."))
        }
        return .denied(
            L(
                "ERROR: Full Disk Access is not granted. Add Osaurus under System Settings → Privacy & Security → Full Disk Access."
            )
        )
    }

    /// Debug function to test Microphone access.
    nonisolated static func debugTestMicrophoneAccess() -> PermissionProbeResult {
        if RuntimeEnvironment.isUnderTests { return .denied(L("ERROR: Access Denied")) }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted(L("SUCCESS: Authorized"))
        case .denied:
            return .denied(L("ERROR: Access Denied"))
        case .restricted:
            return .denied(L("ERROR: Access Restricted"))
        case .notDetermined:
            return .denied(L("WARNING: Access Not Determined"))
        @unknown default:
            return .denied(L("ERROR: Unknown Status"))
        }
    }

    /// Debug function to test Screen Recording access.
    nonisolated static func debugTestScreenRecordingAccess() -> PermissionProbeResult {
        if SystemPermissionProbe.screenRecordingGranted() {
            return .granted(L("SUCCESS: Authorized"))
        }
        return .denied(
            L(
                "ERROR: Screen Recording is not granted. Add Osaurus under System Settings → Privacy & Security → Screen Recording."
            )
        )
    }

    // MARK: - Debug: Test Notes Access

    /// Debug function to test if Notes access works via AppleScript.
    nonisolated static func debugTestNotesAccess() async -> PermissionProbeResult {
        await probeAppleEvents(appName: "Notes")
    }

    // MARK: - Debug: Test Maps Access

    /// Debug function to test if Maps access works via AppleScript.
    nonisolated static func debugTestMapsAccess() async -> PermissionProbeResult {
        await probeAppleEvents(appName: "Maps")
    }

    // MARK: - Debug: Test Messages Access

    /// Debug function to test if Messages access works via Apple Events.
    /// Sends a read-only query (app name) — this is the same class of Apple
    /// Event `imsg send` uses, so a SUCCESS here proves the TCC grant.
    nonisolated static func debugTestMessagesAccess() async -> PermissionProbeResult {
        await probeAppleEvents(appName: "Messages")
    }

    // MARK: - Debug: Test Music Access

    /// Debug function to test if Music access works via AppleScript.
    nonisolated static func debugTestMusicAccess() async -> PermissionProbeResult {
        await probeAppleEvents(appName: "Music")
    }

    // MARK: - Debug: Test Mail Access

    /// Debug function to test if Mail access works via AppleScript.
    nonisolated static func debugTestMailAccess() async -> PermissionProbeResult {
        await probeAppleEvents(appName: "Mail")
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
