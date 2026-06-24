//
//  FileDiffDebugLog.swift
//  osaurus
//
//  TEMPORARY diagnostic logger for the file-diff card's collapse/expand
//  behavior. Appends timestamped lines to /tmp/osaurus-filediff.log so the
//  toggle → reconfigure → measure path can be traced when the card freezes.
//  Remove once the toggle bug is resolved.
//

import Foundation

enum FileDiffDebugLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var opened = false
    static let path = "/tmp/osaurus-filediff.log"

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: @autoclosure () -> String) {
        lock.lock()
        defer { lock.unlock() }
        if !opened {
            opened = true
            // Fresh file each launch so a run's trace isn't buried under old ones.
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path)
        }
        let line = "[\(formatter.string(from: Date()))] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        handle?.write(data)
    }
}
