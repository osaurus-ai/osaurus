//
//  BundledWorkflowContractTests.swift
//  OsaurusCoreTests
//
//  The bundled default workflows and prepared asks against the real tools
//  they call: each passes the strict validator, every tool step sends only
//  arguments its tool declares, and each code step reads the result shape
//  its tool really returns. Eval fixtures alone let a step that read the
//  wrong field pass.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Bundled workflow contracts")
@MainActor
struct BundledWorkflowContractTests {

    private static func template(_ name: String) throws -> Template {
        try #require(TeamSeeder.loadBundled(name), "\(name)")
    }

    private static func codeSource(_ name: String, node id: String) throws -> String {
        let def = try #require(try template(name).workflow, "\(name)")
        let node = try #require(def.node(id), "\(name)/\(id)")
        guard case .code(let spec) = node.kind else {
            Issue.record("\(name)/\(id) is not a code step")
            return ""
        }
        return spec.source
    }

    private static func runCode(_ name: String, node id: String, input: JSONValue) async throws -> JSONValue {
        let result = try await CodeNodeExecutor.run(
            source: try codeSource(name, node: id), input: input,
            grants: CodeNodeGrants(allowedHosts: [], secrets: [:], workspace: nil),
            timeout: 10, memoryLimitMB: CodeNodeExecutor.defaultMemoryLimitMB,
            fetcher: { _ in throw URLError(.notConnectedToInternet) })
        return result.output
    }

    private static func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    // MARK: - Graph and arguments

    @Test
    func everyBundledWorkflow_passesTheStrictValidator() throws {
        for (name, template) in try BundledTeamReferenceTests.bundledWorkflowResources() {
            let def = try #require(template.workflow, "\(name)")
            let issues = WorkflowValidator.validate(def, allowPlaceholders: false)
            #expect(issues.isEmpty, "\(name): \(issues.map(\.message))")
        }
    }

    /// Each tool step binds only fields its tool's published output schema
    /// lists, and none leaves `output_schema` as `{}` for a tool that
    /// publishes nothing.
    @Test
    func everyBundledWorkflow_readsOnlyFieldsItsToolsReturn() throws {
        for (name, template) in try BundledTeamReferenceTests.bundledWorkflowResources() {
            let def = try #require(template.workflow, "\(name)")
            let warnings = WorkflowValidator.warnings(def, toolOutputSchema: WorkflowToolCatalog.publishedOutputSchema)
                .filter { $0.message.contains("output schema") || $0.message.contains("returns no") }
            #expect(warnings.isEmpty, "\(name): \(warnings.map(\.message))")
        }
    }

    @Test
    func everyBundledToolStep_sendsOnlyArgumentsItsToolDeclares_andEveryRequiredOne() throws {
        FolderToolManager.shared.ensureFolderToolsRegistered()
        for (name, template) in try BundledTeamReferenceTests.bundledWorkflowResources() {
            for (node, spec) in BundledTeamReferenceTests.toolSteps(template) {
                let schema = try #require(
                    ToolRegistry.shared.parametersForTool(name: spec.tool.name)?.objectValue,
                    "\(name)/\(node.id): \(spec.tool.name) is not a registered tool")
                let declared = Set(schema["properties"]?.objectValue?.keys.map { $0 } ?? [])
                let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
                let sent = node.input.fieldNames
                #expect(
                    sent.isSubset(of: declared),
                    "\(name)/\(node.id) sends \(sent.subtracting(declared).sorted()) to \(spec.tool.name)")
                #expect(
                    required.isSubset(of: sent),
                    "\(name)/\(node.id) leaves out \(required.subtracting(sent).sorted()) for \(spec.tool.name)")
            }
        }
    }

    // MARK: - Code steps on real result shapes

    /// `web_search` per query, collected by the map: the pages to open
    /// alternate between the queries' results, a repeated URL is opened
    /// once, at most five are opened, and a failed query's error loses its
    /// "tool failed (kind):" prefix.
    @Test
    func researchBrief_picksPagesAcrossTheQueries_andKeepsTheSearchErrors() async throws {
        let search = try Self.decode(
            """
            {"count": 2, "failed": [{"index": 2, "error": "web_search failed (not_found): No results from any search provider. Try a broader query."}],
             "items": [
               {"query": "q1", "results": [
                 {"url": "https://a.test/1", "title": "A1", "snippet": "a one"},
                 {"url": "https://a.test/2", "title": "A2", "snippet": "a two"},
                 {"url": "https://a.test/3", "title": "A3", "snippet": "a three"},
                 {"url": "https://a.test/4", "title": "A4", "snippet": "a four"}]},
               {"query": "q2", "results": [
                 {"url": "https://a.test/1", "title": "dup", "snippet": "dup"},
                 {"url": "https://b.test/1", "title": "B1", "snippet": "b one"}]},
               null]}
            """)
        let out = try await Self.runCode(
            "default-workflow-research-brief", node: "pick", input: .object(["search": search]))
        let targets = try #require(out.objectValue?["targets"]?.arrayValue)
        #expect(
            targets.compactMap { $0.objectValue?["url"]?.stringValue }
                == ["https://a.test/1", "https://a.test/2", "https://b.test/1", "https://a.test/3", "https://a.test/4"])
        #expect(targets.first?.objectValue?["snippet"] == .string("a one"))
        #expect(
            out.objectValue?["errors"]
                == .array([.string("No results from any search provider. Try a broader query.")]))
    }

    /// `search_and_extract` per picked page: an opened page carries its
    /// `markdown`; a page that could not be opened, whether its call failed
    /// or it came back unread, keeps its search snippet.
    @Test
    func researchBrief_readsOpenedPages_andFallsBackToTheSnippet() async throws {
        let targets = try Self.decode(
            """
            [{"url": "https://a.test/1", "title": "One", "snippet": "short one"},
             {"url": "https://b.test/2", "title": "Two", "snippet": "only a snippet"},
             {"url": "https://c.test/3", "title": "Three", "snippet": "blocked"},
             {"url": "https://d.test/4", "title": "Four", "snippet": ""}]
            """)
        let extract = try Self.decode(
            """
            {"count": 3, "failed": [{"index": 2, "error": "search_and_extract failed (execution_error): No page content"}],
             "items": [
               {"mode": "direct_url", "results": [{"url": "https://a.test/1", "title": "One, full", "extracted": true,
                 "markdown": "# One\\nThe full page.", "extract_status": "ok"}]},
               {"mode": "direct_url", "results": [{"url": "https://b.test/2", "extracted": false, "extract_status": "challenge"}]},
               null, null]}
            """)
        let out = try await Self.runCode(
            "default-workflow-research-brief", node: "pages",
            input: .object(["targets": targets, "errors": .array([]), "extract": extract]))
        let pages = try #require(out.objectValue?["pages"]?.arrayValue)
        #expect(pages.count == 3, "a page with neither text nor snippet is left out")
        #expect(pages[0].objectValue?["text"] == .string("# One\nThe full page."))
        #expect(pages[0].objectValue?["title"] == .string("One, full"))
        #expect(pages[0].objectValue?["read"] == .bool(true))
        #expect(pages[1].objectValue?["text"] == .string("only a snippet"))
        #expect(pages[1].objectValue?["read"] == .bool(false))
        #expect(pages[2].objectValue?["text"] == .string("blocked"))
        #expect(out.objectValue?["search_problem"] == .string(""), "findings exist, so there is no problem to report")
    }

    /// With no pages at all, the note's text is the search's own error, not
    /// advice a model makes up.
    @Test
    func researchBrief_withNothingFound_reportsTheFirstSearchError() async throws {
        let error = "No results from any search provider. Try a broader query."
        let out = try await Self.runCode(
            "default-workflow-research-brief", node: "pages",
            input: .object([
                "targets": .array([]), "errors": .array([.string(error)]),
                "extract": .object(["items": .array([]), "count": .number(0), "failed": .array([])]),
            ]))
        #expect(out.objectValue?["pages"] == .array([]))
        #expect(out.objectValue?["search_problem"] == .string("The web search did not work: " + error))
        let instructions = try #require(
            try Self.template("default-workflow-research-brief").workflow?.node("write").flatMap { node -> String? in
                guard case .inference(let spec) = node.kind else { return nil }
                return spec.instructions
            })
        #expect(!instructions.contains("Settings"), "the writer is never handed a fix to repeat")
    }

    /// The sources are the read pages the note cites, in the order cited, so
    /// a URL the model made up never lands in the list.
    @Test
    func researchBrief_listsTheReadPagesTheNoteCites_inOrder() async throws {
        let pages: JSONValue = .array(
            ["https://a.test/1/", "https://b.test/2", "https://c.test/3"].map { .object(["url": .string($0)]) })
        let note = "Short answer [https://B.test/2]. More [https://a.test/1]. Again [https://b.test/2]. [https://x.test]"
        let out = try await Self.runCode(
            "default-workflow-research-brief", node: "sources", input: .object(["note": .string(note), "pages": pages]))
        #expect(out.objectValue?["sources"] == .array([.string("https://b.test/2"), .string("https://a.test/1/")]))
        let none = try await Self.runCode("default-workflow-research-brief", node: "sources", input: .object([:]))
        #expect(none.objectValue?["sources"] == .array([]))
    }

    /// `mail_list` returns headers with camelCase `mailboxPath`; automated
    /// senders are left out and at most five are read.
    @Test
    func mailSteps_pickPeopleByIdAndMailbox_andTrimTheBodies() async throws {
        let messages: [JSONValue] = (0..<7).map { i in
            .object([
                "id": .string("<m\(i)@acme.test>"), "subject": .string("S\(i)"),
                "sender": .string("Person \(i) <p\(i)@acme.test>"), "dateReceived": .string("2026-11-05T09:00:00Z"),
                "isRead": .bool(false), "isFlagged": .bool(false), "mailboxPath": .string("Work/INBOX"),
            ])
        }
        let automated: JSONValue = .object([
            "id": .string("<n@x.test>"), "subject": .string("Weekly"), "sender": .string("noreply@x.test"),
            "mailboxPath": .string("INBOX"),
        ])
        let unfiled: JSONValue = .object(["id": .string("<u@acme.test>"), "sender": .string("Una <u@acme.test>")])
        let body = String(repeating: "word  \n", count: 400)

        for name in ["default-workflow-mail-triage", "prepared-ask-courier-reply"] {
            let picked = try await Self.runCode(
                name, node: "pick",
                input: .object(["mail": .object(["messages": .array([automated, unfiled] + messages)])]))
            let items = try #require(picked.objectValue?["items"]?.arrayValue, "\(name)")
            #expect(items.count == 5, "\(name)")
            #expect(
                items.first == .object(["id": .string("<u@acme.test>"), "mailbox_path": .string("INBOX")]), "\(name)")
            #expect(items[1].objectValue?["mailbox_path"] == .string("Work/INBOX"), "\(name)")
            #expect(!items.contains { $0.objectValue?["id"] == .string("<n@x.test>") }, "\(name) skips noreply")

            let read: JSONValue = .object([
                "message": .object([
                    "id": .string("<m0@acme.test>"), "sender": .string("Person 0"), "subject": .string("S0"),
                    "content": .string(body), "attachments": .array([]),
                ])
            ])
            let trimmed = try await Self.runCode(
                name, node: "trim",
                input: .object([
                    "bodies": .object(["items": .array([read]), "count": .number(1), "failed": .array([])])
                ]))
            let excerpts = try #require(trimmed.objectValue?["excerpts"]?.arrayValue, "\(name)")
            #expect(excerpts.count == 1, "\(name)")
            let excerpt = try #require(excerpts.first?.objectValue?["excerpt"]?.stringValue, "\(name)")
            #expect(excerpt.count == 1200, "\(name)")
            #expect(!excerpt.contains("\n") && !excerpt.contains("  "), "\(name)")
        }
    }

    @Test
    func meetingPrep_saysNotFound_onAnEmptyCalendar() async throws {
        let empty = try await Self.runCode(
            "default-workflow-meeting-prep", node: "who",
            input: .object(["events": .object(["events": .array([])])]))
        #expect(empty.objectValue?["found"] == .bool(false))

        let event = try await Self.runCode(
            "default-workflow-meeting-prep", node: "who",
            input: .object([
                "events": .object([
                    "events": .array([
                        .object([
                            "title": .string("Acme renewal"),
                            "attendees": .array([.object(["name": .string("Dana Lee")])]),
                        ])
                    ])
                ])
            ]))
        #expect(event.objectValue?["found"] == .bool(true))
        #expect(event.objectValue?["title"] == .string("Acme renewal"))
        #expect(event.objectValue?["person"] == .string("Dana Lee"))
    }

    /// The edges skip both searches when there is no event.
    @Test
    func meetingPrep_searchesOnlyWhenAnEventWasFound() throws {
        let def = try #require(try Self.template("default-workflow-meeting-prep").workflow)
        for target in ["notes", "mail"] {
            let edge = try #require(def.edges.first { $0.from == "who" && $0.to == target })
            #expect(edge.when?.evaluate(.object(["found": .bool(false)])) == false, "\(target)")
            #expect(edge.when?.evaluate(.object(["found": .bool(true)])) == true, "\(target)")
        }
        #expect(def.edges.contains { $0.from == "who" && $0.to == "prep" })
        #expect(def.node("prep")?.join == .any)
    }

    @Test
    func gitWeekSteps_sendAnISOTimeSevenDaysBack() async throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let week: TimeInterval = 7 * 86400
        for name in ["prepared-ask-builder-week", "default-workflow-repo-digest"] {
            let before = Date()
            let out = try await Self.runCode(name, node: "range", input: .object([:]))
            let after = Date()
            let since = try #require(out.objectValue?["since"]?.stringValue, "\(name)")
            let date = try #require(iso.date(from: since), "\(name): \(since)")
            #expect(date >= before.addingTimeInterval(-week - 1), "\(name)")
            #expect(date <= after.addingTimeInterval(-week + 1), "\(name)")
        }
    }

    @Test
    func newDownload_keepsOnlyNamedFiles_andAtMostEight() async throws {
        let files: [JSONValue] = [.string(""), .number(3)] + (0..<10).map { .string("file\($0).pdf") }
        let out = try await Self.runCode(
            "default-workflow-new-download", node: "pick", input: .object(["files": .array(files)]))
        let picked = try #require(out.objectValue?["files"]?.arrayValue)
        #expect(picked.count == 8)
        #expect(picked.first == .string("file0.pdf"))
        let none = try await Self.runCode("default-workflow-new-download", node: "pick", input: .object([:]))
        #expect(none.objectValue?["files"] == .array([]))
    }

    // MARK: - git_log

    @Test
    func gitLogArguments_capTheCount_andAddSinceAndStatOnlyWhenAsked() {
        let base = ["log", "--no-color", "--date=short", "--pretty=format:%h %ad %an%n    %s", "-n"]
        #expect(GitLogTool.arguments(since: nil, limit: nil, stat: false) == base + ["30"])
        #expect(GitLogTool.arguments(since: "  ", limit: 0, stat: false) == base + ["1"])
        #expect(
            GitLogTool.arguments(since: "2026-11-01T00:00:00.000Z", limit: 500, stat: true)
                == base + ["200", "--since=2026-11-01T00:00:00.000Z", "--stat=100"])
    }

    @Test
    func gitLog_readsARealRepository_andSaysWhenThereAreNoCommits() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("gitlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        try git("init", "-q")
        let tool = GitLogTool(rootPath: repo)
        let empty = try await tool.execute(argumentsJSON: "{}")
        #expect(empty.contains("No commits yet"), "\(empty)")

        try "hello\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git("add", "a.txt")
        try git("-c", "user.name=Dana", "-c", "user.email=d@x.test", "commit", "-q", "-m", "Add greeting")
        let log = try await tool.execute(argumentsJSON: #"{"since": "7 days ago", "stat": true}"#)
        #expect(log.contains("Add greeting"), "\(log)")
        #expect(log.contains("Dana"), "\(log)")
        #expect(log.contains("a.txt"), "--stat lists the file: \(log)")
    }
}
