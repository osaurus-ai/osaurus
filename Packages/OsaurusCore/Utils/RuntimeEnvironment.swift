//
//  RuntimeEnvironment.swift
//  osaurus
//
//  Process-level environment introspection. Centralised here so the
//  guards we need against unsafe-in-test code paths (XPC chats with
//  `contactsd`, `NSPanel` window display, eager singleton refreshes,
//  etc.) reference one named symbol instead of duplicating
//  `ProcessInfo.processInfo.environment[...]` lookups.
//

import Foundation

public enum RuntimeEnvironment {
    /// True when running inside an XCTest / Swift Testing test
    /// process. `XCTestConfigurationFilePath` is set by Xcode (and
    /// by `xcodebuild test` / `swift test`) for every test run, so
    /// it's the most reliable signal that a singleton init or
    /// system-framework call is happening from a test rather than
    /// from a real app launch.
    ///
    /// Use this to gate code paths that are *unsafe* in headless
    /// CI environments — anything that talks to a macOS XPC
    /// service that may not exist on the runner (`contactsd`,
    /// `EventKit`, `CLLocationManager`), creates an `NSPanel`
    /// without a display server, or kicks off a long-running
    /// background `Task` from a singleton's init.
    ///
    /// This guard pattern landed in 2026-04 after a CI run timed
    /// out for 45 minutes because `SystemPermissionService.shared.init()`
    /// triggered a detached task that called
    /// `CNContactStore.authorizationStatus` via
    /// `await MainActor.run`; on a CI runner with no `contactsd`
    /// the call hung holding the main actor, and ~100 other
    /// `@MainActor` tests stalled behind it.
    public static var isUnderTests: Bool {
        let processName = ProcessInfo.processInfo.processName
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || processName.hasSuffix("xctest") || processName == "swiftpm-testing-helper"
            || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
            || ProcessInfo.processInfo.environment["CI"] == "true"
    }
}
