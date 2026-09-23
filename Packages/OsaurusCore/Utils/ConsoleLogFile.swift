//
//  ConsoleLogFile.swift
//  osaurus
//
//  Debug builds copy everything the app prints, stdout and stderr, into
//  `tmp/osaurus.log` in the checkout, one timestamped line at a time, while
//  the Xcode console keeps showing it exactly as before. That picks up the
//  `[PrivacyFilter]`, `[PrivacyReview]` and `[Osaurus]` lines without
//  touching their call sites. Unified-log (`Logger`) trails that matter, such
//  as `RemoteAgentRunLog`, mirror themselves in through `append`.
//
//  Each launch writes a header; a file past 20 MB is cleared at launch so it
//  never grows without bound. Release builds do nothing.
//

import Darwin
import Foundation

enum ConsoleLogFile {

    #if DEBUG
        /// …/Packages/OsaurusCore/Utils/ConsoleLogFile.swift → `<checkout>/tmp/osaurus.log`.
        static let fileURL: URL = {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Utils
                .deletingLastPathComponent()  // OsaurusCore
                .deletingLastPathComponent()  // Packages
                .deletingLastPathComponent()  // repo root
            return root.appendingPathComponent("tmp", isDirectory: true).appendingPathComponent("osaurus.log")
        }()

        private static let sink = Sink(url: fileURL)
        @MainActor private static var started = false
    #endif

    /// Starts copying stdout and stderr into the file. Call once, as early
    /// in launch as possible; later calls do nothing.
    @MainActor
    static func start() {
        #if DEBUG
            guard !started else { return }
            started = true
            // A pipe makes stdio fully buffered; line buffering keeps each
            // `print` arriving when it happens, not 4 KB later.
            setvbuf(stdout, nil, _IOLBF, 0)
            sink.appendLine(
                "===== Osaurus launched, pid \(ProcessInfo.processInfo.processIdentifier) =====")
            tee(STDOUT_FILENO)
            tee(STDERR_FILENO)
        #endif
    }

    /// Adds one line for a caller that logs through `Logger`, whose output
    /// never passes through stdout.
    static func append(_ message: String) {
        #if DEBUG
            sink.appendLine(message)
        #endif
    }

    #if DEBUG
        /// Points `fd` at a pipe whose reader passes every byte on to the
        /// original descriptor (Xcode's console) and to the file.
        private static func tee(_ fd: Int32) {
            let original = dup(fd)
            guard original >= 0 else { return }
            let pipe = Pipe()
            guard dup2(pipe.fileHandleForWriting.fileDescriptor, fd) >= 0 else {
                close(original)
                return
            }
            let passthrough = FileHandle(fileDescriptor: original, closeOnDealloc: false)
            let target = Self.sink
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                try? passthrough.write(contentsOf: data)
                target.append(data)
            }
            target.keepAlive(pipe)
        }

        /// Owns the file. Everything runs on one serial queue, which is what
        /// makes the unchecked Sendable sound.
        private final class Sink: @unchecked Sendable {
            private let queue = DispatchQueue(label: "com.osaurus.console-log-file", qos: .utility)
            private var handle: FileHandle?
            private var partial = Data()
            private var pipes: [Pipe] = []
            private let stamp: DateFormatter = {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
                return formatter
            }()

            init(url: URL) {
                let manager = FileManager.default
                try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                if size > 20_000_000 { try? manager.removeItem(at: url) }
                if !manager.fileExists(atPath: url.path) {
                    manager.createFile(atPath: url.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }

            func keepAlive(_ pipe: Pipe) {
                queue.async { self.pipes.append(pipe) }
            }

            func appendLine(_ line: String) {
                let now = Date()
                queue.async { self.write(line, at: now) }
            }

            /// Raw console bytes: stamped and written a whole line at a time,
            /// holding back a trailing partial line until it completes.
            func append(_ data: Data) {
                let now = Date()
                queue.async {
                    self.partial.append(data)
                    while let newline = self.partial.firstIndex(of: 0x0A) {
                        let line = self.partial[self.partial.startIndex ..< newline]
                        self.partial.removeSubrange(self.partial.startIndex ... newline)
                        self.write(String(decoding: line, as: UTF8.self), at: now)
                    }
                }
            }

            private func write(_ line: String, at date: Date) {
                guard let handle else { return }
                let text = "\(stamp.string(from: date)) \(line)\n"
                try? handle.write(contentsOf: Data(text.utf8))
            }
        }
    #endif
}
