import CryptoKit
import Foundation
import Network
import Testing

@testable import OsaurusCore

struct ModelRepairTests {
    private let helloSHA256 = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    private let helloGitOID = "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0"

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("model-repair-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func chunkedFixture(size: Int) -> Data {
        let chunkSize = 4 * 1024 * 1024
        var data = Data(capacity: size)
        while data.count < size {
            let count = min(chunkSize, size - data.count)
            data.append(Data(repeating: UInt8(data.count / chunkSize + 1), count: count))
        }
        return data
    }

    private func digest(of data: Data, gitBlob: Bool) -> ModelFileDigest {
        if gitBlob {
            var hash = Insecure.SHA1()
            hash.update(data: Data("blob \(data.count)\0".utf8))
            hash.update(data: data)
            return .gitBlobSHA1(hash.finalize().map { String(format: "%02x", $0) }.joined().uppercased())
        }
        return .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().uppercased())
    }

    @Test(arguments: [false, true])
    func detectsSameSizeCorruption(inWeights: Bool) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = HuggingFaceService.MatchedFile(
            path: inWeights ? "model.safetensors" : "config.json",
            size: 5,
            digest: inWeights ? .sha256(helloSHA256) : .gitBlobSHA1(helloGitOID)
        )
        try Data("jello".utf8).write(to: dir.appendingPathComponent(file.path))
        #expect(try ModelDownloadService.filesNeedingDownload([file], under: dir, verifyContents: true).count == 1)
        // Automatic top-up still respects deliberately edited files.
        #expect(ModelDownloadService.filesToFetch(remote: [file], under: dir, intent: .automatic).isEmpty)
        #expect(ModelDownloadService.filesToFetch(remote: [file], under: dir, intent: .explicitRepair).count == 1)
    }

    @Test func keepsIntactFilesAndFindsMissingAndTruncatedFiles() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hello".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data("he".utf8).write(to: dir.appendingPathComponent("model.safetensors"))
        let files = [
            HuggingFaceService.MatchedFile(path: "config.json", size: 5, digest: .gitBlobSHA1(helloGitOID)),
            HuggingFaceService.MatchedFile(path: "model.safetensors", size: 5, digest: .sha256(helloSHA256)),
            HuggingFaceService.MatchedFile(path: "tokenizer.json", size: 5, digest: .gitBlobSHA1(helloGitOID)),
        ]
        #expect(
            try ModelDownloadService.filesNeedingDownload(files, under: dir, verifyContents: true).map(\.path)
                == ["model.safetensors", "tokenizer.json"]
        )
    }

    @Test func repairScanHonorsCancellation() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ModelDownloadService.filesNeedingDownload(
                [.init(path: "config.json", size: 5)],
                under: dir,
                verifyContents: true
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func failedAtomicCommitKeepsExistingFile() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("config.json")
        try Data("original".utf8).write(to: destination)
        #expect(throws: (any Error).self) {
            try ModelFileIntegrity.commit(staged: dir.appendingPathComponent("absent"), to: destination)
        }
        #expect(try Data(contentsOf: destination) == Data("original".utf8))
    }

    @Test func validationCanStopDuringHashing() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appendingPathComponent("staged")
        let size = 9 * 1024 * 1024
        try Data(repeating: 1, count: size).write(to: staged)
        var checks = 0
        #expect(throws: CancellationError.self) {
            try ModelFileIntegrity.validate(staged, size: Int64(size), digest: .sha256(helloSHA256)) {
                checks += 1
                if checks == 3 { throw CancellationError() }
            }
        }
        #expect(checks == 3)
    }

    @Test(arguments: [false, true], [0, 1, (4 << 20) - 1, 4 << 20, (4 << 20) + 1, (8 << 20) + 17])
    func hashingDrainsEachChunkAndMatchesWholeBufferDigest(gitBlob: Bool, size: Int) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("payload")
        let data = chunkedFixture(size: size)
        try data.write(to: file)
        let expected = digest(of: data, gitBlob: gitBlob)
        let chunks = (size + (4 << 20) - 1) / (4 << 20)
        let released = RepairChunkReleaseCounter()
        var checks = 0

        // Keep an outer pool alive like a Repair worker. Each chunk's witness
        // must die before the next read, not at worker/task completion. This
        // deterministic lifetime check avoids process-footprint timing noise.
        let matches = try autoreleasepool {
            let matches = try ModelFileIntegrity.matches(file, size: Int64(size), digest: expected) {
                checks += 1
                guard checks > 1 else { return }  // Pre-file cancellation check.
                #expect(released.count == checks - 2)
                _ = Unmanaged.passRetained(RepairChunkReleaseWitness(counter: released)).autorelease()
            }
            #expect(released.count == chunks, "Last chunk must drain before the outer worker pool")
            return matches
        }
        #expect(matches)
        #expect(checks == chunks + 1)
        let wrong: ModelFileDigest =
            gitBlob
            ? .gitBlobSHA1(String(repeating: "0", count: 40))
            : .sha256(String(repeating: "0", count: 64))
        #expect(try !ModelFileIntegrity.matches(file, size: Int64(size), digest: wrong))
        #expect(try !ModelFileIntegrity.matches(file, size: Int64(size + 1), digest: expected))
    }

    @Test(arguments: [false, true], [1, 2, 3])
    func cancelledHashingDrainsCurrentChunk(gitBlob: Bool, cancelAt: Int) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("payload")
        let data = chunkedFixture(size: (8 << 20) + 17)
        try data.write(to: file)
        let expected = digest(of: data, gitBlob: gitBlob)
        let released = RepairChunkReleaseCounter()
        var checks = 0
        autoreleasepool {
            #expect(throws: CancellationError.self) {
                try ModelFileIntegrity.validate(file, size: Int64(data.count), digest: expected) {
                    checks += 1
                    if checks > 1 {
                        #expect(released.count == checks - 2)
                        _ = Unmanaged.passRetained(RepairChunkReleaseWitness(counter: released)).autorelease()
                    }
                    if checks == cancelAt { throw CancellationError() }
                }
            }
            #expect(checks == cancelAt)
            #expect(released.count == max(0, cancelAt - 1), "Throwing chunk must drain before the outer pool")
        }
    }

    @Test func hashingIOErrorsRemainDifferentFromDigestMismatch() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("payload")
        try Data("jello".utf8).write(to: file)
        #expect(try !ModelFileIntegrity.matches(file, size: 5, digest: .sha256(helloSHA256)))
        #expect(throws: URLError.self) {
            try ModelFileIntegrity.validate(file, size: 5, digest: .sha256(helloSHA256))
        }
        #expect(throws: (any Error).self) {
            try ModelFileIntegrity.matches(dir.appendingPathComponent("absent"), size: 5, digest: .sha256(helloSHA256))
        }
        #expect(try !ModelFileIntegrity.matches(dir, size: 0, digest: .sha256(helloSHA256)))
        #expect(throws: (any Error).self) {
            try ModelFileDigest.sha256(helloSHA256).matches(dir, size: 0)
        }
    }

    @Test(arguments: ["valid", "wrong-size", "wrong-hash", "http-error"])
    func realSingleFileTransferPreservesOldFileUntilValidated(scenario: String) async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("config.json")
        try Data("original".utf8).write(to: destination)
        let body = scenario == "wrong-size" ? "hi" : scenario == "wrong-hash" ? "jello" : "hello"
        let server = try await RepairHTTPFixture.start(body: body, status: scenario == "http-error" ? 403 : 200)
        defer { server.listener.cancel() }
        let downloader = DirectDownloader()
        defer { downloader.invalidate() }
        do {
            try await downloader.download(
                from: server.url,
                to: destination,
                expectedSize: 5,
                expectedDigest: .gitBlobSHA1(helloGitOID),
                onProgress: { _, _ in }
            )
            #expect(scenario == "valid")
            #expect(try Data(contentsOf: destination) == Data("hello".utf8))
        } catch {
            #expect(scenario != "valid", "unexpected transfer failure: \(error)")
            #expect(try Data(contentsOf: destination) == Data("original".utf8))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["config.json"])
    }

    @Test func lfsDigestIsPayloadSHA256RatherThanPointerOID() throws {
        let data = Data(
            #"{"path":"model.safetensors","size":134,"oid":"pointer","lfs":{"size":5000,"oid":"payload"}}"#.utf8
        )
        let node = try JSONDecoder().decode(HuggingFaceService.TreeNode.self, from: data)
        #expect(node.bestSize == 5000)
        #expect(node.digest == .sha256("payload"))
    }

    @Test func followsEveryPageAtOneImmutableRevision() async throws {
        let fixture = RepairManifestFixture()
        let service = HuggingFaceService(metadataRequest: { request in try await fixture.respond(request) })
        let files = try await service.fetchDownloadFiles(repoId: "org/repo", patterns: ["*.json", "*.safetensors"])
        #expect(files.map(\.path) == ["config.json", "model.safetensors"])
        #expect(files.allSatisfy { $0.revision == RepairManifestFixture.revision })
        #expect(files[0].digest == .gitBlobSHA1(helloGitOID))
        #expect(files[1].digest == .sha256(helloSHA256))
        #expect(await fixture.requests.count == 3)
        let url = ModelDownloadService.resolveURL(repoId: "org/repo", path: files[1].path, revision: files[1].revision!)
        #expect(url?.path == "/org/repo/resolve/\(RepairManifestFixture.revision)/model.safetensors")
    }

    @Test(arguments: [
        "https://evil.example/api/models/org/repo/tree/sha?cursor=2",
        "https://huggingface.co/api/models/org/repo/tree/main?cursor=2",
    ])
    func rejectsUntrustedOrChangedRevisionPagination(linkURL: String) {
        #expect(throws: (any Error).self) {
            try HuggingFaceService.nextTreePage(
                "<\(linkURL)>; rel=\"next\"",
                under: URL(string: "https://huggingface.co/api/models/org/repo/tree/sha")!
            )
        }
    }

    @Test func metadataFailureKeepsHTTPStatus() async {
        let service = HuggingFaceService(metadataRequest: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await service.fetchDownloadFiles(repoId: "org/private", patterns: ["*.json"])
            Issue.record("Expected an authenticated repository error")
        } catch let error as DirectDownloader.HTTPStatusError {
            #expect(error.statusCode == 401)
        } catch { Issue.record("Lost HTTP status: \(error)") }
    }
}

private final class RepairChunkReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}

private final class RepairChunkReleaseWitness: NSObject {
    private let counter: RepairChunkReleaseCounter

    init(counter: RepairChunkReleaseCounter) {
        self.counter = counter
        super.init()
    }

    deinit { counter.increment() }
}

private struct RepairHTTPFixture {
    let listener: NWListener
    let url: URL

    static func start(body: String, status: Int) async throws -> Self {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
                let response =
                    "HTTP/1.1 \(status) Test\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(
                    content: Data(response.utf8),
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        let port = try #require(listener.port)
        return Self(listener: listener, url: URL(string: "http://127.0.0.1:\(port.rawValue)/config.json")!)
    }
}

private actor RepairManifestFixture {
    static let revision = String(repeating: "a", count: 40)
    var requests: [URL] = []

    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        requests.append(url)
        var headers: [String: String] = [:]
        let body: String
        if url.path.contains("/revision/") {
            body = "{\"sha\":\"\(Self.revision)\"}"
        } else if url.query?.contains("cursor=next") == true {
            body =
                #"[{"type":"file","path":"model.safetensors","size":5,"oid":"pointer","lfs":{"size":5,"oid":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"}}]"#
        } else {
            #expect(url.path.hasSuffix(Self.revision))
            headers["Link"] =
                "<https://huggingface.co/api/models/org/repo/tree/\(Self.revision)?recursive=1&cursor=next>; rel=\"next\""
            body = #"[{"type":"file","path":"config.json","size":5,"oid":"b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0"}]"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}
