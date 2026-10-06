//
//  MCPSpecAlignmentTests.swift
//  osaurusTests
//
//  MCP 2025-11-25 client behavior: client registration strategy (CIMD /
//  DCR / cached), RFC 9207 issuer checks, token endpoint client auth, legacy
//  discovery, tool metadata and result conversion, scope step-up, and
//  request cancellation.
//

import Foundation
import MCP
import Testing

@testable import OsaurusCore

@Suite("MCP spec alignment")
struct MCPSpecAlignmentTests {
    private static func asm(
        issuer: String = "https://auth.example.com",
        registration: String? = nil,
        cimd: Bool? = nil,
        issParameter: Bool? = nil,
        authMethods: [String]? = nil
    ) -> MCPAuthorizationServerMetadata {
        MCPAuthorizationServerMetadata(
            issuer: issuer,
            authorizationEndpoint: "\(issuer)/authorize",
            tokenEndpoint: "\(issuer)/token",
            registrationEndpoint: registration,
            scopesSupported: nil,
            codeChallengeMethodsSupported: ["S256"],
            grantTypesSupported: nil,
            tokenEndpointAuthMethodsSupported: authMethods,
            clientIdMetadataDocumentSupported: cimd,
            authorizationResponseIssParameterSupported: issParameter
        )
    }

    // MARK: Client registration strategy

    @Test func cachedClientIdIsReusedForTheSameIssuer() {
        let strategy = MCPOAuthClientMetadata.strategy(
            cachedClientId: "abc",
            cachedIssuer: "https://auth.example.com",
            asm: Self.asm(registration: "https://auth.example.com/register", cimd: true),
            metadataDocumentPublished: true
        )
        #expect(strategy == .cached(clientId: "abc"))
    }

    @Test func manuallyEnteredClientIdWithoutIssuerIsReused() {
        let strategy = MCPOAuthClientMetadata.strategy(
            cachedClientId: "manual",
            cachedIssuer: nil,
            asm: Self.asm(),
            metadataDocumentPublished: false
        )
        #expect(strategy == .cached(clientId: "manual"))
    }

    @Test func clientIdFromAnotherIssuerIsNotReused() {
        let strategy = MCPOAuthClientMetadata.strategy(
            cachedClientId: "abc",
            cachedIssuer: "https://old-auth.example.com",
            asm: Self.asm(registration: "https://auth.example.com/register"),
            metadataDocumentPublished: false
        )
        #expect(strategy == .dynamicRegistration(endpoint: "https://auth.example.com/register"))
    }

    @Test func metadataDocumentIsPreferredOverDCRWhenPublished() {
        let strategy = MCPOAuthClientMetadata.strategy(
            cachedClientId: nil,
            cachedIssuer: nil,
            asm: Self.asm(registration: "https://auth.example.com/register", cimd: true),
            metadataDocumentPublished: true
        )
        #expect(strategy == .metadataDocument(clientId: MCPOAuthClientMetadata.documentURL.absoluteString))
    }

    @Test func unpublishedMetadataDocumentFallsBackToDCR() {
        let strategy = MCPOAuthClientMetadata.strategy(
            cachedClientId: nil,
            cachedIssuer: nil,
            asm: Self.asm(registration: "https://auth.example.com/register", cimd: true),
            metadataDocumentPublished: false
        )
        #expect(strategy == .dynamicRegistration(endpoint: "https://auth.example.com/register"))
    }

    @Test func noRegistrationMechanismIsUnavailable() {
        let strategy = MCPOAuthClientMetadata.strategy(
            cachedClientId: "",
            cachedIssuer: nil,
            asm: Self.asm(cimd: true),
            metadataDocumentPublished: false
        )
        #expect(strategy == .unavailable)
    }

    @Test func repositoryMetadataDocumentMatchesTheClient() throws {
        // docs/oauth/mcp-client-metadata.json is what gets published at
        // `documentURL`; it must pass the same check the app runs at sign-in.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/oauth/mcp-client-metadata.json")
        let data = try Data(contentsOf: url)
        #expect(MCPOAuthClientMetadata.isValidPublishedDocument(data))
        let published = try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        #expect(published == MCPOAuthClientMetadata.document as NSDictionary)
    }

    @Test func metadataDocumentWithWrongClientIdIsRejected() throws {
        var document = MCPOAuthClientMetadata.document
        document["client_id"] = "https://evil.example.com/client.json"
        let data = try JSONSerialization.data(withJSONObject: document)
        #expect(!MCPOAuthClientMetadata.isValidPublishedDocument(data))
    }

    @Test func authorizationServerMetadataDecodesCIMDAndIssFlags() throws {
        let json = """
            {"issuer":"https://a.example.com","authorization_endpoint":"https://a.example.com/a",
             "token_endpoint":"https://a.example.com/t","client_id_metadata_document_supported":true,
             "authorization_response_iss_parameter_supported":true}
            """
        let decoded = try JSONDecoder().decode(MCPAuthorizationServerMetadata.self, from: Data(json.utf8))
        #expect(decoded.clientIdMetadataDocumentSupported == true)
        #expect(decoded.authorizationResponseIssParameterSupported == true)
    }

    // MARK: RFC 9207 issuer

    @Test func matchingIssIsAccepted() {
        let url = URL(string: "http://127.0.0.1:5000/callback?code=c&state=s&iss=https%3A%2F%2Fauth.example.com%2F")!
        #expect(MCPOAuthClientMetadata.validateIssuer(callbackURL: url, asm: Self.asm()) == .valid)
    }

    @Test func mismatchedIssIsRejected() {
        let url = URL(string: "http://127.0.0.1:5000/callback?code=c&state=s&iss=https%3A%2F%2Fevil.example.com")!
        #expect(
            MCPOAuthClientMetadata.validateIssuer(callbackURL: url, asm: Self.asm())
                == .mismatch(received: "https://evil.example.com")
        )
    }

    @Test func missingIssIsOnlyRejectedWhenAdvertised() {
        let url = URL(string: "http://127.0.0.1:5000/callback?code=c&state=s")!
        #expect(MCPOAuthClientMetadata.validateIssuer(callbackURL: url, asm: Self.asm()) == .valid)
        #expect(MCPOAuthClientMetadata.validateIssuer(callbackURL: url, asm: Self.asm(issParameter: true)) == .missing)
    }

    // MARK: Token endpoint client authentication

    @Test func clientSecretBasicOnlyWhenPostIsNotAllowed() {
        #expect(!MCPOAuthService.usesClientSecretBasic(nil))
        #expect(!MCPOAuthService.usesClientSecretBasic(["client_secret_post", "client_secret_basic"]))
        #expect(MCPOAuthService.usesClientSecretBasic(["client_secret_basic"]))
    }

    @Test func basicHeaderFormEncodesCredentials() {
        let header = MCPOAuthService.basicAuthorizationHeader(clientId: "id:1", clientSecret: "s&t")
        let decoded = String(data: Data(base64Encoded: String(header.dropFirst("Basic ".count)))!, encoding: .utf8)
        #expect(decoded == "id%3A1:s%26t")
    }

    // MARK: Legacy discovery

    @Test func serverWithoutPRMFallsBackToOriginAuthorizationServer() async throws {
        let discovery = MCPOAuthDiscovery()
        await discovery._setFetcher { url in
            let ok = url.path == "/.well-known/oauth-authorization-server"
            let body =
                ok
                ? #"{"issuer":"https://mcp.example.com","authorization_endpoint":"https://mcp.example.com/authorize","token_endpoint":"https://mcp.example.com/token","registration_endpoint":"https://mcp.example.com/register"}"#
                : "{}"
            let response = HTTPURLResponse(url: url, statusCode: ok ? 200 : 404, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        let (prm, asm) = try await discovery.discover(serverURL: URL(string: "https://mcp.example.com/mcp")!, hint: nil)
        #expect(prm.authorizationServers == ["https://mcp.example.com"])
        #expect(asm.registrationEndpoint == "https://mcp.example.com/register")
    }

    @Test func serverWithNeitherPRMNorOriginASMStillReportsMissingPRM() async {
        let discovery = MCPOAuthDiscovery()
        await discovery._setFetcher { url in
            (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: MCPOAuthDiscoveryError.self) {
            _ = try await discovery.discover(serverURL: URL(string: "https://mcp.example.com/mcp")!, hint: nil)
        }
    }

    // MARK: Tool metadata and results

    @Test func toolTitleAnnotationsAndOutputSchemaPropagate() {
        let tool = MCP.Tool(
            name: "list_matters",
            title: "  List matters ",
            description: "Lists matters",
            inputSchema: .object(["type": .string("object")]),
            annotations: .init(readOnlyHint: true, destructiveHint: true, openWorldHint: false),
            outputSchema: .object(["type": .string("object")])
        )
        let provider = MCPProviderTool(mcpTool: tool, providerId: UUID(), providerName: "Firm")
        #expect(provider.title == "List matters")
        #expect(provider.hints.isReadOnly)
        #expect(!provider.hints.isDestructive)
        #expect(provider.summary.displayName == "List matters")
        #expect(provider.summary.hasOutputSchema)
    }

    @Test func annotationTitleIsUsedWhenToolTitleIsMissing() {
        let tool = MCP.Tool(
            name: "delete_invoice",
            description: nil,
            inputSchema: .object([:]),
            annotations: .init(title: "Delete invoice", destructiveHint: true)
        )
        let provider = MCPProviderTool(mcpTool: tool, providerId: UUID(), providerName: "Books")
        #expect(provider.title == "Delete invoice")
        #expect(provider.hints.isDestructive)
        #expect(!provider.summary.hasOutputSchema)
    }

    // MARK: Hint-driven approval defaults

    private func tool(_ annotations: MCP.Tool.Annotations) -> MCPProviderTool {
        MCPProviderTool(
            mcpTool: MCP.Tool(name: "t", description: nil, inputSchema: .object([:]), annotations: annotations),
            providerId: UUID(),
            providerName: "P"
        )
    }

    @Test func readOnlyClosedWorldToolRunsWithoutPrompt() {
        let t = tool(.init(readOnlyHint: true, openWorldHint: false))
        #expect(t.defaultPermissionPolicy == .auto)
        #expect(!t.requiresApprovalEveryCall(argumentsJSON: "{}"))
    }

    @Test func readOnlyToolWithoutOpenWorldHintRunsWithoutPrompt() {
        let t = tool(.init(readOnlyHint: true))
        #expect(t.defaultPermissionPolicy == .auto)
        #expect(!t.requiresApprovalEveryCall(argumentsJSON: "{}"))
    }

    @Test func readOnlyOpenWorldToolStillAsks() {
        let t = tool(.init(readOnlyHint: true, openWorldHint: true))
        #expect(t.defaultPermissionPolicy == .ask)
        #expect(!t.requiresApprovalEveryCall(argumentsJSON: "{}"))
    }

    @Test func unannotatedToolIsConfirmedEveryCall() {
        let t = tool(.init())
        #expect(t.defaultPermissionPolicy == .ask)
        #expect(t.requiresApprovalEveryCall(argumentsJSON: "{}"))
    }

    @Test func explicitlyNonDestructiveWriteToolAllowsALease() {
        let t = tool(.init(readOnlyHint: false, destructiveHint: false))
        #expect(t.defaultPermissionPolicy == .ask)
        #expect(!t.requiresApprovalEveryCall(argumentsJSON: "{}"))
    }

    @Test func destructiveToolIsConfirmedEveryCall() {
        let t = tool(.init(destructiveHint: true, openWorldHint: false))
        #expect(t.defaultPermissionPolicy == .ask)
        #expect(t.requiresApprovalEveryCall(argumentsJSON: "{}"))
    }

    @Test func resourceLinkIsKept() throws {
        let output = try MCPProviderTool.convertMCPContent(
            [
                .text(text: "Found one contract.", annotations: nil, _meta: nil),
                .resourceLink(
                    uri: "https://files.example.com/c.pdf", name: "c.pdf", title: "Contract",
                    mimeType: "application/pdf"
                ),
            ],
            toolName: "search"
        )
        #expect(output.contains("resource_link"))
        #expect(output.contains("https:\\/\\/files.example.com\\/c.pdf") || output.contains("https://files.example.com/c.pdf"))
        #expect(output.contains("application\\/pdf") || output.contains("application/pdf"))
    }

    @Test func structuredContentIsUsedOnlyWithoutText() throws {
        let structured: MCP.Value = .object(["balance": .int(42)])
        let fallback = try MCPProviderTool.convertMCPContent([], structuredContent: structured, toolName: "balance")
        #expect(fallback.contains("balance"))
        #expect(fallback.contains("42"))

        let mirrored = try MCPProviderTool.convertMCPContent(
            [.text(text: "Balance is 42", annotations: nil, _meta: nil)],
            structuredContent: structured,
            toolName: "balance"
        )
        #expect(mirrored.contains("Balance is 42"))
        #expect(!mirrored.contains(":42"))
    }

    // MARK: Scope step-up

    @Test func stepUpScopesKeepGrantedAccess() {
        #expect(
            MCPScopeStepUp.merged(current: ["read", "write"], required: MCPScopeStepUp.split("write  admin"))
                == ["read", "write", "admin"]
        )
        #expect(MCPScopeStepUp.merged(current: [], required: [""]) == [])
    }

    @Test func forbiddenErrorIsRecognized() {
        #expect(MCPProviderManager.isForbiddenError(MCPError.internalError("Access forbidden")))
        #expect(!MCPProviderManager.isForbiddenError(MCPError.internalError("Something else")))
        #expect(!MCPProviderManager.isForbiddenError(URLError(.timedOut)))
    }

    // MARK: Cancellation

    @Test func timedOutToolCallCancelsTheServerRequest() async throws {
        let observed = CancellationObserver()
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "slow", version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await observed.markHandlerCancelled()
                throw error
            }
            return .init(content: [])
        }
        await server.onNotification(CancelledNotification.self) { message in
            await observed.record(reason: message.params.reason)
        }
        try await server.start(transport: serverTransport)
        let client = Client(name: "osaurus-test", version: "1")
        _ = try await client.connect(transport: clientTransport)

        await #expect(throws: MCPProviderError.self) {
            _ = try await MCPProviderManager.callMCPTool(
                client: client, toolName: "slow", arguments: [:], timeout: 0.3
            )
        }

        for _ in 0..<50 where await !observed.handlerCancelled {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await observed.handlerCancelled)
        #expect(await observed.reasons.first??.hasPrefix("Timed out") == true)
        await client.disconnect()
        await server.stop()
    }
}

private actor CancellationObserver {
    var handlerCancelled = false
    var reasons: [String?] = []
    func markHandlerCancelled() { handlerCancelled = true }
    func record(reason: String?) { reasons.append(reason) }
}
