import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

/// Two real share nodes on this machine, found by address instead of mDNS:
/// a host publishing a model folder and a receiver copying it through the
/// same downloader the app uses.
@Suite("Model share loopback", .serialized)
struct ModelShareLoopbackTests {
    private final class Quiet: ModelShareListener, @unchecked Sendable {
        func hostsChanged() {}
    }

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 0
        func set(_ bytes: Int64) { lock.withLock { value = max(value, bytes) } }
        var bytes: Int64 { lock.withLock { value } }
    }

    private struct Pair {
        let host: ModelShareNode
        let receiver: ModelShareNode
        let source: NearbySource
        let model: NearbyModel
        let root: URL

        func stop() async {
            await host.stop()
            await receiver.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static let weights: Data = Data((0 ..< (16 << 20)).map { UInt8(truncatingIfNeeded: $0 % 251) })

    private func makePair() async throws -> Pair {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("osaurus-loopback-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("host/Raptor-4bit", isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("tokenizer"), withIntermediateDirectories: true)
        try Data(#"{"model_type":"raptor"}"#.utf8).write(to: bundle.appendingPathComponent("config.json"))
        try Self.weights.write(to: bundle.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("tokenizer/tokenizer.json"))

        let files = try #require(ShareableFiles.list(root: bundle))
        let shareable = ShareableModel(
            kind: .language,
            localId: "mlx-community/Raptor-4bit",
            name: "Raptor",
            repoId: "mlx-community/Raptor-4bit",
            revision: nil,
            files: files
        )
        let published = try await SharedModelIndex(cacheURL: root.appendingPathComponent("hashes.json"))
            .prepare(shareable)

        let host = try ModelShareNode()
        let receiver = try ModelShareNode()
        try await host.start(
            config: ModelShareConfig(deviceName: "Studio", share: true, browse: false, mdns: false, bindPort: 0),
            listener: Quiet()
        )
        try await receiver.start(
            config: ModelShareConfig(deviceName: "Mini", share: false, browse: true, mdns: false, bindPort: 0),
            listener: Quiet()
        )
        try host.setSharedModels(models: [published])
        try await receiver.addHostAddress(address: try #require(host.localAddress()))

        let nearby = try #require(receiver.hosts().first)
        #expect(nearby.name == "Studio")
        let model = try #require(nearby.models.first)
        return Pair(
            host: host,
            receiver: receiver,
            source: NearbySource(hostId: nearby.id, hostName: nearby.name, itemId: model.id),
            model: model,
            root: root
        )
    }

    private func withPair(_ body: (Pair) async throws -> Void) async throws {
        let pair = try await makePair()
        do {
            try await body(pair)
        } catch {
            await pair.stop()
            throw error
        }
        await pair.stop()
    }

    private func expected(_ path: String, in model: NearbyModel) throws -> (ModelFileDigest, Int64) {
        let file = try #require(model.files.first { $0.path == path })
        return (.sha256(file.sha256), Int64(file.size))
    }

    @Test func receiverSeesWhatTheHostPublishes() async throws {
        try await withPair { pair in

            #expect(pair.model.id == "language:mlx-community/Raptor-4bit")
            #expect(pair.model.kind == "language")
            #expect(pair.model.format == "mlx")
            #expect(pair.model.repoId == "mlx-community/Raptor-4bit")
            #expect(pair.model.files.map(\.path) == ["config.json", "model.safetensors", "tokenizer/tokenizer.json"])
            #expect(pair.model.files.allSatisfy { $0.sha256.count == 64 })
            #expect(!pair.model.files.contains { $0.path.hasPrefix("/") })
        }
    }

    @Test func copiesAFileAndChecksItsDigest() async throws {
        try await withPair { pair in
            let (digest, size) = try expected("model.safetensors", in: pair.model)
            let destination = pair.root.appendingPathComponent("receiver/Raptor-4bit/model.safetensors")
            let received = Received()

            try await NearbyFileDownloader.download(
                node: pair.receiver,
                source: pair.source,
                path: "model.safetensors",
                size: size,
                digest: digest,
                to: destination
            ) { received.set($0) }

            #expect(try Data(contentsOf: destination) == Self.weights)
            #expect(received.bytes == size)
            #expect(!FileManager.default.fileExists(atPath: NearbyFileDownloader.partURL(for: destination).path))
        }
    }

    @Test func resumesFromAPartialCopy() async throws {
        try await withPair { pair in
            let (digest, size) = try expected("model.safetensors", in: pair.model)
            let destination = pair.root.appendingPathComponent("receiver/model.safetensors")
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let half = Self.weights.count / 2
            try Self.weights.prefix(half).write(to: NearbyFileDownloader.partURL(for: destination))
            #expect(NearbyFileDownloader.resumableBytes(for: destination) == Int64(half))

            try await NearbyFileDownloader.download(
                node: pair.receiver,
                source: pair.source,
                path: "model.safetensors",
                size: size,
                digest: digest,
                to: destination
            ) { _ in }

            #expect(try Data(contentsOf: destination) == Self.weights)
        }
    }

    @Test func pauseKeepsTheReceivedBytesAndResumeFinishes() async throws {
        try await withPair { pair in
            let (digest, size) = try expected("model.safetensors", in: pair.model)
            let destination = pair.root.appendingPathComponent("receiver/model.safetensors")
            let node = pair.receiver
            let source = pair.source
            let transfer = Task {
                try await NearbyFileDownloader.download(
                    node: node,
                    source: source,
                    path: "model.safetensors",
                    size: size,
                    digest: digest,
                    to: destination
                ) { _ in }
            }
            while NearbyFileDownloader.resumableBytes(for: destination) == 0 {
                try await Task.sleep(for: .milliseconds(1))
            }
            transfer.cancel()
            await #expect(throws: CancellationError.self) { try await transfer.value }

            let kept = NearbyFileDownloader.resumableBytes(for: destination)
            #expect(kept > 0 && kept < size)
            #expect(!FileManager.default.fileExists(atPath: destination.path))

            try await NearbyFileDownloader.download(
                node: node,
                source: source,
                path: "model.safetensors",
                size: size,
                digest: digest,
                to: destination
            ) { _ in }
            #expect(try Data(contentsOf: destination) == Self.weights)
        }
    }

    @Test func mismatchedBytesAreDiscarded() async throws {
        try await withPair { pair in
            let (_, size) = try expected("model.safetensors", in: pair.model)
            let destination = pair.root.appendingPathComponent("receiver/model.safetensors")

            await #expect(throws: NearbyTransferError.contentMismatch(path: "model.safetensors")) {
                try await NearbyFileDownloader.download(
                    node: pair.receiver,
                    source: pair.source,
                    path: "model.safetensors",
                    size: size,
                    digest: .sha256(String(repeating: "0", count: 64)),
                    to: destination
                ) { _ in }
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(!FileManager.default.fileExists(atPath: NearbyFileDownloader.partURL(for: destination).path))
        }
    }

    @Test func refusesPathsTheHostDoesNotShare() async throws {
        try await withPair { pair in
            let destination = pair.root.appendingPathComponent("receiver/passwd")

            await #expect(throws: NearbyTransferError.self) {
                try await NearbyFileDownloader.download(
                    node: pair.receiver,
                    source: pair.source,
                    path: "../../../../etc/passwd",
                    size: 10,
                    digest: .sha256(String(repeating: "0", count: 64)),
                    to: destination
                ) { _ in }
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func copiesAWholeBundleIntoPlace() async throws {
        try await withPair { pair in
            let destination = pair.root.appendingPathComponent("receiver/bundle", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: destination.appendingPathComponent("stale.bin"))
            let received = Received()

            try await NearbyBundleTransfer.fetch(
                node: pair.receiver,
                source: pair.source,
                files: pair.model.files,
                into: destination
            ) { bytes, _ in received.set(bytes) }

            #expect(try Data(contentsOf: destination.appendingPathComponent("model.safetensors")) == Self.weights)
            #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("tokenizer/tokenizer.json").path))
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("stale.bin").path))
            #expect(!FileManager.default.fileExists(atPath: NearbyBundleTransfer.stagingURL(for: destination).path))
            #expect(received.bytes == pair.model.files.reduce(0) { $0 + Int64($1.size) })
        }
    }

    @Test func stoppedHostIsReportedUnreachable() async throws {
        try await withPair { pair in
            let (digest, size) = try expected("model.safetensors", in: pair.model)
            await pair.host.stop()

            await #expect(throws: NearbyTransferError.hostUnavailable(hostName: "Studio")) {
                try await NearbyFileDownloader.download(
                    node: pair.receiver,
                    source: pair.source,
                    path: "model.safetensors",
                    size: size,
                    digest: digest,
                    to: pair.root.appendingPathComponent("receiver/model.safetensors")
                ) { _ in }
            }
        }
    }

    @Test func nearbyCopyMarkerNamesTheHost() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(NearbyCopyMarker.hostName(in: directory) == nil)
        NearbyCopyMarker.record(in: directory, hostName: "Studio")
        #expect(NearbyCopyMarker.hostName(in: directory) == "Studio")
        NearbyCopyMarker.record(in: directory, hostName: nil)
        #expect(NearbyCopyMarker.hostName(in: directory) == nil)
    }
}
