//
//  ToolsDoctor.swift
//  osaurus
//
//  Diagnoses common plugin load failures: missing entry symbols, signature
//  problems, broken `current` symlinks, ABI version negotiation, and the
//  consent gate. Output is one line per check, prefixed OK/WARN/FAIL.
//

import CryptoKit
import Foundation
import OsaurusRepository

public struct ToolsDoctor {

    private struct Check {
        let label: String
        let result: Result
    }

    private enum Result {
        case ok(String?)
        case warn(String)
        case fail(String)

        var prefix: String {
            switch self {
            case .ok: return "OK"
            case .warn: return "WARN"
            case .fail: return "FAIL"
            }
        }

        var detail: String {
            switch self {
            case .ok(let s): return s ?? ""
            case .warn(let s), .fail(let s): return s
            }
        }

        var isFailure: Bool {
            if case .fail = self { return true }
            return false
        }
    }

    public static func execute(args: [String]) {
        let target = args.first
        let fm = FileManager.default
        let root = PluginInstallManager.toolsRootDirectory()

        guard let pluginDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            print("(no tools installed at \(root.path))")
            exit(EXIT_SUCCESS)
        }

        var failures = 0
        var didMatch = false

        for pluginDir in pluginDirs where pluginDir.hasDirectoryPath {
            let pluginId = pluginDir.lastPathComponent
            if let target, target != pluginId, target != "all" { continue }
            didMatch = true
            print("\n• \(pluginId)")

            let checks = runChecks(for: pluginDir, fm: fm)
            for check in checks {
                let detail = check.result.detail.isEmpty ? "" : "  — \(check.result.detail)"
                print("  [\(check.result.prefix)] \(check.label)\(detail)")
                if check.result.isFailure { failures += 1 }
            }
        }

        if !didMatch, let target {
            print("(no plugin matching '\(target)' is installed)")
            exit(EXIT_FAILURE)
        }

        if failures > 0 {
            print("\n\(failures) check(s) failed.")
            exit(EXIT_FAILURE)
        }
        exit(EXIT_SUCCESS)
    }

    // MARK: - Checks

    private static func runChecks(for pluginDir: URL, fm: FileManager) -> [Check] {
        var checks: [Check] = []

        // 1. `current` symlink resolves
        let currentLink = pluginDir.appendingPathComponent("current")
        let activeVersionDir: URL?
        if let dest = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) {
            activeVersionDir = pluginDir.appendingPathComponent(dest, isDirectory: true)
            checks.append(.init(label: "current symlink", result: .ok(dest)))
        } else {
            activeVersionDir = nil
            checks.append(.init(label: "current symlink", result: .fail("missing or unreadable")))
        }

        guard let versionDir = activeVersionDir else { return checks }
        let versionExists = fm.fileExists(atPath: versionDir.path)
        if !versionExists {
            checks.append(.init(label: "version directory exists", result: .fail("missing: \(versionDir.path)")))
            return checks
        }
        checks.append(.init(label: "version directory exists", result: .ok(versionDir.lastPathComponent)))

        // 2. receipt.json present and decodes
        let receiptURL = versionDir.appendingPathComponent("receipt.json")
        let receiptResult: (PluginReceipt, Result)
        if let rdata = try? Data(contentsOf: receiptURL),
            let receipt = try? JSONDecoder().decode(PluginReceipt.self, from: rdata)
        {
            receiptResult = (receipt, .ok("\(receipt.plugin_id)@\(receipt.version)"))
        } else {
            checks.append(.init(label: "receipt.json", result: .fail("missing or invalid")))
            return checks
        }
        checks.append(.init(label: "receipt.json", result: receiptResult.1))
        let receipt = receiptResult.0

        // 3. dylib present and SHA matches
        let dylibURL = versionDir.appendingPathComponent(receipt.dylib_filename)
        guard let dylibData = try? Data(contentsOf: dylibURL) else {
            checks.append(.init(label: "dylib present", result: .fail("missing: \(dylibURL.lastPathComponent)")))
            return checks
        }
        let digest = CryptoKit.SHA256.hash(data: dylibData)
        let sha = Data(digest).map { String(format: "%02x", $0) }.joined()
        if sha.lowercased() == receipt.dylib_sha256.lowercased() {
            checks.append(.init(label: "dylib SHA-256", result: .ok("matches receipt")))
        } else {
            checks.append(
                .init(
                    label: "dylib SHA-256",
                    result: .fail("expected \(receipt.dylib_sha256), got \(sha)")
                )
            )
        }

        // 4. Codesign (best-effort: shells to `codesign -v`).
        checks.append(codesignCheck(dylibURL: dylibURL))

        // 5. Architecture (best-effort: shells to `lipo -info`).
        checks.append(architectureCheck(dylibURL: dylibURL))

        // 6. Entry symbols. We dlopen the dylib and dlsym for the v2 and v1
        //    entries. We do NOT call init() — that would actually load the
        //    plugin and possibly take side effects. Just verify the symbols
        //    are present so the host's loader will find them.
        checks.append(contentsOf: entrySymbolChecks(dylibURL: dylibURL))

        // 7. User consent (release builds only — DEBUG skips).
        let consentFile = versionDir.appendingPathComponent(".user_consent")
        if fm.fileExists(atPath: consentFile.path) {
            checks.append(.init(label: "user consent", result: .ok("granted")))
        } else {
            checks.append(
                .init(
                    label: "user consent",
                    result: .warn("missing — release builds will fail to load until granted (DEBUG skips)")
                )
            )
        }

        // 8. Sandbox status — Osaurus is sandboxed in production. We can't
        //    introspect the running app from the CLI, but flag the doctor
        //    output as advisory.
        checks.append(
            .init(
                label: "sandbox status",
                result: .ok(
                    "doctor cannot introspect; check Console.app for [Osaurus] dlopen errors if the plugin fails to load"
                )
            )
        )

        return checks
    }

    // MARK: - Helpers

    private static func codesignCheck(dylibURL: URL) -> Check {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-v", dylibURL.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return .init(label: "codesign", result: .ok("verified"))
            }
            let stderr = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8) ?? "unknown"
            return .init(label: "codesign", result: .fail(stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch {
            return .init(label: "codesign", result: .warn("codesign tool unavailable: \(error.localizedDescription)"))
        }
    }

    private static func architectureCheck(dylibURL: URL) -> Check {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        process.arguments = ["-info", dylibURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            if process.terminationStatus == 0 {
                return .init(label: "architecture", result: .ok(out.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return .init(label: "architecture", result: .warn("lipo failed"))
        } catch {
            return .init(label: "architecture", result: .warn("lipo tool unavailable"))
        }
    }

    private static func entrySymbolChecks(dylibURL: URL) -> [Check] {
        guard let handle = dlopen(dylibURL.path, RTLD_LAZY) else {
            let err = dlerror().map { String(cString: $0) } ?? "unknown error"
            return [.init(label: "dlopen", result: .fail(err))]
        }
        defer { dlclose(handle) }

        var checks: [Check] = [.init(label: "dlopen", result: .ok(nil))]

        let v2 = dlsym(handle, "osaurus_plugin_entry_v2") != nil
        let v1 = dlsym(handle, "osaurus_plugin_entry") != nil

        switch (v2, v1) {
        case (true, _):
            checks.append(.init(label: "entry symbol", result: .ok("osaurus_plugin_entry_v2 (v3 surface)")))
        case (false, true):
            checks.append(
                .init(
                    label: "entry symbol",
                    result: .warn(
                        "only legacy osaurus_plugin_entry exported; plugin loads but cannot call host APIs. "
                            + "Rebuild with osaurus_plugin_entry_v2 to access the v3 surface."
                    )
                )
            )
        case (false, false):
            checks.append(
                .init(
                    label: "entry symbol",
                    result: .fail("neither osaurus_plugin_entry_v2 nor osaurus_plugin_entry is exported")
                )
            )
        }

        return checks
    }
}
