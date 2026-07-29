//
//  IMessageHelperInstaller.swift
//  osaurus
//
//  Runtime download + install of the pinned `imsg` helper, mirroring the
//  sandbox runtime-asset lane: the archive is fetched with the resumable
//  downloader against a pinned SHA-256, every installed Mach-O digest is
//  verified again, quarantine is stripped only after those digests match,
//  and the install lands atomically under
//  `~/.osaurus/helpers/imsg/<version>/`.
//
//  This is the only acquisition lane: the helper is never part of the app
//  bundle or the release pipeline (same model as the sandbox runtime and
//  models — download on demand, verify against compiled-in pins).
//

import Foundation

#if os(macOS)

    import Darwin

    enum IMessageHelperInstallError: LocalizedError, Equatable {
        case downloadFailed(String)
        case extractionFailed(String)
        case memberMissing(String)
        case digestMismatch(member: String, expected: String, actual: String)
        case architectureMissing(member: String, architecture: String)
        case installFailed(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let detail):
                return "Helper download failed: \(IMessageRPCSecurity.redact(detail))"
            case .extractionFailed(let detail):
                return "Helper archive could not be extracted: \(IMessageRPCSecurity.redact(detail))"
            case .memberMissing(let member):
                return "Helper archive is missing `\(member)`."
            case .digestMismatch(let member, let expected, let actual):
                return
                    "Helper `\(member)` failed integrity verification (expected \(expected.prefix(12))…, got \(actual.prefix(12))…). Nothing was installed."
            case .architectureMissing(let member, let architecture):
                return
                    "Helper `\(member)` is missing the required \(architecture) slice. Nothing was installed."
            case .installFailed(let detail):
                return "Helper could not be installed: \(IMessageRPCSecurity.redact(detail))"
            case .verificationFailed(let detail):
                return "Installed helper failed verification: \(detail)"
            }
        }
    }

    /// Observable install state for the setup UI.
    @MainActor
    public final class IMessageHelperInstallState: ObservableObject {
        public static let shared = IMessageHelperInstallState()

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
    /// `IMessageRuntimeAssets` pins.
    struct IMessageHelperPins: Sendable {
        var archiveURLString: String
        var archiveSHA256: String
        var executableSHA256: String
        var bridgeDylibSHA256: String
        var resourceBundleNames: [String]
        /// Mach-O slices each member must carry (from the pinned manifest;
        /// the bridge additionally needs arm64e because Messages.app runs
        /// arm64e). Tests that install crafted non-Mach-O fixtures pass
        /// empty arrays to opt out.
        var executableRequiredArchitectures: [String] =
            IMessageRuntimeAssets.executableRequiredArchitectures
        var bridgeDylibRequiredArchitectures: [String] =
            IMessageRuntimeAssets.bridgeDylibRequiredArchitectures

        static let production = IMessageHelperPins(
            archiveURLString: IMessageRuntimeAssets.archiveURLString,
            archiveSHA256: IMessageRuntimeAssets.archiveSHA256,
            executableSHA256: IMessageRuntimeAssets.executableSHA256,
            bridgeDylibSHA256: IMessageRuntimeAssets.bridgeDylibSHA256,
            resourceBundleNames: IMessageRuntimeAssets.resourceBundleNames
        )
    }

    final class IMessageHelperInstaller: Sendable {
        static let shared = IMessageHelperInstaller()

        private let pins: IMessageHelperPins

        init(pins: IMessageHelperPins = .production) {
            self.pins = pins
        }

        /// Download, verify, and install the pinned helper, reporting phase
        /// changes to the shared UI state. Safe to call again after a
        /// failure; the resumable downloader continues a partial archive.
        @discardableResult
        func installFromRelease() async throws -> URL {
            let state = await MainActor.run { IMessageHelperInstallState.shared }
            guard !(await state.isBusy) else {
                throw IMessageHelperInstallError.installFailed("An install is already running.")
            }
            await state.update(.downloading(nil))
            do {
                let archive = try await downloadArchive { fraction in
                    Task { @MainActor in
                        IMessageHelperInstallState.shared.update(.downloading(fraction))
                    }
                }
                await state.update(.installing)
                let installed = try Self.installArchive(
                    archive,
                    into: IMessageRuntimeAssets.downloadedHelpersDirectoryURL(),
                    pins: pins
                )
                // The runtime trust gate is the final word; run it once now
                // so the UI can't show "installed" for a copy the spawn path
                // would refuse.
                guard IMessageRuntimeAssets.verifyBundledExecutable().trustedURL != nil else {
                    throw IMessageHelperInstallError.verificationFailed(
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
                "imsg-macos-\(IMessageRuntimeAssets.version).zip"
            )
            let downloader = SandboxResumableDownloader(
                maxBytes: IMessageRuntimeAssets.maxArchiveDownloadBytes
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
                throw IMessageHelperInstallError.downloadFailed(error.localizedDescription)
            }
            return destination
        }

        // MARK: - Pure install gate (unit-tested without a network)

        /// Extract `archive`, verify every member digest against the pins,
        /// strip quarantine, and atomically install into `destination`.
        /// Fail-closed: on any mismatch nothing is installed and any prior
        /// install at `destination` is left untouched.
        @discardableResult
        static func installArchive(
            _ archive: URL,
            into destination: URL,
            pins: IMessageHelperPins
        ) throws -> URL {
            let fm = FileManager.default
            let workDir = fm.temporaryDirectory
                .appendingPathComponent("osaurus-imsg-install-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: workDir) }
            let extracted = workDir.appendingPathComponent("extracted", isDirectory: true)
            try fm.createDirectory(at: extracted, withIntermediateDirectories: true)

            try extractZip(archive, to: extracted)

            let executable = extracted.appendingPathComponent(IMessageRuntimeAssets.executableName)
            let dylib = extracted.appendingPathComponent(IMessageRuntimeAssets.bridgeDylibName)
            try verifyMember(
                executable,
                name: IMessageRuntimeAssets.executableName,
                expected: pins.executableSHA256
            )
            try verifyMember(
                dylib,
                name: IMessageRuntimeAssets.bridgeDylibName,
                expected: pins.bridgeDylibSHA256
            )
            // Same slice requirements the build lane enforces with
            // `lipo -verify_arch`: the helper must run on Apple silicon, and
            // the bridge additionally needs arm64e because Messages.app runs
            // arm64e and dylib injection requires a matching ABI. Parsed
            // natively — end-user machines have no `lipo`.
            try verifyArchitectures(
                executable,
                name: IMessageRuntimeAssets.executableName,
                required: pins.executableRequiredArchitectures
            )
            try verifyArchitectures(
                dylib,
                name: IMessageRuntimeAssets.bridgeDylibName,
                required: pins.bridgeDylibRequiredArchitectures
            )
            for bundleName in pins.resourceBundleNames {
                var isDirectory: ObjCBool = false
                let bundle = extracted.appendingPathComponent(bundleName)
                guard fm.fileExists(atPath: bundle.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else {
                    throw IMessageHelperInstallError.memberMissing(bundleName)
                }
            }

            // Stage the exact layout `Contents/Helpers` uses. Quarantine is
            // stripped only for files whose bytes just passed the digest
            // pins — that verification is the trust decision, not Gatekeeper.
            let stage = workDir.appendingPathComponent("stage", isDirectory: true)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            let stagedExecutable = stage.appendingPathComponent(IMessageRuntimeAssets.executableName)
            try fm.copyItem(at: executable, to: stagedExecutable)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedExecutable.path)
            try fm.copyItem(
                at: dylib,
                to: stage.appendingPathComponent(IMessageRuntimeAssets.bridgeDylibName)
            )
            for bundleName in pins.resourceBundleNames {
                try fm.copyItem(
                    at: extracted.appendingPathComponent(bundleName),
                    to: stage.appendingPathComponent(bundleName)
                )
            }
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
                throw IMessageHelperInstallError.installFailed(error.localizedDescription)
            }
            return destination.appendingPathComponent(IMessageRuntimeAssets.executableName)
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
                throw IMessageHelperInstallError.extractionFailed(error.localizedDescription)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail =
                    String(
                        data: stderr.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                throw IMessageHelperInstallError.extractionFailed(
                    "ditto exited \(process.terminationStatus): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
        }

        private static func verifyArchitectures(
            _ url: URL,
            name: String,
            required: [String]
        ) throws {
            guard !required.isEmpty else { return }
            let present = machOArchitectures(ofFileAt: url)
            for architecture in required where !present.contains(architecture) {
                throw IMessageHelperInstallError.architectureMissing(
                    member: name,
                    architecture: architecture
                )
            }
        }

        /// Architectures present in a thin or fat Mach-O at `url` (e.g.
        /// "arm64", "arm64e", "x86_64"). Unknown/unparseable files report
        /// an empty set, which fails any non-empty requirement.
        static func machOArchitectures(ofFileAt url: URL) -> Set<String> {
            guard let handle = try? FileHandle(forReadingFrom: url),
                let header = try? handle.read(upToCount: 4_096), header.count >= 8
            else { return [] }
            defer { try? handle.close() }

            func be32(_ offset: Int) -> UInt32 {
                UInt32(header[offset]) << 24 | UInt32(header[offset + 1]) << 16
                    | UInt32(header[offset + 2]) << 8 | UInt32(header[offset + 3])
            }
            func le32(_ offset: Int) -> UInt32 {
                UInt32(header[offset]) | UInt32(header[offset + 1]) << 8
                    | UInt32(header[offset + 2]) << 16 | UInt32(header[offset + 3]) << 24
            }
            func archName(cputype: UInt32, cpusubtype: UInt32) -> String? {
                switch cputype {
                case 0x0100_0007: return "x86_64"
                case 0x0100_000C:
                    // Capability bits masked; subtype 2 is arm64e.
                    return (cpusubtype & 0x00FF_FFFF) == 2 ? "arm64e" : "arm64"
                default: return nil
                }
            }

            let magic = be32(0)
            switch magic {
            case 0xCAFE_BABE, 0xCAFE_BABF:  // FAT_MAGIC / FAT_MAGIC_64 (big-endian on disk)
                let entrySize = magic == 0xCAFE_BABE ? 20 : 32
                let count = Int(be32(4))
                guard count > 0, count <= 32 else { return [] }
                var architectures: Set<String> = []
                for index in 0 ..< count {
                    let offset = 8 + index * entrySize
                    guard offset + 8 <= header.count else { break }
                    if let name = archName(cputype: be32(offset), cpusubtype: be32(offset + 4)) {
                        architectures.insert(name)
                    }
                }
                return architectures
            case 0xCFFA_EDFE, 0xCEFA_EDFE:  // MH_MAGIC_64 / MH_MAGIC, little-endian on disk
                // Little-endian thin Mach-O read as big-endian: swap back.
                if let name = archName(cputype: le32(4), cpusubtype: le32(8)) {
                    return [name]
                }
                return []
            case 0xFEED_FACF, 0xFEED_FACE:
                // Big-endian thin Mach-O (not produced for modern macOS, but
                // parse defensively).
                if let name = archName(cputype: be32(4), cpusubtype: be32(8)) {
                    return [name]
                }
                return []
            default:
                return []
            }
        }

        private static func verifyMember(_ url: URL, name: String, expected: String) throws {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw IMessageHelperInstallError.memberMissing(name)
            }
            guard let actual = IMessageRuntimeAssets.sha256Hex(ofFileAt: url) else {
                throw IMessageHelperInstallError.memberMissing(name)
            }
            guard actual == expected.lowercased() else {
                throw IMessageHelperInstallError.digestMismatch(
                    member: name,
                    expected: expected.lowercased(),
                    actual: actual
                )
            }
        }

        private static func writeProvenance(into directory: URL, pins: IMessageHelperPins) throws {
            let provenance: [String: String] = [
                "artifact": IMessageRuntimeAssets.executableName,
                "version": IMessageRuntimeAssets.version,
                "executableSHA256": pins.executableSHA256,
                "bridgeDylibSHA256": pins.bridgeDylibSHA256,
                "archive": pins.archiveURLString,
                "archiveSHA256": pins.archiveSHA256,
                "upstreamRepository": IMessageRuntimeAssets.upstreamRepository,
                "license": IMessageRuntimeAssets.license,
                "installedBy": "runtime-download",
            ]
            let data = try JSONSerialization.data(
                withJSONObject: provenance,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: directory.appendingPathComponent("imsg.provenance.json"))
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
