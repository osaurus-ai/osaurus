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

    /// Upper bound on how long we wait for `fdesetup status`. A hung probe
    /// must never stall launch convergence (it runs before the mutation gate
    /// is taken, so it can't deadlock anything, but it can delay memory/search
    /// init indefinitely), so on timeout we terminate the child and report off.
    private static let probeTimeout: DispatchTimeInterval = .seconds(3)

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

        // Read to EOF on a background queue so a wedged `fdesetup` can't pin us
        // here forever. `runWithTimeout` orders the producer's write before our
        // read of `box.data` (it returns only after the worker signals).
        let box = ProbeOutputBox()
        let handle = pipe.fileHandleForReading
        let finished = runWithTimeout(probeTimeout) {
            box.data = handle.readDataToEndOfFile()
        }

        guard finished else {
            // Terminate the stuck child and bail rather than block. The reader
            // closure unblocks at EOF once the child dies and then exits on its
            // own; we just don't wait for it.
            process.terminate()
            log.error(
                "fdesetup probe timed out after \(String(describing: probeTimeout), privacy: .public); treating FileVault as off"
            )
            return false
        }
        process.waitUntilExit()

        let output = String(data: box.data, encoding: .utf8) ?? ""
        // `fdesetup status` prints "FileVault is On." or "FileVault is Off."
        let on = output.localizedCaseInsensitiveContains("FileVault is On")
        log.info("FileVault probe: \(on ? "on" : "off", privacy: .public)")
        return on
    }

    /// Run `work` on a utility queue and return `true` if it finished within
    /// `timeout`, `false` otherwise. The caller owns any cleanup on the `false`
    /// path (the probe terminates its child process). Internal so the timeout
    /// behavior can be unit-tested with a deliberately slow `work` closure
    /// rather than a real subprocess (which the harness must never spawn).
    static func runWithTimeout(
        _ timeout: DispatchTimeInterval,
        _ work: @escaping @Sendable () -> Void
    ) -> Bool {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            work()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }
}

/// Mutable hand-off box for the probe's background reader thread. Access is
/// ordered by the semaphore inside `runWithTimeout` (the worker writes then
/// signals; the probe reads only after a successful wait), so the unchecked
/// Sendable is sound.
private final class ProbeOutputBox: @unchecked Sendable {
    var data = Data()
}
