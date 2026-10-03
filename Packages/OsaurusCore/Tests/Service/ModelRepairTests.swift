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
