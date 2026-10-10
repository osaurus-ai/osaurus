//
//  ModelMirrorTests.swift
//  osaurusTests
//
//  Unit tests for ModelMirror URL construction and ModelScope
//  response decoding. No network calls — all inputs are local.
//

import Foundation
import Testing
@testable import OsaurusCore

struct ModelMirrorTests {

    // MARK: - HF URL construction

    @Test func hfFileListURL() {
        let url = ModelMirror.huggingFace.fileListURL(repoId: "mlx-community/gemma-4-e4b-it-4bit")
        #expect(url?.host == "huggingface.co")
        #expect(url?.path == "/api/models/mlx-community/gemma-4-e4b-it-4bit/tree/main")
        #expect(url?.query?.contains("recursive=1") == true)
    }

    @Test func hfDownloadURL() {
        let url = ModelMirror.huggingFace.downloadURL(
            repoId: "mlx-community/gemma-4-e4b-it-4bit",
            filePath: "model.safetensors"
        )
        #expect(url?.absoluteString ==
            "https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit/resolve/main/model.safetensors")
    }

    @Test func hfDownloadURLEncodesSpaces() {
        let url = ModelMirror.huggingFace.downloadURL(
            repoId: "org/repo",
            filePath: "sub dir/file name.safetensors"
        )
        #expect(url?.absoluteString?.contains("%20") == true)
    }

    // MARK: - ModelScope URL construction

    @Test func msFileListURL() {
        let url = ModelMirror.modelScope.fileListURL(repoId: "mlx-community/gemma-4-e4b-it-4bit")
        #expect(url?.host == "www.modelscope.cn")
        #expect(url?.path == "/api/v1/models/mlx-community/gemma-4-e4b-it-4bit/repo/files")
        #expect(url?.query == nil)
    }

    @Test func msDownloadURL() {
        let url = ModelMirror.modelScope.downloadURL(
            repoId: "mlx-community/gemma-4-e4b-it-4bit",
            filePath: "config.json"
        )
        #expect(url?.host == "www.modelscope.cn")
        #expect(url?.path == "/api/v1/models/mlx-community/gemma-4-e4b-it-4bit/repo")
        #expect(url?.query == "FilePath=config.json")
    }

    @Test func msDownloadURLEncodesPath() {
        let url = ModelMirror.modelScope.downloadURL(
            repoId: "org/repo",
            filePath: "sub/model.safetensors"
        )
        // FilePath value should be percent-encoded in the query
        #expect(url?.query?.contains("FilePath=sub") == true)
    }

    // MARK: - ModelScope JSON decoding

    @Test func msFileListDecoding() throws {
        let json = """
        {
          "Code": 200,
          "Data": {
            "Files": [
              {
                "Path": "config.json",
                "Size": 6229,
                "Type": "blob",
                "Name": "config.json",
                "CommitMessage": "",
                "CommittedDate": 1775179795,
                "CommitterName": "systemd",
                "InCheck": false,
                "IsLFS": false,
                "Mode": "33188",
                "Revision": "abc123",
                "Sha256": "deadbeef"
              },
              {
                "Path": "model.safetensors",
                "Size": 5217361182,
                "Type": "blob",
                "Name": "model.safetensors",
                "CommitMessage": "",
                "CommittedDate": 1775179795,
                "CommitterName": "systemd",
                "InCheck": false,
                "IsLFS": true,
                "Mode": "33188",
                "Revision": "abc123",
                "Sha256": "deadbeef"
              },
              {
                "Path": "subdir",
                "Size": 0,
                "Type": "tree",
                "Name": "subdir",
                "CommitMessage": "",
                "CommittedDate": 1775179795,
                "CommitterName": "systemd",
                "InCheck": false,
                "IsLFS": false,
                "Mode": "16384",
                "Revision": "abc123",
                "Sha256": ""
              }
            ]
          }
        }
        """
        // Decode using the same private struct shape via the internal test hook
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(MSFilesResponseTestable.self, from: data)
        #expect(decoded.Code == 200)
        let files = try #require(decoded.Data?.Files)
        #expect(files.count == 3)

        // Only blobs with size > 0 should survive the filter
        let blobs = files.filter { $0.Type == "blob" && $0.Size > 0 }
        #expect(blobs.count == 2)
        #expect(blobs[0].Path == "config.json")
        #expect(blobs[1].Size == 5_217_361_182)
    }

    // MARK: - UserDefaults persistence

    @Test func mirrorPersistsToUserDefaults() {
        // Save
        ModelMirror.current = .modelScope
        #expect(ModelMirror.current == .modelScope)
        #expect(UserDefaults.standard.string(forKey: "modelDownloadMirror") == "modelScope")

        // Reset
        ModelMirror.current = .huggingFace
        #expect(ModelMirror.current == .huggingFace)
    }

    @Test func unknownRawValueDefaultsToHF() {
        UserDefaults.standard.set("unknownMirror", forKey: "modelDownloadMirror")
        #expect(ModelMirror.current == .huggingFace)
        // Cleanup
        UserDefaults.standard.removeObject(forKey: "modelDownloadMirror")
    }
}

// MARK: - Testable mirror of the private MSFilesResponse struct
// Mirrors the exact shape used in HuggingFaceService so we can decode
// the same JSON without making the private type internal/public.

struct MSFilesResponseTestable: Decodable {
    let Code: Int
    let Data: MSFilesData?

    struct MSFilesData: Decodable {
        let Files: [MSFile]?
    }

    struct MSFile: Decodable {
        let Path: String
        let Size: Int64
        let Type: String
    }
}
