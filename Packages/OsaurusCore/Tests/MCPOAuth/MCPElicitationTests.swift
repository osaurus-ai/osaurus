//
//  MCPElicitationTests.swift
//  osaurusTests
//

import Foundation
import MCP
import Testing

@testable import OsaurusCore

@Suite("MCP elicitation schema")
struct MCPElicitationSchemaTests {
    private func schema(_ properties: [String: Value], required: [String] = []) -> Elicitation.RequestSchema {
        Elicitation.RequestSchema(properties: properties, required: required)
    }

    @Test func parsesFlatPrimitiveFieldsRequiredFirst() throws {
        let form = try MCPElicitationForm.parse(
            schema(
                [
                    "notes": .object(["type": "string", "title": "Notes"]),
                    "email": .object(["type": "string", "format": "email", "title": "Work email"]),
                    "seats": .object(["type": "integer", "minimum": 1, "maximum": 50, "default": 5]),
                    "agree": .object(["type": "boolean", "default": true]),
                    "court": .object([
                        "type": "string", "enum": ["fed", "state"], "enumNames": ["Federal", "State"],
                    ]),
                    "tier": .object([
                        "type": "string",
                        "oneOf": [.object(["const": "pro", "title": "Pro"]), .object(["const": "basic"])],
                    ]),
                ],
                required: ["email", "seats"]))

        #expect(form.fields.map(\.key) == ["email", "seats", "agree", "court", "notes", "tier"])
        #expect(form.fields[0].title == "Work email")
        #expect(form.fields[0].required)
        #expect(form.fields[0].kind == .text(format: .email, minLength: nil, maxLength: nil))
        #expect(form.fields[1].kind == .number(integer: true, minimum: 1, maximum: 50))
        #expect(form.fields[1].defaultValue == .text("5"))
        #expect(form.fields[2].defaultValue == .flag(true))
        #expect(form.fields[3].kind == .choice([.init(value: "fed", label: "Federal"), .init(value: "state", label: "State")]))
        #expect(form.fields[5].kind == .choice([.init(value: "pro", label: "Pro"), .init(value: "basic", label: "basic")]))
    }

    @Test(arguments: [
        Value.object(["type": "object", "properties": .object([:])]),
        Value.object(["type": "array", "items": .object(["type": "string", "enum": ["a"]])]),
        Value.object(["type": "string", "format": "password"]),
        Value.string("not a schema"),
    ])
    func rejectsAnythingButFlatPrimitives(_ property: Value) {
        #expect(throws: MCPElicitationSchemaError.self) {
            try MCPElicitationForm.parse(schema(["field": property]))
        }
    }

    @Test func validationConvertsTypesAndReportsPerField() throws {
        let form = try MCPElicitationForm.parse(
            schema(
                [
                    "email": .object(["type": "string", "format": "email"]),
                    "seats": .object(["type": "integer", "minimum": 1, "maximum": 50]),
                    "rate": .object(["type": "number"]),
                    "agree": .object(["type": "boolean"]),
                    "notes": .object(["type": "string", "maxLength": 5]),
                ],
                required: ["email", "seats", "agree"]))

        guard case .failure(let errors) = form.content(from: ["email": .text("nope"), "seats": .text("99")]) else {
            Issue.record("expected validation errors")
            return
        }
        #expect(Set(errors.messages.keys) == ["email", "seats", "agree"])

        let ok = form.content(from: [
            "email": .text(" ada@example.com "), "seats": .text("3"), "rate": .text("2.5"),
            "agree": .flag(false), "notes": .text(""),
        ])
        #expect(
            ok == .success([
                "email": .string("ada@example.com"), "seats": .int(3), "rate": .double(2.5), "agree": .bool(false),
            ]))

        guard case .failure(let tooLong) = form.content(from: [
            "email": .text("a@b.co"), "seats": .text("1"), "agree": .flag(true), "notes": .text("too long"),
        ]) else {
            Issue.record("expected maxLength error")
            return
        }
        #expect(tooLong.messages.keys.sorted() == ["notes"])
    }

    @Test func onlyWebURLsAreOpenable() {
        #expect(MCPElicitationURLPolicy.openableURL("https://app.clio.com/oauth?x=1") != nil)
        #expect(MCPElicitationURLPolicy.openableURL("http://127.0.0.1:8080/cb") != nil)
        #expect(MCPElicitationURLPolicy.openableURL("http://evil.example/login") == nil)
        #expect(MCPElicitationURLPolicy.openableURL("javascript:alert(1)") == nil)
        #expect(MCPElicitationURLPolicy.openableURL("file:///etc/passwd") == nil)
        #expect(MCPElicitationURLPolicy.openableURL("x-apple.systempreferences:com.apple") == nil)
    }
}

/// Real SDK client/server pair. The fake server's `ask` tool elicits from the
/// client and reports what came back as its text result.
@Suite("MCP elicitation round trip", .serialized)
@MainActor
struct MCPElicitationRoundTripTests {
    private static let formSchema = Elicitation.RequestSchema(
        title: "Matter intake",
        properties: ["client": .object(["type": "string", "title": "Client name"])],
        required: ["client"])

    private enum Ask: Sendable {
        case form(Elicitation.RequestSchema)
        case url(String, completeAfter: Duration?)
    }

    private func connect(_ ask: Ask) async throws -> (Client, Server) {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "elicit", version: "1", capabilities: .init(tools: .init()))
        await server.withMethodHandler(CallTool.self) { [weak server] _ in
            guard let server else { throw MCPError.internalError("gone") }
            let result: CreateElicitation.Result
            do {
                switch ask {
                case .form(let schema):
                    result = try await server.requestElicitation(message: "Who is the client?", requestedSchema: schema)
                case .url(let url, let completeAfter):
                    if let completeAfter {
                        Task {
                            try await Task.sleep(for: completeAfter)
                            try await server.notify(ElicitationCompleteNotification.message(.init(elicitationId: "e-1")))
                        }
                    }
                    result = try await server.requestElicitation(
                        message: "Finish connecting", url: url, elicitationId: "e-1")
                }
            } catch {
                return .init(content: [.text(text: "error", annotations: nil, _meta: nil)], isError: true)
            }
            let client = result.content?["client"]?.stringValue ?? ""
            return .init(content: [.text(text: "\(result.action.rawValue):\(client)", annotations: nil, _meta: nil)])
        }
        try await server.start(transport: serverTransport)

        let client = Client(name: "osaurus-test", version: "1", capabilities: MCPProviderManager.clientCapabilities)
        await MCPProviderManager.installElicitationHandling(on: client, providerName: "Clio")
        _ = try await client.connect(transport: clientTransport)
        return (client, server)
    }

    private func callAsk(_ client: Client) async throws -> String {
        let result = try await MCPProviderManager.callMCPTool(
            client: client, toolName: "ask", arguments: [:], timeout: 5)
        guard case .text(let text, _, _)? = result.content.first else { return "" }
        return text
    }

    private func withPresenter<T>(
        _ presenter: @escaping (MCPElicitationRequest) -> Void,
        _ body: () async throws -> T
    ) async rethrows -> T {
        MCPElicitationPromptService.presentationOverrideForTests = presenter
        defer { MCPElicitationPromptService.presentationOverrideForTests = nil }
        return try await body()
    }

    @Test(arguments: [
        (MCPElicitationOutcome.accept(["client": .string("Acme LLP")]), "accept:Acme LLP"),
        (.decline, "decline:"),
        (.cancel, "cancel:"),
    ])
    func formOutcomeReachesTheServer(_ outcome: MCPElicitationOutcome, _ expected: String) async throws {
        let (client, server) = try await connect(.form(Self.formSchema))
        var seen: MCPElicitationRequest?
        let text = try await withPresenter({ request in
            seen = request
            MCPElicitationPromptService.performForTesting(id: request.id, .respond(outcome))
        }) { try await callAsk(client) }

        #expect(text == expected)
        let request = try #require(seen)
        #expect(request.providerName == "Clio")
        #expect(request.message == "Who is the client?")
        guard case .form(let form) = request.mode else {
            Issue.record("expected form mode")
            return
        }
        #expect(form.title == "Matter intake")
        #expect(form.fields.map(\.key) == ["client"])
        await client.disconnect()
        await server.stop()
    }

    @Test func headlessCallsCancelWithoutPrompting() async throws {
        let (client, server) = try await connect(.form(Self.formSchema))
        var prompted = false
        let text = try await withPresenter({ request in
            prompted = true
            MCPElicitationPromptService.performForTesting(id: request.id, .respond(.accept([:])))
        }) {
            try await ChatExecutionContext.$denyUnapprovedToolPrompts.withValue(true) {
                try await callAsk(client)
            }
        }
        #expect(text == "cancel:")
        #expect(!prompted)
        await client.disconnect()
        await server.stop()
    }

    @Test func externalCallersCancelWithoutPrompting() async throws {
        let (client, server) = try await connect(.form(Self.formSchema))
        var prompted = false
        let text = try await withPresenter({ _ in prompted = true }) {
            try await ChatExecutionContext.$isExternalSurface.withValue(true) {
                try await callAsk(client)
            }
        }
        #expect(text == "cancel:")
        #expect(!prompted)
        await client.disconnect()
        await server.stop()
    }

    @Test func unsupportedSchemaIsAnErrorNotAPrompt() async throws {
        let nested = Elicitation.RequestSchema(properties: ["address": .object(["type": "object"])])
        let (client, server) = try await connect(.form(nested))
        var prompted = false
        let text = try await withPresenter({ _ in prompted = true }) { try await callAsk(client) }
        #expect(text == "error")
        #expect(!prompted)
        await client.disconnect()
        await server.stop()
    }

    @Test func urlModeAcceptsOnOpenAndClosesOnCompletion() async throws {
        let (client, server) = try await connect(.url("https://app.clio.com/connect", completeAfter: .milliseconds(200)))
        var seen: MCPElicitationRequest?
        try await withPresenter({ request in
            seen = request
            MCPElicitationPromptService.performForTesting(id: request.id, .openedURL)
        }) {
            #expect(try await callAsk(client) == "accept:")
            // Answered, but the card waits for the server's confirmation.
            #expect(MCPElicitationPromptService.presentedRequestForTesting?.id == seen?.id)
            for _ in 0 ..< 100 where MCPElicitationPromptService.presentedRequestForTesting != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        guard case .url(let url, let id)? = seen?.mode else {
            Issue.record("expected url mode")
            return
        }
        #expect(url.host == "app.clio.com")
        #expect(id == "e-1")
        #expect(MCPElicitationPromptService.presentedRequestForTesting == nil)
        await client.disconnect()
        await server.stop()
    }

    @Test func urlModeDoneClosesWithoutCompletion() async throws {
        let (client, server) = try await connect(.url("https://app.clio.com/connect", completeAfter: nil))
        var seen: MCPElicitationRequest?
        try await withPresenter({ request in
            seen = request
            MCPElicitationPromptService.performForTesting(id: request.id, .openedURL)
        }) {
            #expect(try await callAsk(client) == "accept:")
            let id = try #require(seen?.id)
            // The call ending does not dismiss an answered URL card.
            #expect(MCPElicitationPromptService.presentedRequestForTesting?.id == id)
            MCPElicitationPromptService.performForTesting(id: id, .done)
        }
        #expect(MCPElicitationPromptService.presentedRequestForTesting == nil)
        await client.disconnect()
        await server.stop()
    }

    @Test func nonWebURLIsRefused() async throws {
        let (client, server) = try await connect(.url("file:///etc/passwd", completeAfter: nil))
        var prompted = false
        let text = try await withPresenter({ _ in prompted = true }) { try await callAsk(client) }
        #expect(text == "error")
        #expect(!prompted)
        await client.disconnect()
        await server.stop()
    }

    @Test func endingTheToolCallDismissesItsPrompt() async throws {
        let (client, server) = try await connect(.form(Self.formSchema))
        var seen: MCPElicitationRequest?
        try await withPresenter({ seen = $0 }) {
            let call = Task { try await callAsk(client) }
            for _ in 0 ..< 100 where seen == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(seen != nil)
            call.cancel()
            _ = try? await call.value
            for _ in 0 ..< 100 where MCPElicitationPromptService.presentedRequestForTesting != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(MCPElicitationPromptService.presentedRequestForTesting == nil)
        await client.disconnect()
        await server.stop()
    }
}
