//
//  WorkflowImportResolutionTests.swift
//  OsaurusCoreTests
//
//  An imported workflow on a Mac that names things differently: which MCP
//  server a template server means, the graph rewritten to the local
//  server's tool names, what to offer for a model that is not here, setup
//  hints surviving the file without carrying secrets, and the links that
//  bring a file to the import sheet.
//

import Foundation
import Testing

@testable import OsaurusCore

private enum Fixture {
    static func linearWorkflow(server: String = "Linear") -> WorkflowDefinition {
        var def = WorkflowDefinition()
        def.nodes = [
            WorkflowNode(
                id: "search", name: "Search",
                kind: .tool(ToolNodeSpec(tool: ToolRef(name: "linear_search_issues", server: server))),
                input: .object([:]))
        ]
        return def
    }

    static func template(server: String = "Linear", hints: [MCPServerHint] = []) -> Template {
        Template(
            name: "Triage", summary: "Test", payload: .workflow(linearWorkflow(server: server)), serverHints: hints
        ).sealed()
    }

    static let linearEntry = MCPProviderTemplate.allTemplates.first { $0.id == "linear" }!
}

struct MCPServerResolutionTests {
    @Test
    func namesMatchIgnoringCaseAndPunctuation() {
        #expect(MCPServerResolution.sameName("Linear", "linear"))
        #expect(MCPServerResolution.sameName("Linear (Work)", "linear-work"))
        #expect(!MCPServerResolution.sameName("Linear", "Linear Work"))
        #expect(MCPServerResolution.localName(for: "linear", bindings: [:], connected: ["Linear"]) == "Linear")
        #expect(
            MCPServerResolution.localName(for: "linear", bindings: ["linear": "Work"], connected: ["Linear", "Work"])
                == "Work", "a connected binding wins")
        #expect(MCPServerResolution.localName(for: "x", bindings: [:], connected: ["X", "x!"]) == nil, "ambiguous")
    }

    @Test
    func candidatesFollowBindingThenConfiguredThenDirectoryThenHint() {
        let work = MCPServerResolution.LocalServer(id: UUID(), name: "Linear (work)", url: "https://mcp.linear.app/mcp/")
        let directory = MCPProviderTemplate.allTemplates

        #expect(
            MCPServerResolution.candidate(
                for: "Linear", hint: nil, bindings: [:], servers: [work], connected: ["Linear (work)"],
                directory: directory) == .ready(local: "Linear (work)"),
            "same endpoint as the Directory entry under another name")
        #expect(
            MCPServerResolution.candidate(
                for: "Linear", hint: nil, bindings: [:], servers: [work], connected: [], directory: directory)
                == .existing(work))
        #expect(
            MCPServerResolution.candidate(
                for: "Linear", hint: nil, bindings: [:], servers: [], connected: [], directory: directory)
                == .directory(Fixture.linearEntry))

        let hint = MCPServerHint(name: "Tracker", url: "https://tracker.example.com/mcp")
        #expect(
            MCPServerResolution.candidate(
                for: "Tracker", hint: hint, bindings: [:], servers: [], connected: [], directory: directory)
                == .hint(hint))
        #expect(
            MCPServerResolution.candidate(
                for: "Tracker", hint: nil, bindings: [:], servers: [], connected: [], directory: directory) == .unknown)

        let byHintID = MCPServerHint(name: "Issues", directoryID: "linear")
        #expect(
            MCPServerResolution.candidate(
                for: "Issues", hint: byHintID, bindings: [:], servers: [], connected: [], directory: directory)
                == .directory(Fixture.linearEntry))
    }

    @Test
    func stdioServersMatchByCommandAndArgs() {
        let local = MCPServerResolution.LocalServer(
            id: UUID(), name: "fs", transport: .stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem"])
        let hint = MCPServerHint(
            name: "Files", transport: .stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem"])
        #expect(
            MCPServerResolution.candidate(
                for: "Files", hint: hint, bindings: [:], servers: [local], connected: ["fs"], directory: [])
                == .ready(local: "fs"))
    }

    @Test
    func autoBindingsBindRenamedServers_andKeepExistingBindings() {
        let template = Fixture.template()
        let work = MCPServerResolution.LocalServer(id: UUID(), name: "Linear (work)", url: "https://mcp.linear.app/mcp")
        let directory = MCPProviderTemplate.allTemplates
        #expect(
            MCPServerResolution.autoBindings(
                for: template, bindings: [:], servers: [work], connected: ["Linear (work)"], directory: directory)
                == ["Linear": "Linear (work)"])
        #expect(
            MCPServerResolution.autoBindings(
                for: template, bindings: ["Linear": "Other"], servers: [work], connected: ["Linear (work)"],
                directory: directory) == ["Linear": "Other"])
        #expect(
            MCPServerResolution.autoBindings(
                for: template, bindings: [:], servers: [], connected: ["Linear"], directory: directory).isEmpty,
            "the same name needs no binding")
    }

    @Test
    func bindingsRewriteToolNamesToTheLocalServer() throws {
        let def = Fixture.linearWorkflow()
        let applied = MCPServerResolution.applying(["Linear": "Linear (work)"], to: def)
        guard case .tool(let spec)? = applied.nodes.first?.kind else {
            Issue.record("tool node missing")
            return
        }
        #expect(spec.tool.server == "Linear (work)")
        #expect(spec.tool.name == "linear_work_search_issues")
        #expect(MCPServerResolution.applying(["Linear": "Linear"], to: def) == def)

        let runnable = MCPServerResolution.runnable(Fixture.template(), servers: ["Linear": "Linear (work)"])
        #expect(runnable.workflow?.calledTools.map(\.name) == ["linear_work_search_issues"])
    }

    @MainActor
    @Test
    func setupPassesWhenTheServerRunsHereUnderAnotherName() {
        let template = Fixture.template()
        var env = SetupChecker.Environment(
            registeredToolNames: ["linear_work_search_issues"],
            modelCatalog: ConfigModelReference.Catalog(localModelIds: [], providers: []),
            isPermissionGranted: { _ in true }, bookmarkResolves: { _ in true }, knowledgeCollectionExists: { _ in true })
        env.toolGroups = [.mcpServer("Linear (work)"): ["linear_work_search_issues"]]

        let unbound = SetupChecker.check(template, bindings: InstallBindings(), subjectId: template.id, environment: env)
        #expect(unbound.blocking.contains { $0.kind == .mcpServer && $0.value == "Linear" })

        var bindings = InstallBindings()
        bindings.mcpServers = ["Linear": "Linear (work)"]
        let bound = SetupChecker.check(template, bindings: bindings, subjectId: template.id, environment: env)
        #expect(bound.blocking.isEmpty)

        env.toolGroups = [.mcpServer("linear"): ["linear_search_issues"]]
        env.registeredToolNames = ["linear_search_issues"]
        let renamedCase = SetupChecker.check(template, bindings: InstallBindings(), subjectId: template.id, environment: env)
        #expect(renamedCase.blocking.isEmpty, "a case-only difference needs no binding")
    }
}

struct WorkflowModelResolutionTests {
    private let catalog = ConfigModelReference.Catalog(
        localModelIds: ["mlx-community/Qwen3-4bit"],
        providers: [.init(prefix: "openai", name: "OpenAI", models: ["gpt-5"])])

    @Test
    func plansSayHowToGetTheModel() {
        typealias P = WorkflowModelResolution.Plan
        #expect(WorkflowModelResolution.plan(for: nil, catalog: catalog) == P.none)
        #expect(WorkflowModelResolution.plan(for: "  ", catalog: catalog) == P.none)
        #expect(WorkflowModelResolution.plan(for: "mlx-community/Qwen3-4bit", catalog: catalog) == .ready("mlx-community/Qwen3-4bit"))
        #expect(WorkflowModelResolution.plan(for: "openai/gpt-5", catalog: catalog) == .ready("openai/gpt-5"))
        #expect(
            WorkflowModelResolution.plan(for: "mlx-community/Gemma-3-4b", catalog: catalog)
                == .download(repoId: "mlx-community/Gemma-3-4b"))
        #expect(
            WorkflowModelResolution.plan(for: "anthropic/claude-sonnet-5", catalog: catalog)
                == .connectProvider(.anthropic, model: "claude-sonnet-5"))
        #expect(
            WorkflowModelResolution.plan(for: "openai/gpt-9", catalog: catalog) == .ready("openai/gpt-9"),
            "a provider set up here is trusted for ids it doesn't list yet")
        #expect(WorkflowModelResolution.plan(for: "mystery-model", catalog: catalog) == .unavailable("mystery-model"))
    }

    @Test
    func knownReposPlaceBareIds_andWinOverProviderPrefixes() {
        let repos = ["mlx-community/Qwen3-Coder-30B-4bit", "google/gemma-3-4b-it"]
        #expect(
            WorkflowModelResolution.plan(for: "qwen3-coder-30b-4bit", catalog: catalog, knownRepos: repos)
                == .download(repoId: "mlx-community/Qwen3-Coder-30B-4bit"))
        #expect(
            WorkflowModelResolution.plan(for: "google/gemma-3-4b-it", catalog: catalog, knownRepos: repos)
                == .download(repoId: "google/gemma-3-4b-it"))
        #expect(
            WorkflowModelResolution.plan(for: "google/gemini-3-pro", catalog: catalog, knownRepos: repos)
                == .connectProvider(.google, model: "gemini-3-pro"))
    }
}

struct MCPServerHintTests {
    @Test
    func hintsRoundTripTheFile_andOnlyReferencedServersStay() throws {
        let hint = MCPServerHint(
            name: "Linear", directoryID: "linear", url: "https://mcp.linear.app/mcp", auth: .oauth,
            headerKeys: ["X-Team"])
        let stray = MCPServerHint(name: "Other", url: "https://other.example.com/mcp")
        let template = Fixture.template(hints: [hint, stray])
        #expect(template.serverHints == [hint])
        #expect(template.serverHint(named: "linear") == hint)

        let read = try Template.parse(try template.jsonString())
        #expect(read.serverHints == [hint])
        #expect(read.contentHash == template.contentHash)
        #expect(read.hashIsValid)
    }

    @Test
    func noHints_leavesTheFileAndHashAsBefore() throws {
        let template = Fixture.template()
        #expect(!(try template.jsonString()).contains("mcp_server_hints"))
        let hinted = Fixture.template(hints: [MCPServerHint(name: "Linear", url: "https://mcp.linear.app/mcp")])
        #expect(hinted.contentHash != template.contentHash)
    }

    @Test
    func theSanitizerRedactsCredentialsInHints() {
        let hint = MCPServerHint(
            name: "Zap", transport: .stdio, url: "https://user:pw@mcp.example.com/api/s/a8F3kQ29xLmZ7pW4vB1n/mcp?team=ops&api_key=abc",
            command: "/usr/local/bin/server", args: ["--api-key", "sk-123", "--token=xyz", "--verbose", "/Volumes/Data/db.sqlite"])
        let clean = TemplateExportSanitizer.sanitized(hint)
        #expect(clean.url == "https://mcp.example.com/api/s/YOUR_KEY/mcp?team=ops")
        #expect(clean.args == ["--api-key", "YOUR_KEY", "--token=YOUR_KEY", "--verbose", "db.sqlite"])
        #expect(clean.command == "server")
        #expect(TemplateExportSanitizer.sanitized(clean) == clean)
    }

    @Test
    func aHintFromAProviderKeepsNamesNotValues() {
        let provider = MCPProvider(
            name: "Search", url: "", transport: .stdio, command: "npx", args: ["-y", "search-mcp"],
            env: ["REGION": "us"], secretEnvKeys: ["SEARCH_API_KEY"])
        let hint = MCPServerHint.from(provider, as: "search", directoryID: nil)
        #expect(hint.envKeys == ["REGION", "SEARCH_API_KEY"])

        let draft = MCPProviderDraft(hint: hint)
        #expect(draft.transport == .stdio)
        #expect(draft.command == "npx")
        #expect(draft.args == ["-y", "search-mcp"])
        #expect(draft.envKeys == ["REGION", "SEARCH_API_KEY"])
        #expect(draft.authType == MCPProviderAuthType.none)
    }
}

struct TemplateShareOptionsTests {
    @Test
    func modelsThisMacRunsFillOpenSlots() throws {
        var def = WF.intake()
        def.modelSlots = []
        let template = WF.template(def).sealed()
        var bindings = InstallBindings()
        bindings.models = ["decision": "mlx-community/Qwen3-4bit"]
        let models = TemplateShareOptions.suggestableModels(template, bindings: bindings)
        #expect(models == ["decision": "mlx-community/Qwen3-4bit"])

        let suggested = TemplateShareOptions.withSuggestedModels(template, models)
        #expect(suggested.requirements.models.first { $0.slot == "decision" }?.preferred == "mlx-community/Qwen3-4bit")
        #expect(suggested.hashIsValid)
        #expect(TemplateShareOptions.suggestableModels(suggested, bindings: bindings).isEmpty, "only open slots")
    }

    @Test
    func directoryServersShareTheirCanonicalEntry() {
        let template = Fixture.template()
        let provider = MCPProvider(
            name: "Linear (work)", url: "https://mcp.linear.app/mcp/", authType: .oauth)
        let hints = TemplateShareOptions.suggestableHints(
            template, servers: ["Linear": provider], directory: MCPProviderTemplate.allTemplates)
        #expect(hints.count == 1)
        #expect(hints.first?.name == "Linear")
        #expect(hints.first?.directoryID == "linear")
        #expect(hints.first?.url == "https://mcp.linear.app/mcp")

        let hinted = TemplateShareOptions.withHints(template, hints)
        #expect(
            TemplateShareOptions.suggestableHints(
                hinted, servers: ["Linear": provider], directory: MCPProviderTemplate.allTemplates
            ).isEmpty, "an author's hint is kept")
    }
}

struct TemplateImportRouterTests {
    @Test
    func linksMustPointAtARegistryTemplateFile() {
        func link(_ s: String) -> URL { URL(string: s)! }
        let prod = WorkflowsRegistryAPIClient.productionBaseURL
        let file = "https://api.store.osaurus.ai/workflows/e2f1832f-93d5-4456-a9ca-ae02348ddde1/versions/2/template.json"
        let encoded = file.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(
            TemplateImportRouter.remoteURL(from: link("osaurus://templates-import?url=\(encoded)"), registry: prod)
                == URL(string: file))
        #expect(
            TemplateImportRouter.remoteURL(
                from: link("osaurus://templates-import?url=\(encoded)"), registry: WorkflowsRegistryAPIClient.stagingBaseURL)
                == nil, "a link to another registry")
        #expect(
            TemplateImportRouter.remoteURL(
                from: link("osaurus://templates-import?url=https%3A%2F%2Fexample.com%2Ft.osaurustemplate"), registry: prod)
                == nil, "any other https host")
        #expect(
            TemplateImportRouter.remoteURL(from: link("osaurus://templates-import?url=http://example.com/t"), registry: prod)
                == nil)
        #expect(
            TemplateImportRouter.remoteURL(from: link("osaurus://templates-import?url=file:///etc/passwd"), registry: prod)
                == nil)
        #expect(TemplateImportRouter.remoteURL(from: link("osaurus://templates-import"), registry: prod) == nil)
        #expect(
            TemplateImportRouter.remoteURL(from: link("osaurus://themes-install?url=\(encoded)"), registry: prod) == nil)
    }

    @Test
    func filesRouteByKind() throws {
        #expect(TemplateImportRouter.kind(of: try Fixture.template().jsonString()) == .workflow)
        #expect(TemplateImportRouter.kind(of: "not a template") == .workflow, "unreadable text opens where errors show")
        #expect(TemplateImportRouter.isTemplateFile(URL(fileURLWithPath: "/tmp/a.osaurustemplate")))
        #expect(!TemplateImportRouter.isTemplateFile(URL(fileURLWithPath: "/tmp/a.json")))
        #expect(!TemplateImportRouter.isTemplateFile(URL(string: "osaurus://templates-import")!))
    }

    @Test
    func anAgentTemplateLinkOpensOnAgentsWithItsRegistrySource() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("RegistryFixtures/agent-template-inbox-desk.json")
        let text = String(decoding: try Data(contentsOf: fixture), as: UTF8.self)
        let template = try Template.parse(text)
        #expect(template.kind == .agent && template.bundled.count == 1, "its workflow travels inside the file")
        #expect(TemplateImportRouter.kind(of: text) == .agent)

        let registry = WorkflowsRegistryAPIClient.productionBaseURL
        let id = "c8b28fcf-d167-4121-b1ac-a1a9368603d5"
        let raw = URL(string: "https://api.store.osaurus.ai/workflows/\(id)/versions/3/template.json")!
        var link = URLComponents(string: "osaurus://templates-import")!
        link.queryItems = [URLQueryItem(name: "url", value: raw.absoluteString)]
        #expect(TemplateImportRouter.remoteURL(from: link.url!, registry: registry) == raw)

        let source = try #require(RegistryImportSource(templateURL: raw, registry: registry))
        #expect(source.workflowID == UUID(uuidString: id) && source.version == 3)
        let pending = PendingTemplateImport(text: text, kind: .agent, sourceHost: raw.host, registry: source)
        #expect(pending.isRemote && pending.registryWorkflowID == source.workflowID)
    }
}
