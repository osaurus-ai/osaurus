//
//  PluginCompatibilityEnforcementTests.swift
//  OsaurusCoreTests
//
//  Pins `PluginManager`'s host-version / macOS-version compatibility
//  enforcement. Manifest declares `min_osaurus` and `min_macos`; this
//  PR turned those from advisory to a hard load gate so plugins that
//  rely on later ABI surfaces (e.g. v4 `get_active_agent_id`) refuse
//  to load against a host that can't satisfy the contract instead of
//  crashing at the first call.
//

import Foundation
import Testing

@testable import OsaurusCore

struct PluginCompatibilityEnforcementTests {

    private func makeManifest(
        minOsaurus: String? = nil,
        minMacos: String? = nil
    ) -> PluginManifest {
        PluginManifest(
            plugin_id: "com.test.compat.\(UUID().uuidString)",
            description: nil,
            capabilities: .init(tools: nil, routes: nil, config: nil, web: nil, artifact_handler: nil),
            instructions: nil,
            name: nil,
            version: nil,
            license: nil,
            authors: nil,
            min_macos: minMacos,
            min_osaurus: minOsaurus,
            secrets: nil,
            docs: nil
        )
    }

    private func os(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    // MARK: - No constraints

    @Test func absentConstraintsPassUnconditionally() {
        let manifest = makeManifest()
        let result = PluginManager.compatibilityFailure(
            manifest: manifest,
            hostVersion: "0.1.0",
            osVersion: os(10, 0, 0)
        )
        #expect(result == nil, "no min_osaurus / min_macos -> never gate")
    }

    @Test func emptyStringConstraintsArePassesNotErrors() {
        // Authors who set the field to `""` in JSON shouldn't get
        // their plugin gated — treat empty as "no constraint".
        let manifest = makeManifest(minOsaurus: "", minMacos: "")
        let result = PluginManager.compatibilityFailure(
            manifest: manifest,
            hostVersion: "1.0.0",
            osVersion: os(14, 0, 0)
        )
        #expect(result == nil)
    }

    // MARK: - min_osaurus

    @Test func hostOlderThanMinOsaurusFails() throws {
        let manifest = makeManifest(minOsaurus: "0.20.0")
        let result = PluginManager.compatibilityFailure(
            manifest: manifest,
            hostVersion: "0.18.13",
            osVersion: os(14, 0, 0)
        )
        let err = try #require(result)
        #expect(err.message.contains("requires Osaurus"))
        #expect(err.message.contains("0.20.0"))
        #expect(err.message.contains("0.18.13"))
    }

    @Test func hostExactlyMinOsaurusPasses() {
        // Equality is satisfaction.
        let manifest = makeManifest(minOsaurus: "0.20.0")
        let result = PluginManager.compatibilityFailure(
            manifest: manifest,
            hostVersion: "0.20.0",
            osVersion: os(14, 0, 0)
        )
        #expect(result == nil)
    }

    @Test func hostNewerThanMinOsaurusPasses() {
        let manifest = makeManifest(minOsaurus: "0.18.0")
        let result = PluginManager.compatibilityFailure(
            manifest: manifest,
            hostVersion: "0.20.5",
            osVersion: os(14, 0, 0)
        )
        #expect(result == nil)
    }

    @Test func unparseableMinOsaurusIsTreatedAsNoConstraint() {
        // We don't want to brick a plugin over a typo. Logged but
        // doesn't block the load.
        let manifest = makeManifest(minOsaurus: "not-a-version")
        let result = PluginManager.compatibilityFailure(
            manifest: manifest,
            hostVersion: "0.1.0",
            osVersion: os(14, 0, 0)
        )
        #expect(result == nil)
    }

    @Test func unknownHostVersionFailsOpenWithWarning() {
        // Dev builds (Bundle.main is the swiftpm helper, or Xcode
        // hasn't yet baked CFBundleShortVersionString) report an
        // empty / unparseable host version. The previous policy
        // ("treat as 0.0.0") bricked every plugin with a real
        // `min_osaurus`. The current policy is fail-open with a
        // one-shot warning so dev iteration isn't blocked.
        let manifest = makeManifest(minOsaurus: "0.5.0")
        for hostVersion in ["", "garbage", "not.a.version"] {
            let result = PluginManager.compatibilityFailure(
                manifest: manifest,
                hostVersion: hostVersion,
                osVersion: os(14, 0, 0)
            )
            #expect(
                result == nil,
                "host '\(hostVersion)' must fail open, got: \(result?.message ?? "nil")"
            )
        }
    }

    @Test func twoComponentHostVersionParsesAsZeroPatched() {
        // Xcode's default `MARKETING_VERSION = 1.0` returns "1.0" from
        // the bundle. Strict semver rejects that, but the host parser
        // pads to `1.0.0`. Pin both directions of the comparison.
        let manifest = makeManifest(minOsaurus: "1.0.0")
        let result = PluginManager.compatibilityFailure(
            manifest: manifest,
            hostVersion: "1.0",
            osVersion: os(14, 0, 0)
        )
        #expect(result == nil, "host '1.0' should satisfy min '1.0.0'")
    }

    @Test func singleComponentHostVersionParsesAsZeroPaddedTwice() {
        // `MARKETING_VERSION = 2` is rare but legal — pad both
        // missing components to zero.
        let manifest = makeManifest(minOsaurus: "1.5.0")
        let result = PluginManager.compatibilityFailure(
            manifest: manifest,
            hostVersion: "2",
            osVersion: os(14, 0, 0)
        )
        #expect(result == nil, "host '2' (-> 2.0.0) should satisfy min '1.5.0'")
    }

    @Test func parseHostVersionAcceptsLooseShapes() throws {
        // Direct sanity-check of the host parser. Strict shape still
        // works; loose shapes pad to zero; pre-release suffix is
        // stripped (matches `SemanticVersion.parse`).
        #expect(PluginManager.parseHostVersion("0.18.13") != nil)
        #expect(PluginManager.parseHostVersion("1.0") != nil)
        #expect(PluginManager.parseHostVersion("1") != nil)
        let withPrerelease = try #require(PluginManager.parseHostVersion("0.18.0-beta"))
        #expect(withPrerelease.major == 0)
        #expect(withPrerelease.minor == 18)
        #expect(PluginManager.parseHostVersion("") == nil)
        #expect(PluginManager.parseHostVersion("garbage") == nil)
    }

    // MARK: - min_macos

    @Test func macosOlderThanMinFails() throws {
        let manifest = makeManifest(minMacos: "15.0")
        let result = PluginManager.compatibilityFailure(
            manifest: manifest,
            hostVersion: "1.0.0",
            osVersion: os(14, 6, 1)
        )
        let err = try #require(result)
        #expect(err.message.contains("requires macOS"))
        #expect(err.message.contains("15.0.0"))
    }

    @Test func macosExactlyMinPasses() {
        let manifest = makeManifest(minMacos: "14.5")
        let result = PluginManager.compatibilityFailure(
            manifest: manifest,
            hostVersion: "1.0.0",
            osVersion: os(14, 5, 0)
        )
        #expect(result == nil)
    }

    @Test func macosNewerThanMinPasses() {
        let manifest = makeManifest(minMacos: "13.0")
        let result = PluginManager.compatibilityFailure(
            manifest: manifest,
            hostVersion: "1.0.0",
            osVersion: os(15, 1, 2)
        )
        #expect(result == nil)
    }

    @Test func parseOSVersionAcceptsMajorOnly() throws {
        let v = try #require(PluginManager.parseOSVersion("14"))
        #expect(v.majorVersion == 14)
        #expect(v.minorVersion == 0)
        #expect(v.patchVersion == 0)
    }

    @Test func parseOSVersionAcceptsMajorMinor() throws {
        let v = try #require(PluginManager.parseOSVersion("14.5"))
        #expect(v.majorVersion == 14)
        #expect(v.minorVersion == 5)
    }

    @Test func parseOSVersionAcceptsMajorMinorPatch() throws {
        let v = try #require(PluginManager.parseOSVersion("14.5.1"))
        #expect(v.majorVersion == 14)
        #expect(v.minorVersion == 5)
        #expect(v.patchVersion == 1)
    }

    @Test func parseOSVersionRejectsGarbage() {
        #expect(PluginManager.parseOSVersion("not-a-version") == nil)
        #expect(PluginManager.parseOSVersion("") == nil)
    }

    @Test func unparseableMinMacosIsTreatedAsNoConstraint() {
        let manifest = makeManifest(minMacos: "sequoia")
        let result = PluginManager.compatibilityFailure(
            manifest: manifest,
            hostVersion: "1.0.0",
            osVersion: os(10, 0, 0)
        )
        #expect(result == nil, "unparseable min_macos must not block load")
    }

    // MARK: - osVersionAtLeast comparison

    @Test func osVersionAtLeastMajorBeats() {
        #expect(PluginManager.osVersionAtLeast(current: os(15, 0, 0), required: os(14, 5, 0)))
        #expect(!PluginManager.osVersionAtLeast(current: os(13, 5, 0), required: os(14, 0, 0)))
    }

    @Test func osVersionAtLeastMinorBeatsWhenMajorEqual() {
        #expect(PluginManager.osVersionAtLeast(current: os(14, 5, 0), required: os(14, 4, 99)))
        #expect(!PluginManager.osVersionAtLeast(current: os(14, 3, 99), required: os(14, 5, 0)))
    }

    @Test func osVersionAtLeastPatchBeatsWhenMajorMinorEqual() {
        #expect(PluginManager.osVersionAtLeast(current: os(14, 5, 1), required: os(14, 5, 0)))
        #expect(PluginManager.osVersionAtLeast(current: os(14, 5, 0), required: os(14, 5, 0)))
        #expect(!PluginManager.osVersionAtLeast(current: os(14, 5, 0), required: os(14, 5, 1)))
    }

    // MARK: - Combined constraints

    @Test func bothConstraintsMustPass() throws {
        // min_osaurus passes, min_macos fails → error reports macOS.
        let manifest = makeManifest(minOsaurus: "0.1.0", minMacos: "20.0")
        let result = PluginManager.compatibilityFailure(
            manifest: manifest,
            hostVersion: "0.20.0",
            osVersion: os(14, 0, 0)
        )
        let err = try #require(result)
        #expect(err.message.contains("macOS"))
    }

    @Test func minOsaurusReportedFirstWhenBothFail() throws {
        // Implementation checks `min_osaurus` before `min_macos`, so
        // the host-version mismatch wins the error message. Pin that
        // ordering so a future refactor doesn't silently swap them.
        let manifest = makeManifest(minOsaurus: "9.0.0", minMacos: "99.0")
        let result = PluginManager.compatibilityFailure(
            manifest: manifest,
            hostVersion: "0.18.0",
            osVersion: os(14, 0, 0)
        )
        let err = try #require(result)
        #expect(err.message.contains("Osaurus"))
        #expect(!err.message.contains("macOS"))
    }
}
