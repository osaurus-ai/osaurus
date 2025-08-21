//
//  osaurusTests.swift
//  osaurusTests
//
//  Created by Terence on 8/17/25.
//

import Foundation
import NIOHTTP1
import Testing
@testable import osaurus

struct osaurusTests {

    @Test func example() async throws {
        // Basic test to ensure the test framework is working
        #expect(1 + 1 == 2)
    }

    @Test func serverConfiguration_portValidation() async throws {
        var cfg = ServerConfiguration.default
        cfg.port = 0
        #expect(cfg.isValidPort == false)

        cfg.port = 1
        #expect(cfg.isValidPort == true)

        cfg.port = 65_535
        #expect(cfg.isValidPort == true)

        cfg.port = 65_536
        #expect(cfg.isValidPort == false)
    }

    @Test func openAI_toInternalMessages_mapping() async throws {
        let request = ChatCompletionRequest(
            model: "test-model",
            messages: [
                ChatMessage(role: "system", content: "You are a test."),
                ChatMessage(role: "user", content: "Hi"),
                ChatMessage(role: "assistant", content: "Hello"),
                ChatMessage(role: "tool", content: "Ignored role maps to user")
            ],
            temperature: nil,
            max_tokens: nil,
            stream: nil,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil
        )

        let internalMessages = request.toInternalMessages()
        #expect(internalMessages.count == 4)
        #expect(internalMessages[0].role.rawValue == "system")
        #expect(internalMessages[1].role.rawValue == "user")
        #expect(internalMessages[2].role.rawValue == "assistant")
        // Unknown role maps to .user per implementation
        #expect(internalMessages[3].role.rawValue == "user")
    }

    @Test func openAIModel_initFromName_setsFields() async throws {
        let name = "mlx-model"
        let model = OpenAIModel(from: name)
        #expect(model.id == name)
        #expect(model.root == name)
        #expect(model.object == "model")
        #expect(model.owned_by == "osaurus")
        #expect(model.created > 0)
    }

    @Test func router_health_and_root_endpoints() async throws {
        let router = Router()

        let health = router.route(method: "GET", path: "/health")
        #expect(health.status == .ok)
        #expect(health.headers.contains { $0.0.lowercased() == "content-type" && $0.1.contains("application/json") })

        // Parse JSON body
        let data = Data(health.body.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["status"] as? String == "healthy")

        let root = router.route(method: "GET", path: "/")
        #expect(root.status == .ok)
        #expect(root.body.contains("Osaurus Server is running"))
    }

    @Test func router_models_endpoint_returns_list() async throws {
        let router = Router()
        let resp = router.route(method: "GET", path: "/models")
        #expect(resp.status == .ok)
        let data = Data(resp.body.utf8)
        let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
        // In a clean test environment, no models should be downloaded
        #expect(modelsResponse.object == "list")
        #expect(modelsResponse.data.count >= 0)

        // Also check OpenAI-compatible path
        let resp2 = router.route(method: "GET", path: "/v1/models")
        #expect(resp2.status == .ok)
    }

    @Test func router_notFound_for_unknown_path() async throws {
        let router = Router()
        let resp = router.route(method: "POST", path: "/unknown")
        #expect(resp.status == .notFound)
    }

    @Test func router_chatCompletions_withoutContext_returnsServerError() async throws {
        let router = Router()
        let request = ChatCompletionRequest(
            model: "nonexistent",
            messages: [ChatMessage(role: "user", content: "Hello")],
            temperature: 0.5,
            max_tokens: 16,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil
        )
        let body = try JSONEncoder().encode(request)
        let resp = router.route(method: "POST", path: "/chat/completions", body: body)
        #expect(resp.status == HTTPResponseStatus.internalServerError)

        let errorData = Data(resp.body.utf8)
        let errorObj = try JSONDecoder().decode(OpenAIError.self, from: errorData)
        #expect(errorObj.error.message == "Server configuration error")
    }
}
