import Foundation
import OsaurusRepository
import XCTest

@testable import OsaurusCLICore

final class PullHubTests: XCTestCase {
    private func node(_ path: String, size: Int64 = 10, type: String = "file") -> PullCommand.TreeNode {
        let json = #"{"path":"\#(path)","type":"\#(type)","size":\#(size)}"#
        return try! JSONDecoder().decode(PullCommand.TreeNode.self, from: Data(json.utf8))
    }

    func testDownloadsWhatTheAppDownloads() {
        let nodes = [
            node("config.json"), node("tokenizer.model"), node("vocab.txt"), node("merges.txt"),
            node("chat_template.jinja"), node("model-00001-of-00002.safetensors"),
            node("model.safetensors.index.json"), node("README.md"), node(".gitattributes"),
            node("original/consolidated.pth"), node("weights", type: "directory"), node("empty.json", size: 0),
            node("../escape.json"),
        ]
        let paths = PullCommand.matchingFiles(in: nodes).map(\.path)
        XCTAssertEqual(
            paths,
            [
                "config.json", "tokenizer.model", "vocab.txt", "merges.txt", "chat_template.jinja",
                "model-00001-of-00002.safetensors", "model.safetensors.index.json",
            ])
        XCTAssertEqual(ModelFilePatterns.download, ["*.json", "*.jinja", "*.txt", "*.model", "*.safetensors"])
    }

    func testFollowsTheNextPageLink() {
        let header =
            #"<https://huggingface.co/api/models/a/b/tree/main?recursive=1&cursor=abc>; rel="next", <https://huggingface.co/x>; rel="prev""#
        XCTAssertEqual(
            PullCommand.nextPageURL(linkHeader: header)?.absoluteString,
            "https://huggingface.co/api/models/a/b/tree/main?recursive=1&cursor=abc")
        XCTAssertNil(PullCommand.nextPageURL(linkHeader: #"<https://huggingface.co/x>; rel="prev""#))
        XCTAssertNil(PullCommand.nextPageURL(linkHeader: nil))
    }

    func testRefusalsSayWhatToDo() {
        let gated = PullCommand.hubStatusMessage(401, repoId: "a/b", hasToken: false)
        XCTAssertTrue(gated?.contains("HF_TOKEN") == true)
        XCTAssertTrue(PullCommand.hubStatusMessage(401, repoId: "a/b", hasToken: true)?.contains("rejected") == true)
        XCTAssertTrue(PullCommand.hubStatusMessage(403, repoId: "a/b", hasToken: true)?.contains("accept its terms") == true)
        XCTAssertTrue(PullCommand.hubStatusMessage(429, repoId: "a/b", hasToken: false)?.contains("rate limiting") == true)
        XCTAssertTrue(PullCommand.hubStatusMessage(404, repoId: "a/b", hasToken: false)?.contains("not found") == true)
        XCTAssertNil(PullCommand.hubStatusMessage(500, repoId: "a/b", hasToken: false))
    }

    func testTokenComesFromTheEnvironmentThenTheHubLogin() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pull-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(PullCommand.huggingFaceToken(environment: [:], home: home))

        let saved = home.appendingPathComponent(".cache/huggingface")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try Data("hf_saved\n".utf8).write(to: saved.appendingPathComponent("token"))
        XCTAssertEqual(PullCommand.huggingFaceToken(environment: [:], home: home), "hf_saved")
        XCTAssertEqual(PullCommand.huggingFaceToken(environment: ["HUGGING_FACE_HUB_TOKEN": "hf_legacy"], home: home), "hf_legacy")
        XCTAssertEqual(
            PullCommand.huggingFaceToken(environment: ["HF_TOKEN": "hf_env", "HUGGING_FACE_HUB_TOKEN": "hf_legacy"], home: home),
            "hf_env")
    }
}
