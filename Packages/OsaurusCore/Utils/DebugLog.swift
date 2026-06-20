//
//  DebugLog.swift
//  osaurus
//
//  Lightweight file-based debug logger.  Works from any isolation context.
//  Writes timestamped lines to /tmp/osaurus_debug.log.
//  No-ops in production (only active when the file already exists or is created
//  on first write).
//

import Foundation

/// Serial queue that owns every debug-log disk write. Callers only pay for the
/// (cheap) line formatting on their own thread; the `open`/`seek`/`write`/`close`
/// all happen here, off whatever thread — frequently the main actor — invoked
/// `debugLog`. A serial queue also preserves append ordering across concurrent
/// callers without a lock.
private let debugLogQueue = DispatchQueue(label: "com.osaurus.debuglog", qos: .utility)

/// Writes a timestamped line to `/tmp/osaurus_debug.log`.
///
/// Safe to call from any actor or thread. The file I/O is dispatched
/// asynchronously onto a serial queue so callers never block on disk — a
/// synchronous `open()` here previously tripped the main-thread hang watchdog.
@inline(__always)
func debugLog(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    debugLogQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        let path = "/tmp/osaurus_debug.log"
        if FileManager.default.fileExists(atPath: path) {
            // Use the throwing Swift APIs (`seekToEnd`/`write(contentsOf:)`/
            // `close`), NOT the legacy `seekToEndOfFile()`/`write(_:)`/
            // `closeFile()`: the legacy variants raise an uncatchable
            // Objective-C `NSFileHandleOperationException` on a full disk
            // (`No space left on device`), which `try?` cannot trap and which
            // terminates the whole process. A debug logger must degrade
            // silently, never crash its host.
            if let fh = FileHandle(forWritingAtPath: path) {
                try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
                try? fh.close()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
