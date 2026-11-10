//
//  ToolOutputSchemaContractTests.swift
//  osaurusTests
//
//  Each built-in's published `outputSchema` against what the tool really
//  returns: the result is turned into a node output and validated exactly
//  as a workflow tool step does, so a schema that names a field the tool
//  never returns (or mistypes one) fails here instead of in a run.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ToolOutputSchemaContractTests {

    private func tmpDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-schema-contract-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The node output a workflow step gets from `envelope`, after checking
    /// it against `tool`'s published schema.
    @discardableResult
    private func expectConforms(
        _ envelope: String, _ tool: any OsaurusTool, _ label: String = "",
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> JSONValue {
        #expect(ToolEnvelope.isSuccess(envelope), "\(tool.name) \(label) failed: \(envelope)", sourceLocation: sourceLocation)
        guard let schema = tool.outputSchema else {
            Issue.record("\(tool.name) publishes no output schema", sourceLocation: sourceLocation)
            return .null
        }
        let output = ToolNodeExecutor.output(of: envelope, declaredSchema: schema)
        let issues = JSONSchemaValidator.validate(output, against: schema)
        #expect(
            issues.isEmpty,
            "\(tool.name) \(label): \(issues.map(\.description)) in \(output.compactJSONString.prefix(600))",
            sourceLocation: sourceLocation)
        return output
    }

    // MARK: - Folder tools

    @Test func folderToolsReturnWhatTheirSchemasSay() async throws {
        DocumentAdaptersBootstrap.registerBuiltIns()
        let env = try FileHistoryTestEnv.make()
        defer { env.cleanup() }
        let root = tmpDir("folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "schema-contract-\(UUID().uuidString)"
        func run(_ tool: any OsaurusTool, _ args: [String: Any]) async throws -> String {
            try await env.run(tool, FileHistoryTestEnv.json(args), sessionId: session, folder: root)
        }

        let write = FileWriteTool(rootPath: root)
        expectConforms(try await run(write, ["path": "notes/a.txt", "content": "alpha\nbeta\n"]), write, "text")
        expectConforms(
            try await run(write, ["path": "resumes/jane.docx", "content": "# Jane Doe\n\nSwift engineer.\n"]), write,
            "docx")
        expectConforms(
            try await run(write, ["path": "resumes/sam.pdf", "content": "# Sam Roe\n\nData analyst.\n"]), write, "pdf")
        expectConforms(
            try await run(write, ["path": "notes/a.txt", "content": "alpha\nbeta\n", "dry_run": true]), write,
            "dry run")

        let read = FileReadTool(rootPath: root)
        let text = expectConforms(try await run(read, ["path": "notes/a.txt"]), read, "text")
        #expect(text.value(atPath: "text")?.stringValue?.contains("alpha") == true)
        expectConforms(try await run(read, ["path": "resumes/sam.pdf"]), read, "pdf")
        expectConforms(try await run(read, ["path": "resumes/jane.docx"]), read, "docx")
        expectConforms(try await run(read, ["path": "resumes"]), read, "directory")
        expectConforms(try await run(read, ["paths": ["notes/a.txt", "resumes/sam.pdf"]]), read, "batch")

        let search = FileSearchTool(rootPath: root)
        let files = expectConforms(
            try await run(search, ["pattern": "*", "target": "files", "path": "resumes"]), search, "files")
        let entries = files.value(atPath: "entries")?.arrayValue ?? []
        #expect(entries.count == 2, "\(files.compactJSONString)")
        for entry in entries {
            let path = try #require(entry.value(atPath: "path")?.stringValue)
            #expect(ToolEnvelope.isSuccess(try await run(read, ["path": path])), "entry path \(path) is not readable")
        }
        expectConforms(try await run(search, ["pattern": "alpha"]), search, "content")
        expectConforms(try await run(search, ["pattern": "nothing-matches-this"]), search, "no content matches")

        let tree = FileTreeTool(rootPath: root)
        expectConforms(try await run(tree, [:]), tree)

        let edit = FileEditTool(rootPath: root)
        expectConforms(
            try await run(edit, ["path": "notes/a.txt", "old_string": "beta", "new_string": "gamma"]), edit)

        let copy = FileCopyTool(rootPath: root)
        let copied = expectConforms(
            try await run(copy, ["source": "notes/a.txt", "destination": "notes/b.txt"]), copy)

        let history = FileOperationHistoryTool(rootPath: root, journal: env.journal)
        expectConforms(try await env.call(history, #"{"limit": 5}"#, sessionId: session), history)

        let undo = FileUndoTool(rootPath: root, journal: env.journal)
        let operation = try #require(copied.value(atPath: "operation_id")?.stringValue)
        expectConforms(
            try await env.call(undo, FileHistoryTestEnv.json(["operation_id": operation]), sessionId: session), undo)

        try "Reach me at jane.doe@example.com or 415-555-0123.\n".write(
            to: root.appendingPathComponent("pii.txt"), atomically: true, encoding: .utf8)
        let detect = DetectPIITool(rootPath: root)
        expectConforms(try await run(detect, ["path": "pii.txt"]), detect)
        let redact = RedactFileTool(rootPath: root)
        expectConforms(try await run(redact, ["path": "pii.txt"]), redact)
    }

    /// A workflow folder outside the working folder: `file_search` paths
    /// must be absolute so `file_read` opens them, not relative to the
    /// wrong root (the resume screener read every file as missing).
    @Test func fileSearchPathsOutsideTheRootAreAbsoluteAndReadable() async throws {
        let root = tmpDir("root")
        let outside = tmpDir("outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try "resume one".write(to: outside.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "resume two".write(
            to: outside.appendingPathComponent("nested/two.txt"), atomically: true, encoding: .utf8)

        let search = FileSearchTool(rootPath: root)
        let read = FileReadTool(rootPath: root)
        try await ChatExecutionContext.$currentWorkflowRunId.withValue(UUID()) {
            try await ChatExecutionContext.$workflowGrantedPaths.withValue([outside]) {
                let envelope = try await search.execute(
                    argumentsJSON: FileHistoryTestEnv.json(["pattern": "*.txt", "target": "files", "path": outside.path]))
                let output = expectConforms(envelope, search, "outside root")
                let paths = (output.value(atPath: "entries")?.arrayValue ?? []).compactMap {
                    $0.value(atPath: "path")?.stringValue
                }
                #expect(paths.count == 2, "\(output.compactJSONString)")
                for path in paths {
                    #expect(path.hasPrefix("/"), "\(path) is not absolute")
                    let opened = try await read.execute(argumentsJSON: FileHistoryTestEnv.json(["path": path]))
                    #expect(ToolEnvelope.isSuccess(opened), "\(path): \(opened)")
                }
            }
        }

        try "inside".write(to: root.appendingPathComponent("in.txt"), atomically: true, encoding: .utf8)
        let inside = expectConforms(
            try await search.execute(argumentsJSON: #"{"pattern": "*.txt", "target": "files"}"#), search, "inside root")
        #expect(inside.value(atPath: "entries.0.path")?.stringValue == "in.txt")
    }

    @Test func gitToolsReturnText() async throws {
        let repo = tmpDir("git")
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path, "-c", "user.name=Test", "-c", "user.email=test@example.com"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        try git("init", "-q")
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git("add", "a.txt")
        try git("commit", "-q", "-m", "first")
        try "two\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let status = GitStatusTool(rootPath: repo)
        expectConforms(try await status.execute(argumentsJSON: "{}"), status)
        let diff = GitDiffTool(rootPath: repo)
        expectConforms(try await diff.execute(argumentsJSON: "{}"), diff)
        let log = GitLogTool(rootPath: repo)
        expectConforms(try await log.execute(argumentsJSON: "{}"), log)
    }

    // MARK: - Other built-ins

    @Test func calculatorAndCurrentTimeReturnWhatTheirSchemasSay() async throws {
        let calculator = CalculatorTool()
        expectConforms(try await calculator.execute(argumentsJSON: #"{"expression": "2 + 3 * 4"}"#), calculator)
        let time = CurrentTimeTool()
        expectConforms(try await time.execute(argumentsJSON: "{}"), time)
    }

    @Test func databaseToolsReturnWhatTheirSchemasSay() async throws {
        try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            func call(_ tool: any OsaurusTool, _ args: [String: Any], _ label: String = "") async throws -> JSONValue {
                expectConforms(try await tool.execute(argumentsJSON: FileHistoryTestEnv.json(args)), tool, label)
            }
            try await call(
                DBCreateTableTool(),
                [
                    "name": "candidates", "purpose": "schema contract",
                    "columns": [["name": "name", "type": "TEXT"], ["name": "score", "type": "INTEGER"]],
                ])
            try await call(DBInsertTool(), ["table": "candidates", "row": ["name": "Jane", "score": 8]], "one row")
            try await call(
                DBInsertTool(),
                ["table": "candidates", "rows": [["name": "Sam", "score": 5], ["name": "Ana", "score": 9]]],
                "rows")
            try await call(DBUpdateTool(), ["table": "candidates", "set": ["score": 6], "where": ["name": "Sam"]])
            let query = try await call(DBQueryTool(), ["sql": "SELECT name, score FROM candidates ORDER BY score"])
            #expect(query.value(atPath: "rows")?.arrayValue?.count == 3, "\(query.compactJSONString)")
            try await call(DBSchemaTool(), [:])
            try await call(
                DBDefineViewTool(),
                [
                    "name": "top_candidates", "sql": "SELECT name FROM candidates WHERE score > 7",
                    "render_hint": "table", "refresh": "manual",
                ])
            try await call(DBRunViewTool(), ["name": "top_candidates"])
            try await call(DBListViewsTool(), [:])
            try await call(DBDropViewTool(), ["name": "top_candidates"])
            try await call(DBDeleteTool(), ["table": "candidates", "where": ["name": "Ana"]])
        }
    }
}
