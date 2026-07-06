//
//  FileDiffStreamingPreviewTests.swift
//  osaurus
//
//  Covers FileDiff.streamingPreview — the live diff card built from a
//  file-writing tool call whose JSON arguments are still streaming.
//

import Testing

@testable import OsaurusCore

@Suite("FileDiff streaming preview")
struct FileDiffStreamingPreviewTests {

    @Test("parses partial content mid-stream")
    func partialContent() throws {
        let args = #"{"path": "script.py", "content": "import os\nimport sy"#
        let diff = try #require(
            FileDiff.streamingPreview(toolName: "file_write", partialArgs: args)
        )
        #expect(diff.path == "script.py")
        #expect(diff.language == "python")
        #expect(diff.isStreamingPreview)
        #expect(diff.lines.map(\.text) == ["import os", "import sy"])
        #expect(diff.lines.allSatisfy { $0.kind == .added })
        #expect(diff.addedCount == 2)
    }

    @Test("decodes escapes and keeps escaped quotes inside the value")
    func escapes() throws {
        let args = #"{"path": "a.txt", "content": "say \"hi\"\n\ttab"#
        let diff = try #require(
            FileDiff.streamingPreview(toolName: "sandbox_write_file", partialArgs: args)
        )
        #expect(diff.lines.map(\.text) == [#"say "hi""#, "\ttab"])
    }

    @Test("drops a trailing truncated escape instead of decoding it wrong")
    func truncatedEscape() throws {
        let args = #"{"path": "a.txt", "content": "line one\"# // ends mid-escape
        let diff = try #require(
            FileDiff.streamingPreview(toolName: "file_write", partialArgs: args)
        )
        #expect(diff.lines.map(\.text) == ["line one"])
    }

    @Test("nil before the content field starts streaming")
    func noContentYet() {
        #expect(
            FileDiff.streamingPreview(toolName: "file_write", partialArgs: #"{"path": "a.t"#)
                == nil
        )
        #expect(
            FileDiff.streamingPreview(
                toolName: "file_write",
                partialArgs: #"{"path": "a.txt", "content": ""#
            ) == nil
        )
    }

    @Test("path value that looks like a key does not shadow the real content")
    func keyLookalikeInPath() throws {
        let args = #"{"path": "content", "content": "real body"#
        let diff = try #require(
            FileDiff.streamingPreview(toolName: "file_write", partialArgs: args)
        )
        #expect(diff.lines.map(\.text) == ["real body"])
    }

    @Test("edit calls preview the new_string field")
    func editNewString() throws {
        let args = #"{"path": "a.swift", "old_string": "let x = 1", "new_string": "let x = 2\nlet y"#
        let diff = try #require(
            FileDiff.streamingPreview(toolName: "file_edit", partialArgs: args)
        )
        #expect(diff.lines.map(\.text) == ["let x = 2", "let y"])
    }

    @Test("gemma function envelope streams name and content")
    func gemmaEnvelope() throws {
        let args = "call:sandbox_write_file{path:<|\"|>gen.py<|\"|>, content:<|\"|>import numpy as np\nprint(1)"
        #expect(FileDiff.partialToolName(inArgs: args) == "sandbox_write_file")
        let diff = try #require(
            FileDiff.streamingPreview(toolName: "sandbox_write_file", partialArgs: args)
        )
        #expect(diff.path == "gen.py")
        #expect(diff.lines.map(\.text) == ["import numpy as np", "print(1)"])
    }

    @Test("gemma envelope trims a trailing partial escape marker")
    func gemmaPartialCloser() throws {
        let args = "call:file_write{path:<|\"|>a.py<|\"|>, content:<|\"|>x = 1<|\""
        let diff = try #require(
            FileDiff.streamingPreview(toolName: "file_write", partialArgs: args)
        )
        #expect(diff.lines.map(\.text) == ["x = 1"])
    }

    @Test("gemma name not reported until its opening brace streams")
    func gemmaIncompleteName() {
        #expect(FileDiff.partialToolName(inArgs: "call:sandbox_wri") == nil)
    }

    @Test("non-diff tools never preview")
    func otherTool() {
        #expect(
            FileDiff.streamingPreview(
                toolName: "web_search",
                partialArgs: #"{"content": "not a file"#
            ) == nil
        )
    }
}
