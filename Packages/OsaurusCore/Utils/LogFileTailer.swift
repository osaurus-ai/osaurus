//
//  LogFileTailer.swift
//  osaurus
//
//  Tails an append-only log file and broadcasts new bytes as a Combine
//  publisher. Used by the streaming UI for `sandbox_exec(background:
//  true)` jobs, whose stdout/stderr lands in a host-visible log file
//  under the container's workspace bind mount (no live `Writer`
//  available the way foreground exec has).
//
//  Strategy:
//   - On `start()`, open the file (creating it if missing — the
//     spawning shell may not have written anything yet), seek to end-
//     of-file (or beginning, configurable), and install a
//     `readabilityHandler` that pumps every available chunk into the
//     subject.
//   - `snapshot()` reads everything currently on disk synchronously;
//     used by late binders to seed their buffer before subscribing.
//   - `stop()` removes the handler and closes the handle. Idempotent.
//
//  Polling note: APFS reliably fires `readabilityHandler` for appends
//  to a regular file on macOS, but only when there's already a
//  consumer at EOF when the write happens. To handle the launch race
//  where the producer (`nohup`) appends BEFORE the tailer's handler
//  is installed, we also kick the publisher with `snapshot()` after
//  install if the file already has content past the seek point.
//

import Combine
import Foundation

public final class LogFileTailer: @unchecked Sendable {
    public let path: String
    private let lock = NSLock()
    private var handle: FileHandle?
    private var started = false
    private var lastReadOffset: UInt64 = 0
    private let subject = PassthroughSubject<Data, Never>()

    public init(path: String) {
        self.path = path
    }

    public var publisher: AnyPublisher<Data, Never> {
        subject.eraseToAnyPublisher()
    }

    /// Start tailing. `seekToEnd: false` (default) emits everything
    /// already on disk plus all subsequent appends. `seekToEnd: true`
    /// only emits future appends — used when the seed snapshot has
    /// already been hand-delivered to the consumer.
    public func start(seekToEnd: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true

        // Ensure the file exists so opening doesn't bail. Background-job
        // spawn writes to the file via `nohup ... > $log 2>&1`, but on a
        // very young job we may race the first write.
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }

        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return
        }
        handle = fh

        if seekToEnd, let end = try? fh.seekToEnd() {
            lastReadOffset = end
        } else {
            lastReadOffset = 0
        }

        // Drain whatever's already past the seek point synchronously so
        // late-installed tailers don't miss the prologue.
        if !seekToEnd {
            if let prologue = try? fh.readToEnd(), !prologue.isEmpty {
                lastReadOffset = UInt64(prologue.count)
                subject.send(prologue)
            }
        }

        // Install the live handler. `readabilityHandler` fires on every
        // append; we read whatever's available and forward it.
        fh.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self.lock.lock()
            self.lastReadOffset += UInt64(chunk.count)
            self.lock.unlock()
            self.subject.send(chunk)
        }
    }

    /// Stop tailing and release the file handle. Safe to call multiple
    /// times; the publisher is NOT completed (consumers may still want
    /// the seed via `snapshot()` after stop).
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        started = false
        handle?.readabilityHandler = nil
        try? handle?.close()
        handle = nil
    }

    /// Read the full file contents synchronously. Used by `seed:` so a
    /// row that mounts mid-stream sees the whole tail before subscribing
    /// to live updates.
    public func snapshot() -> Data {
        guard FileManager.default.fileExists(atPath: path) else { return Data() }
        return (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
    }

    deinit {
        stop()
    }
}
