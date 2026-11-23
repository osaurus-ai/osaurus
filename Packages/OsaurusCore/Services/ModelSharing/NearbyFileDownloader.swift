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

private final class TransferProgressRelay: TransferProgress, @unchecked Sendable {
    private let handler: @Sendable (Int64) -> Void
    init(_ handler: @escaping @Sendable (Int64) -> Void) { self.handler = handler }
    func onProgress(received: UInt64, total: UInt64) { handler(Int64(received)) }
}

enum NearbyFileDownloader {
    static func partURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).nearby.part")
    }

    /// Bytes of `destination` already received from a nearby Mac.
    static func resumableBytes(for destination: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: partURL(for: destination).path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Copies `path` of `source` to `destination`, validating it against
    /// `size` and `digest` before replacing anything. `onProgress` gets the
    /// file's received byte count. Cancelling the calling task stops the
    /// transfer and keeps the partial file.
    static func download(
        node: ModelShareNode,
        source: NearbySource,
        path: String,
        size: Int64,
        digest: ModelFileDigest,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = partURL(for: destination)
        var offset = resumableBytes(for: destination)
        if offset > size {
            try? fm.removeItem(at: part)
            offset = 0
        }
        if offset > 0 { onProgress(offset) }
        if offset < size || !fm.fileExists(atPath: part.path) {
            let transfer: FileTransfer
            do {
                transfer = try node.startDownload(
                    host: source.hostId,
                    model: source.itemId,
                    path: path,
                    destination: part.path,
                    offset: UInt64(offset),
                    progress: TransferProgressRelay(onProgress)
                )
            } catch let error as ModelShareError {
                throw NearbyTransferError(error, hostName: source.hostName)
            }
            do {
                _ = try await withTaskCancellationHandler {
                    try await transfer.wait()
                } onCancel: {
                    transfer.cancel()
                }
            } catch let error as ModelShareError {
                if Task.isCancelled { throw CancellationError() }
                throw NearbyTransferError(error, hostName: source.hostName)
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
