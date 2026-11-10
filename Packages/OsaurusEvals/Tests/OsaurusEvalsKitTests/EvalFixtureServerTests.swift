//
//  EvalFixtureServerTests.swift
//  OsaurusEvalsKitTests
//
//  The loopback API Architect cases call: cursor and Link paging, bearer
//  auth, fail-first endpoints, keyed records, request counting, and a
//  decode smoke over the committed Architect suite.
//

import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

struct EvalFixtureServerTests {

    private func api(_ json: String) throws -> EvalFixtureAPI {
        try JSONDecoder().decode(EvalFixtureAPI.self, from: Data(json.utf8))
    }

    private func get(_ url: String, bearer: String? = nil) async throws -> (Int, JSONValue, [String: String]) {
        var request = URLRequest(url: URL(string: url)!)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        let headers = Dictionary(
            http.allHeaderFields.map { ("\($0.key)".lowercased(), "\($0.value)") }, uniquingKeysWith: { a, _ in a })
        return (http.statusCode, try JSONDecoder().decode(JSONValue.self, from: data), headers)
    }

    @Test func cursorPagesRequireTheBearerToken() async throws {
        let server = try EvalFixtureServer(
            api(
                """
                {"routes": [{"path": "/v1/issues", "bearer": "tok", "pages": [{"items": [1]}, {"items": [2]}]}]}
                """))
        let base = try await server.start()
        defer { server.stop() }

        let (denied, _, _) = try await get("\(base)/v1/issues")
        #expect(denied == 401)
        let (status, first, _) = try await get("\(base)/v1/issues", bearer: "tok")
        #expect(status == 200)
        #expect(first.objectValue?["next_cursor"] == .string("c1"))
        let (_, last, _) = try await get("\(base)/v1/issues?cursor=c1", bearer: "tok")
        #expect(last.objectValue?["items"] == .array([.number(2)]))
        #expect(last.objectValue?["next_cursor"] == .null)
        #expect(server.requestCounts()["/v1/issues"] == 3)
    }

    @Test func linkPagingAndFailFirstAndKeyedRecords() async throws {
        let server = try EvalFixtureServer(
            api(
                """
                {"routes": [
                  {"path": "/v1/repos", "paging": "link", "pages": [[1], [2]]},
                  {"path": "/v1/rates", "failFirst": 2, "failStatus": 429, "body": {"usd": 1}},
                  {"path": "/v1/orders/*", "byKey": {"A1": {"total": 5}}}
                ]}
                """))
        let base = try await server.start()
        defer { server.stop() }

        let (_, _, headers) = try await get("\(base)/v1/repos")
        #expect(headers["link"]?.contains("page=2") == true)
        let (_, _, lastHeaders) = try await get("\(base)/v1/repos?page=2")
        #expect(lastHeaders["link"] == nil)

        #expect(try await get("\(base)/v1/rates").0 == 429)
        #expect(try await get("\(base)/v1/rates").0 == 429)
        #expect(try await get("\(base)/v1/rates").0 == 200)

        #expect(try await get("\(base)/v1/orders/A1").1.objectValue?["total"] == .number(5))
        #expect(try await get("\(base)/v1/orders/B9").0 == 404)
    }

    @Test func architectSuiteDecodes() throws {
        let suite = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Suites/Architect")
        let files = try FileManager.default.contentsOfDirectory(at: suite, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(!files.isEmpty)
        for file in files {
            let testCase = try JSONDecoder().decode(EvalCase.self, from: Data(contentsOf: file))
            #expect(testCase.expect.architect != nil, "\(file.lastPathComponent) has no architect expectation")
            guard let seed = testCase.expect.architect?.seed else { continue }
            let json = seed.definition.compactJSONString
                .replacingOccurrences(of: "{{fixture.base_url}}", with: "http://127.0.0.1:8080")
            let definition = try JSONDecoder().decode(WorkflowDefinition.self, from: Data(json.utf8))
            let issues = WorkflowValidator.validate(definition, allowPlaceholders: false)
            #expect(issues.isEmpty, "\(file.lastPathComponent) seed: \(issues.map(\.message))")
        }
    }
}
