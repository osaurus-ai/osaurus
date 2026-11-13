//
//  WorkflowIntegrationSynthesisTests.swift
//  OsaurusCoreTests
//
//  Integration by synthesis: OAuth 2 secrets and shared connections (the
//  vault, setup, runtime resolution), the `declare_server` op, adopting a
//  registry or library workflow into the draft, and `workflow_discover`
//  (directory MCP search, OpenAPI compaction, registry search, models).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WorkflowIntegrationSynthesisTests {

    // MARK: - Fixtures

    private static func spec(
        authorize: String = "https://accounts.example.com/authorize", token: String = "https://accounts.example.com/token"
    ) -> OAuth2Spec {
        OAuth2Spec(authorizeURL: authorize, tokenURL: token, scopes: ["read"])
    }

    private static func codeTemplate(secrets: [String], name: String = "Secretive") -> Template {
        WF.template(
            WorkflowDefinition(
                inputSchema: WF.object([:]),
                nodes: [
                    WorkflowNode(
                        id: "fetch", name: "Fetch",
                        kind: .code(CodeSpec(source: "async function run() { return {} }", secrets: secrets)))
                ],
                output: .object([:]),
                secrets: secrets.map { SecretRequirement(key: $0, label: $0) }), name: name)
    }

    private static func environment(
        connection: @escaping (String) -> SetupChecker.ConnectionState = { _ in .missing }
    ) -> SetupChecker.Environment {
        var env = SetupChecker.Environment(
            registeredToolNames: [],
            modelCatalog: ConfigModelReference.Catalog(localModelIds: [], providers: []),
            isPermissionGranted: { _ in true }, bookmarkResolves: { _ in true },
            knowledgeCollectionExists: { _ in true })
        env.secretPresent = { WorkflowSecretsKeychain.hasValue(account: $0) }
        env.connectionState = connection
        return env
    }

    private func asArchitect<T>(session: String, _ body: @MainActor () async throws -> T) async rethrows -> T {
        try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            try await ChatExecutionContext.$currentSessionId.withValue(session) { try await body() }
        }
    }

    private func result(_ envelope: String) throws -> [String: JSONValue] {
        let parsed = try #require(JSONValue.parse(envelope)?.objectValue, "\(envelope.prefix(300))")
        #expect(parsed["ok"]?.boolValue == true, "\(envelope.prefix(400))")
        return try #require(parsed["result"]?.objectValue)
    }

    private func discover(_ json: String, session: String = "architect-\(UUID().uuidString)") async throws -> String {
        try await asArchitect(session: session) { try await WorkflowDiscoverTool().execute(argumentsJSON: json) }
    }

    // MARK: - OAuth2Spec on a secret

    @Test
    func secretRequirement_carriesOAuth2_andDecodesWithoutIt() throws {
        var secret = SecretRequirement(key: "GOOGLE", label: "Google account", help: "Sign in")
        secret.oauth2 = OAuth2Spec(
            authorizeURL: "https://accounts.google.com/o/oauth2/v2/auth", tokenURL: "https://oauth2.googleapis.com/token",
            scopes: ["calendar.readonly"], requiresClientSecret: true, authorizeParameters: ["access_type": "offline"])
        let data = try JSONEncoder().encode(secret)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let oauth = try #require(json["oauth2"] as? [String: Any])
        #expect(oauth["authorize_url"] as? String == "https://accounts.google.com/o/oauth2/v2/auth")
        #expect(oauth["requires_client_secret"] as? Bool == true)
        let back = try JSONDecoder().decode(SecretRequirement.self, from: data)
        #expect(back == secret)
        #expect(back.oauth2?.serviceHost == "accounts.google.com")

        let legacy = try JSONDecoder().decode(
            SecretRequirement.self, from: Data(#"{"key":"API","label":"API key"}"#.utf8))
        #expect(legacy.oauth2 == nil)
        #expect(legacy.key == "API")
    }

    @Test
    func validator_reportsBadOAuthEndpoints_andDuplicateSecrets() {
        var bad = SecretRequirement(key: "SVC", label: "Service")
        bad.oauth2 = Self.spec(authorize: "http://insecure.example.com/authorize", token: "not a url")
        let def = WorkflowDefinition(
            inputSchema: WF.object([:]),
            nodes: [WF.code("a")],
            output: .object([:]),
            secrets: [bad, SecretRequirement(key: "SVC", label: "Again")])
        let messages = WorkflowValidator.validate(def, allowPlaceholders: true).map(\.message)
        #expect(messages.contains { $0.contains("secret `SVC` oauth2") && $0.contains("https") })
        #expect(messages.contains { $0.contains("more than once") })

        var good = bad
        good.oauth2 = Self.spec()
        let clean = WorkflowDefinition(inputSchema: WF.object([:]), nodes: [WF.code("a")], output: .object([:]), secrets: [good])
        #expect(!WorkflowValidator.validate(clean, allowPlaceholders: true).contains { $0.message.contains("oauth2") })
    }

    @Test
    func declareSecretOp_acceptsOAuth2Block() throws {
        let op = try WorkflowDraftOp.parse(
            .object([
                "op": .string("declare_secret"), "key": .string("GH"), "label": .string("GitHub"),
                "oauth2": .object([
                    "authorize_url": .string("https://github.com/login/oauth/authorize"),
                    "token_url": .string("https://github.com/login/oauth/access_token"),
                    "scopes": .array([.string("repo")]),
                ]),
            ]))
        guard case .declareSecret(let secret) = op else { Issue.record("expected declare_secret"); return }
        #expect(secret.oauth2?.scopes == ["repo"])
        #expect(secret.oauth2?.serviceHost == "github.com")
    }

    /// `declare_connection` turns a provider name into a complete secret:
    /// key, label, help, endpoints, scopes, and the service host setup
    /// matches connections on. Catalog defaults bend to the op's fields;
    /// a service with no tokens refuses `sign_in: false`.
    @Test
    func declareConnectionOp_fillsInFromTheCatalog_andTakesOverrides() throws {
        let op = try WorkflowDraftOp.parse(.object(["op": .string("declare_connection"), "provider": .string("GitHub")]))
        guard case .declareSecret(let github) = op else { Issue.record("expected declare_secret"); return }
        #expect(github.key == "GITHUB_TOKEN")
        #expect(github.label == "GitHub account")
        #expect(github.provider == "github" && github.service == "api.github.com")
        #expect(github.serviceHost == "api.github.com" && github.isConnection)
        #expect(github.oauth2?.authorizeURL == "https://github.com/login/oauth/authorize")
        #expect(github.oauth2?.requiresClientSecret == true)
        #expect(github.help?.contains("OAuth App") == true, "sign-in help names where to register the app")

        let token = try WorkflowDraftOp.parse(
            .object([
                "op": .string("declare_connection"), "provider": .string("github"), "sign_in": .bool(false),
                "key": .string("GH"), "label": .string("GitHub login"),
            ]))
        guard case .declareSecret(let pat) = token else { Issue.record("expected declare_secret"); return }
        #expect(pat.key == "GH" && pat.label == "GitHub login" && pat.oauth2 == nil)
        #expect(pat.help?.contains("Personal access tokens") == true)
        #expect(pat.service == "api.github.com", "a pasted token still matches the service's connections")

        let scoped = try WorkflowDraftOp.parse(
            .object([
                "op": .string("declare_connection"), "provider": .string("google"),
                "scopes": .array([.string("https://www.googleapis.com/auth/calendar.readonly")]),
            ]))
        guard case .declareSecret(let google) = scoped else { Issue.record("expected declare_secret"); return }
        #expect(google.oauth2?.scopes == ["https://www.googleapis.com/auth/calendar.readonly"])
        #expect(google.oauth2?.authorizeParameters["access_type"] == "offline")

        let custom = try WorkflowDraftOp.parse(
            .object(["op": .string("declare_connection"), "service": .string("api.acme.com"), "help": .string("Acme → API")]))
        guard case .declareSecret(let acme) = custom else { Issue.record("expected declare_secret"); return }
        #expect(acme.key == "API_ACME_COM_TOKEN" && acme.label == "api.acme.com account" && acme.oauth2 == nil)
        #expect(acme.provider == nil && acme.service == "api.acme.com")

        #expect(throws: WorkflowDraftOp.ParseError.self, "Google has no personal tokens") {
            try WorkflowDraftOp.parse(
                .object(["op": .string("declare_connection"), "provider": .string("google"), "sign_in": .bool(false)]))
        }
        // A token-only service takes a key even when sign-in was not refused.
        guard case .declareSecret(let stripe) = try WorkflowDraftOp.parse(.object(["op": .string("declare_connection"), "provider": .string("stripe")]))
        else { Issue.record("expected declare_secret"); return }
        #expect(stripe.oauth2 == nil && stripe.help?.contains("API keys") == true)
        #expect(throws: WorkflowDraftOp.ParseError.self) {
            try WorkflowDraftOp.parse(.object(["op": .string("declare_connection"), "provider": .string("myspace")]))
        }
        #expect(throws: WorkflowDraftOp.ParseError.self) {
            try WorkflowDraftOp.parse(.object(["op": .string("declare_connection")]))
        }

        // The declaration round-trips with its service and provider.
        let data = try JSONEncoder().encode(github)
        let back = try JSONDecoder().decode(SecretRequirement.self, from: data)
        #expect(back == github)
        let old = try JSONDecoder().decode(SecretRequirement.self, from: Data(#"{"key":"K","label":"K"}"#.utf8))
        #expect(old.service == nil && old.provider == nil && !old.isConnection)
    }

    /// Every catalogued sign-in has https endpoints the flow accepts.
    @Test
    func connectionProviders_haveValidEndpoints_andUniqueIDs() {
        #expect(Set(ConnectionProviders.all.map(\.id)).count == ConnectionProviders.all.count)
        for provider in ConnectionProviders.all {
            #expect(provider.supportsSignIn || provider.supportsToken, "\(provider.id)")
            if let spec = provider.oauth2 { #expect(spec.problems.isEmpty, "\(provider.id): \(spec.problems)") }
            #expect(!provider.apiHosts.isEmpty, "\(provider.id)")
        }
        #expect(ConnectionProviders.provider(id: " Linear ")?.id == "linear")
    }

    /// An http step may name the login with `auth: connection`; the
    /// request carries it as a bearer token and the secret is derived.
    @Test
    func httpConnectionAuth_sendsBearer_andCountsAsASecret() async throws {
        let spec = HTTPSpec(url: "https://api.github.com/user/repos", auth: .connection(secret: "GITHUB_TOKEN"))
        let node = WorkflowNode(id: "repos", name: "Repos", kind: .http(spec))
        let def = WorkflowDefinition(
            inputSchema: WF.object([:]), outputSchema: WF.object([:]), nodes: [node], output: .object([:]),
            secrets: [SecretRequirement(key: "GITHUB_TOKEN", label: "GitHub account", service: "api.github.com", provider: "github")])
        #expect(WorkflowValidator.validate(def, allowPlaceholders: false).isEmpty)
        #expect(WorkflowRequirementsDeriver.derive(def).secrets.map(\.key) == ["GITHUB_TOKEN"])
        let encoded = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        #expect(encoded.contains(#""type":"connection""#))
        #expect(try JSONDecoder().decode(HTTPSpec.self, from: Data(encoded.utf8)) == spec)

        let context = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "W", node: node, input: .object([:]),
            bindings: BindingContext(input: .object([:]), outputs: [:]), model: nil, secretAccounts: [:],
            secrets: ["GITHUB_TOKEN": "gho_live"], caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(),
            attempt: 1, timeout: 30)
        let transport = HTTPNodeExecutor.Transport { request, _ in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gho_live")
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let outcome = try await HTTPNodeExecutor.run(spec: spec, context: context, transport: transport)
        #expect(outcome.output.value(atPath: "body") == .array([]))
    }

    // MARK: - Connections

    @Test
    func connectionStore_savesValues_offersCandidates_andListsUsers() throws {
        let store = WorkflowConnectionStore.shared
        store.resetForTesting()
        defer { store.resetForTesting() }
        // Other suites install workflows in parallel; only this test's own
        // install is touched (a reset here would delete theirs).
        let installed = InstalledWorkflowStore.shared

        let connection = try #require(store.addValue(name: "Acme key", service: "api.acme.com", value: "acme-123"))
        #expect(store.connection(binding: connection.binding)?.id == connection.id)
        #expect(store.hasValue(connection))
        #expect(WorkflowSecretsKeychain.isConnectionAccount(connection.binding))
        #expect(WorkflowSecretsKeychain.connectionID(of: connection.binding) == connection.id)

        var secret = SecretRequirement(key: "ACME", label: "Acme")
        secret.oauth2 = Self.spec(authorize: "https://api.acme.com/authorize", token: "https://api.acme.com/token")
        _ = try #require(store.addValue(name: "Other", service: "other.example", value: "x"))
        #expect(store.candidates(for: secret).first?.name == "Acme key", "same-service connections come first")

        var workflow = try installed.install(Self.codeTemplate(secrets: ["ACME"]), bindings: InstallBindings())
        defer { installed.delete(id: workflow.id) }
        workflow.bindings.secrets["ACME"] = connection.binding
        try installed.save(workflow)
        #expect(store.users(of: connection.id).map(\.id) == [workflow.id])

        store.rename(connection.id, to: "Acme production")
        #expect(store.connection(id: connection.id)?.name == "Acme production")

        store.delete(id: connection.id)
        #expect(store.connection(id: connection.id) == nil)
        #expect(!WorkflowSecretsKeychain.hasValue(account: WorkflowSecretsKeychain.connectionAccount(id: connection.id, field: "value")))
    }

    @Test
    func resolver_returnsPastedValues_andRefreshesExpiredTokens() async throws {
        let store = WorkflowConnectionStore.shared
        store.resetForTesting()
        defer { store.resetForTesting() }

        let pasted = try #require(store.addValue(name: "Key", service: nil, value: "plain-value"))
        #expect(try await WorkflowConnectionResolver.resolve(binding: pasted.binding) == "plain-value")
        #expect(try await WorkflowConnectionResolver.resolve(binding: "secret:ABC") == nil, "not a connection")

        var oauth = WorkflowConnection(
            name: "Service", service: "accounts.example.com", kind: .oauth2, oauth2: Self.spec(),
            expiresAt: Date(timeIntervalSinceNow: -10), canRefresh: true)
        oauth.oauth2?.clientID = "client"
        store.upsert(oauth)
        WorkflowSecretsKeychain.save("stale", account: WorkflowSecretsKeychain.connectionAccount(id: oauth.id, field: "access"))
        WorkflowSecretsKeychain.save("refresh-1", account: WorkflowSecretsKeychain.connectionAccount(id: oauth.id, field: "refresh"))

        WorkflowConnectionResolver.refreshOverride = { _ in
            OAuth2ConnectionFlow.Tokens(accessToken: "fresh", refreshToken: "refresh-2", expiresAt: Date(timeIntervalSinceNow: 3600))
        }
        defer { WorkflowConnectionResolver.refreshOverride = nil }
        #expect(try await WorkflowConnectionResolver.resolve(binding: oauth.binding) == "fresh")
        #expect(WorkflowSecretsKeychain.read(account: WorkflowSecretsKeychain.connectionAccount(id: oauth.id, field: "access")) == "fresh")
        #expect(WorkflowSecretsKeychain.read(account: WorkflowSecretsKeychain.connectionAccount(id: oauth.id, field: "refresh")) == "refresh-2")
        let updated = try #require(store.connection(id: oauth.id))
        #expect((updated.expiresAt ?? .distantPast) > Date())
        // Live now: no refresh call.
        WorkflowConnectionResolver.refreshOverride = { _ in throw OAuth2ConnectionFlow.Failure.exchange("should not refresh") }
        #expect(try await WorkflowConnectionResolver.resolve(binding: oauth.binding) == "fresh")

        var expired = updated
        expired.expiresAt = Date(timeIntervalSinceNow: -5)
        expired.canRefresh = false
        store.upsert(expired)
        #expect(expired.needsSignIn())
        await #expect(throws: WorkflowConnectionResolver.Failure.signInNeeded("Service")) {
            try await WorkflowConnectionResolver.resolve(binding: expired.binding)
        }

        let gone = WorkflowSecretsKeychain.connectionBinding(id: UUID())
        await #expect(throws: WorkflowConnectionResolver.Failure.self) {
            try await WorkflowConnectionResolver.resolve(binding: gone)
        }
    }

    @Test
    func setupChecker_acceptsAReadyConnection_andNamesExpiredOrMissingOnes() throws {
        let template = Self.codeTemplate(secrets: ["ACME"])
        let subject = UUID()
        var bindings = InstallBindings()
        bindings.secrets["ACME"] = WorkflowSecretsKeychain.connectionBinding(id: UUID())

        let ready = SetupChecker.check(template, bindings: bindings, subjectId: subject, environment: Self.environment { _ in .ready })
        #expect(!ready.items.contains { $0.kind == .secret })

        let expired = SetupChecker.check(
            template, bindings: bindings, subjectId: subject, environment: Self.environment { _ in .signInNeeded("Acme") })
        #expect(expired.items.first { $0.kind == .secret }?.detail.contains("Acme") == true)
        #expect(expired.hasBlockers)

        let missing = SetupChecker.check(template, bindings: bindings, subjectId: subject, environment: Self.environment())
        #expect(missing.items.first { $0.kind == .secret }?.detail.contains("gone") == true)

        var secret = SecretRequirement(key: "ACME", label: "Acme")
        secret.oauth2 = Self.spec()
        var def = try #require(template.workflow)
        def.secrets = [secret]
        let oauthTemplate = WF.template(def)
        #expect(oauthTemplate.requirements.secrets.first?.oauth2 != nil, "requirements carry the oauth2 block")
        let unbound = SetupChecker.check(oauthTemplate, bindings: InstallBindings(), subjectId: subject, environment: Self.environment())
        #expect(unbound.items.first { $0.kind == .secret }?.detail.contains("Sign in") == true)
    }

    @Test
    func rekey_keepsConnectionBindings() {
        let source = UUID()
        let destination = UUID()
        let connection = WorkflowSecretsKeychain.connectionBinding(id: UUID())
        WorkflowSecretsKeychain.save("v", account: WorkflowSecretsKeychain.secretAccount(scope: source, key: "PLAIN"))
        let bindings = WorkflowCredentials.rekey(
            ["PLAIN", "LINKED"], from: source, to: destination, keeping: ["LINKED": connection])
        #expect(bindings["LINKED"] == connection)
        #expect(bindings["PLAIN"] == WorkflowSecretsKeychain.secretAccount(scope: destination, key: "PLAIN"))
    }

    @Test
    func runner_readsASecretBoundToAConnection() async throws {
        let store = WorkflowConnectionStore.shared
        store.resetForTesting()
        defer { store.resetForTesting() }
        let connection = try #require(store.addValue(name: "Acme", service: nil, value: "conn-token-999"))

        let template = Self.codeTemplate(secrets: ["ACME"])
        let seen = NodeCallLog()
        let executor = ClosureExecutor { ctx, _ in
            await seen.enter(ctx.secrets["ACME"] ?? "<none>")
            return WorkflowNodeOutcome(output: .object([:]), logs: ["token conn-token-999"])
        }
        let request = WorkflowRunner.Request(
            workflowID: UUID(), workflowName: template.name, template: template,
            secretAccounts: ["ACME": connection.binding],
            caller: WorkflowCaller(kind: .user), input: .object([:]), workspace: WF.tempDir())
        let run = await WorkflowRunner(request: request, executor: executor).execute()
        #expect(run.status == .completed, "\(run.error?.reason ?? "")")
        #expect(await seen.calls == ["conn-token-999"])
        #expect(run.nodes.first?.logs == ["token [REDACTED:ACME]"])

        store.delete(id: connection.id)
        let again = await WorkflowRunner(request: request, executor: executor).execute()
        #expect(again.status == .failed)
        #expect(again.error?.reason.contains("removed") == true)
    }

    // MARK: - declare_server and adopt

    @Test
    func declareServerOp_fillsDirectoryEntries_andRefusesUnknownOrInsecure() throws {
        let entry = try #require(MCPProviderTemplate.allTemplates.first)
        let op = try WorkflowDraftOp.parse(
            .object(["op": .string("declare_server"), "name": .string("Tracker"), "directory_id": .string(entry.id)]))
        guard case .declareServer(let hint, let remove) = op else { Issue.record("expected declare_server"); return }
        #expect(!remove)
        #expect(hint.name == "Tracker")
        #expect(hint.url == entry.url)
        #expect(hint.auth == entry.authType)

        #expect(throws: WorkflowDraftOp.ParseError.self) {
            try WorkflowDraftOp.parse(
                .object(["op": .string("declare_server"), "name": .string("X"), "directory_id": .string("no-such-entry")]))
        }
        #expect(throws: WorkflowDraftOp.ParseError.self) {
            try WorkflowDraftOp.parse(
                .object(["op": .string("declare_server"), "name": .string("X"), "url": .string("http://plain.example.com/mcp")]))
        }
        let remote = try WorkflowDraftOp.parse(
            .object(["op": .string("declare_server"), "name": .string("Remote"), "url": .string("https://mcp.example.com/sse")]))
        guard case .declareServer(let remoteHint, _) = remote else { Issue.record("expected declare_server"); return }
        #expect(remoteHint.url == "https://mcp.example.com/sse")
    }

    @Test
    func patch_declareServer_updatesDraftHints_andUndoRestoresThem() throws {
        let drafts = WorkflowDraftStore.shared
        let draft = drafts.create(sessionID: "s-\(UUID().uuidString)")
        defer { drafts.delete(draft.id) }

        _ = try drafts.applyArchitectPatch(
            draft.id,
            ops: [
                .planPlaceholder(id: "a", name: "A", intent: "Do a"),
                .declareServer(MCPServerHint(name: "Linear", url: "https://mcp.linear.app/sse", auth: .oauth), remove: false),
            ])
        #expect(drafts.draft(id: draft.id)?.serverHints.map(\.name) == ["Linear"])
        #expect(drafts.draft(id: draft.id)?.history.last?.summary.contains("Declared the MCP server") == true)

        _ = try drafts.applyArchitectPatch(
            draft.id, ops: [.declareServer(MCPServerHint(name: "linear"), remove: true)])
        #expect(drafts.draft(id: draft.id)?.serverHints.isEmpty == true, "names match case-insensitively")

        drafts.undo(draft.id)
        #expect(drafts.draft(id: draft.id)?.serverHints.map(\.name) == ["Linear"])
    }

    @Test
    func adopt_replacesTheGraph_andDetachesFromASavedWorkflow() async throws {
        try await ChatHistoryTestStorage.run {
            let templates = TemplateStore.shared
            let saved = try templates.save(WF.template(WF.intake(), name: "Saved Intake \(UUID().uuidString.prefix(6))"))
            defer { try? templates.delete(id: saved.id) }
            var other = Template(
                name: "Registry Pick", summary: "From the registry", payload: .workflow(Self.codeTemplate(secrets: ["K"]).workflow!))
            // The initializer keeps only hints for servers the steps use; a
            // decoded registry template carries whatever it was published with.
            other.serverHints = [MCPServerHint(name: "Notion", url: "https://mcp.notion.com/mcp")]

            let drafts = WorkflowDraftStore.shared
            let draft = drafts.create(sessionID: "s-\(UUID().uuidString)", from: saved)
            #expect(draft.templateID == saved.id)
            let newID = try #require(drafts.adopt(draft.id, template: other, source: "registry"))
            defer { drafts.delete(newID) }
            let adopted = try #require(drafts.draft(id: newID))
            #expect(adopted.templateID == nil, "saving must not overwrite the saved workflow")
            #expect(adopted.name == "Registry Pick")
            #expect(adopted.definition.nodes.map(\.id) == ["fetch"])
            #expect(adopted.serverHints.map(\.name) == ["Notion"])
            #expect(adopted.history.last?.summary.contains("Started from") == true)
        }
    }

    // MARK: - workflow_discover

    @Test
    func discover_refusesOtherAgents_andUnknownActions() async throws {
        let refused = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await WorkflowDiscoverTool().execute(argumentsJSON: #"{"action": "templates"}"#)
        }
        #expect(refused.contains("\"ok\":false") || refused.contains("\"ok\" : false"))
        let unknown = try await discover(#"{"action": "nope"}"#)
        #expect(unknown.contains("Unknown action"))
        let needsQuery = try await discover(#"{"action": "mcp"}"#)
        #expect(needsQuery.contains("needs `query`"))
        for removed in ["skill", "connections"] {
            let gone = try await discover(#"{"action": "\#(removed)"}"#)
            #expect(gone.contains("Unknown action"), "\(removed) → \(gone)")
        }
    }

    @Test
    func openAPI_compactsJSONAndYAML_andFiltersWithFind() throws {
        let json = """
            {"openapi":"3.0.0","info":{"title":"Pets","version":"2"},
             "servers":[{"url":"https://api.pets.example/v1"}],
             "components":{"securitySchemes":{"bearer":{"type":"http","scheme":"bearer"},
               "oauth":{"type":"oauth2","flows":{"authorizationCode":{"authorizationUrl":"https://a/x","tokenUrl":"https://a/t","scopes":{"read":"r"}}}}},
               "schemas":{"Pet":{"type":"object","required":["id"],"properties":{"id":{"type":"string"},"name":{"type":"string"}}}}},
             "security":[{"bearer":[]}],
             "paths":{"/pets":{"get":{"summary":"List pets","operationId":"listPets",
                 "parameters":[{"name":"limit","in":"query"}],
                 "responses":{"200":{"content":{"application/json":{"schema":{"type":"array","items":{"$ref":"#/components/schemas/Pet"}}}}}}},
               "post":{"summary":"Create a pet","security":[{"oauth":["read"]}],
                 "requestBody":{"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Pet"}}}},
                 "responses":{"201":{"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Pet"}}}}}}},
               "/pets/{id}":{"parameters":[{"name":"id","in":"path","required":true}],"delete":{"summary":"Remove"}}}}
            """
        let api = try #require(OpenAPISummary.parse(json))
        #expect(api.title == "Pets")
        #expect(api.servers == ["https://api.pets.example/v1"])
        #expect(api.securitySchemes["bearer"] == "http bearer")
        #expect(api.securitySchemes["oauth"]?.contains("authorize=https://a/x") == true)
        #expect(api.operations.map { "\($0.method) \($0.path)" } == ["GET /pets", "POST /pets", "DELETE /pets/{id}"])
        let list = api.operations[0]
        #expect(list.parameters == ["limit (query)"])
        #expect(list.responseFields == ["[]", "id*", "name"])
        #expect(list.security == ["bearer"], "inherits the document's security")
        #expect(api.operations[1].requestBody == ["application/json", ".id*", ".name"])
        #expect(api.operations[1].security == ["oauth"])
        #expect(api.operations[2].parameters == ["id* (path)"], "path-level parameters apply")

        let compact = api.compact(find: "create")
        #expect(compact["matched"] as? Int == 1)
        #expect((compact["operations"] as? [[String: Any]])?.first?["path"] as? String == "/pets")
        #expect(compact["kind"] as? String == "openapi")

        let yaml = """
            swagger: "2.0"
            info: {title: Legacy, version: "1"}
            host: legacy.example.com
            basePath: /api
            schemes: [https]
            securityDefinitions:
              key: {type: apiKey, in: header, name: X-Api-Key}
            paths:
              /things:
                get:
                  summary: List things
                  responses:
                    "200":
                      schema: {type: object, properties: {items: {type: array, items: {type: string}}}}
            """
        let legacy = try #require(OpenAPISummary.parse(yaml))
        #expect(legacy.servers == ["https://legacy.example.com/api"])
        #expect(legacy.securitySchemes["key"] == "apiKey header X-Api-Key")
        #expect(legacy.operations.first?.responseFields == ["items"])

        #expect(OpenAPISummary.parse("<html><body>not an api</body></html>") == nil)
        #expect(OpenAPISummary.parse(#"{"paths":{}}"#) == nil, "needs openapi or swagger")
    }

    @Test
    func docs_refusesHTTP_andUsesTheFetchSeam() async throws {
        let insecure = try await discover(#"{"action": "docs", "url": "http://example.com/api"}"#)
        #expect(insecure.contains("Only https"))

        let previous = WorkflowDiscoverTool.fetch
        defer { WorkflowDiscoverTool.fetch = previous }
        WorkflowDiscoverTool.fetch = { url in
            WorkflowDiscoverTool.Fetched(
                data: Data(#"{"openapi":"3.1.0","info":{"title":"Seam"},"paths":{"/ping":{"get":{"summary":"Ping"}}}}"#.utf8),
                contentType: "application/json", url: url)
        }
        let got = try result(await discover(#"{"action": "docs", "url": "https://api.example.com/openapi.json"}"#))
        #expect(got["kind"]?.stringValue == "openapi")
        #expect(got["title"]?.stringValue == "Seam")
        #expect(got["operations"]?.arrayValue?.first?.objectValue?["path"]?.stringValue == "/ping")

        WorkflowDiscoverTool.fetch = { url in
            WorkflowDiscoverTool.Fetched(
                data: Data("<html><body><h1>Guide</h1><p>Use the token header.</p></body></html>".utf8),
                contentType: "text/html; charset=utf-8", url: url)
        }
        let page = try await discover(#"{"action": "docs", "url": "https://docs.example.com/", "find": "token"}"#)
        #expect(page.contains("not_found"), "a page that is not OpenAPI is refused: \(page)")
        #expect(page.contains("OpenAPI URL"))

        WorkflowDiscoverTool.fetch = { _ in throw WorkflowDiscoverTool.Failure.status(404) }
        let failed = try await discover(#"{"action": "docs", "url": "https://docs.example.com/missing"}"#)
        #expect(failed.contains("HTTP 404"))
    }

    /// The model picks the docs URL, so private and local addresses are
    /// refused before any request, and a redirect to one is refused too.
    @Test
    func docs_refusesPrivateAndLocalAddresses_beforeFetchingAndOnRedirect() async throws {
        let previous = WorkflowDiscoverTool.fetch
        defer { WorkflowDiscoverTool.fetch = previous }
        WorkflowDiscoverTool.fetch = { url in
            Issue.record("must not fetch \(url)")
            return WorkflowDiscoverTool.Fetched(data: Data("{}".utf8), contentType: "application/json", url: url)
        }
        for url in [
            "https://169.254.169.254/latest/meta-data", "https://10.0.0.5/openapi.json", "https://192.168.1.1/",
            "https://172.16.0.9/api", "https://localhost:8443/openapi.json", "https://127.0.0.1/", "https://[::1]/",
            "https://[::ffff:10.0.0.1]/",
        ] {
            let refused = try await discover(#"{"action": "docs", "url": "\#(url)"}"#)
            #expect(refused.contains("private or local address"), "\(url) → \(refused)")
        }
        #expect(WorkflowDiscoverTool.docsURLProblem(URL(string: "https://api.example.com/openapi.json")!) == nil)

        // Redirect guard: a hop onto a private address is refused and reported.
        let guardDelegate = WorkflowDiscoverTool.DocsRedirectGuard()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://api.example.com/")!)
        let response = HTTPURLResponse(url: URL(string: "https://api.example.com/")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var allowed: URLRequest?? = nil
        guardDelegate.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://10.1.2.3/secret")!)
        ) { allowed = .some($0) }
        #expect(allowed == .some(nil))
        #expect(guardDelegate.refused?.localizedDescription.contains("private or local address") == true)
        var passed: URLRequest?? = nil
        guardDelegate.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://cdn.example.com/openapi.json")!)
        ) { passed = .some($0) }
        #expect(passed??.url?.host == "cdn.example.com")
    }

    @Test
    func mcp_searchesOnlyTheDirectory_andFlagsConnected() async throws {
        let entry = try #require(MCPProviderTemplate.allTemplates.first)
        let previous = WorkflowDiscoverTool.fetch
        defer { WorkflowDiscoverTool.fetch = previous }
        WorkflowDiscoverTool.fetch = { url in
            Issue.record("mcp must not reach the network: \(url)")
            throw WorkflowDiscoverTool.Failure.status(500)
        }
        let got = try result(await discover(#"{"action": "mcp", "query": "\#(entry.displayName)"}"#))
        let servers = try #require(got["servers"]?.arrayValue).compactMap(\.objectValue)
        #expect(servers.first?["source"]?.stringValue == "directory")
        #expect(servers.first?["directory_id"]?.stringValue == entry.id)
        #expect(servers.allSatisfy { $0["source"]?.stringValue == "directory" })

        let local = [MCPServerResolution.LocalServer(id: UUID(), name: "My Thing", url: "https://mcp.thing.example/mcp/")]
        #expect(WorkflowDiscoverTool.sameEndpoint("https://mcp.thing.example/mcp", local[0].url))
        let matches = WorkflowDiscoverTool.directoryMatches(query: entry.displayName, local: local)
        #expect(matches.first?.name == entry.displayName)

        let none = try result(await discover(#"{"action": "mcp", "query": "zzqxv"}"#))
        #expect(none["count"]?.numberValue == 0)
        #expect(none["hint"]?.stringValue?.contains("OpenAPI") == true)
    }

    /// `models` lists each slot the draft uses with the models that can
    /// serve it, from the same lists the setup wizard's picker uses.
    @Test
    func models_listsEverySlotTheDraftUses() async throws {
        let session = "architect-\(UUID().uuidString)"
        let draft = await MainActor.run { WorkflowDraftStore.shared.create(sessionID: session, from: nil) }
        defer { Task { @MainActor in WorkflowDraftStore.shared.delete(draft.id) } }
        try await MainActor.run {
            _ = try WorkflowDraftStore.shared.applyArchitectPatch(
                draft.id,
                ops: [
                    .planPlaceholder(id: "decide", name: "Decide", intent: "Pick one"),
                    .declareSlot(ModelRequirement(slot: "judge", preferred: "foundation", strictness: .always)),
                ])
        }
        let got = try result(await discover(#"{"action": "models"}"#, session: session))
        let slots = try #require(got["slots"]?.arrayValue).compactMap(\.objectValue)
        let judge = try #require(slots.first { $0["slot"]?.stringValue == "judge" })
        #expect(judge["strictness"]?.stringValue == "always")
        #expect(judge["preferred"]?.stringValue == "foundation")
        #expect(judge["usable"]?.arrayValue != nil)
        #expect(got["hint"]?.stringValue?.contains("declare_slot") == true)

        let one = try result(await discover(#"{"action": "models", "slot": "writer"}"#, session: session))
        #expect(try #require(one["slots"]?.arrayValue).first?.objectValue?["slot"]?.stringValue == "writer")
    }

    @Test
    func registry_searchBuildsTemplateURLs_andAdoptRefusesOtherURLs() async throws {
        let previous = WorkflowDiscoverTool.fetch
        defer { WorkflowDiscoverTool.fetch = previous }
        let id = UUID().uuidString.lowercased()
        WorkflowDiscoverTool.fetch = { url in
            #expect(url.host == WorkflowsRegistryAPIClient.defaultBaseURL.host)
            #expect(url.query?.contains("q=invoice") == true)
            let body = """
                {"items":[{"id":"\(id)","slug":"invoice-triage","name":"Invoice Triage","summary":"Sorts invoices",
                  "author":{"display_name":"Pat"},"latest_version":3,"node_count":5,"install_count":12},
                  {"id":"not-a-uuid","name":"Broken","latest_version":1}]}
                """
            return WorkflowDiscoverTool.Fetched(data: Data(body.utf8), contentType: "application/json", url: url)
        }
        let got = try result(await discover(#"{"action": "registry", "query": "invoice"}"#))
        let rows = try #require(got["workflows"]?.arrayValue).compactMap(\.objectValue)
        #expect(rows.count == 1, "rows without a usable id are dropped")
        let url = try #require(rows.first?["template_url"]?.stringValue.flatMap(URL.init(string:)))
        #expect(WorkflowsRegistryAPIClient.isRegistryTemplateURL(url))
        #expect(url.path.hasSuffix("/\(id)/versions/3/template.json"))
        #expect(rows.first?["author"]?.stringValue == "Pat")

        let refused = try await discover(#"{"action": "adopt", "url": "https://evil.example.com/template.json"}"#)
        #expect(refused.contains("not an arbitrary URL"))
        let nothing = try await discover(#"{"action": "adopt"}"#)
        #expect(nothing.contains("needs `template`"))
    }

    @Test
    func templates_andAdoptFromTheLibrary() async throws {
        try await ChatHistoryTestStorage.run {
            let templates = TemplateStore.shared
            let name = "Library Pick \(UUID().uuidString.prefix(6))"
            let saved = try templates.save(WF.template(WF.intake(), name: name))
            defer { try? templates.delete(id: saved.id) }

            let listed = try result(await discover(#"{"action": "templates", "query": "library pick"}"#))
            let rows = try #require(listed["templates"]?.arrayValue).compactMap(\.objectValue)
            #expect(rows.contains { $0["name"]?.stringValue == name })
            #expect(rows.first { $0["name"]?.stringValue == name }?["installed"]?.boolValue == false)

            let session = "architect-\(UUID().uuidString)"
            let draft = WorkflowDraftStore.shared.create(sessionID: session)
            defer { WorkflowDraftStore.shared.delete(draft.id) }
            let adopted = try result(await discover(#"{"action": "adopt", "template": "\#(name)"}"#, session: session))
            #expect(adopted["adopted"]?.stringValue == name)
            #expect(adopted["source"]?.stringValue == "library")
            #expect(adopted["node_count"]?.numberValue == Double(WF.intake().nodes.count))
            #expect(WorkflowDraftStore.shared.draft(id: draft.id)?.definition == WF.intake())

            let missing = try await discover(#"{"action": "adopt", "template": "No Such Workflow"}"#, session: session)
            #expect(missing.contains("No library workflow"))
        }
    }
}
