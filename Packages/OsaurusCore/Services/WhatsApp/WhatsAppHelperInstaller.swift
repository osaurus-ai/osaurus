//
//  WhatsAppHelperInstaller.swift
//  osaurus
//
//  Runtime download + install of the pinned `osaurus-wa` helper, mirroring
//  the iMessage helper lane: the archive is fetched with the resumable
//  downloader against a pinned SHA-256, the installed binary's digest is
//  verified again, quarantine is stripped only after that digest matches,
//  and the install lands atomically under
//  `~/.osaurus/helpers/osaurus-wa/<version>/`.
//
//  If `WhatsAppRuntimeAssets` digests were ever all-zero (unpinned), the
//  install refuses up front; dev builds use `make wa-helper` +
//  `OSAURUS_WA_PATH` instead.
//

import Foundation

#if os(macOS)

    import Darwin

    enum WhatsAppHelperInstallError: LocalizedError, Equatable {
        case unpinned
        case downloadFailed(String)
        case extractionFailed(String)
        case memberMissing(String)
        case digestMismatch(expected: String, actual: String)
        case architectureMissing(String)
        case installFailed(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unpinned:
                return
                    "No release digests are pinned in this build, so a download cannot be verified. Build the helper locally with `make wa-helper` instead."
            case .downloadFailed(let detail):
                return "Helper download failed: \(WhatsAppRPCSecurity.redact(detail))"
            case .extractionFailed(let detail):
                return "Helper archive could not be extracted: \(WhatsAppRPCSecurity.redact(detail))"
            case .memberMissing(let member):
                return "Helper archive is missing `\(member)`."
            case .digestMismatch(let expected, let actual):
                return
                    "Helper failed integrity verification (expected \(expected.prefix(12))…, got \(actual.prefix(12))…). Nothing was installed."
            case .architectureMissing(let architecture):
                return "Helper is missing the required \(architecture) slice. Nothing was installed."
            case .installFailed(let detail):
                return "Helper could not be installed: \(WhatsAppRPCSecurity.redact(detail))"
            case .verificationFailed(let detail):
                return "Installed helper failed verification: \(detail)"
            }
        }
    }

    /// Observable install state for the setup UI.
    @MainActor
    public final class WhatsAppHelperInstallState: ObservableObject {
        public static let shared = WhatsAppHelperInstallState()

        public enum Phase: Equatable {
            case idle
            /// Fraction 0...1, or nil while the total size is unknown.
            case downloading(Double?)
            case installing
            case installed
            case failed(String)
        }

        @Published public private(set) var phase: Phase = .idle

        public var isBusy: Bool {
            switch phase {
            case .downloading, .installing: return true
            case .idle, .installed, .failed: return false
            }
        }

        func update(_ phase: Phase) {
            self.phase = phase
        }
    }

    /// Digest pins for one helper release. Injectable so tests can exercise
    /// the install gate with crafted archives; production always uses the
    /// `WhatsAppRuntimeAssets` pins.
    struct WhatsAppHelperPins: Sendable {
        var archiveURLString: String
        var archiveSHA256: String
        var executableSHA256: String
        /// Mach-O slices the binary must carry. Tests that install crafted
        /// non-Mach-O fixtures pass an empty array to opt out.
        var executableRequiredArchitectures: [String] =
            WhatsAppRuntimeAssets.executableRequiredArchitectures

        static let production = WhatsAppHelperPins(
            archiveURLString: WhatsAppRuntimeAssets.archiveURLString,
            archiveSHA256: WhatsAppRuntimeAssets.archiveSHA256,
            executableSHA256: WhatsAppRuntimeAssets.executableSHA256
        )
    }

    final class WhatsAppHelperInstaller: Sendable {
        static let shared = WhatsAppHelperInstaller()

        private let pins: WhatsAppHelperPins

        init(pins: WhatsAppHelperPins = .production) {
            self.pins = pins
        }

        /// Download, verify, and install the pinned helper, reporting phase
        /// changes to the shared UI state. Safe to call again after a
        /// failure; the resumable downloader continues a partial archive.
        @discardableResult
        func installFromRelease() async throws -> URL {
            let state = await MainActor.run { WhatsAppHelperInstallState.shared }
            guard !(await state.isBusy) else {
                throw WhatsAppHelperInstallError.installFailed("An install is already running.")
            }
            guard pins.executableSHA256 != String(repeating: "0", count: 64) else {
                await state.update(
                    .failed(WhatsAppHelperInstallError.unpinned.localizedDescription)
                )
                throw WhatsAppHelperInstallError.unpinned
            }
            await state.update(.downloading(nil))
            do {
                let archive = try await downloadArchive { fraction in
                    Task { @MainActor in
                        WhatsAppHelperInstallState.shared.update(.downloading(fraction))
                    }
                }
                await state.update(.installing)
                let installed = try Self.installArchive(
                    archive,
                    into: WhatsAppRuntimeAssets.downloadedHelpersDirectoryURL(),
                    pins: pins
                )
                // The runtime trust gate is the final word; run it once now
                // so the UI can't show "installed" for a copy the spawn path
                // would refuse.
                guard WhatsAppRuntimeAssets.verifyExecutable().trustedURL != nil else {
                    throw WhatsAppHelperInstallError.verificationFailed(
                        "the runtime trust gate rejected the installed helper"
                    )
                }
                try? FileManager.default.removeItem(at: archive)
                await state.update(.installed)
                return installed
            } catch {
                await state.update(.failed(error.localizedDescription))
                throw error
            }
        }

        private func downloadArchive(
            progress: @escaping @Sendable (Double?) -> Void
        ) async throws -> URL {
            let cacheDir = OsaurusPaths.cache()
            OsaurusPaths.ensureExistsSilent(cacheDir)
            let destination = cacheDir.appendingPathComponent(
                "osaurus-wa-macos-\(WhatsAppRuntimeAssets.version).zip"
            )
            let downloader = SandboxResumableDownloader(
                maxBytes: WhatsAppRuntimeAssets.maxArchiveDownloadBytes
            )
            do {
                try await downloader.download(
                    from: [
                        SandboxResumableDownloader.Source(
                            url: pins.archiveURLString,
                            expectedSHA256: pins.archiveSHA256
                        )
                    ],
                    to: destination,
                    progress: { bytes, total in
                        progress(total > 0 ? Double(bytes) / Double(total) : nil)
                    }
                )
            } catch {
                throw WhatsAppHelperInstallError.downloadFailed(error.localizedDescription)
            }
            return destination
        }

        // MARK: - Pure install gate (unit-tested without a network)

        /// Extract `archive`, verify the helper digest against the pins,
        /// strip quarantine, and atomically install into `destination`.
        /// Fail-closed: on any mismatch nothing is installed and any prior
        /// install at `destination` is left untouched.
        @discardableResult
        static func installArchive(
            _ archive: URL,
            into destination: URL,
            pins: WhatsAppHelperPins
        ) throws -> URL {
            let fm = FileManager.default
            let workDir = fm.temporaryDirectory
                .appendingPathComponent("osaurus-wa-install-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: workDir) }
            let extracted = workDir.appendingPathComponent("extracted", isDirectory: true)
            try fm.createDirectory(at: extracted, withIntermediateDirectories: true)

            try extractZip(archive, to: extracted)

            let executable = extracted.appendingPathComponent(WhatsAppRuntimeAssets.executableName)
            try verifyMember(executable, expected: pins.executableSHA256)
            // Same slice requirement the build lane enforces: the helper
            // must run on Apple silicon. Parsed natively — end-user machines
            // have no `lipo`.
            if !pins.executableRequiredArchitectures.isEmpty {
                let present = IMessageHelperInstaller.machOArchitectures(ofFileAt: executable)
                for architecture in pins.executableRequiredArchitectures
                where !present.contains(architecture) {
                    throw WhatsAppHelperInstallError.architectureMissing(architecture)
                }
            }

            // Stage, strip quarantine only for bytes that just passed the
            // digest pin — that verification is the trust decision, not
            // Gatekeeper.
            let stage = workDir.appendingPathComponent("stage", isDirectory: true)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            let stagedExecutable = stage.appendingPathComponent(WhatsAppRuntimeAssets.executableName)
            try fm.copyItem(at: executable, to: stagedExecutable)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedExecutable.path)
            try writeProvenance(into: stage, pins: pins)
            removeQuarantineRecursively(at: stage)

            do {
                try fm.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: stage)
                } else {
                    try fm.moveItem(at: stage, to: destination)
                }
            } catch {
                throw WhatsAppHelperInstallError.installFailed(error.localizedDescription)
            }
            return destination.appendingPathComponent(WhatsAppRuntimeAssets.executableName)
        }

        private static func extractZip(_ archive: URL, to directory: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, directory.path]
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = Pipe()
            do {
                try process.run()
            } catch {
                throw WhatsAppHelperInstallError.extractionFailed(error.localizedDescription)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail =
                    String(
                        data: stderr.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                throw WhatsAppHelperInstallError.extractionFailed(
                    "ditto exited \(process.terminationStatus): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
        }

        private static func verifyMember(_ url: URL, expected: String) throws {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw WhatsAppHelperInstallError.memberMissing(
                    WhatsAppRuntimeAssets.executableName
                )
            }
            guard let actual = WhatsAppRuntimeAssets.sha256Hex(ofFileAt: url) else {
                throw WhatsAppHelperInstallError.memberMissing(
                    WhatsAppRuntimeAssets.executableName
                )
            }
            guard actual == expected.lowercased() else {
                throw WhatsAppHelperInstallError.digestMismatch(
                    expected: expected.lowercased(),
                    actual: actual
                )
            }
        }

        private static func writeProvenance(into directory: URL, pins: WhatsAppHelperPins) throws {
            let provenance: [String: String] = [
                "artifact": WhatsAppRuntimeAssets.executableName,
                "version": WhatsAppRuntimeAssets.version,
                "executableSHA256": pins.executableSHA256,
                "archive": pins.archiveURLString,
                "archiveSHA256": pins.archiveSHA256,
                "upstreamRepository": WhatsAppRuntimeAssets.upstreamRepository,
                "license": WhatsAppRuntimeAssets.license,
                "installedBy": "runtime-download",
            ]
            let data = try JSONSerialization.data(
                withJSONObject: provenance,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: directory.appendingPathComponent("osaurus-wa.provenance.json"))
        }

        /// Strip `com.apple.quarantine` from everything under `root`. Called
        /// strictly after digest verification; without this, spawning the
        /// downloaded (quarantined) helper would be blocked by Gatekeeper
        /// even though its bytes are pin-verified.
        private static func removeQuarantineRecursively(at root: URL) {
            let fm = FileManager.default
            var paths = [root.path]
            if let enumerator = fm.enumerator(atPath: root.path) {
                for case let relative as String in enumerator {
                    paths.append(root.appendingPathComponent(relative).path)
                }
            }
            for path in paths {
                removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
            }
        }
    }

#endif
