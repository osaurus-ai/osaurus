import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

/// Live transfers hit the real Hugging Face CDN, so they stay opt-in.
private func liveHFDownloadEnabled() -> Bool {
    ProcessInfo.processInfo.environment["RUN_LIVE_HF_DOWNLOAD"] == "1"
}

/// Coverage for the parallel Range downloader used for large weight shards.
///
/// The pure helpers run everywhere. The transfer tests hit the real Hugging
/// Face CDN and are gated behind `RUN_LIVE_HF_DOWNLOAD=1`, because chunked
/// range semantics are exactly the thing a mock would get wrong.
///
/// Serialized: the live tests share the process-wide `LaneBudget`, so running
/// them concurrently starves all but the first of lanes and makes their
/// timings meaningless.
@Suite(.serialized)
struct ChunkedFileDownloaderTests {

    // MARK: - Commit pinning

    @Test func pinsResolveMainToCommitSHA() {
        let url = URL(string: "https://huggingface.co/org/repo/resolve/main/model.safetensors")!
        let pinned = ChunkedFileDownloader.pinnedURL(url, commitSHA: "abc123")
        #expect(pinned.path == "/org/repo/resolve/abc123/model.safetensors")
    }

    @Test func pinningPreservesNestedPaths() {
        let url = URL(string: "https://huggingface.co/org/repo/resolve/main/sub/dir/model.bin")!
        let pinned = ChunkedFileDownloader.pinnedURL(url, commitSHA: "deadbeef")
        #expect(pinned.path == "/org/repo/resolve/deadbeef/sub/dir/model.bin")
    }

    /// A Hub layout change must degrade to "unpinned", never to a malformed URL.
    @Test func pinningFallsBackWhenShapeIsUnexpected() {
        let url = URL(string: "https://huggingface.co/org/repo/blob/main/model.safetensors")!
        #expect(ChunkedFileDownloader.pinnedURL(url, commitSHA: "abc").absoluteString == url.absoluteString)
    }

    @Test func pinningIsNoOpWithoutCommit() {
        let url = URL(string: "https://huggingface.co/org/repo/resolve/main/model.safetensors")!
        #expect(ChunkedFileDownloader.pinnedURL(url, commitSHA: nil).absoluteString == url.absoluteString)
        #expect(ChunkedFileDownloader.pinnedURL(url, commitSHA: "").absoluteString == url.absoluteString)
    }

    // MARK: - Checksum gate

    /// `x-linked-etag` is a content sha256 only for LFS objects; for ordinary
    /// blobs it carries a git object id, which would fail verification.
    @Test func onlyTreatsRealHashesAsSHA256() {
        #expect(ChunkedFileDownloader.isSHA256Hex(String(repeating: "a", count: 64)))
        #expect(!ChunkedFileDownloader.isSHA256Hex(String(repeating: "a", count: 40)))
        #expect(!ChunkedFileDownloader.isSHA256Hex(String(repeating: "z", count: 64)))
        #expect(!ChunkedFileDownloader.isSHA256Hex(""))
    }

    // MARK: - Chunkability

    @Test func smallFilesAreNotChunked() {
        let meta = HuggingFaceFileMetadata(
            commitSHA: "abc",
            size: 1024,
            sha256: nil,
            acceptsRanges: true
        )
        #expect(!meta.isChunkable)
    }

    @Test func rangelessServersAreNotChunked() {
        let meta = HuggingFaceFileMetadata(
            commitSHA: "abc",
            size: ChunkedFileDownloader.minimumChunkableSize * 2,
            sha256: nil,
            acceptsRanges: false
        )
        #expect(!meta.isChunkable)
    }

    // MARK: - Lane budget

    /// Concurrent files must share one connection ceiling rather than each
    /// opening a full set of lanes.
    @Test func budgetCapsTotalLanesAcrossFiles() async {
        let budget = LaneBudget(limit: 8)
        #expect(await budget.reserve(desired: 8) == 8)
        // Budget spent — but a second file still gets a lane rather than stalling.
        #expect(await budget.reserve(desired: 8) == 1)
        await budget.release(8)
        #expect(await budget.reserve(desired: 4) == 4)
    }

    @Test func budgetNeverGrantsMoreThanAsked() async {
        let budget = LaneBudget(limit: 8)
        #expect(await budget.reserve(desired: 2) == 2)
        #expect(await budget.reserve(desired: 3) == 3)
    }

    /// Releasing more than was taken must not inflate the ceiling.
    @Test func budgetReleaseIsClamped() async {
        let budget = LaneBudget(limit: 4)
        await budget.release(100)
        #expect(await budget.reserve(desired: 99) == 4)
    }

    // MARK: - Live transfer

    /// 335 MB LFS object: large enough to span ~11 chunks.
    private static let liveURL = URL(
        string: "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/resolve/main/model.safetensors"
    )!

    @Test(.enabled(if: liveHFDownloadEnabled())) func liveProbeReadsSizeCommitAndHash() async throws {
        let meta = try #require(try await ChunkedFileDownloader.probe(url: Self.liveURL))
        // Not pinned to an exact byte count — a repo push would break that
        // without telling us anything about the probe.
        #expect(meta.size > ChunkedFileDownloader.minimumChunkableSize)
        #expect(meta.acceptsRanges)
        #expect(meta.isChunkable)
        #expect(meta.sha256 != nil)
        #expect(meta.commitSHA != nil)
    }

    /// The whole point of the downloader: bytes assembled from parallel Range
    /// requests must hash to what Hugging Face says the file hashes to.
    @Test(.enabled(if: liveHFDownloadEnabled())) func liveChunkedDownloadMatchesPublishedChecksum() async throws {
        let meta = try #require(try await ChunkedFileDownloader.probe(url: Self.liveURL))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("model.safetensors")

        try await ChunkedFileDownloader().download(
            from: Self.liveURL,
            to: destination,
            metadata: meta,
            onProgress: { _, _ in }
        )

        let size =
            try FileManager.default.attributesOfItem(atPath: destination.path)[.size]
            as? NSNumber
        #expect(size?.int64Value == meta.size)

        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: destination)
        defer { try? handle.close() }
        while let block = try handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty {
            hasher.update(data: block)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(digest == meta.sha256)

        // Success cleans up its scratch state.
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".part"))
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".part.json"))
    }

    /// Pausing tears down the lanes' sessions, so the in-flight chunk fails
    /// with `URLError.cancelled`. That must be reported as `PauseInfo` — if it
    /// escapes as a plain error the orchestration marks the model `.failed`
    /// and the user sees a broken download instead of a paused one.
    @Test(.enabled(if: liveHFDownloadEnabled())) func livePauseSurfacesAsPauseNotFailure() async throws {
        let meta = try #require(try await ChunkedFileDownloader.probe(url: Self.liveURL))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunked-pause-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloader = ChunkedFileDownloader()
        let task = Task {
            try await downloader.download(
                from: Self.liveURL,
                to: dir.appendingPathComponent("model.safetensors"),
                metadata: meta,
                onProgress: { _, _ in }
            )
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        downloader.pause()

        switch await task.result {
        case .success:
            Issue.record("expected the paused transfer to throw, not complete")
        case .failure(let error):
            #expect(
                error is DirectDownloader.PauseInfo,
                "pause surfaced as \(type(of: error)): \(error)"
            )
        }
    }

    /// A transfer interrupted partway must resume from the `.part` manifest
    /// rather than restarting at byte zero — the behavior that made a failed
    /// retry re-download an entire multi-gigabyte shard.
    @Test(.enabled(if: liveHFDownloadEnabled())) func liveInterruptedDownloadResumesFromManifest() async throws {
        let meta = try #require(try await ChunkedFileDownloader.probe(url: Self.liveURL))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunked-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("model.safetensors")

        let manifestURL = destination.appendingPathExtension("part.json")
        let first = ChunkedFileDownloader()
        let paused = Task {
            try await first.download(
                from: Self.liveURL,
                to: destination,
                metadata: meta,
                onProgress: { _, _ in }
            )
        }

        // Interrupt once a chunk is actually durable, rather than guessing a
        // duration — lane count varies with the shared budget and the link.
        func completedChunks() -> Int {
            guard let data = try? Data(contentsOf: manifestURL),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return 0 }
            return (json["completed"] as? [Int])?.count ?? 0
        }
        let deadline = Date().addingTimeInterval(120)
        while completedChunks() == 0, Date() < deadline, !paused.isCancelled {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let completedAtPause = completedChunks()
        first.pause()
        _ = await paused.result

        #expect(completedAtPause > 0, "expected at least one durable chunk before pause")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path))

        // A fresh downloader must finish the job, not restart it. The proof is
        // that its very first progress report already credits the chunks the
        // interrupted run made durable, instead of starting at zero.
        let firstReport = Counter()
        try await ChunkedFileDownloader().download(
            from: Self.liveURL,
            to: destination,
            metadata: meta,
            onProgress: { bytes, _ in firstReport.captureFirst(bytes) }
        )
        #expect(
            firstReport.value >= ChunkedFileDownloader.chunkSize,
            "resumed run reported \(firstReport.value) bytes first — expected it to start from the durable chunks"
        )

        let size =
            try FileManager.default.attributesOfItem(atPath: destination.path)[.size]
            as? NSNumber
        #expect(size?.int64Value == meta.size)
    }

    /// Captures only the first value it is handed, from any thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var first: Int64?

        func captureFirst(_ bytes: Int64) {
            lock.lock()
            defer { lock.unlock() }
            if first == nil { first = bytes }
        }

        var value: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return first ?? -1
        }
    }
}
