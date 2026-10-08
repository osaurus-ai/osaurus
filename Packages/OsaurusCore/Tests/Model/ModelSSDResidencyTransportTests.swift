import Foundation
import Testing
@testable import OsaurusCore

private final class SSDHeaderURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let mode = url.pathComponents[1].split(separator: "-").first.map(String.init)!
        let tensor = "model.layers.0.ple.ngram_embedding.weight"
        let header = mode == "malformed" ? Data("not JSON".utf8) :
            Data((mode == "missing" ? "{}" : "{\"\(tensor)\":{\"data_offsets\":[0,16]}}").utf8)
        var size = UInt64(header.count).littleEndian
        var shard = withUnsafeBytes(of: &size) { Data($0) }
        shard.append(header)
        shard.append(Data(count: 16))
        var status = 200
        var fields: [String: String] = [:]
        let body: Data
        if url.lastPathComponent == "model.safetensors.index.json" {
            body = Data((mode == "zero" ? "{\"weight_map\":{}}" :
                "{\"weight_map\":{\"\(tensor)\":\"model.safetensors\"}}").utf8)
        } else if mode == "ignored" {
            body = shard
        } else {
            let bounds = request.value(forHTTPHeaderField: "Range")!.dropFirst(6).split(separator: "-")
            let lower = Int(bounds[0])!, upper = Int(bounds[1])!
            status = 206
            let total = mode == "unknown" ? "*" : String(shard.count)
            fields["Content-Range"] = "bytes \(mode == "mismatch" ? lower + 1 : lower)-\(upper)/\(total)"
            body = shard.subdata(in: lower..<(upper + 1))
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: fields)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct ModelSSDResidencyTransportTests {
    @Test(arguments: ["ignored", "mismatch", "malformed", "missing"])
    func invalidRangeOrHeaderDoesNotPoisonCache(mode: String) async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SSDHeaderURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let repo = "\(mode)-\(UUID().uuidString)/fixture"
        let result = await ModelSSDResidency.remoteNGramBytes(repoId: repo, revision: "fixture", session: session)
        #expect(result == nil)
        #expect(ModelSizeCache.entry(forId: repo + "#ssd-resident-ngram") == nil)
    }

    @Test(arguments: ["zero", "table", "unknown"])
    func validRangeResponsesKeepZeroDistinctFromFailure(mode: String) async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SSDHeaderURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let repo = "\(mode)-\(UUID().uuidString)/fixture"
        let expected: Int64 = mode == "zero" ? 0 : 16
        let result = await ModelSSDResidency.remoteNGramBytes(repoId: repo, revision: "fixture", session: session)
        #expect(result == expected)
        #expect(ModelSizeCache.entry(forId: repo + "#ssd-resident-ngram") != nil)
        // A successful measurement is still reusable without another transport request.
        #expect(await ModelSSDResidency.remoteNGramBytes(repoId: repo, revision: "fixture", session: session) == expected)
    }
}
