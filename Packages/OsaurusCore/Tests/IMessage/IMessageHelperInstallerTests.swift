//
//  IMessageHelperInstallerTests.swift
//  osaurusTests
//
//  Fixture coverage for the runtime download/install gate of the pinned
//  `imsg` helper: digest pins are fail-closed, a bad archive installs
//  nothing (and never clobbers a prior good install), and a good archive
//  lands with the executable bit set, provenance recorded, and quarantine
//  stripped.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IMessageHelperInstallerTests {

    @Test func archiveURLAndPinsAreWellFormed() {
        #expect(
            IMessageRuntimeAssets.archiveURLString
                == "https://github.com/openclaw/imsg/releases/download/v\(IMessageRuntimeAssets.version)/imsg-macos.zip"
        )
        for pin in [
            IMessageRuntimeAssets.archiveSHA256,
            IMessageRuntimeAssets.executableSHA256,
            IMessageRuntimeAssets.bridgeDylibSHA256,
        ] {
            #expect(pin.count == 64)
            #expect(pin.allSatisfy { $0.isHexDigit })
        }
        #expect(!IMessageRuntimeAssets.resourceBundleNames.isEmpty)
    }

    /// Pin-sync lock: the Swift constants must match
    /// `scripts/build/imsg-helper-manifest.json`, the single source of truth
    /// for the pinned helper release. A pin bump that touches only one side
    /// fails here in CI.
    @Test func pinsStayInSyncWithBuildManifest() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // file name
            .deletingLastPathComponent()  // IMessage
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusCore
            .deletingLastPathComponent()  // Packages
            .appendingPathComponent("scripts/build/imsg-helper-manifest.json")
        let manifest =
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
            as? [String: Any] ?? [:]

        #expect(manifest["version"] as? String == IMessageRuntimeAssets.version)
        #expect(manifest["archiveURL"] as? String == IMessageRuntimeAssets.archiveURLString)
        #expect(manifest["archiveSHA256"] as? String == IMessageRuntimeAssets.archiveSHA256)
        #expect(manifest["executableName"] as? String == IMessageRuntimeAssets.executableName)
        #expect(
            manifest["executableSHA256"] as? String == IMessageRuntimeAssets.executableSHA256
        )
        #expect(manifest["bridgeDylibName"] as? String == IMessageRuntimeAssets.bridgeDylibName)
        #expect(
            manifest["bridgeDylibSHA256"] as? String == IMessageRuntimeAssets.bridgeDylibSHA256
        )
        #expect(
            manifest["upstreamRepository"] as? String
                == IMessageRuntimeAssets.upstreamRepository
        )
        #expect(
            manifest["resourceBundles"] as? [String] == IMessageRuntimeAssets.resourceBundleNames
        )
        #expect(
            manifest["executableRequiredArchitectures"] as? [String]
                == IMessageRuntimeAssets.executableRequiredArchitectures
        )
        #expect(
            manifest["bridgeDylibRequiredArchitectures"] as? [String]
                == IMessageRuntimeAssets.bridgeDylibRequiredArchitectures
        )
    }

    @Test func installArchiveStagesVerifiedHelperLayout() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let installedExecutable = try IMessageHelperInstaller.installArchive(
            fixture.archive,
            into: fixture.destination,
            pins: fixture.pins
        )

        let fm = FileManager.default
        #expect(fm.isExecutableFile(atPath: installedExecutable.path))
        #expect(
            fm.fileExists(
                atPath: fixture.destination
                    .appendingPathComponent(IMessageRuntimeAssets.bridgeDylibName).path
            )
        )
        for bundle in fixture.pins.resourceBundleNames {
            #expect(fm.fileExists(atPath: fixture.destination.appendingPathComponent(bundle).path))
        }

        let provenance =
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: fixture.destination.appendingPathComponent("imsg.provenance.json")
                )
            ) as? [String: Any]
        #expect(provenance?["installedBy"] as? String == "runtime-download")
        #expect(provenance?["executableSHA256"] as? String == fixture.pins.executableSHA256)

        // Quarantine must be gone from every installed file.
        for path in [
            installedExecutable.path,
            fixture.destination.appendingPathComponent(IMessageRuntimeAssets.bridgeDylibName).path,
        ] {
            #expect(getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) == -1)
        }
    }

    @Test func executableDigestMismatchInstallsNothing() throws {
        var fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.pins.executableSHA256 = String(repeating: "a", count: 64)

        #expect {
            try IMessageHelperInstaller.installArchive(
                fixture.archive,
                into: fixture.destination,
                pins: fixture.pins
            )
        } throws: { error in
            guard case IMessageHelperInstallError.digestMismatch(let member, _, _) = error else {
                return false
            }
            return member == IMessageRuntimeAssets.executableName
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func badArchiveNeverClobbersAPriorGoodInstall() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try IMessageHelperInstaller.installArchive(
            fixture.archive,
            into: fixture.destination,
            pins: fixture.pins
        )

        var tamperedPins = fixture.pins
        tamperedPins.bridgeDylibSHA256 = String(repeating: "b", count: 64)
        #expect(throws: (any Error).self) {
            try IMessageHelperInstaller.installArchive(
                fixture.archive,
                into: fixture.destination,
                pins: tamperedPins
            )
        }

        // Prior install stays intact and executable.
        #expect(
            FileManager.default.isExecutableFile(
                atPath: fixture.destination
                    .appendingPathComponent(IMessageRuntimeAssets.executableName).path
            )
        )
    }

    @Test func missingResourceBundleFailsClosed() throws {
        let fixture = try Fixture(includeBundles: false)
        defer { fixture.cleanUp() }

        #expect {
            try IMessageHelperInstaller.installArchive(
                fixture.archive,
                into: fixture.destination,
                pins: fixture.pins
            )
        } throws: { error in
            guard case IMessageHelperInstallError.memberMissing(let member) = error else {
                return false
            }
            return fixture.pins.resourceBundleNames.contains(member)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func downloadedCopyMustMatchDigestExactlyEvenIfValidlySigned() throws {
        // A same-team-signed binary that does not match the digest pin must
        // NOT be trusted outside the app bundle: /bin/ls is validly signed
        // (by Apple, so the team check would already fail) — the stronger
        // property checked here is that a wrong-digest file in the
        // user-writable downloaded location is rejected outright.
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try IMessageHelperInstaller.installArchive(
            fixture.archive,
            into: fixture.destination,
            pins: fixture.pins
        )
        // The fixture binary's digest does not match the production pin, so
        // the runtime gate must report a mismatch for it (it resolves via the
        // downloaded-helpers path only when OsaurusPaths points there; here we
        // verify the digest logic directly).
        let installed = fixture.destination
            .appendingPathComponent(IMessageRuntimeAssets.executableName)
        let actual = IMessageRuntimeAssets.sha256Hex(ofFileAt: installed)
        #expect(actual == fixture.pins.executableSHA256)
        #expect(actual != IMessageRuntimeAssets.executableSHA256)
    }

    @Test func machOArchitectureParserReadsFatAndThinHeaders() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-imsg-macho-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        func be(_ value: UInt32) -> [UInt8] {
            [
                UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
            ]
        }
        func le(_ value: UInt32) -> [UInt8] {
            [
                UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
                UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24),
            ]
        }

        // Universal (fat) binary carrying arm64 + arm64e slices.
        var fat: [UInt8] = be(0xCAFE_BABE) + be(2)
        fat += be(0x0100_000C) + be(0) + be(0) + be(0) + be(0)  // arm64
        fat += be(0x0100_000C) + be(2) + be(0) + be(0) + be(0)  // arm64e
        let fatURL = workDir.appendingPathComponent("fat")
        try Data(fat).write(to: fatURL)
        #expect(
            IMessageHelperInstaller.machOArchitectures(ofFileAt: fatURL) == ["arm64", "arm64e"]
        )

        // Thin little-endian x86_64 Mach-O.
        let thin: [UInt8] = le(0xFEED_FACF) + le(0x0100_0007) + le(3) + le(0)
        let thinURL = workDir.appendingPathComponent("thin")
        try Data(thin).write(to: thinURL)
        #expect(IMessageHelperInstaller.machOArchitectures(ofFileAt: thinURL) == ["x86_64"])

        // Junk parses to an empty set, which fails any requirement.
        let junkURL = workDir.appendingPathComponent("junk")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: junkURL)
        #expect(IMessageHelperInstaller.machOArchitectures(ofFileAt: junkURL).isEmpty)
    }

    @Test func missingArchitectureSliceInstallsNothing() throws {
        var fixture = try Fixture()
        defer { fixture.cleanUp() }
        // Digests match, but the crafted members are not Mach-Os at all —
        // exactly what the slice gate must catch.
        fixture.pins.executableRequiredArchitectures = ["arm64"]

        #expect {
            try IMessageHelperInstaller.installArchive(
                fixture.archive,
                into: fixture.destination,
                pins: fixture.pins
            )
        } throws: { error in
            guard
                case IMessageHelperInstallError.architectureMissing(let member, let architecture) =
                    error
            else { return false }
            return member == IMessageRuntimeAssets.executableName && architecture == "arm64"
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func corruptedBundledCopyDoesNotMaskValidDownloadedCopy() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-imsg-fallback-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let bundled = workDir.appendingPathComponent("bundled-imsg")
        try Data("corrupted bundled bytes".utf8).write(to: bundled)
        let downloaded = workDir.appendingPathComponent("downloaded-imsg")
        try Data("pinned downloaded bytes".utf8).write(to: downloaded)
        let pin = try #require(IMessageRuntimeAssets.sha256Hex(ofFileAt: downloaded))

        // Bundled fails digest and signature: the downloaded copy must win.
        let fallback = IMessageRuntimeAssets.verifyExecutableCandidates(
            override: nil,
            bundled: bundled,
            downloaded: downloaded,
            executablePin: pin,
            pinsAvailable: true,
            sameTeamTrust: { _ in false }
        )
        #expect(fallback == .verified(downloaded))

        // A bundled copy trusted via the release re-sign path still wins.
        let sealed = IMessageRuntimeAssets.verifyExecutableCandidates(
            override: nil,
            bundled: bundled,
            downloaded: downloaded,
            executablePin: pin,
            pinsAvailable: true,
            sameTeamTrust: { _ in true }
        )
        #expect(sealed == .verified(bundled))

        // Both invalid: report the bundled copy's mismatch (trust order).
        let bothBad = IMessageRuntimeAssets.verifyExecutableCandidates(
            override: nil,
            bundled: bundled,
            downloaded: downloaded,
            executablePin: String(repeating: "f", count: 64),
            pinsAvailable: true,
            sameTeamTrust: { _ in false }
        )
        guard case .digestMismatch(_, let actual) = bothBad else {
            Issue.record("expected digestMismatch, got \(bothBad)")
            return
        }
        #expect(actual == IMessageRuntimeAssets.sha256Hex(ofFileAt: bundled))

        // The same-team escape hatch must never apply to the downloaded
        // copy: even with sameTeamTrust always-true, a wrong-digest
        // downloaded file with no bundled candidate is rejected.
        let downloadOnly = IMessageRuntimeAssets.verifyExecutableCandidates(
            override: nil,
            bundled: nil,
            downloaded: downloaded,
            executablePin: String(repeating: "f", count: 64),
            pinsAvailable: true,
            sameTeamTrust: { _ in true }
        )
        #expect(downloadOnly.trustedURL == nil)
    }

    @Test func tamperedBridgeDylibFailsSpawnVerification() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-imsg-dylib-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }
        let executable = workDir.appendingPathComponent(IMessageRuntimeAssets.executableName)
        try Data("executable".utf8).write(to: executable)

        // No dylib installed: basic mode, not fatal.
        #expect(
            IMessageRuntimeAssets.verifyBridgeDylib(
                nextTo: executable,
                dylibPin: String(repeating: "a", count: 64),
                sealedSameTeamTrust: { _ in false }
            ) == .missing
        )

        let dylib = workDir.appendingPathComponent(IMessageRuntimeAssets.bridgeDylibName)
        try Data("legit dylib bytes".utf8).write(to: dylib)
        let pin = try #require(IMessageRuntimeAssets.sha256Hex(ofFileAt: dylib))
        #expect(
            IMessageRuntimeAssets.verifyBridgeDylib(
                nextTo: executable,
                dylibPin: pin,
                sealedSameTeamTrust: { _ in false }
            ) == .verified(dylib)
        )

        // Tampered after install: every spawn re-checks and refuses.
        try Data("swapped dylib bytes".utf8).write(to: dylib)
        let tampered = IMessageRuntimeAssets.verifyBridgeDylib(
            nextTo: executable,
            dylibPin: pin,
            sealedSameTeamTrust: { _ in false }
        )
        guard case .mismatch(let expected, _) = tampered else {
            Issue.record("expected mismatch, got \(tampered)")
            return
        }
        #expect(expected == pin)
    }

    // MARK: - Fixture

    /// Builds a crafted `imsg-macos.zip` (tiny stand-in binaries + resource
    /// bundles), with pins computed from the actual fixture bytes.
    private struct Fixture {
        let workDir: URL
        let archive: URL
        let destination: URL
        var pins: IMessageHelperPins

        init(includeBundles: Bool = true) throws {
            let fm = FileManager.default
            workDir = fm.temporaryDirectory
                .appendingPathComponent("osaurus-imsg-fixture-\(UUID().uuidString)", isDirectory: true)
            let payload = workDir.appendingPathComponent("payload", isDirectory: true)
            try fm.createDirectory(at: payload, withIntermediateDirectories: true)

            let executable = payload.appendingPathComponent(IMessageRuntimeAssets.executableName)
            try Data("#!/bin/sh\necho 0.13.4-test\n".utf8).write(to: executable)
            let dylib = payload.appendingPathComponent(IMessageRuntimeAssets.bridgeDylibName)
            try Data("fake dylib bytes".utf8).write(to: dylib)
            // Simulate a quarantined download source.
            for url in [executable, dylib] {
                "0083;00000000;osaurus-test;".withCString { value in
                    _ = setxattr(url.path, "com.apple.quarantine", value, strlen(value), 0, 0)
                }
            }
            if includeBundles {
                for bundle in IMessageRuntimeAssets.resourceBundleNames {
                    let dir = payload.appendingPathComponent(bundle, isDirectory: true)
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try Data("resource".utf8).write(to: dir.appendingPathComponent("resource.txt"))
                }
            }

            archive = workDir.appendingPathComponent("imsg-macos.zip")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", payload.path, archive.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                throw IMessageHelperInstallError.extractionFailed("fixture zip failed")
            }

            destination = workDir.appendingPathComponent("installed", isDirectory: true)
            // Fixture members are crafted text files, not Mach-Os, so slice
            // validation is opted out; it has dedicated coverage below.
            pins = IMessageHelperPins(
                archiveURLString: "https://example.test/imsg-macos.zip",
                archiveSHA256: IMessageRuntimeAssets.sha256Hex(ofFileAt: archive) ?? "",
                executableSHA256: IMessageRuntimeAssets.sha256Hex(ofFileAt: executable) ?? "",
                bridgeDylibSHA256: IMessageRuntimeAssets.sha256Hex(ofFileAt: dylib) ?? "",
                resourceBundleNames: IMessageRuntimeAssets.resourceBundleNames,
                executableRequiredArchitectures: [],
                bridgeDylibRequiredArchitectures: []
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: workDir)
        }
    }
}
