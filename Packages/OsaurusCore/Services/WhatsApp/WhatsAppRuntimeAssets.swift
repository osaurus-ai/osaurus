//
//  WhatsAppRuntimeAssets.swift
//  osaurus
//
//  Single source of truth for the pinned `osaurus-wa` helper the native
//  WhatsApp channel drives. `osaurus-wa` is a whatsmeow-based WhatsApp Web
//  bridge (source in `helpers/osaurus-wa/`), spoken to over the same
//  newline-framed JSON-RPC stdio protocol as the iMessage `imsg` helper.
//
//  The trust model mirrors `IMessageRuntimeAssets`: fail-closed digest pins
//  locked to `scripts/build/wa-helper-manifest.json`, a DEBUG-only dev
//  override env var, and a same-team code-signature carve-out for a copy
//  sealed inside the app bundle. Digests are pinned to the
//  `wa-helper-v0.2.3` release archive; rotate them with
//  `make wa-helper-release` per docs/CHANNEL_RELEASE_RUNBOOK_WHATSAPP.md.
//

import CryptoKit
import Foundation
import Security

#if os(macOS)

    public enum WhatsAppRuntimeAssets {
        // MARK: - Pinned release

        /// Pinned `osaurus-wa` release. Bump together with the digests below
        /// when rotating the helper.
        public static let version = "0.2.3"

        public static let upstreamRepository = "https://github.com/osaurus-ai/osaurus"
        public static let license = "MIT"

        public static let executableName = "osaurus-wa"

        // MARK: - Digests (fail-closed pins)
        //
        // MUST match `scripts/build/wa-helper-manifest.json` (locked by a
        // unit test). Pinned to the `wa-helper-v0.2.3` release archive; an
        // all-zero pin would mean unpinned and refuse every copy except the
        // DEBUG dev override and an app-sealed same-team signed copy.

        public static let executableSHA256 =
            "8bb150af3e5d617f77a4bc1d0734faaf940adc38684941160b4bba0283a4b1d6"

        public static let archiveURLString =
            "https://github.com/osaurus-ai/osaurus/releases/download/wa-helper-v\(version)/osaurus-wa-macos.zip"
        public static let archiveSHA256 =
            "156b184b28aa86ef65712c891ed06af4bb343ef479671f2ded6a8c5229501856"
        public static let maxArchiveDownloadBytes = 64 * 1_024 * 1_024

        public static let executableRequiredArchitectures = ["arm64"]

        /// True once the digests above carry real release values.
        public static var digestsPinned: Bool {
            executableSHA256 != String(repeating: "0", count: 64)
        }

        // MARK: - Resolution

        public static let bundleSubdirectory = "Helpers"

        /// Env override for local testing against a dev-built `osaurus-wa`
        /// (`make wa-helper`). Honored in DEBUG builds only, mirroring
        /// `OSAURUS_IMSG_PATH`.
        public static let executableOverrideEnvKey = "OSAURUS_WA_PATH"

        static func overrideExecutableURL() -> URL? {
            #if DEBUG
                guard
                    let override = ProcessInfo.processInfo.environment[executableOverrideEnvKey],
                    !override.isEmpty
                else { return nil }
                return URL(fileURLWithPath: override)
            #else
                return nil
            #endif
        }

        /// `~/.osaurus/helpers/osaurus-wa/<version>/` — the runtime download
        /// install location (versioned so a pin bump never trusts a stale
        /// install).
        public static func downloadedHelpersDirectoryURL() -> URL {
            OsaurusPaths.helpers()
                .appendingPathComponent(executableName, isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
        }

        /// Where the helper keeps the linked WhatsApp Web session (whatsmeow
        /// SQLite store). Created and owned by the helper; Swift only passes
        /// the path and deletes it on unlink-with-wipe.
        public static func sessionStoreDirectoryURL() -> URL {
            OsaurusPaths.root()
                .appendingPathComponent("whatsapp", isDirectory: true)
                .appendingPathComponent("session", isDirectory: true)
        }

        /// Any installed candidate, without judging trust (UI "is anything
        /// installed" states). Use `verifyExecutable().trustedURL` for the
        /// copy that may actually be spawned.
        public static func installedExecutableURL() -> URL? {
            if let override = overrideExecutableURL() {
                return FileManager.default.isExecutableFile(atPath: override.path) ? override : nil
            }
            if let bundled = helperFileURL(in: bundledHelpersDirectoryURL()) {
                return bundled
            }
            return helperFileURL(in: downloadedHelpersDirectoryURL())
        }

        private static func helperFileURL(in directory: URL?) -> URL? {
            guard let directory else { return nil }
            let candidate = directory.appendingPathComponent(executableName)
            return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
        }

        private static func bundledHelpersDirectoryURL() -> URL? {
            let contents = Bundle.main.bundleURL.appendingPathComponent(
                "Contents",
                isDirectory: true
            )
            let helpers = contents.appendingPathComponent(bundleSubdirectory, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: helpers.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { return nil }
            return helpers
        }

        // MARK: - Fail-closed verification

        public enum VerificationResult: Equatable, Sendable {
            case verified(URL)
            case missing
            case digestMismatch(expected: String, actual: String)
            case unpinned
            case overridden(URL)

            public var trustedURL: URL? {
                switch self {
                case .verified(let url), .overridden(let url):
                    return url
                case .missing, .digestMismatch, .unpinned:
                    return nil
                }
            }
        }

        /// Verify the installed `osaurus-wa` executable — the gate consulted
        /// before every spawn. Trust order: DEBUG dev override, app-sealed
        /// copy (digest or same-team signature), downloaded copy (digest
        /// only, since its directory is user-writable).
        public static func verifyExecutable() -> VerificationResult {
            verifyExecutableCandidates(
                override: overrideExecutableURL(),
                bundled: helperFileURL(in: bundledHelpersDirectoryURL()),
                downloaded: helperFileURL(in: downloadedHelpersDirectoryURL())
            )
        }

        static func verifyExecutableCandidates(
            override: URL?,
            bundled: URL?,
            downloaded: URL?,
            executablePin: String = executableSHA256,
            pinsAvailable: Bool = digestsPinned,
            sameTeamTrust: (URL) -> Bool = { url in
                guard let helperTeam = teamIdentifier(ofValidlySignedCodeAt: url),
                    let hostTeam = hostTeamIdentifier()
                else { return false }
                return helperTeam == hostTeam
            }
        ) -> VerificationResult {
            if let override {
                return FileManager.default.isExecutableFile(atPath: override.path)
                    ? .overridden(override)
                    : .missing
            }
            guard bundled != nil || downloaded != nil else { return .missing }
            // Same-team signature can trust a sealed bundled copy even
            // before a release pins digests.
            if let bundled, sameTeamTrust(bundled) { return .verified(bundled) }
            guard pinsAvailable else { return .unpinned }

            var firstFailure: VerificationResult?
            if let bundled, let actual = sha256Hex(ofFileAt: bundled) {
                if actual == executablePin { return .verified(bundled) }
                firstFailure = .digestMismatch(expected: executablePin, actual: actual)
            }
            if let downloaded, let actual = sha256Hex(ofFileAt: downloaded) {
                if actual == executablePin { return .verified(downloaded) }
                if firstFailure == nil {
                    firstFailure = .digestMismatch(expected: executablePin, actual: actual)
                }
            }
            return firstFailure ?? .missing
        }

        // MARK: - Code-signature trust

        static func hostTeamIdentifier() -> String? {
            teamIdentifier(ofValidlySignedCodeAt: Bundle.main.bundleURL)
        }

        static func teamIdentifier(ofValidlySignedCodeAt url: URL) -> String? {
            var staticCode: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
                let code = staticCode
            else { return nil }
            let checkFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
            guard SecStaticCodeCheckValidity(code, checkFlags, nil) == errSecSuccess else {
                return nil
            }
            var info: CFDictionary?
            let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
            guard SecCodeCopySigningInformation(code, infoFlags, &info) == errSecSuccess,
                let dictionary = info as? [String: Any]
            else { return nil }
            return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        }

        static func sha256Hex(ofFileAt url: URL) -> String? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try? handle.read(upToCount: 1_048_576)
                guard let chunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

#endif
