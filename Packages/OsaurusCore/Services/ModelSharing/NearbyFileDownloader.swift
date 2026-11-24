//
//  NearbyFileDownloader.swift
//  osaurus
//
//  Copies one file from a nearby Mac. Bytes land in a hidden `.part` file
//  beside the destination, so a pause or a dropped connection resumes from
//  where it stopped; the file moves into place only once its size and digest
//  match. A host is any machine on the network, so the digest is the one the
//  caller trusts (the Hub's when it can be reached), never taken on faith.
//

import Foundation
import OsaurusSync

/// Where a nearby copy of a model comes from.
struct NearbySource: Sendable, Hashable {
    let hostId: String
    let hostName: String
    let itemId: String
}

enum NearbyTransferError: LocalizedError, Equatable {
    /// The host went away, stopped sharing the model, or the transfer stalled.
    case hostUnavailable(hostName: String)
    /// The host is serving as many files as it allows.
    case hostBusy(hostName: String)
    /// What arrived doesn't match the digest the receiver trusts.
    case contentMismatch(path: String)
    case invalidPath(String)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .hostUnavailable(let name):
            return L("\(name) is no longer reachable. Try again when it's back on this network.")
        case .hostBusy(let name):
            return L("\(name) is busy sharing other files. Try again in a moment.")
        case .contentMismatch(let path):
            return L("\(path) from the nearby Mac didn't match the expected checksum.")
        case .invalidPath(let path):
            return L("The nearby Mac listed an invalid file path: \(path)")
        case .notRunning:
            return L("Finding models on nearby Macs is turned off.")
        }
    }

    init(_ error: ModelShareError, hostName: String) {
        switch error {
        case .Busy: self = .hostBusy(hostName: hostName)
        case .NotRunning: self = .notRunning
        case .InvalidInput(let detail): self = .invalidPath(detail)
        case .NotFound, .Unreachable, .Io, .Cancelled: self = .hostUnavailable(hostName: hostName)
        }
    }
}

/// Limits how many files this Mac copies from each nearby host at once. A
/// host serves `slotsPerHost` files at a time and refuses the rest as busy,
/// so copies past the limit wait here, first come first served, rather than
/// being refused and fetched from Hugging Face instead.
actor NearbyHostGate {
    static let shared = NearbyHostGate()
    /// Must match `MAX_UPLOADS` in osaurus-models-net.
    static let slotsPerHost = 4

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let slotsPerHost: Int
    private var holders: [String: Int] = [:]
    private var waiters: [String: [Waiter]] = [:]

    init(slotsPerHost: Int = NearbyHostGate.slotsPerHost) {
        self.slotsPerHost = slotsPerHost
    }

    /// Waits for a slot on `hostId`. Every successful acquire needs one
    /// `release`; a cancelled wait throws and holds nothing.
    func acquire(_ hostId: String) async throws {
        try Task.checkCancellation()
        if holders[hostId, default: 0] < slotsPerHost, waiters[hostId, default: []].isEmpty {
            holders[hostId, default: 0] += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[hostId, default: []].append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, hostId: hostId) }
        }
    }

    /// Hands the slot to the next waiter, or frees it.
    func release(_ hostId: String) {
        if var queue = waiters[hostId], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[hostId] = queue.isEmpty ? nil : queue
            next.continuation.resume()
            return
        }
        let remaining = holders[hostId, default: 0] - 1
        holders[hostId] = remaining > 0 ? remaining : nil
    }

    func holderCount(_ hostId: String) -> Int { holders[hostId, default: 0] }
    func waiterCount(_ hostId: String) -> Int { waiters[hostId]?.count ?? 0 }

    private func cancelWaiter(_ id: UUID, hostId: String) {
        guard var queue = waiters[hostId], let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        waiters[hostId] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private final class TransferProgressRelay: TransferProgress, @unchecked Sendable {
    private let handler: @Sendable (Int64) -> Void
    init(_ handler: @escaping @Sendable (Int64) -> Void) { self.handler = handler }
    func onProgress(received: UInt64, total: UInt64) { handler(Int64(received)) }
}

enum NearbyFileDownloader {
    static func partURL(for destination: URL) -> URL {
        // The hint matters: without `isDirectory`, URL stats the filesystem
        // (lstat) to decide whether to append a trailing slash — synchronous
        // I/O on a path that runs on MainActor from ModelDownloadService.
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).nearby.part", isDirectory: false)
    }

    /// Bytes of `destination` already received from a nearby Mac.
    static func resumableBytes(for destination: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: partURL(for: destination).path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Seconds to wait before asking a busy host again.
    static func busyRetryDelay(attempt: Int) -> Double {
        min(10, pow(2, Double(max(0, attempt - 1))))
    }

    /// Copies `path` of `source` to `destination`, validating it against
    /// `size` and `digest` before replacing anything. `onProgress` gets the
    /// file's received byte count. Cancelling the calling task stops the
    /// transfer and keeps the partial file. A busy host (serving other Macs)
    /// is asked again until it has room, so a copy that can come from the
    /// nearby Mac never turns into an internet download just for waiting.
    static func download(
        node: ModelShareNode,
        source: NearbySource,
        path: String,
        size: Int64,
        digest: ModelFileDigest,
        to destination: URL,
        gate: NearbyHostGate = .shared,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = partURL(for: destination)
        var busyAttempts = 0
        copying: while true {
            var offset = resumableBytes(for: destination)
            if offset > size {
                try? fm.removeItem(at: part)
                offset = 0
            }
            if offset > 0 { onProgress(offset) }
            guard offset < size || !fm.fileExists(atPath: part.path) else { break copying }

            try await gate.acquire(source.hostId)
            let outcome: Result<Void, Error>
            do {
                try await receive(node: node, source: source, path: path, into: part, offset: offset, onProgress: onProgress)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            await gate.release(source.hostId)

            switch outcome {
            case .success:
                break copying
            case .failure(let error as ModelShareError):
                if Task.isCancelled { throw CancellationError() }
                guard case .Busy = error else { throw NearbyTransferError(error, hostName: source.hostName) }
                busyAttempts += 1
                try await Task.sleep(for: .seconds(busyRetryDelay(attempt: busyAttempts)))
            case .failure(let error):
                throw error
            }
        }
        try Task.checkCancellation()
        guard try ModelFileIntegrity.matches(part, size: size, digest: digest) else {
            try? fm.removeItem(at: part)
            throw NearbyTransferError.contentMismatch(path: path)
        }
        try Task.checkCancellation()
        try ModelFileIntegrity.commit(staged: part, to: destination)
        onProgress(size)
    }

    /// One request for the rest of `path`, appending to `part` from `offset`.
    /// Throws the host's `ModelShareError` unmapped so the caller can tell a
    /// busy host from one that's gone.
    private static func receive(
        node: ModelShareNode,
        source: NearbySource,
        path: String,
        into part: URL,
        offset: Int64,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let transfer = try node.startDownload(
            host: source.hostId,
            model: source.itemId,
            path: path,
            destination: part.path,
            offset: UInt64(offset),
            progress: TransferProgressRelay(onProgress)
        )
        _ = try await withTaskCancellationHandler {
            try await transfer.wait()
        } onCancel: {
            transfer.cancel()
        }
    }
}

/// Copies a whole bundle from a nearby Mac for kinds whose installers expect
/// a complete directory (speech, privacy detection): files go into a hidden
/// staging directory beside `destination`, which replaces it only once every
/// file checks out against the host's digests.
enum NearbyBundleTransfer {
    static func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).nearby")
    }

    static func fetch(
        node: ModelShareNode,
        source: NearbySource,
        files: [NearbyModelFile],
        into destination: URL,
        onProgress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void
    ) async throws {
        let staging = stagingURL(for: destination)
        let total = files.reduce(Int64(0)) { $0 + Int64($1.size) }
        let counter = ByteCounter()
        var planned: [(file: NearbyModelFile, url: URL)] = []
        for file in files {
            guard let url = HuggingFaceService.destinationURL(forRemotePath: file.path, under: staging) else {
                throw NearbyTransferError.invalidPath(file.path)
            }
            planned.append((file, url))
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = planned.makeIterator()
            func addNext() -> Bool {
                guard let (file, url) = iterator.next() else { return false }
                group.addTask {
                    let size = Int64(file.size)
                    if (try? ModelFileIntegrity.matches(url, size: size, digest: .sha256(file.sha256))) == true {
                        onProgress(counter.set(file.path, size), total)
                        return
                    }
                    try await NearbyFileDownloader.download(
                        node: node,
                        source: source,
                        path: file.path,
                        size: size,
                        digest: .sha256(file.sha256),
                        to: url
                    ) { received in
                        onProgress(counter.set(file.path, received), total)
                    }
                }
                return true
            }
            for _ in 0 ..< 3 where addNext() {}
            while try await group.next() != nil { _ = addNext() }
        }
        try Task.checkCancellation()
        try install(staging: staging, at: destination)
    }

    /// Swaps `staging` in for `destination`, putting the old directory back
    /// if the move fails.
    static func install(staging: URL, at destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else {
            try fm.moveItem(at: staging, to: destination)
            return
        }
        let replaced = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).replaced-\(UUID().uuidString)")
        try fm.moveItem(at: destination, to: replaced)
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.moveItem(at: replaced, to: destination)
            throw error
        }
        try? fm.removeItem(at: replaced)
    }
}

/// A hidden file naming the Mac a model was copied from while Hugging Face
/// couldn't be reached. Its files were checked only against that Mac's
/// digests; a later download or Repair that reaches the Hub removes it.
enum NearbyCopyMarker {
    static let filename = ".osaurus-nearby-copy"

    static func record(in directory: URL, hostName: String?) {
        let url = directory.appendingPathComponent(filename)
        if let hostName {
            try? Data(hostName.utf8).write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func hostName(in directory: URL) -> String? {
        (try? String(contentsOf: directory.appendingPathComponent(filename), encoding: .utf8))
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Sums per-file byte counts reported from concurrent transfers.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [String: Int64] = [:]

    func set(_ key: String, _ value: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        bytes[key] = value
        return bytes.values.reduce(0, +)
    }
}
