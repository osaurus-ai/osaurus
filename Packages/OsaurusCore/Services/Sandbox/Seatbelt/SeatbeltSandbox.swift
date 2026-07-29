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
        NSTemporaryDirectory() + "osaurus-seatbelt"
    }

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
        network: NetworkPolicy
    ) -> String {
        let workspace = escapeProfilePath(workspaceRoot)
        let temp = escapeProfilePath(tempDir)

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
            "  (literal \"/\")",
            "  (literal \"/private\")",
            "  (literal \"/tmp\")",
            "  (literal \"/var\")",
            "  (literal \"/etc\"))",
            // Writes: workspace + scratch only, plus the pseudo
            // devices shells rely on.
            "(allow file-read* file-write*",
            "  (subpath \"\(workspace)\")",
            "  (subpath \"\(temp)\")",
            "  (literal \"/dev/null\")",
            "  (literal \"/dev/zero\")",
            "  (literal \"/dev/random\")",
            "  (literal \"/dev/urandom\")",
            "  (literal \"/dev/stdin\")",
            "  (literal \"/dev/stdout\")",
            "  (literal \"/dev/stderr\")",
            "  (subpath \"/dev/fd\"))",
        ]

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

