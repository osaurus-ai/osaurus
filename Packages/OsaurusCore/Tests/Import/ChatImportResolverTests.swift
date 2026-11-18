//
//  ChatImportResolverTests.swift
//  OsaurusCoreTests
//
//  Chat import's fetch-and-resolve half: link scanning, GitHub link
//  shapes, install-link decoding, typed refusals, markdown-first page
//  fetches, GitHub archives, and which text values are grounded in.
//  Every network call goes through `SafeImportFetcher.transportOverride`.
//

import Foundation
import Testing

@testable import OsaurusCore

private struct Route: Sendable {
    var status = 200
    var contentType = "text/markdown"
    var body: Data
}

private func transport(_ routes: [String: Route]) -> SafeImportFetcher.Transport {
    { request, _ in
        let url = request.url!
        let route = routes[url.absoluteString] ?? Route(status: 404, contentType: "text/plain", body: Data())
        return SafeImportFetcher.Response(
            requestedURL: url, finalURL: url, status: route.status, contentType: route.contentType, data: route.body)
    }
}

private func text(_ s: String, type: String = "text/markdown") -> Route {
    Route(contentType: type, body: Data(s.utf8))
}

/// Zips `files` under one top folder, the way GitHub archives look.
private func archive(_ files: [String: String]) throws -> Data {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("import-fixture-\(UUID().uuidString)")
    let top = root.appendingPathComponent("repo-main")
    defer { try? fm.removeItem(at: root) }
    for (path, contents) in files {
        let url = top.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    let zip = root.appendingPathComponent("repo.zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--keepParent", top.path, zip.path]
    try process.run()
    process.waitUntilExit()
    return try Data(contentsOf: zip)
}

private let tempoSkill = """
    ---
    name: tempo
    description: Pay and get paid with Tempo stablecoins.
    ---
    # Tempo

    Use the Tempo CLI to send payments.
    """

struct ChatImportLinkTests {

    @Test
    func scanner_classifiesEveryLinkShape() {
        let links = ChatImportLinkScanner.links(
            in: "Read https://tempo.xyz/SKILL.md, then http://old.example/x and git@github.com:o/r.git. "
                + "Also github.com/acme/skills and mailto:me@example.com")
        let kinds = links.map(\.kind)
        #expect(kinds.contains(.web(URL(string: "https://tempo.xyz/SKILL.md")!)))
        #expect(kinds.contains(.insecure))
        #expect(kinds.contains(.ssh))
        #expect(links.contains { $0.raw == "github.com/acme/skills" })
        #expect(!links.contains { $0.raw.hasPrefix("mailto") })
        #expect(links.first?.raw == "https://tempo.xyz/SKILL.md", "trailing punctuation is trimmed")
    }

    @Test
    func scanner_marksEndpointsInsideAConfigBlockAsValues() {
        let text = """
            Read https://tempo.xyz/SKILL.md and use this server:
            {"mcpServers":{"context7":{"type":"http","url":"https://mcp.context7.com/mcp?key=abc"}}}
            """
        let values = ChatImportLinkScanner.serverValueLinks(in: text)
        #expect(values == ["https://mcp.context7.com/mcp?key=abc"])
        #expect(ChatImportLinkScanner.serverValueLinks(in: "Read https://tempo.xyz/SKILL.md").isEmpty)
        let command = "The README says:\nclaude mcp add --transport http linear https://mcp.linear.app/mcp\nDocs: https://linear.app/docs/mcp"
        #expect(ChatImportLinkScanner.serverValueLinks(in: command) == ["https://mcp.linear.app/mcp"])
    }

    @Test
    func resolve_neverFetchesAnEndpointWrittenInsidePastedConfig() async {
        let pasted = #"{"mcpServers":{"context7":{"type":"http","url":"https://mcp.context7.com/mcp"}}}"#
        let bundle = await ChatImportSourceResolver.resolve(source: pasted, userText: "Use this MCP server: \(pasted)")
        #expect(bundle.sources == ["https://mcp.context7.com/mcp"])
        #expect(bundle.documents.count == 1)
        #expect(bundle.documents.first?.origin == "your message")
        #expect(bundle.refusals.isEmpty, "no fetch was attempted, so there is no fetch error to report")
    }

    @Test
    func github_parsesRepoTreeBlobAndRaw() throws {
        let repo = try #require(GitHubLocation.parse(URL(string: "https://github.com/acme/skills.git")!))
        #expect(repo.repo == "skills" && repo.kind == .repo && repo.candidates == [.init(ref: nil, path: "")])

        let tree = try #require(GitHubLocation.parse(URL(string: "https://github.com/acme/skills/tree/feature/x/pdf")!))
        #expect(tree.kind == .tree)
        #expect(tree.candidates.first == .init(ref: "feature", path: "x/pdf"))
        #expect(tree.candidates.contains(.init(ref: "feature/x", path: "pdf")), "refs with slashes are tried")

        let raw = try #require(GitHubLocation.parse(URL(string: "https://raw.githubusercontent.com/a/b/main/SKILL.md")!))
        #expect(raw.kind == .raw && raw.tail == ["main", "SKILL.md"])

        #expect(GitHubLocation.parse(URL(string: "https://github.com/settings/tokens")!) == nil)
        #expect(GitHubLocation.parse(URL(string: "https://github.com/acme/skills/issues/3")!) == nil)
    }

    @Test
    func decoding_readsPercentAndBase64Payloads() {
        let config = #"{"command":"npx","args":["-y","@acme/mcp"]}"#
        let base64 = Data(config.utf8).base64EncodedString()
        let cursor = "cursor://anysphere.cursor-deeplink/mcp/install?name=acme&config=\(base64)"
        let payloads = ChatImportDecoding.payloads(in: cursor)
        #expect(payloads.contains { $0.contains("\"mcpServers\"") && $0.contains("\"acme\"") && $0.contains("@acme/mcp") })

        let encoded = config.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let vscode = "vscode:mcp/install?\(encoded)"
        #expect(ChatImportDecoding.payloads(in: vscode).contains { $0.contains("@acme/mcp") })

        #expect(ChatImportDecoding.payloads(in: "https://example.com/?q=short").isEmpty)
    }

    @Test
    func refusals_areTypedWithFixedMessages() {
        let azure = ChatImportSourceResolver.refusal(for: URL(string: "https://dev.azure.com/org/p")!, raw: "a")
        #expect(azure == .azureDevOps("a"))
        let card = ChatImportSourceResolver.refusal(
            for: URL(string: "https://agent.example/.well-known/agent.json")!, raw: "b")
        #expect(card == .a2aAgentCard("b"))
        #expect(ChatImportSourceResolver.refusal(for: URL(string: "https://example.com/setup")!, raw: "c") == nil)
        let source = "git@github.com:acme/zzq-secret.git"
        for refusal in [ChatImportRefusal.sshRemote(source), .privateOrMissingRepo(source), .nonStoreTemplate(source)] {
            #expect(!refusal.message.contains("zzq-secret"), "messages never echo the source")
        }
    }
}

struct ChatImportResolveTests {

    @Test
    func skillPage_becomesOneDocumentAndAFastPathSkill() async {
        let bundle = await SafeImportFetcher.$transportOverride.withValue(
            transport(["https://tempo.xyz/SKILL.md": text(tempoSkill)])
        ) {
            await ChatImportSourceResolver.resolve(
                source: "https://tempo.xyz/SKILL.md", userText: "Read https://tempo.xyz/SKILL.md and set up tempo")
        }
        #expect(bundle.refusals.isEmpty)
        #expect(bundle.documents.count == 1)
        #expect(bundle.documents.first?.origin == "https://tempo.xyz/SKILL.md")
        let fast = ChatImportFastPaths.run(bundle)
        #expect(fast.items.map(\.kind) == [.skill])
        #expect(fast.items.first?.name.lowercased() == "tempo")
        #expect(fast.consumedDocumentIds == ["d1"])
    }

    @Test
    func htmlPage_prefersTheMarkdownVariant() async {
        let routes = [
            "https://docs.example/setup": text("<html><body><p>Nav</p></body></html>", type: "text/html"),
            "https://docs.example/setup.md": text("# Setup\n\nRun `npx -y @acme/mcp`."),
        ]
        let bundle = await SafeImportFetcher.$transportOverride.withValue(transport(routes)) {
            await ChatImportSourceResolver.resolve(source: "https://docs.example/setup", userText: nil)
        }
        #expect(bundle.documents.first?.text.contains("npx -y @acme/mcp") == true)
        #expect(bundle.documents.first?.text.contains("<html>") == false)
    }

    @Test
    func userMessage_isWhatValuesGroundIn() async {
        let message = "Add this:\n```json\n{\"mcpServers\": {\"acme\": {\"url\": \"https://mcp.acme.dev/mcp\"}}}\n```"
        let bundle = await SafeImportFetcher.$transportOverride.withValue(transport([:])) {
            await ChatImportSourceResolver.resolve(source: "the acme server", userText: message)
        }
        #expect(bundle.userText == message)
        #expect(bundle.documents.first?.origin == "your message")
        #expect(!bundle.groundingText.contains("the acme server"))
    }

    @Test
    func refusedSources_installNothing() async {
        let routes = ["https://github.com/acme/private/archive/HEAD.zip": Route(status: 404, body: Data())]
        let bundle = await SafeImportFetcher.$transportOverride.withValue(transport(routes)) {
            await ChatImportSourceResolver.resolve(
                source: "",
                userText: "set up git@github.com:acme/x.git and http://plain.example/x and "
                    + "https://github.com/acme/private and osaurus://templates-import?url=https://evil.example/t.json")
        }
        let codes = Set(bundle.refusals.map(\.code))
        #expect(codes == ["ssh_remote", "insecure_url", "private_or_missing_repo", "non_store_template"])
        #expect(bundle.documents.allSatisfy { $0.origin != "http://plain.example/x" })
        #expect(bundle.storeTemplateLinks.isEmpty)
    }

    @Test
    func otherOsaurusLinks_areNotTemplates() async {
        let bundle = await ChatImportSourceResolver.resolve(source: "", userText: "open osaurus://agents/open?id=1")
        #expect(!bundle.refusals.contains { $0.code == "non_store_template" })
    }

    @Test
    func githubTree_downloadsTheArchiveAndKeepsSkillFolders() async throws {
        let zip = try archive([
            "skills/pdf/SKILL.md": "---\nname: pdf\ndescription: Work with PDFs.\n---\nUse scripts/fill.py.",
            "skills/pdf/scripts/fill.py": "print('fill')",
            "skills/other/SKILL.md": "---\nname: other\ndescription: Other.\n---\nOther.",
            "README.md": "# Repo",
        ])
        let routes = [
            "https://github.com/acme/skills/archive/main.zip": Route(contentType: "application/zip", body: zip)
        ]
        let bundle = await SafeImportFetcher.$transportOverride.withValue(transport(routes)) {
            await ChatImportSourceResolver.resolve(source: "https://github.com/acme/skills/tree/main/skills/pdf", userText: nil)
        }
        defer { bundle.cleanUp() }
        #expect(bundle.refusals.isEmpty)
        #expect(bundle.skillPackages.count == 1, "the link named one folder")
        let package = try #require(bundle.skillPackages.first)
        #expect(FileManager.default.fileExists(atPath: package.directory.appendingPathComponent("scripts/fill.py").path))
        let items = ChatImportFastPaths.run(bundle).items
        #expect(items.first?.name.lowercased() == "pdf")
        #expect(items.first?.warnings.contains { $0.contains("script") } == true)
    }
}
