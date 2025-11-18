//
//  FileToolsTests.swift
//  osaurusTests
//
//  Minimal smoke tests for file.read and file.write tools.
//

import Foundation
import Testing

@testable import OsaurusCore

struct FileToolsTests {

    private func jsonString(_ obj: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func payloadJSON(from result: String) throws -> [String: Any] {
        // Tools return "summary\n{json}"
        guard let idx = result.firstIndex(of: "\n") else { return [:] }
        let jsonPart = String(result[result.index(after: idx)...])
        let data = Data(jsonPart.utf8)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    @Test func write_create_overwrite_append_and_read_utf8() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let testDir = tmpDir.appendingPathComponent("osaurus-filetools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        let fileURL = testDir.appendingPathComponent("sample.txt", isDirectory: false)

        // 1) Create new file (no flags) should succeed
        let write1 = FileWriteTool()
        let args1: [String: Any] = [
            "path": fileURL.path,
            "content": "hello",
            "create_dirs": true,
        ]
        let res1 = try await write1.execute(argumentsJSON: try jsonString(args1))
        let payload1 = try payloadJSON(from: res1)
        #expect((payload1["operation"] as? String) == "created")
        #expect((payload1["bytesWritten"] as? Int) == 5)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect((try? String(contentsOf: fileURL)) == "hello")

        // 2) Write again without flags should fail (file exists)
        let res2 = try await write1.execute(argumentsJSON: try jsonString(args1))
        #expect(res2.hasPrefix("File write failed"))

        // 3) Append '!' to existing file
        let args3: [String: Any] = [
            "path": fileURL.path,
            "content": "!",
            "append": true,
        ]
        let res3 = try await write1.execute(argumentsJSON: try jsonString(args3))
        let payload3 = try payloadJSON(from: res3)
        #expect((payload3["operation"] as? String) == "appended")
        #expect((payload3["bytesWritten"] as? Int) == 1)
        #expect((try? String(contentsOf: fileURL)) == "hello!")

        // 4) Overwrite with 'bye'
        let args4: [String: Any] = [
            "path": fileURL.path,
            "content": "bye",
            "overwrite": true,
        ]
        let res4 = try await write1.execute(argumentsJSON: try jsonString(args4))
        let payload4 = try payloadJSON(from: res4)
        #expect((payload4["operation"] as? String) == "overwritten")
        #expect((payload4["bytesWritten"] as? Int) == 3)
        #expect((try? String(contentsOf: fileURL)) == "bye")

        // 5) Read full file as utf8
        let read = FileReadTool()
        let args5: [String: Any] = [
            "path": fileURL.path,
            "encoding": "utf8",
            "with_stats": true,
        ]
        let res5 = try await read.execute(argumentsJSON: try jsonString(args5))
        let payload5 = try payloadJSON(from: res5)
        #expect((payload5["readBytes"] as? Int) == 3)
        #expect((payload5["truncated"] as? Bool) == false)
        #expect((payload5["encodingUsed"] as? String) == "utf8")
        #expect((payload5["content"] as? String) == "bye")
    }

    @Test func read_with_range_and_truncation() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("osaurus-filetools-\(UUID().uuidString).txt")
        try "abcdefg".data(using: .utf8)!.write(to: fileURL, options: [.atomic])

        let read = FileReadTool()
        let args: [String: Any] = [
            "path": fileURL.path,
            "start": 2,
            "max_bytes": 3,
            "encoding": "utf8",
        ]
        let res = try await read.execute(argumentsJSON: try jsonString(args))
        let payload = try payloadJSON(from: res)
        #expect((payload["readBytes"] as? Int) == 3)
        #expect((payload["truncated"] as? Bool) == true)
        #expect((payload["content"] as? String) == "cde")
    }

    @Test func base64_write_and_read() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("osaurus-filetools-\(UUID().uuidString).bin")

        // bytes: 0x00 0x01 0x02
        let write = FileWriteTool()
        let wargs: [String: Any] = [
            "path": fileURL.path,
            "content": "AAEC",
            "encoding": "base64",
            "create_dirs": true,
        ]
        let wres = try await write.execute(argumentsJSON: try jsonString(wargs))
        let wpayload = try payloadJSON(from: wres)
        #expect((wpayload["bytesWritten"] as? Int) == 3)

        let read = FileReadTool()
        let rargs: [String: Any] = [
            "path": fileURL.path,
            "encoding": "base64",
        ]
        let rres = try await read.execute(argumentsJSON: try jsonString(rargs))
        let rpayload = try payloadJSON(from: rres)
        #expect((rpayload["encodingUsed"] as? String) == "base64")
        #expect((rpayload["content"] as? String) == "AAEC")
    }

    @Test func read_directory_should_fail() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let res = try await FileReadTool().execute(
            argumentsJSON: try jsonString([
                "path": tmpDir.path
            ])
        )
        #expect(res.hasPrefix("File read failed"))
    }
}
