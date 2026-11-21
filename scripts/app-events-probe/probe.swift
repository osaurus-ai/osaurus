#!/usr/bin/env swift
//
//  probe.swift
//  osaurus — app events probe
//
//  Logs, as JSON lines on stdout, what actually arrives on this Mac for
//  each signal a workflow trigger could listen to. Findings are recorded
//  in docs/APP_EVENTS.md.
//
//    swift scripts/app-events-probe/probe.swift [--seconds N] [--exercise]
//
//  --seconds N   how long to listen (default 20).
//  --exercise    drive the signals it safely can: launch Calculator in
//                the background, bring it forward, quit it, and post a
//                distributed notification of its own, timing each.
//
//  Reads only: it never opens the Notification Center database, only
//  checks whether it could. Every permission is reported as it stands for
//  the process running the script (the terminal app).
//

import AppKit
import ApplicationServices
import Contacts
import EventKit
import Foundation

// MARK: - Output

let started = Date()
let encoder: JSONSerialization.WritingOptions = [.sortedKeys]

func emit(_ signal: String, _ fields: [String: Any] = [:]) {
    var line = fields
    line["signal"] = signal
    line["t"] = (Date().timeIntervalSince(started) * 1000).rounded() / 1000
    guard let data = try? JSONSerialization.data(withJSONObject: line, options: encoder),
        let text = String(data: data, encoding: .utf8)
    else { return }
    print(text)
    fflush(stdout)
}

var seconds: TimeInterval = 20
var exercise = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--seconds": seconds = args.next().flatMap(TimeInterval.init) ?? seconds
    case "--exercise": exercise = true
    default: break
    }
}

/// When the probe itself caused a signal, by key, so arrival can be timed.
var caused: [String: Date] = [:]
func latency(_ key: String) -> Any {
    guard let at = caused[key] else { return NSNull() }
    return (Date().timeIntervalSince(at) * 1000).rounded()
}

let calculatorID = "com.apple.calculator"

// MARK: - NSWorkspace app lifecycle

let workspace = NSWorkspace.shared.notificationCenter
let workspaceNames: [(Notification.Name, String)] = [
    (NSWorkspace.didLaunchApplicationNotification, "launched"),
    (NSWorkspace.didTerminateApplicationNotification, "quit"),
    (NSWorkspace.didActivateApplicationNotification, "activated"),
    (NSWorkspace.didDeactivateApplicationNotification, "deactivated"),
    (NSWorkspace.didHideApplicationNotification, "hidden"),
    (NSWorkspace.didUnhideApplicationNotification, "unhidden"),
    (NSWorkspace.activeSpaceDidChangeNotification, "space_changed"),
    (NSWorkspace.didWakeNotification, "wake"),
    (NSWorkspace.willSleepNotification, "sleep"),
    (NSWorkspace.screensDidSleepNotification, "screens_sleep"),
    (NSWorkspace.screensDidWakeNotification, "screens_wake"),
    (NSWorkspace.didMountNotification, "volume_mounted"),
    (NSWorkspace.didUnmountNotification, "volume_unmounted"),
]
for (name, event) in workspaceNames {
    workspace.addObserver(forName: name, object: nil, queue: .main) { note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        var fields: [String: Any] = ["event": event]
        if let app {
            fields["bundle_id"] = app.bundleIdentifier ?? NSNull()
            fields["name"] = app.localizedName ?? NSNull()
            fields["pid"] = Int(app.processIdentifier)
            if app.bundleIdentifier == calculatorID { fields["latency_ms"] = latency(event) }
        }
        if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { fields["volume"] = url.path }
        emit("workspace", fields)
    }
}

// MARK: - Distributed notifications

let distributed = DistributedNotificationCenter.default()
let probeName = Notification.Name("com.osaurus.app-events-probe.ping")
let namedDistributed = [
    "com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "com.apple.screensaver.didstart",
    "com.apple.screensaver.didstop", "AppleInterfaceThemeChangedNotification", "com.apple.Music.playerInfo",
    "com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged",
    "com.apple.bluetooth.status", "com.apple.accessibility.api", probeName.rawValue,
]
for raw in namedDistributed {
    distributed.addObserver(forName: Notification.Name(raw), object: nil, queue: .main) { note in
        var fields: [String: Any] = ["name": note.name.rawValue, "observer": "named"]
        fields["user_info_keys"] = (note.userInfo?.keys.map { "\($0)" } ?? []).sorted()
        if note.name == probeName { fields["latency_ms"] = latency("distributed_named") }
        emit("distributed", fields)
    }
}
var wildcardCount = 0
var wildcardNames = Set<String>()
distributed.addObserver(forName: nil, object: nil, queue: .main) { note in
    wildcardCount += 1
    let first = wildcardNames.insert(note.name.rawValue).inserted
    if first || note.name == probeName {
        var fields: [String: Any] = ["name": note.name.rawValue, "observer": "wildcard"]
        if note.name == probeName { fields["latency_ms"] = latency("distributed_wildcard") }
        emit("distributed", fields)
    }
}

// MARK: - Accessibility observers

let axTrusted = AXIsProcessTrusted()
emit("accessibility", ["trusted": axTrusted, "note": axTrusted ? "observers registered" : "no AX trust; skipped"])

var axObservers: [AXObserver] = []
let axCallback: AXObserverCallback = { _, element, notification, _ in
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let app = NSRunningApplication(processIdentifier: pid)
    let isBanner = app?.bundleIdentifier == "com.apple.notificationcenterui"
    emit("accessibility", [
        "notification": notification as String, "pid": Int(pid),
        "bundle_id": app?.bundleIdentifier ?? NSNull(),
        "latency_ms": isBanner ? latency("banner") : NSNull(),
    ])
}

func observeAX(pid: pid_t, notifications: [String]) {
    guard axTrusted else { return }
    var observer: AXObserver?
    guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else { return }
    let element = AXUIElementCreateApplication(pid)
    var added: [String] = []
    for name in notifications where AXObserverAddNotification(observer, element, name as CFString, nil) == .success {
        added.append(name)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    axObservers.append(observer)
    emit("accessibility", ["observing_pid": Int(pid), "added": added])
}

if let front = NSWorkspace.shared.frontmostApplication {
    observeAX(
        pid: front.processIdentifier,
        notifications: [
            kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification, kAXTitleChangedNotification,
            kAXFocusedUIElementChangedNotification,
        ])
}
// Notification banners are windows of the Notification Center agent.
if let banners = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
    .first
{
    observeAX(pid: banners.processIdentifier, notifications: [kAXWindowCreatedNotification, kAXCreatedNotification])
} else {
    emit("accessibility", ["notification_center": "not running"])
}

// MARK: - Calendar, Reminders, Contacts

func describe(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "not_determined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .fullAccess: return "full_access"
    case .writeOnly: return "write_only"
    @unknown default: return "unknown"
    }
}

let eventStore = EKEventStore()
emit("eventkit", [
    "calendar": describe(EKEventStore.authorizationStatus(for: .event)),
    "reminders": describe(EKEventStore.authorizationStatus(for: .reminder)),
])
NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { note in
    emit("eventkit", ["event": "store_changed", "user_info_keys": (note.userInfo?.keys.map { "\($0)" } ?? []).sorted()])
}

let contactsStatus: String = {
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .notDetermined: return "not_determined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "authorized"
    case .limited: return "limited"
    @unknown default: return "unknown"
    }
}()
emit("contacts", ["status": contactsStatus])
NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { _ in
    emit("contacts", ["event": "store_changed"])
}

// MARK: - Notification Center database

let home = FileManager.default.homeDirectoryForCurrentUser
let notificationDBs = [
    "Library/Group Containers/group.com.apple.usernoted/db2/db",
    "Library/Application Support/NotificationCenter",
].map { home.appendingPathComponent($0).path }
for path in notificationDBs {
    let exists = FileManager.default.fileExists(atPath: path)
    // Opening for read is what Full Disk Access gates; nothing is read.
    let handle = exists ? FileHandle(forReadingAtPath: path) : nil
    try? handle?.close()
    emit("notification_db", ["path": path, "exists": exists, "readable": handle != nil])
}

// MARK: - Exercise

/// Posts a banner the way a script can: as Script Editor, via osascript.
func postBanner() {
    caused["banner"] = Date()
    emit("exercise", ["step": "post banner via osascript display notification"])
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", #"display notification "probe banner" with title "Osaurus probe""#]
    try? task.run()
}

func exerciseSignals() {
    let previous = NSWorkspace.shared.frontmostApplication
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: calculatorID) else {
        emit("exercise", ["error": "Calculator not found"])
        return
    }
    caused["launched"] = Date()
    emit("exercise", ["step": "launch", "bundle_id": calculatorID])
    NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
        if let error { emit("exercise", ["error": error.localizedDescription]) }
        guard let app else { return }
        // AX registration fails until the app has finished launching.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            observeAX(
                pid: app.processIdentifier,
                notifications: [
                    kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                    kAXMainWindowChangedNotification, kAXApplicationActivatedNotification,
                    kAXApplicationDeactivatedNotification, kAXUIElementDestroyedNotification,
                ])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            caused["activated"] = Date()
            emit("exercise", ["step": "activate"])
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                caused["deactivated"] = Date()
                emit("exercise", ["step": "reactivate previous app", "bundle_id": previous?.bundleIdentifier ?? NSNull()])
                previous?.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    caused["quit"] = Date()
                    emit("exercise", ["step": "quit"])
                    app.terminate()
                }
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        caused["distributed_named"] = Date()
        caused["distributed_wildcard"] = Date()
        emit("exercise", ["step": "post distributed", "name": probeName.rawValue])
        distributed.postNotificationName(probeName, object: nil, userInfo: ["probe": "1"], deliverImmediately: true)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { postBanner() }
}

emit("start", [
    "seconds": seconds, "exercise": exercise,
    "macos": ProcessInfo.processInfo.operatingSystemVersionString, "uid": Int(getuid()),
])
if exercise { exerciseSignals() }
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
emit("end", ["wildcard_distributed_received": wildcardCount, "wildcard_distinct_names": wildcardNames.count])
