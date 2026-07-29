//
//  IMessageRuntimeAssets.swift
//  osaurus
//
//  Single source of truth for the pinned `imsg` helper the native iMessage
//  channel drives. `imsg` (MIT) is an open-source CLI/daemon that talks to
//  Messages.app and the local `chat.db`. The helper is not part of the app
//  bundle: it is downloaded on demand (like the sandbox runtime and models)
//  by `IMessageHelperInstaller`, which verifies the archive and each Mach-O
//  against the digests pinned here before anything is installed.
//
//  Everything here is version- and digest-pinned, and every spawn re-verifies
//  the installed copy — fail-closed on both sides, so a mirror/registry
//  compromise cannot swap the bytes Osaurus executes without failing
//  verification on the host. The pins are locked to
//  `scripts/build/imsg-helper-manifest.json` by a unit test.
//

import CryptoKit
import Foundation
import Security

#if os(macOS)

    public enum IMessageRuntimeAssets {
        // MARK: - Pinned upstream release

        /// Pinned `imsg` release tag. Bump together with every digest below
        /// when rotating the helper.
        public static let version = "0.13.4"

        /// Upstream project + license, recorded for provenance/acknowledgements.
        public static let upstreamRepository = "https://github.com/openclaw/imsg"
        public static let license = "MIT"

        /// Nested Mach-O + resource file names inside `Contents/Helpers`.
        /// `executableName` is the JSON-RPC entrypoint Osaurus spawns; the
        /// bridge dylib is only used by `imsg`'s private-API mode (advanced
        /// actions) and must be signed as a nested Mach-O before the app seal.
        public static let executableName = "imsg"
        public static let bridgeDylibName = "imsg-bridge-helper.dylib"

        // MARK: - Digests (fail-closed pins)
        //
        // These MUST match the artifacts published for `version` and the
        // manifest in `scripts/build/imsg-helper-manifest.json` (a unit test
        // locks them together). `verifyBundledExecutable()` refuses to spawn
        // any copy that does not match the digest pin — with one carve-out
        // for a copy sealed inside the app bundle carrying a valid signature
        // from the host app's team (kept as defense in depth for a future
        // bundling lane; no build lane stages a copy today). A stale pin
        // degrades to a hard failure (no iMessage helper) rather than a
        // silently wrong binary — see
        // docs/CHANNEL_RELEASE_RUNBOOK_IMESSAGE.md.

        /// SHA-256 of the published (fat) `imsg` executable, pre re-sign.
        public static let executableSHA256 =
            "3de325ab7e2c7940c6edb8fd1402296b3842f3e00119872588355bce85b28c97"

        /// SHA-256 of the published `imsg-bridge-helper.dylib`, pre re-sign.
        public static let bridgeDylibSHA256 =
            "3942ca55ce148f013ff35136ddf3422d6e74df54aecef9a2ab2dc6fe27674213"

        /// Pinned release archive for the runtime download path (same lane as
        /// the sandbox runtime assets: download on demand, verify the archive
        /// digest, then verify each installed Mach-O digest again).
        public static let archiveURLString =
            "https://github.com/openclaw/imsg/releases/download/v\(version)/imsg-macos.zip"
        public static let archiveSHA256 =
            "e2fcac341363b5d53d16d28e61df981c4585bcc6b7fa8fdc77ec41f14e87c468"
        /// The published archive is ~10 MB; anything near this cap is wrong.
        public static let maxArchiveDownloadBytes = 64 * 1_024 * 1_024

        /// Resource bundles `imsg` loads relative to its own executable path.
        /// They must be installed next to the binary, mirroring the
        /// `Contents/Helpers` layout used when the helper is bundled.
        public static let resourceBundleNames = [
            "PhoneNumberKit_PhoneNumberKit.bundle",
            "SQLite.swift_SQLite.bundle",
        ]

        /// Mach-O slices each artifact must carry. The helper must run on
        /// Apple silicon; the bridge additionally needs arm64e because
        /// Messages.app runs arm64e and dylib injection requires a matching
        /// ABI.
        public static let executableRequiredArchitectures = ["arm64"]
        public static let bridgeDylibRequiredArchitectures = ["arm64", "arm64e"]

        /// True once the digests above have been filled with real release
        /// values. Until then the channel treats every helper copy as
        /// unverified and stays in basic-only fallback mode instead of
        /// spawning an unpinned binary.
        public static var digestsPinned: Bool {
            executableSHA256 != String(repeating: "0", count: 64)
                && bridgeDylibSHA256 != String(repeating: "0", count: 64)
        }

        // MARK: - Bundle resolution

        /// Subdirectory under `Contents/` checked for an app-sealed helper
        /// copy (defense in depth; no build lane stages one today). Mirrors
        /// the existing CLI helper layout (`Contents/Helpers`).
        public static let bundleSubdirectory = "Helpers"

        /// Env override for local testing against a dev-built `imsg` without a
        /// full signed app bundle. When set to an existing file, digest
        /// verification is skipped so a locally-built helper can be exercised
        /// end to end. Honored in DEBUG builds only — release builds ignore
        /// the variable entirely so it can never be used to point a shipped
        /// app at an arbitrary binary.
        public static let executableOverrideEnvKey = "OSAURUS_IMSG_PATH"

        /// The dev override URL, or nil when unset/not a debug build.
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

        /// Where the runtime download path installs the helper:
        /// `~/.osaurus/helpers/imsg/<version>/`. Versioned so a pin bump
        /// never trusts a stale install; the old directory simply stops
        /// resolving. The directory is user-writable, which is why every
        /// spawn re-verifies the executable digest below — a swapped binary
        /// fails verification instead of running.
        public static func downloadedHelpersDirectoryURL() -> URL {
            OsaurusPaths.helpers()
                .appendingPathComponent(executableName, isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
        }

        /// Locate any installed `imsg` executable candidate (dev override,
        /// bundled, or downloaded), without judging trust. Use
        /// `verifyBundledExecutable().trustedURL` for the copy that may
        /// actually be spawned; this is for "is anything installed at all"
        /// UI states. Returns `nil` on a fresh install before the user
        /// downloads the helper.
        public static func bundledExecutableURL() -> URL? {
            if let override = overrideExecutableURL() {
                return FileManager.default.isExecutableFile(atPath: override.path) ? override : nil
            }
            if let bundled = helperFileURL(
                named: executableName,
                in: bundledHelpersDirectoryURL(),
                requireExecutable: true
            ) {
                return bundled
            }
            return helperFileURL(
                named: executableName,
                in: downloadedHelpersDirectoryURL(),
                requireExecutable: true
            )
        }

        /// Locate the bridge dylib next to the executable that verification
        /// actually trusts, so a rejected bundled copy can never contribute
        /// its dylib to a session spawned from the downloaded copy.
        public static func bundledBridgeDylibURL() -> URL? {
            guard let executable = verifyBundledExecutable().trustedURL else { return nil }
            return helperFileURL(
                named: bridgeDylibName,
                in: executable.deletingLastPathComponent(),
                requireExecutable: false
            )
        }

        private static func helperFileURL(
            named name: String,
            in directory: URL?,
            requireExecutable: Bool
        ) -> URL? {
            guard let directory else { return nil }
            let candidate = directory.appendingPathComponent(name)
            let fm = FileManager.default
            if requireExecutable {
                return fm.isExecutableFile(atPath: candidate.path) ? candidate : nil
            }
            return fm.fileExists(atPath: candidate.path) ? candidate : nil
        }

        /// `Contents/Helpers` for the running app. `Bundle.main.bundleURL`
        /// points at `Osaurus.app`; helpers live beside `Contents/MacOS`.
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
            /// No bundled helper present (dev/test build, or a stripped bundle).
            case missing
            /// A helper file exists but its digest does not match the pin.
            case digestMismatch(expected: String, actual: String)
            /// Digests are not yet pinned to a real release; refuse to trust
            /// the bundled binary.
            case unpinned
            /// Dev override in use; digest verification intentionally skipped.
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

        /// Verify the installed `imsg` executable. This is the gate the
        /// connection service consults before it will spawn the helper.
        ///
        /// Candidates are verified independently, in trust order: dev
        /// override (DEBUG only), the copy sealed inside the app bundle,
        /// then the runtime-downloaded copy. A corrupted bundled copy does
        /// not mask a valid downloaded copy — the first candidate that
        /// verifies wins, and the first failure is reported only when none
        /// do.
        ///
        /// Two trust paths, both fail-closed:
        /// 1. Digest pin: the file is byte-identical to the pinned upstream
        ///    release (dev `make app` staging, which does not re-sign).
        /// 2. Same-team signature: the release pipeline re-signs the helper
        ///    with Osaurus's Developer ID (changing its digest), so a helper
        ///    whose signature is valid AND whose TeamIdentifier matches the
        ///    host app's is the pinned binary as sealed by our own release.
        ///    This path exists only for the sealed bundled copy: a
        ///    runtime-downloaded copy lives in a user-writable directory and
        ///    is never re-signed, so it must match the digest pin exactly —
        ///    otherwise any other same-team binary dropped there would pass.
        public static func verifyBundledExecutable() -> VerificationResult {
            verifyExecutableCandidates(
                override: overrideExecutableURL(),
                bundled: helperFileURL(
                    named: executableName,
                    in: bundledHelpersDirectoryURL(),
                    requireExecutable: true
                ),
                downloaded: helperFileURL(
                    named: executableName,
                    in: downloadedHelpersDirectoryURL(),
                    requireExecutable: true
                )
            )
        }

        /// Candidate-order verification, parameterized so tests can exercise
        /// the fallback logic with crafted files and pins.
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
            guard pinsAvailable else { return .unpinned }

            var firstFailure: VerificationResult?
            if let bundled, let actual = sha256Hex(ofFileAt: bundled) {
                if actual == executablePin { return .verified(bundled) }
                if sameTeamTrust(bundled) { return .verified(bundled) }
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

        // MARK: - Bridge dylib verification (per spawn)

        public enum BridgeDylibVerification: Equatable, Sendable {
            /// Digest (or sealed same-team signature) verified.
            case verified(URL)
            /// No dylib next to the executable: basic mode only, not fatal.
            case missing
            /// A dylib exists but fails verification — refuse to spawn: the
            /// helper would dlopen tampered code from a user-writable path.
            case mismatch(expected: String, actual: String)
        }

        /// Re-verify the bridge dylib sitting next to `executable`. Called at
        /// every spawn because the downloaded install lives in a
        /// user-writable directory: install-time verification alone would
        /// not catch a dylib swapped afterwards. Parameterized so tests can
        /// exercise the gate with crafted files and pins.
        static func verifyBridgeDylib(
            nextTo executable: URL,
            dylibPin: String = bridgeDylibSHA256,
            sealedSameTeamTrust: (URL) -> Bool = { url in
                // Sealed bundled copy only: the release re-sign changes its
                // digest, so same-team signature is the trust anchor (as for
                // the executable). Never applies to the user-writable
                // download directory.
                guard isInsideMainBundle(url),
                    let dylibTeam = teamIdentifier(ofValidlySignedCodeAt: url),
                    let hostTeam = hostTeamIdentifier()
                else { return false }
                return dylibTeam == hostTeam
            }
        ) -> BridgeDylibVerification {
            let dylib = executable.deletingLastPathComponent()
                .appendingPathComponent(bridgeDylibName)
            guard FileManager.default.fileExists(atPath: dylib.path) else { return .missing }
            guard let actual = sha256Hex(ofFileAt: dylib) else { return .missing }
            if actual == dylibPin { return .verified(dylib) }
            if sealedSameTeamTrust(dylib) { return .verified(dylib) }
            return .mismatch(expected: dylibPin, actual: actual)
        }

        static func isInsideMainBundle(_ url: URL) -> Bool {
            let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
            let candidatePath = url.standardizedFileURL.path
            return candidatePath.hasPrefix(bundlePath + "/")
        }

        // MARK: - Code-signature trust (release re-sign path)

        /// TeamIdentifier of the host app bundle's signature, or nil when the
        /// app is unsigned / ad-hoc signed (dev builds).
        static func hostTeamIdentifier() -> String? {
            teamIdentifier(ofValidlySignedCodeAt: Bundle.main.bundleURL)
        }

        /// TeamIdentifier of a validly signed Mach-O/bundle at `url`. Returns
        /// nil when the signature is missing, invalid, or carries no team.
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
