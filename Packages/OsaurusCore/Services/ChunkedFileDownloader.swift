//
//  ChunkedFileDownloader.swift
//  OsaurusCore
//
//  Downloads a single large file as parallel HTTP Range requests.
//

import CryptoKit
import Foundation

/// What Hugging Face tells us about a file *before* it redirects to a CDN.
///
/// These headers only exist on the `huggingface.co` 3xx — the CDN's own 206
/// does not echo them — so the probe below deliberately refuses to follow the
/// redirect in order to read them.
struct HuggingFaceFileMetadata: Sendable {
    /// Commit the `main` ref currently points at. Every chunk request is
    /// pinned to this so a push mid-download can't splice two revisions of
    /// the file together — a corruption the size-only completion check
    /// downstream would never notice.
    let commitSHA: String?
    /// `x-linked-size`: the real byte length of the LFS object.
    let size: Int64
    /// `x-linked-etag`: sha256 of the file's contents, for LFS objects.
    let sha256: String?
    let acceptsRanges: Bool

    var isChunkable: Bool { acceptsRanges && size >= ChunkedFileDownloader.minimumChunkableSize }
}

/// Refuses redirects so the caller sees Hugging Face's 3xx and its headers
/// rather than the CDN's eventual 206.
private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// On-disk record of which chunks of a `.part` file are already durable.
///
/// This is what makes a half-finished download survive both a failed retry
/// and an app relaunch: without it a transfer that dies at 90% starts again
/// from byte zero.
private struct PartManifest: Codable {
    let sha256: String?
    let commitSHA: String?
    let size: Int64
    let chunkSize: Int64
    var completed: [Int]

    /// A `.part` file is only reusable if it describes the same bytes we are
    /// about to fetch. A repo push (new commit / new hash) or a changed chunk
    /// layout invalidates it.
    func matches(_ other: PartManifest) -> Bool {
        sha256 == other.sha256 && commitSHA == other.commitSHA && size == other.size
            && chunkSize == other.chunkSize
    }
}

/// Fetches one file as several concurrent HTTP Range requests, each streamed
/// straight into its own offset of a pre-allocated `.part` file.
///
/// Three measured properties shape this design:
///
/// 1. Per-connection throughput to the CDN is capped well below most links, so
///    a single-shard repo (one 4.6 GB `model.safetensors`) transfers at the
///    speed of exactly one connection no matter how fast the user's network
///    is. Splitting the file across connections is the only way past it.
/// 2. `URLSession` multiplexes concurrent HTTP/2 requests to the same host
///    onto a *single* TCP connection. Sharing one session across chunks
///    therefore collapses them back onto one connection and wins nothing —
///    so each lane owns a separate `URLSession`. Raising
///    `httpMaximumConnectionsPerHost` does not substitute for this.
/// 3. A session *per chunk* is just as bad: every chunk then pays a fresh TLS
///    handshake, a fresh redirect, and a fresh TCP slow-start ramp, which ate
///    most of the parallelism in practice. So a fixed set of lanes each drain
///    chunks from a shared queue over one reused connection.
final class ChunkedFileDownloader: @unchecked Sendable {
    /// Below this, one connection is already enough to saturate the transfer
    /// and the extra round-trips would cost more than they save.
    static let minimumChunkableSize: Int64 = 64 * 1024 * 1024

    /// Retry granularity. A dead chunk costs one chunk, not the whole file.
    static let chunkSize: Int64 = 32 * 1024 * 1024

    /// Lanes one file may use. Measured end-to-end against Hugging Face's CDN
    /// on a 4.6 GB shard: 4 lanes ≈ 107 MB/s, 6 ≈ 147, 8 ≈ 167, 12 ≈ 181,
    /// 16 ≈ 185. Eight buys ~90% of the achievable gain at half the sockets of
    /// sixteen, and everything past twelve is inside the run-to-run noise.
    static let maxConcurrentChunks = 8

    private static let progressInterval: CFAbsoluteTime = 0.25
    private static let perChunkAttempts = 3

    private let lock = NSLock()
    /// Serializes `onProgress` deliveries. Without it, two lanes can both
    /// clear the throttle, unlock, and then land their callbacks in the
    /// opposite order — the consumer sees progress jump backwards.
    private let reportLock = NSLock()
    private var lanes: [TransferLane] = []
    private var pauseRequested = false
    private var bytesSoFar: Int64 = 0
    private var lastProgressTime: CFAbsoluteTime = 0

    // MARK: - Metadata probe

    /// Reads Hugging Face's pre-redirect headers. Returns `nil` when the file
    /// is not a chunkable LFS object (no `x-linked-size`), leaving the caller
    /// to fall back to a plain single-connection download.
    static func probe(url: URL) async throws -> HuggingFaceFileMetadata? {
        let delegate = RedirectBlockingDelegate()
        let session = GlobalProxySettings.makeSession(base: .default, delegate: delegate)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        // A one-byte GET rather than HEAD: some CDN edges answer HEAD from a
        // different cache tier and omit the linked-* headers.
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        HuggingFaceAuth.authorize(&request)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        let redirected = (300 ..< 400).contains(http.statusCode)
        guard redirected || (200 ..< 300).contains(http.statusCode) else {
            throw DirectDownloader.HTTPStatusError(
                statusCode: http.statusCode,
                retryAfterSeconds: (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
            )
        }

        guard let sizeHeader = http.value(forHTTPHeaderField: "x-linked-size"),
            let size = Int64(sizeHeader), size > 0
        else {
            return nil  // Not an LFS object — small config/tokenizer file.
        }

        // Only trust `x-linked-etag` when it really is a content hash. For
        // non-LFS blobs it carries a git object id, which is not sha256 of
        // the file bytes and would fail verification.
        let rawETag = http.value(forHTTPHeaderField: "x-linked-etag")?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"W/"))
        let sha256 = rawETag.flatMap { Self.isSHA256Hex($0) ? $0.lowercased() : nil }

        return HuggingFaceFileMetadata(
            commitSHA: http.value(forHTTPHeaderField: "x-repo-commit"),
            size: size,
            sha256: sha256,
            acceptsRanges: http.value(forHTTPHeaderField: "accept-ranges")?.lowercased() == "bytes"
        )
    }

    static func isSHA256Hex(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }

    /// Rewrites `.../resolve/main/<path>` to `.../resolve/<sha>/<path>`.
    /// Returns the original URL when the shape isn't what we expect, so a
    /// Hub layout change degrades to "unpinned" rather than "broken".
    static func pinnedURL(_ url: URL, commitSHA: String?) -> URL {
        guard let commitSHA, !commitSHA.isEmpty,
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let range = comps.path.range(of: "/resolve/main/")
        else { return url }
        comps.path.replaceSubrange(range, with: "/resolve/\(commitSHA)/")
        return comps.url ?? url
    }

    // MARK: - Transfer

    func download(
        from url: URL,
        to destination: URL,
        metadata: HuggingFaceFileMetadata,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let partURL = destination.appendingPathExtension("part")
        let manifestURL = destination.appendingPathExtension("part.json")
        let total = metadata.size
        let chunkCount = Int((total + Self.chunkSize - 1) / Self.chunkSize)

        let fresh = PartManifest(
            sha256: metadata.sha256,
            commitSHA: metadata.commitSHA,
            size: total,
            chunkSize: Self.chunkSize,
            completed: []
        )
        var manifest = Self.loadManifest(at: manifestURL, matching: fresh) ?? fresh
        if manifest.completed.isEmpty { try await Self.preallocate(partURL, size: total) }

        var done = Set(manifest.completed)
        // A `.part` that vanished (cache sweep, user deletion) invalidates the
        // completed set even though the manifest survived.
        if !fm.fileExists(atPath: partURL.path) {
            done.removeAll()
            manifest.completed = []
            try await Self.preallocate(partURL, size: total)
        }

        let resumedBytes = lock.withLock { () -> Int64 in
            bytesSoFar = Self.bytesFor(done, total: total)
            pauseRequested = false
            return bytesSoFar
        }
        onProgress(resumedBytes, total)

        let target = Self.pinnedURL(url, commitSHA: metadata.commitSHA)
        let pending = (0 ..< chunkCount).filter { !done.contains($0) }
        let queue = ChunkQueue(pending)

        // One lane per connection, each draining chunks from the shared queue
        // over a *reused* session. A session per chunk would pay a fresh TLS
        // handshake, a fresh 302, and a fresh TCP slow-start ramp every 32 MB,
        // which measurably eats most of the parallelism it buys.
        let desired = min(Self.maxConcurrentChunks, max(pending.count, 1))
        let laneCount = await LaneBudget.shared.reserve(desired: desired)
        let active = (0 ..< laneCount).map { _ in TransferLane() }
        lock.withLock { lanes = active }
        defer {
            lock.withLock { lanes = [] }
            for lane in active { lane.invalidate() }
            Task { await LaneBudget.shared.release(laneCount) }
        }

        // Serializes manifest writes across lanes.
        let recorder = CompletionRecorder(manifest: manifest, url: manifestURL)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for lane in active {
                group.addTask {
                    while let index = queue.next() {
                        try await self.transferChunk(
                            index: index,
                            total: total,
                            url: target,
                            partURL: partURL,
                            lane: lane,
                            onProgress: onProgress
                        )
                        recorder.record(index)
                    }
                }
            }
            try await group.waitForAll()
        }

        try await Self.verifyAndCommit(
            partURL: partURL,
            manifestURL: manifestURL,
            destination: destination,
            expectedSize: total,
            expectedSHA256: metadata.sha256
        )
    }

    /// Streams one Range request into `partURL` at its offset, over `lane`'s
    /// persistent connection.
    private func transferChunk(
        index: Int,
        total: Int64,
        url: URL,
        partURL: URL,
        lane: TransferLane,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let start = Int64(index) * Self.chunkSize
        let end = min(start + Self.chunkSize, total) - 1
        let expected = end - start + 1

        var attempt = 1
        while true {
            try checkPause()
            // Bytes a failed attempt already credited to progress must be
            // taken back, or the retry double-counts them and the bar runs
            // past 100%. The counter is written from the delegate thread.
            let credited = Counter()
            do {
                let handle = try FileHandle(forWritingTo: partURL)
                try handle.seek(toOffset: UInt64(start))
                defer { try? handle.close() }
                try await lane.fetch(
                    url: url,
                    range: "bytes=\(start)-\(end)",
                    handle: handle,
                    expected: expected,
                    onBytes: { [weak self] delta in
                        credited.add(delta)
                        self?.advanceProgress(by: delta, total: total, onProgress: onProgress)
                    }
                )
                try checkPause()
                return
            } catch let pause as DirectDownloader.PauseInfo {
                throw pause
            } catch {
                advanceProgress(by: -credited.value, total: total, onProgress: onProgress)
                // `pause()` tears the lane's session down, so the in-flight
                // chunk surfaces as `URLError.cancelled`. Left unclassified it
                // would be reported as a failed download rather than a paused
                // one, and the user's progress would look lost.
                try checkPause()
                guard attempt < Self.perChunkAttempts,
                    ModelDownloadService.isRetryableTransferError(error)
                else { throw error }
                let delay = ModelDownloadService.transferRetryDelay(attempt: attempt, error: error)
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func advanceProgress(
        by delta: Int64,
        total: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        bytesSoFar += delta
        let due = now - lastProgressTime >= Self.progressInterval || bytesSoFar >= total
        if due { lastProgressTime = now }
        lock.unlock()
        guard due else { return }
        // Deliveries are serialized, and each re-reads the counter once it
        // holds the report lock, so every callback carries a value at least
        // as fresh as the one delivered before it.
        reportLock.lock()
        let value = lock.withLock { bytesSoFar }
        onProgress(value, total)
        reportLock.unlock()
    }

    private func checkPause() throws {
        lock.lock()
        let paused = pauseRequested
        let bytes = bytesSoFar
        lock.unlock()
        if paused { throw DirectDownloader.PauseInfo(resumeData: nil, bytesDownloaded: bytes) }
        try Task.checkCancellation()
    }

    /// Cancels every in-flight chunk. Completed chunks are already recorded in
    /// the `.part.json` manifest, so `download` picks up where it left off —
    /// no `URLSession` resume blob required, which is why this reports `nil`
    /// resume data.
    func pause() {
        lock.lock()
        pauseRequested = true
        let active = lanes
        lock.unlock()
        for lane in active { lane.invalidate() }
    }

    func invalidate() {
        lock.lock()
        let active = lanes
        lanes.removeAll()
        lock.unlock()
        for lane in active { lane.invalidate() }
    }

    // MARK: - Commit

    /// Verifies the assembled file and moves it into place. The `.part` file
    /// is left behind on failure so the next attempt resumes from it.
    private static func verifyAndCommit(
        partURL: URL,
        manifestURL: URL,
        destination: URL,
        expectedSize: Int64,
        expectedSHA256: String?
    ) async throws {
        let fm = FileManager.default
        let actual =
            (try fm.attributesOfItem(atPath: partURL.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        guard actual == expectedSize else {
            throw URLError(
                .cannotDecodeContentData,
                userInfo: [
                    NSLocalizedDescriptionKey: "Size mismatch: expected \(expectedSize), got \(actual)"
                ]
            )
        }

        // Hugging Face hands us the content hash for free in `x-linked-etag`.
        // The pre-existing completion check only compares byte counts, which a
        // truncated-then-padded or revision-spliced file can satisfy.
        if let expectedSHA256 {
            // Detached: hashing a multi-gigabyte file is seconds of blocking
            // file I/O, which must not tie up the caller's (possibly main)
            // executor. Same pattern as `SandboxManager.verifySHA256Async`.
            let digest = try await Task.detached(priority: .userInitiated) {
                try hashFile(at: partURL)
            }.value
            guard digest == expectedSHA256 else {
                try? fm.removeItem(at: partURL)
                try? fm.removeItem(at: manifestURL)
                throw URLError(
                    .cannotDecodeContentData,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Checksum mismatch: expected \(expectedSHA256), got \(digest)"
                    ]
                )
            }
        }

        try? fm.removeItem(at: destination)
        try fm.moveItem(at: partURL, to: destination)
        try? fm.removeItem(at: manifestURL)
    }

    private static func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Part file + manifest

    /// Detached for the same reason as the checksum: truncating a file out to
    /// multiple gigabytes is blocking disk I/O that must not run on the
    /// caller's (possibly main) executor.
    private static func preallocate(_ url: URL, size: Int64) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(size))
        }.value
    }

    private static func bytesFor(_ done: Set<Int>, total: Int64) -> Int64 {
        done.reduce(Int64(0)) { sum, index in
            let start = Int64(index) * chunkSize
            return sum + (min(start + chunkSize, total) - start)
        }
    }

    private static func loadManifest(at url: URL, matching expected: PartManifest) -> PartManifest? {
        guard let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode(PartManifest.self, from: data),
            stored.matches(expected)
        else { return nil }
        return stored
    }

    fileprivate static func saveManifest(_ manifest: PartManifest, at url: URL) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Caps how many connections all in-flight chunked downloads may hold at once.
///
/// `ModelDownloadService` transfers several files concurrently, so without a
/// shared ceiling a multi-shard repo would open `files × lanes` sockets — 24 at
/// the current settings. That is actively harmful on a thin link, where the
/// connections just compete for the same bottleneck and add queueing delay.
///
/// Reservation never blocks: a download that arrives when the budget is spent
/// still gets one lane, so a small file can never be starved behind a large
/// one. The worst case is therefore `budget + (concurrent files - 1)`.
actor LaneBudget {
    static let shared = LaneBudget(limit: ChunkedFileDownloader.maxConcurrentChunks)

    private let limit: Int
    private var available: Int

    init(limit: Int) {
        self.limit = limit
        self.available = limit
    }

    func reserve(desired: Int) -> Int {
        let granted = max(1, min(desired, available))
        available = max(0, available - granted)
        return granted
    }

    func release(_ count: Int) {
        available = min(limit, available + count)
    }
}

/// Hands out the next chunk index to whichever lane asks first, so a slow
/// connection simply pulls fewer chunks instead of stalling a fixed share.
private final class ChunkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int]
    private var cursor = 0

    init(_ pending: [Int]) { self.pending = pending }

    func next() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard cursor < pending.count else { return nil }
        defer { cursor += 1 }
        return pending[cursor]
    }
}

/// Serializes `.part.json` writes as lanes finish chunks out of order.
private final class CompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var manifest: PartManifest
    private var done: Set<Int>
    private let url: URL

    init(manifest: PartManifest, url: URL) {
        self.manifest = manifest
        self.done = Set(manifest.completed)
        self.url = url
    }

    func record(_ index: Int) {
        lock.lock()
        done.insert(index)
        manifest.completed = done.sorted()
        let snapshot = manifest
        lock.unlock()
        ChunkedFileDownloader.saveManifest(snapshot, at: url)
    }
}

/// Lock-guarded byte tally, written from a `URLSession` delegate thread and
/// read by the transfer's retry path.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0

    func add(_ delta: Int64) {
        lock.lock()
        total += delta
        lock.unlock()
    }

    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}

// MARK: - Transfer lane

/// One connection's worth of work: a `URLSession` reused across many chunks,
/// streaming each Range response straight to disk as it arrives.
///
/// Reuse is the point. Keeping the session alive lets `URLSession` hold the
/// TLS session and the warmed TCP congestion window open between chunks, so
/// only the first chunk on a lane pays the ramp. Streaming (rather than
/// buffering the chunk in memory) keeps peak RSS flat and lets a slow link
/// still report byte-level progress instead of jumping 32 MB at a time.
///
/// Exactly one request is in flight per lane, so the per-request state below
/// needs no queue — only a lock, since the delegate callbacks land on a
/// `URLSession` thread.
private final class TransferLane: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var expected: Int64 = 0
    private var onBytes: (@Sendable (Int64) -> Void)?
    private var received: Int64 = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    private lazy var session: URLSession = {
        GlobalProxySettings.makeSession(base: .default, delegate: self)
    }()

    func fetch(
        url: URL,
        range: String,
        handle: FileHandle,
        expected: Int64,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        HuggingFaceAuth.authorize(&request)

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.handle = handle
            self.expected = expected
            self.onBytes = onBytes
            self.received = 0
            self.failure = nil
            self.continuation = c
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    func invalidate() { session.invalidateAndCancel() }

    private func setFailure(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        handle = nil
        onBytes = nil
        lock.unlock()
        c?.resume(with: result)
    }

    /// `resolve/<sha>` URLs 302-redirect to Hugging Face's CDN. Don't leak the
    /// user's access token to that (or any other) third-party host: the
    /// Authorization header only travels while the request stays on the host
    /// it was originally sent to. Mirrors `DirectDownloader`'s handler.
    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        if redirected.url?.host != task.originalRequest?.url?.host {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            setFailure(URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        // A 200 here means the server ignored `Range` and is about to stream
        // the whole file into a single chunk's offset. Refuse it.
        guard http.statusCode == 206 else {
            setFailure(
                DirectDownloader.HTTPStatusError(
                    statusCode: http.statusCode,
                    retryAfterSeconds: http.value(forHTTPHeaderField: "Retry-After")
                        .flatMap(Double.init)
                )
            )
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let target = handle
        let notify = onBytes
        lock.unlock()
        guard let target else { return }
        do {
            try target.write(contentsOf: data)
            lock.lock()
            received += Int64(data.count)
            lock.unlock()
            notify?(Int64(data.count))
        } catch {
            setFailure(error)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let existing = failure
        let target = handle
        let got = received
        let want = expected
        lock.unlock()

        if let existing {
            finish(.failure(existing))
            return
        }
        if let error {
            finish(.failure(error))
            return
        }
        do {
            try target?.synchronize()
        } catch {
            finish(.failure(error))
            return
        }
        // A short body that still reported success would leave a hole of
        // zeros inside the part file that only the checksum would catch.
        guard got == want else {
            finish(
                .failure(
                    URLError(
                        .cannotDecodeContentData,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Short chunk: expected \(want) bytes, got \(got)"
                        ]
                    )
                )
            )
            return
        }
        finish(.success(()))
    }
}
