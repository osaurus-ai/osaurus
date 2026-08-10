//
//  SeatbeltSandbox.swift
//  osaurus
//
//  Host-level sandbox fallback for macOS versions that cannot run the
//  Containerization VM (macOS 26 "Tahoe" is the SDK's floor). On older
//  systems sandboxed commands run directly on the host, confined by a
//  Seatbelt profile via `/usr/bin/sandbox-exec`.
//
//  This is a strictly weaker isolation tier than the VM: processes share
//  the host kernel and run as the logged-in user. The profile is
//  deny-by-default — commands may read the OS/toolchain paths they need
//  to execute, but may only WRITE inside the sandbox workspace and their
//  private temp directory, and network access follows the sandbox
//  configuration. On macOS 26+ this backend is never selected; the VM is
//  always used.
//

import Foundation

/// Which isolation backend the sandbox subsystem uses on this host.
public enum SandboxBackend: Sendable, Equatable {
    /// Containerization VM (macOS 26+). Full isolation: separate
    /// kernel, rootfs, per-agent Linux users, vmnet networking.
    case virtualMachine
    /// Seatbelt (`sandbox-exec`) host-process confinement for
    /// macOS < 26. Weaker: same kernel, same user, path + network
    /// confinement only.
    case seatbelt

    /// Resolved once from the OS version. macOS 26+ ALWAYS uses the
    /// VM — the Seatbelt fallback must never be selected on Tahoe or
    /// later, even if the VM fails to boot (a boot failure surfaces
    /// as an error the user can act on; silently downgrading the
    /// isolation tier would not be).
    ///
    /// Debug override: launching with `OSAURUS_FORCE_SEATBELT=1` in the
    /// environment forces the Seatbelt backend regardless of OS version,
    /// so the fallback can be exercised and debugged on a Tahoe machine.
    /// Env vars don't survive a normal Finder/Dock launch, so this can't
    /// be tripped by accident — it requires an Xcode scheme entry or a
    /// terminal launch.
    public static let current: SandboxBackend = {
        if ProcessInfo.processInfo.environment["OSAURUS_FORCE_SEATBELT"] == "1" {
            return .seatbelt
        }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
            ? .virtualMachine
            : .seatbelt
    }()
}

public enum SeatbeltSandbox {

    /// Host path of the `sandbox-exec` binary. Deprecated by Apple but
    /// shipped on every supported macOS release.
    public static let sandboxExecPath = "/usr/bin/sandbox-exec"

    /// True when this host can run the Seatbelt fallback at all.
    /// Only meaningful when `SandboxBackend.current == .seatbelt`.
    public static var isSupported: Bool {
        FileManager.default.isExecutableFile(atPath: sandboxExecPath)
    }

    /// Scratch directory granted read-write in every profile and
    /// exported as `TMPDIR` — the user's real `$TMPDIR` stays denied.
    public static var scratchDir: String {
        canonicalProfilePath(
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("osaurus-seatbelt", isDirectory: true)
                .path
        )
    }

    /// xcrun's shared lookup database. Apple's `/usr/bin` developer-tool
    /// shims consult this file even when `TMPDIR` points at our private
    /// scratch directory. It is exposed read-only: letting sandboxed work
    /// update the host's developer-tool cache would cross the confinement
    /// boundary, while denying reads makes successful shim launches emit
    /// spurious cache-write failures.
    static var xcrunCacheFiles: [String] {
        profilePathVariants(
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("xcrun_db", isDirectory: false)
                .path
        )
    }

    /// Seatbelt evaluates canonical filesystem paths. Normalize aliases such
    /// as `/tmp` and `/var` before embedding a path in the profile so an exact
    /// workspace or scratch grant remains effective after kernel resolution.
    private static func canonicalProfilePath(_ raw: String) -> String {
        var existing = URL(fileURLWithPath: raw).standardizedFileURL
        var missingComponents: [String] = []
        while existing.path != "/",
              !FileManager.default.fileExists(atPath: existing.path)
        {
            missingComponents.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }

        guard let resolved = realpath(existing.path, nil) else {
            return URL(fileURLWithPath: raw).standardizedFileURL.path
        }
        defer { free(resolved) }

        var canonical = URL(
            fileURLWithPath: String(cString: resolved), isDirectory: true)
        for component in missingComponents.reversed() {
            canonical.appendPathComponent(component)
        }
        // Do not call `standardizedFileURL` here: on modern macOS Foundation
        // rewrites realpath's `/private/var` and `/private/tmp` back to their
        // synthetic aliases, defeating the canonical Seatbelt grant.
        return canonical.path
    }

    /// `sandbox-exec` path matching is not consistent about whether a vnode
    /// reached through macOS's synthetic `/tmp` and `/var` aliases is reported
    /// lexically or canonically. Grant both spellings when they differ; they
    /// resolve to the same object and therefore do not widen the capability.
    private static func profilePathVariants(_ raw: String) -> [String] {
        let lexical = URL(fileURLWithPath: raw).standardizedFileURL.path
        let canonical = canonicalProfilePath(lexical)
        return canonical == lexical ? [canonical] : [canonical, lexical]
    }

    private static func validatedDeveloperDirectory(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let path = URL(fileURLWithPath: trimmed, isDirectory: true)
            .standardizedFileURL.path
        let isXcodeBundle = path.hasSuffix(".app/Contents/Developer")
            && (path.hasPrefix("/Applications/")
                || path.hasPrefix("/System/Applications/")
                || path.hasPrefix("/Volumes/"))
        let hasExpectedShape = isXcodeBundle
            || path == "/Library/Developer/CommandLineTools"
        var isDirectory: ObjCBool = false
        guard hasExpectedShape,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return path
    }

    /// Read root needed by the active developer toolchain. Xcode command-line
    /// shims load DVT frameworks from `Contents/SharedFrameworks`, a sibling of
    /// `Contents/Developer`, so an Xcode selection needs the containing
    /// `Contents` tree. CommandLineTools is already self-contained.
    private static func developerReadRoot(_ developerDirectory: String?) -> String? {
        guard let directory = validatedDeveloperDirectory(developerDirectory) else {
            return nil
        }
        if directory.hasSuffix(".app/Contents/Developer") {
            return URL(fileURLWithPath: directory, isDirectory: true)
                .deletingLastPathComponent().path
        }
        return directory
    }

    /// The active Xcode developer directory used by Apple's `/usr/bin`
    /// tool shims (including `python3` via `xcrun`). The deny-by-default
    /// profile already permits `/usr`, but the shim dynamically loads
    /// Xcode frameworks from the selected app bundle under `/Applications`.
    ///
    /// Resolve once on the host before entering Seatbelt. Only canonical
    /// Xcode/CommandLineTools directory shapes are accepted so a malformed
    /// selection can never turn into an arbitrary broad read grant.
    public static let activeDeveloperDirectory: String? = {
        if let configured = validatedDeveloperDirectory(
            ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        ) {
            return configured
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return validatedDeveloperDirectory(
                String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            )
        } catch {
            return nil
        }
    }()

    // MARK: - Profile

    /// Network policy for a generated profile, derived from
    /// `SandboxConfiguration.network`.
    public enum NetworkPolicy: Sendable, Equatable {
        case allowed
        case denied

        /// Map the shared sandbox config's network mode. "outbound"
        /// allows network. "none" denies it. "proxy" (domain
        /// allowlist) cannot be enforced by Seatbelt — the filtering
        /// egress proxy is a vmnet construct — so it fails CLOSED to
        /// no network rather than silently widening an allowlist to
        /// unrestricted egress.
        public static func from(configNetwork: String) -> NetworkPolicy {
            configNetwork == "outbound" ? .allowed : .denied
        }
    }

    /// Build the Seatbelt profile (`.sb` scheme text) for one exec.
    ///
    /// - Parameters:
    ///   - workspaceRoot: Host directory that plays the role of the
    ///     VM's `/workspace` mount. Read-write.
    ///   - tempDir: Per-process scratch directory. Read-write.
    ///   - network: Whether the process may use the network.
    public static func profile(
        workspaceRoot: String,
        tempDir: String,
        network: NetworkPolicy,
        developerDirectory: String? = activeDeveloperDirectory
    ) -> String {
        let workspaces = profilePathVariants(workspaceRoot).map(escapeProfilePath)
        let temps = profilePathVariants(tempDir).map(escapeProfilePath)
        let xcrunCaches = xcrunCacheFiles.map(escapeProfilePath)

        var lines: [String] = [
            "(version 1)",
            "(deny default)",
            // Process lifecycle: the wrapper shell forks and execs
            // freely; signals stay within the sandbox.
            "(allow process-fork)",
            "(allow process-exec*)",
            "(allow process-info*)",
            "(allow signal (target same-sandbox))",
            // Baseline kernel/service access virtually every binary
            // needs to start (dyld, libSystem, Foundation tools).
            "(allow sysctl-read)",
            "(allow mach-lookup)",
            "(allow file-read-metadata)",
            "(allow file-ioctl (subpath \"/dev\"))",
            // Read-only OS + toolchain surface. No home-directory
            // read grant: user data outside the workspace stays off
            // limits.
            "(allow file-read*",
            "  (subpath \"/usr\")",
            "  (subpath \"/bin\")",
            "  (subpath \"/sbin\")",
            "  (subpath \"/System\")",
            "  (subpath \"/Library\")",
            "  (subpath \"/private/etc\")",
            "  (subpath \"/private/var/db/timezone\")",
            "  (subpath \"/opt\")",
            "  (subpath \"/dev\")",
        ]
        // Read the host-prepared xcrun lookup database without allowing
        // sandboxed tools to mutate it or its containing temp directory.
        lines.append(contentsOf: xcrunCaches.map { "  (literal \"\($0)\")" })
        if let readRoot = developerReadRoot(developerDirectory) {
            lines.append(
                "  (subpath \"\(escapeProfilePath(readRoot))\")"
            )
        }
        lines.append(contentsOf: [
            "  (literal \"/\")",
            "  (literal \"/private\")",
            "  (literal \"/tmp\")",
            "  (literal \"/var\")",
            "  (literal \"/etc\"))",
            // Writes: workspace + scratch only, plus the pseudo
            // devices shells rely on.
            "(allow file-read* file-write*",
        ])
        lines.append(contentsOf: workspaces.map { "  (subpath \"\($0)\")" })
        lines.append(contentsOf: temps.map { "  (subpath \"\($0)\")" })
        lines.append(contentsOf: [
            "  (literal \"/dev/null\")",
            "  (literal \"/dev/zero\")",
            "  (literal \"/dev/random\")",
            "  (literal \"/dev/urandom\")",
            "  (literal \"/dev/stdin\")",
            "  (literal \"/dev/stdout\")",
            "  (literal \"/dev/stderr\")",
            "  (subpath \"/dev/fd\"))",
        ])

        switch network {
        case .allowed:
            lines.append("(allow network*)")
            // DNS via the system resolver daemon.
            lines.append("(allow system-socket)")
        case .denied:
            lines.append("(deny network*)")
        }

        return lines.joined(separator: "\n")
    }

    /// Escape a path for embedding in a double-quoted scheme string.
    static func escapeProfilePath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Translates the VM's stable in-guest paths to their host-side
/// equivalents. Tools, prompts, and the model all speak `/workspace/…`
/// (the guest mount point); on the Seatbelt backend those files live
/// under `OsaurusPaths.containerWorkspace()` on the host, so command
/// strings / cwd / env values are rewritten before execution. Keeping
/// the guest-style paths as the model-facing contract means agent
/// homes, plugin dirs, and saved artifacts keep identical paths across
/// both backends (and across an OS upgrade that switches backend).
public enum SeatbeltPathMapper {

    /// Rewrite every `/workspace` path token in `text` to live under
    /// `workspaceRoot`. Only whole path components are rewritten:
    /// `/workspace/agents/x` and a bare `/workspace` match;
    /// `/workspaces` or `foo/workspace` do not.
    public static func mapToHost(_ text: String, workspaceRoot: String) -> String {
        guard text.contains("/workspace") else { return text }
        let root = workspaceRoot.hasSuffix("/") ? String(workspaceRoot.dropLast()) : workspaceRoot
        // (?<![\w/.-])  — not preceded by a path/word character, so
        //                 host paths like `foo/workspace` survive
        // (?![\w.-])    — followed by `/`, whitespace, quote, or end,
        //                 so `/workspaces` survives
        let pattern = #"(?<![\w/.\-])/workspace(?![\w.\-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: root)
        )
    }

    /// Map a dictionary of environment values.
    public static func mapEnvToHost(
        _ env: [String: String], workspaceRoot: String
    ) -> [String: String] {
        env.mapValues { mapToHost($0, workspaceRoot: workspaceRoot) }
    }
}
