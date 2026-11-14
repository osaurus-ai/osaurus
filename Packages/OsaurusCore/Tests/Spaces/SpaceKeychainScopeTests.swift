// Copyright © 2026 osaurus.

import Foundation
import OsaurusRepository
import Testing

@testable import OsaurusCore

@Suite("Per-Space Keychain entries")
struct SpaceKeychainScopeTests {
    @Test("Default keeps bare service names; other Spaces get a suffix")
    func serviceNames() {
        let id = SpaceRegistry.newSpaceId()
        #expect(SpaceKeychainScope.service("com.osaurus.account", spaceId: SpaceRegistry.defaultSpaceId)
            == "com.osaurus.account")
        #expect(SpaceKeychainScope.service("com.osaurus.account", spaceId: id) == "com.osaurus.account.space.\(id)")
    }

    @Test("Test processes always run in Default, so wrapper names are unchanged")
    func testProcessUsesDefault() {
        #expect(SpaceKeychainScope.service(OsaurusKeychainServices.storage) == OsaurusKeychainServices.storage)
        #expect(SpaceKeychainScope.allowsSharedAndSyncedItems)
    }

    @Test("Outside Default, identity writes are one device-only attempt")
    func deviceOnlyOutsideDefault() {
        let deviceOnly = OsaurusKeychainGroup.writeAttemptGroups(sharedGroup: "TEAM.ai.osaurus.identity", allowsSynced: false)
        #expect(deviceOnly == [[OsaurusKeychainGroup.WriteTarget(accessGroup: nil, synchronizable: false)]])

        let normal = OsaurusKeychainGroup.writeAttemptGroups(sharedGroup: "TEAM.ai.osaurus.identity")
        #expect(normal.count == 2)
        #expect(normal[0].first == OsaurusKeychainGroup.WriteTarget(accessGroup: nil, synchronizable: true))
    }

    @Test("Only update and language preferences carry into a new Space")
    func carriedOverKeys() {
        #expect(SpaceLauncher.isCarriedOverKey("SUEnableAutomaticChecks"))
        #expect(SpaceLauncher.isCarriedOverKey("AppleLanguages"))
        #expect(!SpaceLauncher.isCarriedOverKey("hasCompletedOnboarding"))
        #expect(!SpaceLauncher.isCarriedOverKey("com.osaurus.device.deviceId"))
    }

    /// Every Security-framework query names its service through
    /// `SpaceKeychainScope`, or a new store would silently share entries
    /// across Spaces.
    @Test("Every kSecAttrService query goes through SpaceKeychainScope")
    func everyServiceQueryIsScoped() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Spaces/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusCore/
        let enumerator = try #require(FileManager.default.enumerator(at: packageRoot, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scopedQueries = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: packageRoot.path + "/", with: "")
            if relative.hasPrefix("Tests/") || relative.hasPrefix(".build/") { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated()
            where line.contains("kSecAttrService as String:") || line.contains("KeychainKeyStore(") {
                let isWipeOfScopedName = relative == "Services/Spaces/SpaceKeychainScope.swift"
                if line.contains("SpaceKeychainScope.service(") || isWipeOfScopedName {
                    scopedQueries += 1
                } else {
                    offenders.append("\(relative):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "Unscoped Keychain service queries: \(offenders)")
        #expect(scopedQueries > 10)
    }

    /// Reset and delete wipe a Space's Keychain entries by service name, so a
    /// store whose service is missing from the list would outlive its Space.
    @Test("Every Keychain service constant is wiped with its Space")
    func everyServiceConstantIsWiped() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pattern = try NSRegularExpression(
            pattern: #"static let (?:keychainService|service)(?:: String)? = "([^"]+)""#
        )
        let enumerator = try #require(FileManager.default.enumerator(at: packageRoot, includingPropertiesForKeys: nil))
        var missing: [String] = []
        var found = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: packageRoot.path + "/", with: "")
            if relative.hasPrefix("Tests/") || relative.hasPrefix(".build/") { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: text) else { continue }
                let service = String(text[valueRange])
                found += 1
                if !SpaceKeychainScope.wipedServices.contains(service) {
                    missing.append("\(relative): \(service)")
                }
            }
        }
        #expect(missing.isEmpty, "Keychain services not wiped with their Space: \(missing)")
        #expect(found > 5)
    }
}
