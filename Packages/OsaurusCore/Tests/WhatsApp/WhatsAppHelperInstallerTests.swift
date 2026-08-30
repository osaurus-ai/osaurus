//
//  WhatsAppHelperInstallerTests.swift
//  osaurusTests
//
//  Fixture coverage for the runtime download/install gate of the pinned
//  `osaurus-wa` helper: digest pins are fail-closed (including the
//  unpinned pre-release state), a bad archive installs nothing and never
//  clobbers a prior good install, and a good archive lands with the
//  executable bit set, provenance recorded, and quarantine stripped.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct WhatsAppHelperInstallerTests {

    @Test func archiveURLAndPinsAreWellFormed() {
        #expect(
            WhatsAppRuntimeAssets.archiveURLString
                == "https://github.com/osaurus-ai/osaurus/releases/download/wa-helper-v\(WhatsAppRuntimeAssets.version)/osaurus-wa-macos.zip"
        )
        for pin in [
            WhatsAppRuntimeAssets.archiveSHA256,
            WhatsAppRuntimeAssets.executableSHA256,
        ] {
            #expect(pin.count == 64)
            #expect(pin.allSatisfy { $0.isHexDigit })
        }
        // The helper must run on Apple silicon.
        #expect(WhatsAppRuntimeAssets.executableRequiredArchitectures.contains("arm64"))
    }

    /// Zeroed digests (the pre-release state) must refuse the download up
    /// front — nothing is fetched, nothing installs.
    @Test func unpinnedDigestsRefuseInstallBeforeDownloading() async throws {
        let installer = WhatsAppHelperInstaller(
            pins: WhatsAppHelperPins(
                archiveURLString: "https://example.test/osaurus-wa-macos.zip",
                archiveSHA256: String(repeating: "0", count: 64),
                executableSHA256: String(repeating: "0", count: 64)
            )
        )
        await #expect(throws: WhatsAppHelperInstallError.unpinned) {
            try await installer.installFromRelease()
        }
        await MainActor.run {
            #expect(!WhatsAppHelperInstallState.shared.isBusy)
            WhatsAppHelperInstallState.shared.update(.idle)
        }
    }

    /// The unpinned state also fails the spawn gate for a downloaded copy —
    /// only the DEBUG override or an app-sealed same-team copy may run.
    @Test func unpinnedVerificationRefusesDownloadedCopy() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-wa-unpinned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let downloaded = workDir.appendingPathComponent("osaurus-wa")
        try Data("helper bytes".utf8).write(to: downloaded)

        let result = WhatsAppRuntimeAssets.verifyExecutableCandidates(
            override: nil,
            bundled: nil,
            downloaded: downloaded,
            executablePin: String(repeating: "0", count: 64),
            pinsAvailable: false,
            sameTeamTrust: { _ in false }
        )
        #expect(result == .unpinned)
        #expect(result.trustedURL == nil)
    }

    /// The same-team signature escape hatch must never apply to the
    /// user-writable downloaded location: a wrong-digest downloaded copy is
    /// rejected even when sameTeamTrust would vouch for it.
    @Test func sameTeamTrustNeverAppliesToDownloadedCopy() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-wa-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let downloaded = workDir.appendingPathComponent("osaurus-wa")
        try Data("downloaded bytes".utf8).write(to: downloaded)

        let wrongPin = String(repeating: "f", count: 64)
        let rejected = WhatsAppRuntimeAssets.verifyExecutableCandidates(
            override: nil,
            bundled: nil,
            downloaded: downloaded,
            executablePin: wrongPin,
            pinsAvailable: true,
            sameTeamTrust: { _ in true }
        )
        #expect(rejected.trustedURL == nil)

        // With a matching pin the downloaded copy verifies.
        let pin = try #require(WhatsAppRuntimeAssets.sha256Hex(ofFileAt: downloaded))
        let verified = WhatsAppRuntimeAssets.verifyExecutableCandidates(
            override: nil,
            bundled: nil,
            downloaded: downloaded,
            executablePin: pin,
            pinsAvailable: true,
            sameTeamTrust: { _ in false }
        )
        #expect(verified == .verified(downloaded))
    }

    @Test func installArchiveStagesVerifiedHelperLayout() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let installedExecutable = try WhatsAppHelperInstaller.installArchive(
            fixture.archive,
            into: fixture.destination,
            pins: fixture.pins
        )

        let fm = FileManager.default
        #expect(fm.isExecutableFile(atPath: installedExecutable.path))

        let provenance =
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: fixture.destination
                        .appendingPathComponent("osaurus-wa.provenance.json")
                )
            ) as? [String: Any]
        #expect(provenance?["installedBy"] as? String == "runtime-download")
        #expect(provenance?["executableSHA256"] as? String == fixture.pins.executableSHA256)

        // Quarantine must be gone: the digest pin is the trust decision.
        #expect(
            getxattr(installedExecutable.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
                == -1
        )
    }

    @Test func executableDigestMismatchInstallsNothing() throws {
        var fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.pins.executableSHA256 = String(repeating: "a", count: 64)

        #expect {
            try WhatsAppHelperInstaller.installArchive(
                fixture.archive,
                into: fixture.destination,
                pins: fixture.pins
            )
        } throws: { error in
            guard case WhatsAppHelperInstallError.digestMismatch(let expected, _) = error else {
                return false
            }
            return expected == String(repeating: "a", count: 64)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func badArchiveNeverClobbersAPriorGoodInstall() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try WhatsAppHelperInstaller.installArchive(
            fixture.archive,
            into: fixture.destination,
            pins: fixture.pins
        )

        var tamperedPins = fixture.pins
        tamperedPins.executableSHA256 = String(repeating: "b", count: 64)
        #expect(throws: (any Error).self) {
            try WhatsAppHelperInstaller.installArchive(
                fixture.archive,
                into: fixture.destination,
                pins: tamperedPins
            )
        }

        // Prior install stays intact and executable.
        #expect(
            FileManager.default.isExecutableFile(
                atPath: fixture.destination
                    .appendingPathComponent(WhatsAppRuntimeAssets.executableName).path
            )
        )
    }

    @Test func missingExecutableInArchiveFailsClosed() throws {
        let fixture = try Fixture(includeExecutable: false)
        defer { fixture.cleanUp() }

        #expect(throws: WhatsAppHelperInstallError.memberMissing("osaurus-wa")) {
            try WhatsAppHelperInstaller.installArchive(
                fixture.archive,
                into: fixture.destination,
                pins: fixture.pins
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func missingArchitectureSliceInstallsNothing() throws {
        var fixture = try Fixture()
        defer { fixture.cleanUp() }
        // Digest matches, but the crafted member is not a Mach-O at all —
        // exactly what the slice gate must catch on user machines.
        fixture.pins.executableRequiredArchitectures = ["arm64"]

        #expect(throws: WhatsAppHelperInstallError.architectureMissing("arm64")) {
            try WhatsAppHelperInstaller.installArchive(
                fixture.archive,
                into: fixture.destination,
                pins: fixture.pins
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    // MARK: - Fixture

    /// Builds a crafted `osaurus-wa-macos.zip` (tiny stand-in binary at the
    /// archive root, matching the `make wa-helper-release` layout), with
    /// pins computed from the actual fixture bytes.
    private struct Fixture {
        let workDir: URL
        let archive: URL
        let destination: URL
        var pins: WhatsAppHelperPins

        init(includeExecutable: Bool = true) throws {
            let fm = FileManager.default
            workDir = fm.temporaryDirectory
                .appendingPathComponent("osaurus-wa-fixture-\(UUID().uuidString)", isDirectory: true)
            let payload = workDir.appendingPathComponent("payload", isDirectory: true)
            try fm.createDirectory(at: payload, withIntermediateDirectories: true)

            let executable = payload.appendingPathComponent(WhatsAppRuntimeAssets.executableName)
            var executableSHA256 = String(repeating: "0", count: 64)
            if includeExecutable {
                try Data("#!/bin/sh\necho 0.1.0-test\n".utf8).write(to: executable)
                // Simulate a quarantined download source.
                "0083;00000000;osaurus-test;".withCString { value in
                    _ = setxattr(
                        executable.path, "com.apple.quarantine", value, strlen(value), 0, 0
                    )
                }
                executableSHA256 = WhatsAppRuntimeAssets.sha256Hex(ofFileAt: executable) ?? ""
            } else {
                // ditto refuses to zip an empty directory tree portably;
                // give it an unrelated member.
                try Data("filler".utf8).write(to: payload.appendingPathComponent("README"))
            }

            archive = workDir.appendingPathComponent("osaurus-wa-macos.zip")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", payload.path, archive.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                throw WhatsAppHelperInstallError.extractionFailed("fixture zip failed")
            }

            destination = workDir.appendingPathComponent("installed", isDirectory: true)
            // The fixture member is a crafted text file, not a Mach-O, so
            // slice validation is opted out; it has dedicated coverage.
            pins = WhatsAppHelperPins(
                archiveURLString: "https://example.test/osaurus-wa-macos.zip",
                archiveSHA256: WhatsAppRuntimeAssets.sha256Hex(ofFileAt: archive) ?? "",
                executableSHA256: executableSHA256,
                executableRequiredArchitectures: []
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: workDir)
        }
    }
}
