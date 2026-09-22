//
//  PermissionProbeLocalizationTests.swift
//  OsaurusCoreTests — Service
//
//  Regression guard for GitHub #2858: the Automation probes returned a
//  localized status string and every consumer decided "granted" with
//  `hasPrefix("SUCCESS")`. `Localizable.xcstrings` translates that prefix
//  (`ERFOLG:` in German, `성공:` in Korean, `成功：` in Chinese), so on those
//  locales a successful `tell application "Mail"` was read as a denial, the
//  tool gate refused every `mail_*` call with `permission_denied`, and no TCC
//  reset could fix it. The decision now travels as
//  `PermissionProbeResult.isGranted`, derived from the real signal.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Permission probes: locale-independent decision")
struct PermissionProbeLocalizationTests {

    /// `Packages/OsaurusCore/` resolved from this file, so the scan works
    /// under both `swift test` and `xcodebuild test`.
    private static var packageRoot: URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // Service/
        cursor.deleteLastPathComponent()  // Tests/
        return cursor.deletingLastPathComponent()  // OsaurusCore/
    }

    @Test("the granted decision does not depend on the message text")
    func decisionIsIndependentOfMessage() {
        // A German success message must still be a grant …
        let german = PermissionProbeResult.granted("ERFOLG: Verbunden mit Mail")
        #expect(german.isGranted)
        #expect(!german.message.hasPrefix("SUCCESS"))
        // … and an English-looking message must not smuggle in a grant.
        let spoofed = PermissionProbeResult.denied("SUCCESS: Connected to Mail")
        #expect(!spoofed.isGranted)
    }

    @Test("no consumer decides a permission from the localized probe text")
    func noPrefixChecksOnProbeMessages() throws {
        let files = [
            "Services/SystemPermissionService.swift",
            "Views/Settings/PermissionsView.swift",
            "Views/Agent/AgentCapabilityManagerView.swift",
        ]
        for relative in files {
            let url = Self.packageRoot.appendingPathComponent(relative)
            let source = try String(contentsOf: url, encoding: .utf8)
            for prefix in ["SUCCESS", "ERROR", "WARNING"] {
                #expect(
                    !source.contains("hasPrefix(\"\(prefix)\")"),
                    "\(relative) branches on the localized \"\(prefix)\" prefix; use PermissionProbeResult.isGranted"
                )
            }
        }
    }

    @Test("the localized success message really does lose its SUCCESS prefix")
    func catalogTranslatesTheSuccessPrefix() throws {
        // Documents why the prefix check was wrong: at least one shipped
        // translation of the Apple Events success message does not start
        // with "SUCCESS". If every translation is ever changed to keep the
        // prefix this guard becomes moot, but the structured decision above
        // still stands on its own.
        let catalog = Self.packageRoot
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Localizable.xcstrings")
        let data = try Data(contentsOf: catalog)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = root?["strings"] as? [String: Any]
        let entry = strings?["SUCCESS: Connected to %@"] as? [String: Any]
        let localizations = try #require(entry?["localizations"] as? [String: Any])
        let values = localizations.values.compactMap {
            (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        #expect(!values.isEmpty)
        #expect(values.contains { !$0.hasPrefix("SUCCESS") })
    }

    @Test("framework-status probes deny without touching TCC under tests")
    func statusProbesAreHermeticUnderTests() async {
        // These read `authorizationStatus` on daemons that may be absent in
        // CI; the test guard makes them fail closed instead of hanging.
        #expect(!SystemPermissionService.debugTestCalendarEventKitAccess().isGranted)
        #expect(!SystemPermissionService.debugTestRemindersAccess().isGranted)
        #expect(!SystemPermissionService.debugTestContactsAccess().isGranted)
        #expect(!SystemPermissionService.debugTestMicrophoneAccess().isGranted)
        #expect(!(await SystemPermissionService.debugTestLocationAccess().isGranted))
        // Every one of them carries a message for the Permissions tab.
        #expect(!SystemPermissionService.debugTestCalendarEventKitAccess().message.isEmpty)
    }

    @Test("the gate's Automation pre-check denies under tests without sending Apple Events")
    @MainActor
    func automationRequestDeniesUnderTests() async {
        let granted = await SystemPermissionService.shared.requestAutomationPermissionAndWait(.automationMail)
        #expect(!granted)
    }
}
