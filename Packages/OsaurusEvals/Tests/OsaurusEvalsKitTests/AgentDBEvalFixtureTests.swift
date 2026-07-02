//
//  AgentDBEvalFixtureTests.swift
//  OsaurusEvalsKitTests
//
//  VM-free coverage for the Agent DB eval harness additions: the
//  `WorkspaceFile.contentsFromFixture` reference, `fixtures.seedSql`
//  pre-seeding, the richer `DbStateAssertion` matchers, and a decode
//  smoke over the committed `Suites/AgentDB` cases so a schema/JSON drift
//  fails CI instead of silently producing `errored` rows at run time.
//

import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

struct AgentDBEvalFixtureTests {

    // MARK: - New field decoding

    @Test func workspaceFileDecodesFixtureReference() throws {
        let json = """
            {
              "id": "agentdb.example",
              "domain": "agent_loop",
              "query": "import it",
              "fixtures": {
                "agentCapabilities": { "dbEnabled": true },
                "workspaceFiles": [
                  { "path": "commits.csv", "contentsFromFixture": "commits-500.csv" }
                ]
              },
              "expect": { "agentLoop": {} }
            }
            """
        let testCase = try JSONDecoder().decode(EvalCase.self, from: Data(json.utf8))
        let file = try #require(testCase.fixtures.workspaceFiles?.first)
        #expect(file.path == "commits.csv")
        #expect(file.contents == nil)
        #expect(file.contentsFromFixture == "commits-500.csv")
    }

    @Test func workspaceFileStillDecodesInlineContents() throws {
        let json = """
            { "path": "a.txt", "contents": "hello\\n" }
            """
        let file = try JSONDecoder().decode(EvalCase.WorkspaceFile.self, from: Data(json.utf8))
        #expect(file.contents == "hello\n")
        #expect(file.contentsFromFixture == nil)
    }

    @Test func seedSqlAndRicherDbStateDecode() throws {
        let json = """
            {
              "id": "agentdb.seed-example",
              "domain": "agent_loop",
              "query": "compute it",
              "fixtures": {
                "agentCapabilities": { "dbEnabled": true },
                "seedSql": [
                  "CREATE TABLE t (a TEXT, b INTEGER); INSERT INTO t (a,b) VALUES ('x',1);"
                ]
              },
              "expect": {
                "agentLoop": {
                  "dbState": [
                    {
                      "sql": "SELECT a, SUM(b) AS total FROM t GROUP BY a ORDER BY a",
                      "expectRowCountEquals": 1,
                      "expectColumns": ["a", "total"],
                      "expectValues": ["x", "1"]
                    }
                  ]
                }
              }
            }
            """
        let testCase = try JSONDecoder().decode(EvalCase.self, from: Data(json.utf8))
        let seeds = try #require(testCase.fixtures.seedSql)
        #expect(seeds.count == 1)
        #expect(seeds[0].contains("CREATE TABLE t"))

        let assertion = try #require(testCase.expect.agentLoop?.dbState?.first)
        #expect(assertion.expectRowCountEquals == 1)
        #expect(assertion.expectColumns == ["a", "total"])
        #expect(assertion.expectValues == ["x", "1"])
        // The original matchers stay optional and default to nil.
        #expect(assertion.expectRowCountAtLeast == nil)
        #expect(assertion.expectFirstValue == nil)
    }

    // MARK: - Suite decode smoke

    @Test func agentDBSuiteDecodesCleanly() throws {
        let suiteDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OsaurusEvalsKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusEvals
            .appendingPathComponent("Suites/AgentDB", isDirectory: true)

        let suite = try EvalSuite.load(from: suiteDir)
        #expect(suite.decodeFailures.isEmpty, "decode failures: \(suite.decodeFailures)")
        // Floor, not exact: new cases must not break this smoke — only
        // deletions or decode drift should.
        #expect(suite.cases.count >= 12, "AgentDB suite shrank; got \(suite.cases.count)")
        for testCase in suite.cases {
            #expect(testCase.domain == "agent_loop")
            #expect(
                testCase.fixtures.agentCapabilities?.dbEnabled == true,
                "\(testCase.id) must enable dbEnabled"
            )
        }
        // Every fixture a case references must exist on disk under
        // Fixtures/AgentDB so a renamed/missing fixture fails here, not at
        // run time as a confusing "file not found" import error.
        let fixturesDir =
            suiteDir
            .deletingLastPathComponent()  // Suites/
            .deletingLastPathComponent()  // <package>/
            .appendingPathComponent("Fixtures/AgentDB", isDirectory: true)
        for testCase in suite.cases {
            for file in testCase.fixtures.workspaceFiles ?? [] {
                guard let fixture = file.contentsFromFixture else { continue }
                let path = fixturesDir.appendingPathComponent(fixture).path
                #expect(
                    FileManager.default.fileExists(atPath: path),
                    "\(testCase.id) references missing fixture \(fixture)"
                )
            }
        }
    }
}
