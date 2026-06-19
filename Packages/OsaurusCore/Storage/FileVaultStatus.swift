//
//  FileVaultStatus.swift
//  osaurus
//
//  Runtime macOS FileVault (full-disk encryption) status.
//
//  Used by launch convergence to decide whether it is safe to silently
//  decrypt an existing SQLCipher install to plaintext: when FileVault is on
//  the whole disk is already encrypted at rest, so dropping SQLCipher loses
//  no real protection; when it is off we keep the user's data encrypted
//  rather than silently strip its only at-rest protection.
//

import Foundation
import os

public enum FileVaultStatus {
    private static let log = Logger(subsystem: "ai.osaurus", category: "storage.filevault")

    /// Test seam: when set, `isEnabled()` returns this value without probing
    /// the host. Lets the launch-mode resolver be tested deterministically.
    nonisolated(unsafe) public static var overrideForTesting: Bool?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Bool?

    /// True when macOS FileVault is enabled. Probed once via
    /// `/usr/bin/fdesetup status` (which needs no admin rights) and cached for
    /// the process. Never throws: on any failure — probe can't launch, times
    /// out, or returns unexpected output — it conservatively returns `false`
    /// so we never silently drop encryption we can't prove is redundant.
    public static func isEnabled() -> Bool {
        if let overrideForTesting { return overrideForTesting }
        // Never spawn a subprocess inside the test harness; tests inject state
        // via `overrideForTesting`, and a stray probe could stall CI.
        if RuntimeEnvironment.isUnderTests { return false }

        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let result = probe()
        lock.lock()
        cached = result
        lock.unlock()
        return result
    }

    private static func probe() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
        process.arguments = ["status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // discard stderr noise

        do {
            try process.run()
        } catch {
            log.error(
                "fdesetup probe failed to launch: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        // Read to EOF before reaping so a tiny output can't deadlock the pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        // `fdesetup status` prints "FileVault is On." or "FileVault is Off."
        let on = output.localizedCaseInsensitiveContains("FileVault is On")
        log.info("FileVault probe: \(on ? "on" : "off", privacy: .public)")
        return on
    }
}
