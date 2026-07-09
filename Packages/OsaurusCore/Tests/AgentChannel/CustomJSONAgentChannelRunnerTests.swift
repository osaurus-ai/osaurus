//
//  CustomJSONAgentChannelRunnerTests.swift
//  osaurusTests
//
//  Security coverage for configuration-only custom JSON Agent Channels.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Custom JSON Agent Channel runner", .serialized)
struct CustomJSONAgentChannelRunnerTests {
    @Test func methodAllowlistRejectsUnlistedMethodBeforeHTTP() async {
        let client = RecordingAgentChannelHTTPClient { request in
            Issue.record("HTTP should not be dispatched: \(request)")
            return jsonResponse(for: request, body: #"{"id":"unexpected"}"#)
        }
        let runner = makeRunner(client: client)
        let connection = makeConnection(
            customHTTP: makeConfiguration(
                allowedMethods: ["GET"],
                actions: [
                    .sendMessage: AgentChannelCustomHTTPAction(
                        method: "POST",
                        path: "/rooms/{{input.room_id}}/messages",
                        bodyTemplate: #"{"content":{{input.content}}}"#
                    ),
                ]
            )
        )

        let error = await expectCustomJSONError {
            try await runner.sendMessage(
                connection: connection,
                roomId: "room-1",
                content: "hello",
                confirmSend: true
            )
        }

        guard case .methodNotAllowed(let method, let allowed)? = error else {
            Issue.record("Expected methodNotAllowed, got \(String(describing: error))")
            return
        }
        #expect(method == "POST")
        #expect(allowed == ["GET"])
        #expect(client.requestCount == 0)
    }

    @Test func localAndPrivateIPTargetsAreDeniedBeforeHTTP() async {
        let blockedBaseURLs = [
            "https://localhost",
            "https://127.0.0.1",
            "https://10.0.0.8",
            "https://172.16.0.8",
            "https://192.168.1.9",
            "https://169.254.169.254",
            "https://2130706433",
            "https://0177.0.0.1",
            "https://0x7f000001",
            "https://127.1",
            "https://[::1]",
            "https://[fd00::1]",
        ]

        for baseURL in blockedBaseURLs {
            let client = RecordingAgentChannelHTTPClient { request in
                Issue.record("HTTP should not be dispatched for \(baseURL): \(request)")
                return jsonResponse(for: request, body: #"{"spaces":[]}"#)
            }
            let runner = makeRunner(client: client)
            let connection = makeConnection(
                customHTTP: makeConfiguration(
                    baseURL: baseURL,
                    actions: [
                        .listSpaces: AgentChannelCustomHTTPAction(path: "/spaces"),
                    ]
                )
            )

            let error = await expectCustomJSONError {
                try await runner.listSpaces(connection: connection)
            }

            guard case .blockedURL? = error else {
                Issue.record("Expected blockedURL for \(baseURL), got \(String(describing: error))")
                continue
            }
            #expect(client.requestCount == 0)
        }
    }

    @Test func plainHTTPAndDisallowedHostsAreDeniedBeforeHTTP() async {
        let cases: [(baseURL: String, allowedHosts: [String], allowInsecureHTTP: Bool)] = [
            ("http://api.example.com", [], false),
            ("https://api.example.com", ["other.example.com"], false),
        ]

        for testCase in cases {
            let client = RecordingAgentChannelHTTPClient { request in
                Issue.record("HTTP should not be dispatched for \(testCase.baseURL): \(request)")
                return jsonResponse(for: request, body: #"{"spaces":[]}"#)
            }
            let runner = makeRunner(client: client)
            let connection = makeConnection(
                customHTTP: makeConfiguration(
                    baseURL: testCase.baseURL,
                    allowedHosts: testCase.allowedHosts,
                    allowInsecureHTTP: testCase.allowInsecureHTTP,
                    actions: [.listSpaces: AgentChannelCustomHTTPAction(path: "/spaces")]
                )
            )

            let error = await expectCustomJSONError {
                try await runner.listSpaces(connection: connection)
            }

            guard case .blockedURL? = error else {
                Issue.record("Expected blockedURL for \(testCase.baseURL), got \(String(describing: error))")
                continue
            }
            #expect(client.requestCount == 0)
        }
    }

    @Test func listRoomsRequiresExplicitSpaceAllowlistBeforeHTTP() async {
        let client = RecordingAgentChannelHTTPClient { request in
            Issue.record("HTTP should not be dispatched without an allowlisted space: \(request)")
            return jsonResponse(for: request, body: #"{"rooms":[]}"#)
        }
        let runner = makeRunner(client: client)
        let connection = makeConnection(
            spaceAllowlist: [],
            customHTTP: makeConfiguration(
                actions: [.listRooms: AgentChannelCustomHTTPAction(path: "/spaces/{{input.space_id}}/rooms")]
            )
        )

        let error = await expectCustomJSONError {
            try await runner.listRooms(connection: connection, spaceId: "ops")
        }

        guard case .spaceNotAllowlisted(let spaceId, let connectionId)? = error else {
            Issue.record("Expected spaceNotAllowlisted, got \(String(describing: error))")
            return
        }
        #expect(spaceId == "ops")
        #expect(connectionId == "custom-json")
        #expect(client.requestCount == 0)
    }

    @Test func managerRejectsUnsafeBaseURLBeforeSave() async throws {
        try await withIsolatedAgentChannelConfiguration {
            let manager = AgentChannelConnectionManager()
            let unsafeBaseURL = "https://127.0.0.1"

            #expect(throws: AgentChannelConnectionManagerError.invalidCustomHTTPBaseURL(unsafeBaseURL)) {
                try manager.upsertConnection(
                    makeConnection(
                        customHTTP: makeConfiguration(
                            baseURL: unsafeBaseURL,
                            actions: [.listSpaces: AgentChannelCustomHTTPAction(path: "/spaces")]
                        )
                    )
                )
            }
        }
    }

    @Test func queryTemplateEscapesInputWithoutAddingSiblingParameters() async throws {
        let injected = "find me&role=admin+plus?x#frag"
        let client = RecordingAgentChannelHTTPClient { request in
            let url = try #require(request.url)
            #expect(url.absoluteString.contains("q=find%20me%26role%3Dadmin%2Bplus%3Fx%23frag"))
            #expect(url.absoluteString.contains("&role=admin") == false)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let queryItems = components.queryItems ?? []
            #expect(queryItems.filter { $0.name == "q" }.map(\.value) == [injected])
            #expect(queryItems.contains { $0.name == "role" } == false)
            return jsonResponse(for: request, body: #"{"messages":[]}"#)
        }
        let runner = makeRunner(client: client)
        let connection = makeConnection(
            customHTTP: makeConfiguration(
                actions: [
                    .searchMessages: AgentChannelCustomHTTPAction(
                        path: "/search",
                        query: ["q": "{{input.query}}"]
                    ),
                ]
            )
        )

        let result = try await runner.searchMessages(
            connection: connection,
            query: injected,
            roomIds: ["room-1"],
            limitPerRoom: nil,
            maxMatches: nil
        )

        #expect(client.requestCount == 1)
        #expect(result["match_count"] as? Int == 0)
    }

    @Test func jsonBodyTemplateEscapesInputRatherThanInjecting() async throws {
        let injected = #"hello"},"admin":true,"x":""#
        let client = RecordingAgentChannelHTTPClient { request in
            #expect(request.url?.absoluteString.contains("/rooms/room%201/messages") == true)
            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["content"] as? String == injected)
            #expect(object["admin"] == nil)
            return jsonResponse(for: request, body: #"{"id":"m1","content":"ok"}"#)
        }
        let runner = makeRunner(client: client)
        let connection = makeConnection(
            writeRooms: ["room 1"],
            customHTTP: makeConfiguration(
                actions: [
                    .sendMessage: AgentChannelCustomHTTPAction(
                        method: "POST",
                        path: "/rooms/{{input.room_id}}/messages",
                        headers: ["Content-Type": "application/json"],
                        bodyTemplate: #"{"content":{{input.content}}}"#
                    ),
                ]
            )
        )

        let result = try await runner.sendMessage(
            connection: connection,
            roomId: "room 1",
            content: injected,
            confirmSend: true
        )

        #expect(client.requestCount == 1)
        #expect(result["delivery_status"] as? String == "confirmed")
        guard let message = result["message"] as? [String: Any] else {
            Issue.record("Missing mapped message")
            return
        }
        #expect(message["id"] as? String == "m1")
    }

    @Test func nonJSONBodyTemplatesRejectPlaceholdersBeforeHTTP() async {
        let client = RecordingAgentChannelHTTPClient { request in
            Issue.record("HTTP should not be dispatched for unsafe non-JSON body template: \(request)")
            return jsonResponse(for: request, body: #"{"id":"unexpected"}"#)
        }
        let runner = makeRunner(client: client)
        let connection = makeConnection(
            customHTTP: makeConfiguration(
                actions: [
                    .sendMessage: AgentChannelCustomHTTPAction(
                        method: "POST",
                        path: "/rooms/{{input.room_id}}/messages",
                        headers: ["Content-Type": "application/x-www-form-urlencoded"],
                        bodyTemplate: "content={{input.content}}"
                    ),
                ]
            )
        )

        let error = await expectCustomJSONError {
            try await runner.sendMessage(
                connection: connection,
                roomId: "room-1",
                content: "hello&admin=true",
                confirmSend: true
            )
        }

        guard case .invalidRequest(let message)? = error else {
            Issue.record("Expected invalidRequest, got \(String(describing: error))")
            return
        }
        #expect(message.contains("Non-JSON body templates"))
        #expect(client.requestCount == 0)
    }

    @Test func secretReferencesAreRedactedFromDiagnosticsAndProviderErrors() async {
        let secret = "super-secret-token"
        let client = RecordingAgentChannelHTTPClient { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(secret)")
            return jsonResponse(for: request, body: #"{"error":"super-secret-token leaked"}"#, status: 500)
        }
        let runner = makeRunner(client: client, secrets: ["api_token": secret])
        let connection = makeConnection(
            secrets: [
                AgentChannelSecretReference(name: "api_token", keychainId: "custom-api-token"),
            ],
            customHTTP: makeConfiguration(
                actions: [
                    .listSpaces: AgentChannelCustomHTTPAction(
                        path: "/spaces",
                        headers: ["Authorization": "Bearer {{secret.api_token}}"]
                    ),
                ]
            )
        )

        let diagnostics = await runner.diagnostics(connection: connection)
        let diagnosticsText = String(describing: diagnostics)
        #expect(!diagnosticsText.contains(secret))
        #expect(diagnosticsText.contains("api_token"))

        let error = await expectCustomJSONError {
            try await runner.listSpaces(connection: connection)
        }
        let description = error?.localizedDescription ?? ""
        #expect(!description.contains(secret))
        #expect(description.contains("[REDACTED:api_token]"))
        #expect(client.requestCount == 1)
    }

    @Test func draftMessageRedactsSecretURLAndNeverDispatchesHTTP() throws {
        let secret = "super+secret=token&x?y#z"
        let client = RecordingAgentChannelHTTPClient { request in
            Issue.record("HTTP should not be dispatched for draft: \(request)")
            return jsonResponse(for: request, body: #"{"id":"unexpected"}"#)
        }
        let runner = makeRunner(client: client, secrets: ["api_token": secret])
        let connection = makeConnection(
            secrets: [
                AgentChannelSecretReference(name: "api_token", keychainId: "custom-api-token"),
            ],
            customHTTP: makeConfiguration(
                actions: [
                    .draftMessage: AgentChannelCustomHTTPAction(
                        method: "POST",
                        path: "/rooms/{{input.room_id}}/{{secret.api_token}}/draft",
                        query: ["token": "{{secret.api_token}}"],
                        headers: ["Authorization": "Bearer {{secret.api_token}}"],
                        bodyTemplate: #"{"content":{{input.content}}}"#
                    ),
                ]
            )
        )

        let result = try runner.draftMessage(connection: connection, roomId: "room-1", content: "draft")
        let resultText = String(describing: result)
        #expect(client.requestCount == 0)
        #expect(!resultText.contains(secret))
        #expect(!resultText.contains("super%2Bsecret%3Dtoken%26x%3Fy%23z"))
        #expect(resultText.contains("[REDACTED:api_token]"))
    }

    @Test func transportErrorsRedactStrictQueryEncodedSecrets() async {
        let secret = "super+secret=token&x?y#z"
        let client = RecordingAgentChannelHTTPClient { request in
            throw EchoingTransportError(message: request.url?.absoluteString ?? "")
        }
        let runner = makeRunner(client: client, secrets: ["api_token": secret])
        let connection = makeConnection(
            secrets: [
                AgentChannelSecretReference(name: "api_token", keychainId: "custom-api-token"),
            ],
            customHTTP: makeConfiguration(
                actions: [
                    .listSpaces: AgentChannelCustomHTTPAction(
                        path: "/spaces",
                        query: ["token": "{{secret.api_token}}"]
                    ),
                ]
            )
        )

        let error = await expectCustomJSONError {
            try await runner.listSpaces(connection: connection)
        }

        let description = error?.localizedDescription ?? ""
        #expect(!description.contains(secret))
        #expect(!description.contains("super%2Bsecret%3Dtoken%26x%3Fy%23z"))
        #expect(description.contains("[REDACTED:api_token"))
        #expect(client.requestCount == 1)
    }

    @Test func idempotencySecretTemplateIsRedactedFromDraftAndSendResults() async throws {
        let secret = "super-secret-idempotency-token"
        let client = RecordingAgentChannelHTTPClient { request in
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == secret)
            return jsonResponse(for: request, body: #"{}"#)
        }
        let runner = makeRunner(client: client, secrets: ["api_token": secret])
        let connection = makeConnection(
            secrets: [
                AgentChannelSecretReference(name: "api_token", keychainId: "custom-api-token"),
            ],
            customHTTP: makeConfiguration(
                actions: [
                    .draftMessage: AgentChannelCustomHTTPAction(
                        method: "POST",
                        path: "/rooms/{{input.room_id}}/draft",
                        bodyTemplate: #"{"content":{{input.content}}}"#,
                        idempotency: AgentChannelCustomHTTPIdempotency(keyTemplate: "{{secret.api_token}}")
                    ),
                    .sendMessage: AgentChannelCustomHTTPAction(
                        method: "POST",
                        path: "/rooms/{{input.room_id}}/messages",
                        bodyTemplate: #"{"content":{{input.content}}}"#,
                        idempotency: AgentChannelCustomHTTPIdempotency(keyTemplate: "{{secret.api_token}}")
                    ),
                ]
            )
        )

        let draft = try runner.draftMessage(connection: connection, roomId: "room-1", content: "draft")
        let result = try await runner.sendMessage(
            connection: connection,
            roomId: "room-1",
            content: "draft",
            confirmSend: true
        )
        let combined = [String(describing: draft), String(describing: result)].joined(separator: " ")
        #expect(!combined.contains(secret))
        #expect(combined.contains("[REDACTED:api_token]"))
        #expect(client.requestCount == 1)
    }

    @Test func invalidHeadersRejectBeforeHTTP() async {
        let cases: [AgentChannelCustomHTTPAction] = [
            AgentChannelCustomHTTPAction(
                path: "/spaces",
                headers: ["Host": "api.example.com"]
            ),
            AgentChannelCustomHTTPAction(
                method: "POST",
                path: "/rooms/{{input.room_id}}/messages",
                bodyTemplate: #"{"content":{{input.content}}}"#,
                idempotency: AgentChannelCustomHTTPIdempotency(keyTemplate: "{{input.content}}")
            ),
        ]

        for action in cases {
            let client = RecordingAgentChannelHTTPClient { request in
                Issue.record("HTTP should not be dispatched for invalid headers: \(request)")
                return jsonResponse(for: request, body: #"{"id":"unexpected"}"#)
            }
            let runner = makeRunner(client: client)
            let connection = makeConnection(
                customHTTP: makeConfiguration(actions: [.sendMessage: action, .listSpaces: action])
            )

            let error = await expectCustomJSONError {
                if action.method == "POST" {
                    _ = try await runner.sendMessage(
                        connection: connection,
                        roomId: "room-1",
                        content: "line one\nline two",
                        confirmSend: true
                    )
                } else {
                    _ = try await runner.listSpaces(connection: connection)
                }
            }

            guard case .invalidRequest? = error else {
                Issue.record("Expected invalidRequest, got \(String(describing: error))")
                continue
            }
            #expect(client.requestCount == 0)
        }
    }

    @Test func disabledWritesRejectBeforeHTTP() async {
        let client = RecordingAgentChannelHTTPClient { request in
            Issue.record("HTTP should not be dispatched: \(request)")
            return jsonResponse(for: request, body: #"{"id":"unexpected"}"#)
        }
        let runner = makeRunner(client: client)
        let connection = makeConnection(
            writeEnabled: false,
            customHTTP: makeConfiguration(
                actions: [
                    .sendMessage: AgentChannelCustomHTTPAction(
                        method: "POST",
                        path: "/rooms/{{input.room_id}}/messages",
                        bodyTemplate: #"{"content":{{input.content}}}"#
                    ),
                ]
            )
        )

        let error = await expectCustomJSONError {
            try await runner.sendMessage(
                connection: connection,
                roomId: "room-1",
                content: "hello",
                confirmSend: true
            )
        }

        guard case .writeDisabled? = error else {
            Issue.record("Expected writeDisabled, got \(String(describing: error))")
            return
        }
        #expect(client.requestCount == 0)
    }

    @Test func authorizationPolicyHookRejectsBeforeHTTP() async {
        let client = RecordingAgentChannelHTTPClient { request in
            Issue.record("HTTP should not be dispatched when policy denies: \(request)")
            return jsonResponse(for: request, body: #"{"messages":[]}"#)
        }
        let policy = DenyingAgentChannelAuthorizationPolicy(message: "group ops-only denied")
        let runner = makeRunner(client: client, authorizationPolicy: policy)
        let connection = makeConnection(
            customHTTP: makeConfiguration(
                actions: [
                    .readMessages: AgentChannelCustomHTTPAction(path: "/rooms/{{input.room_id}}/messages"),
                ]
            )
        )

        let error = await expectCustomJSONError {
            try await runner.readMessages(connection: connection, roomId: "room-1", limit: 10)
        }

        guard case .invalidRequest(let message)? = error else {
            Issue.record("Expected invalidRequest, got \(String(describing: error))")
            return
        }
        #expect(message.contains("Authorization denied"))
        #expect(message.contains("group ops-only denied"))
        #expect(policy.requests.map(\.action) == [.readMessages])
        #expect(policy.requests.map(\.roomId) == ["room-1"])
        #expect(client.requestCount == 0)
    }

    @Test func duplicateDeliveryUsesIdempotencyLedger() async throws {
        let client = RecordingAgentChannelHTTPClient { request in
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key")?.isEmpty == false)
            return jsonResponse(for: request, body: #"{"id":"provider-message-1","content":"sent"}"#)
        }
        let runner = makeRunner(client: client)
        let connection = makeConnection(
            customHTTP: makeConfiguration(
                actions: [
                    .sendMessage: AgentChannelCustomHTTPAction(
                        method: "POST",
                        path: "/rooms/{{input.room_id}}/messages",
                        bodyTemplate: #"{"content":{{input.content}}}"#,
                        idempotency: AgentChannelCustomHTTPIdempotency()
                    ),
                ]
            )
        )

        let first = try await runner.sendMessage(
            connection: connection,
            roomId: "room-1",
            content: "same message",
            confirmSend: true
        )
        let second = try await runner.sendMessage(
            connection: connection,
            roomId: "room-1",
            content: "same message",
            confirmSend: true
        )

        #expect(client.requestCount == 1)
        #expect(first["delivery_status"] as? String == "confirmed")
        #expect(second["delivery_status"] as? String == "duplicate_suppressed")
        #expect(second["duplicate"] as? Bool == true)
        #expect(second["partial_write"] as? Bool == false)
    }

    @Test func concurrentDuplicateDeliveryIsSuppressedWhileFirstSendInFlight() async throws {
        let client = RecordingAgentChannelHTTPClient { request in
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key")?.isEmpty == false)
            try await Task.sleep(nanoseconds: 50_000_000)
            return jsonResponse(for: request, body: #"{"id":"provider-message-1","content":"sent"}"#)
        }
        let runner = makeRunner(client: client)
        let connection = makeConnection(
            customHTTP: makeConfiguration(
                actions: [
                    .sendMessage: AgentChannelCustomHTTPAction(
                        method: "POST",
                        path: "/rooms/{{input.room_id}}/messages",
                        bodyTemplate: #"{"content":{{input.content}}}"#,
                        idempotency: AgentChannelCustomHTTPIdempotency()
                    ),
                ]
            )
        )

        let firstTask = Task<String, Error> {
            let result = try await runner.sendMessage(
                connection: connection,
                roomId: "room-1",
                content: "same in-flight message",
                confirmSend: true
            )
            return result["delivery_status"] as? String ?? ""
        }
        for _ in 0 ..< 100 where client.requestCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let second = try await runner.sendMessage(
            connection: connection,
            roomId: "room-1",
            content: "same in-flight message",
            confirmSend: true
        )
        let firstStatus = try await firstTask.value

        #expect(client.requestCount == 1)
        #expect(firstStatus == "confirmed")
        #expect(second["delivery_status"] as? String == "duplicate_in_flight_suppressed")
        #expect(second["duplicate"] as? Bool == true)
        #expect(second["partial_write"] as? Bool == true)
    }

    @Test func responseExceedingLimitIsRejected() async {
        let client = RecordingAgentChannelHTTPClient { request in
            jsonResponse(for: request, body: String(repeating: "x", count: 1_025))
        }
        let runner = makeRunner(client: client)
        let connection = makeConnection(
            customHTTP: makeConfiguration(
                maxResponseBytes: 1_024,
                actions: [.listSpaces: AgentChannelCustomHTTPAction(path: "/spaces")]
            )
        )

        let error = await expectCustomJSONError {
            try await runner.listSpaces(connection: connection)
        }

        guard case .invalidResponse(let message, nil)? = error else {
            Issue.record("Expected invalidResponse, got \(String(describing: error))")
            return
        }
        #expect(message.contains("1024"))
        #expect(client.responseLimits == [1_024])
        #expect(client.requestCount == 1)
    }

    @Test func managerRejectsInvalidResponseIdPathBeforeSave() async throws {
        try await withIsolatedAgentChannelConfiguration {
            let manager = AgentChannelConnectionManager()
            let invalidPath = "message..id"

            #expect(
                throws: AgentChannelConnectionManagerError.invalidCustomHTTPResponseMapping(
                    action: "send_message",
                    path: invalidPath
                )
            ) {
                try manager.upsertConnection(
                    makeConnection(
                        customHTTP: makeConfiguration(
                            actions: [
                                .sendMessage: AgentChannelCustomHTTPAction(
                                    method: "POST",
                                    path: "/rooms/{{input.room_id}}/messages",
                                    bodyTemplate: #"{"content":{{input.content}}}"#,
                                    idempotency: AgentChannelCustomHTTPIdempotency(
                                        responseIdPath: invalidPath
                                    )
                                ),
                            ]
                        )
                    )
                )
            }
        }
    }

    @Test func responseMappingRejectsUnsupportedPaths() async {
        let client = RecordingAgentChannelHTTPClient { request in
            jsonResponse(for: request, body: #"{"messages":[]}"#)
        }
        let runner = makeRunner(client: client)
        let connection = makeConnection(
            customHTTP: makeConfiguration(
                actions: [
                    .readMessages: AgentChannelCustomHTTPAction(
                        path: "/rooms/{{input.room_id}}/messages",
                        responseMapping: AgentChannelCustomHTTPResponseMapping(itemsPath: "messages..items")
                    ),
                ]
            )
        )

        let error = await expectCustomJSONError {
            try await runner.readMessages(connection: connection, roomId: "room-1", limit: 10)
        }

        guard case .invalidResponse(let message, nil)? = error else {
            Issue.record("Expected invalidResponse, got \(String(describing: error))")
            return
        }
        #expect(message.contains("empty segments"))
        #expect(client.requestCount == 1)
    }

    @Test func responseMappingCapsMappedRows() async throws {
        let spacesJSON = (0 ..< 150)
            .map { #"{"id":"space-\#($0)","name":"Space \#($0)"}"# }
            .joined(separator: ",")
        let client = RecordingAgentChannelHTTPClient { request in
            jsonResponse(for: request, body: #"{"spaces":[\#(spacesJSON)]}"#)
        }
        let runner = makeRunner(client: client)
        let connection = makeConnection(
            customHTTP: makeConfiguration(
                actions: [.listSpaces: AgentChannelCustomHTTPAction(path: "/spaces")]
            )
        )

        let spaces = try await runner.listSpaces(connection: connection)

        #expect(spaces.count == 100)
        #expect(spaces.first?["id"] as? String == "space-0")
        #expect(spaces.last?["id"] as? String == "space-99")
        #expect(client.requestCount == 1)
    }

    @Test func malformedSuccessWriteResponseDoesNotAllowImmediateDuplicateDispatch() async throws {
        let client = RecordingAgentChannelHTTPClient { request in
            jsonResponse(for: request, body: #"{"#)
        }
        let runner = makeRunner(client: client)
        let connection = makeConnection(
            customHTTP: makeConfiguration(
                actions: [
                    .sendMessage: AgentChannelCustomHTTPAction(
                        method: "POST",
                        path: "/rooms/{{input.room_id}}/messages",
                        bodyTemplate: #"{"content":{{input.content}}}"#,
                        idempotency: AgentChannelCustomHTTPIdempotency()
                    ),
                ]
            )
        )

        let error = await expectCustomJSONError {
            try await runner.sendMessage(
                connection: connection,
                roomId: "room-1",
                content: "malformed response",
                confirmSend: true
            )
        }
        guard case .invalidResponse(_, "malformed_write_response")? = error else {
            Issue.record("Expected malformed write response, got \(String(describing: error))")
            return
        }

        let duplicate = try await runner.sendMessage(
            connection: connection,
            roomId: "room-1",
            content: "malformed response",
            confirmSend: true
        )

        #expect(client.requestCount == 1)
        #expect(duplicate["duplicate"] as? Bool == true)
        #expect(duplicate["partial_write"] as? Bool == true)
        #expect(duplicate["delivery_status"] as? String == "duplicate_unconfirmed_suppressed")
    }

    @Test func transportFailureAfterWriteDispatchDoesNotAllowImmediateDuplicateDispatch() async throws {
        let client = RecordingAgentChannelHTTPClient { _ in
            throw URLError(.networkConnectionLost)
        }
        let runner = makeRunner(client: client)
        let connection = makeConnection(
            customHTTP: makeConfiguration(
                actions: [
                    .sendMessage: AgentChannelCustomHTTPAction(
                        method: "POST",
                        path: "/rooms/{{input.room_id}}/messages",
                        bodyTemplate: #"{"content":{{input.content}}}"#,
                        idempotency: AgentChannelCustomHTTPIdempotency()
                    ),
                ]
            )
        )

        let error = await expectCustomJSONError {
            try await runner.sendMessage(
                connection: connection,
                roomId: "room-1",
                content: "transport uncertain",
                confirmSend: true
            )
        }
        guard case .transport(_, "transport_unconfirmed")? = error else {
            Issue.record("Expected transport_unconfirmed, got \(String(describing: error))")
            return
        }

        let duplicate = try await runner.sendMessage(
            connection: connection,
            roomId: "room-1",
            content: "transport uncertain",
            confirmSend: true
        )

        #expect(client.requestCount == 1)
        #expect(duplicate["duplicate"] as? Bool == true)
        #expect(duplicate["partial_write"] as? Bool == true)
        #expect(duplicate["delivery_status"] as? String == "duplicate_unconfirmed_suppressed")
    }

    @Test func malformedReadResponseIsRejected() async {
        let client = RecordingAgentChannelHTTPClient { request in
            jsonResponse(for: request, body: #"{"messages":"not-an-array"}"#)
        }
        let runner = makeRunner(client: client)
        let connection = makeConnection(
            customHTTP: makeConfiguration(
                actions: [
                    .readMessages: AgentChannelCustomHTTPAction(path: "/rooms/{{input.room_id}}/messages"),
                ]
            )
        )

        let error = await expectCustomJSONError {
            try await runner.readMessages(connection: connection, roomId: "room-1", limit: 10)
        }

        guard case .invalidResponse(let message, nil)? = error else {
            Issue.record("Expected invalidResponse, got \(String(describing: error))")
            return
        }
        #expect(message.contains("not an array"))
        #expect(client.requestCount == 1)
    }

    @Test func cancellationAfterWriteDispatchReportsPartialStatus() async throws {
        let client = RecordingAgentChannelHTTPClient { request in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return jsonResponse(for: request, body: #"{"id":"late","content":"sent"}"#)
        }
        let runner = makeRunner(client: client)
        let connection = makeConnection(
            customHTTP: makeConfiguration(
                actions: [
                    .sendMessage: AgentChannelCustomHTTPAction(
                        method: "POST",
                        path: "/rooms/{{input.room_id}}/messages",
                        bodyTemplate: #"{"content":{{input.content}}}"#
                    ),
                ]
            )
        )

        let task = Task<Void, Error> {
            _ = try await runner.sendMessage(
                connection: connection,
                roomId: "room-1",
                content: "cancel me",
                confirmSend: true
            )
        }

        for _ in 0 ..< 100 where client.requestCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(client.requestCount == 1)
        task.cancel()

        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch let error as AgentChannelCustomJSONRunnerError {
            guard case .cancelled(let partialWriteStatus) = error else {
                Issue.record("Expected cancelled, got \(error)")
                return
            }
            #expect(partialWriteStatus == "cancelled_after_dispatch")
        } catch {
            Issue.record("Expected AgentChannelCustomJSONRunnerError, got \(error)")
        }
    }
}

private func makeRunner(
    client: RecordingAgentChannelHTTPClient,
    secrets: [String: String] = [:],
    authorizationPolicy: any AgentChannelCustomJSONAuthorizationPolicy =
        PermissiveAgentChannelCustomJSONAuthorizationPolicy()
) -> AgentChannelCustomJSONRunner {
    AgentChannelCustomJSONRunner(
        httpClient: client,
        secretResolver: StaticAgentChannelSecretResolver(secrets: secrets),
        authorizationPolicy: authorizationPolicy
    )
}

private func makeConfiguration(
    baseURL: String = "https://api.example.com",
    allowedHosts: [String] = [],
    allowedMethods: [String] = ["GET", "POST"],
    allowInsecureHTTP: Bool = false,
    maxResponseBytes: Int = 131_072,
    actions: [AgentChannelAction: AgentChannelCustomHTTPAction]
) -> AgentChannelCustomHTTPConfiguration {
    AgentChannelCustomHTTPConfiguration(
        baseURL: baseURL,
        allowedHosts: allowedHosts,
        allowedMethods: allowedMethods,
        allowInsecureHTTP: allowInsecureHTTP,
        maxResponseBytes: maxResponseBytes,
        actions: Dictionary(uniqueKeysWithValues: actions.map { ($0.rawValue, $1) })
    )
}

private func makeConnection(
    id: String = "custom-json",
    name: String = "Custom JSON",
    spaceAllowlist: [String] = ["space-1"],
    readRooms: [String] = ["room-1"],
    writeRooms: [String] = ["room-1"],
    writeEnabled: Bool = true,
    secrets: [AgentChannelSecretReference] = [],
    customHTTP: AgentChannelCustomHTTPConfiguration
) -> AgentChannelConnection {
    AgentChannelConnection(
        id: id,
        name: name,
        kind: .customHTTP,
        enabled: true,
        supportedActions: AgentChannelAction.allCases,
        spaceAllowlist: spaceAllowlist,
        readRoomAllowlist: readRooms,
        writeRoomAllowlist: writeRooms,
        writeEnabled: writeEnabled,
        secrets: secrets,
        customHTTP: customHTTP
    )
}

private func expectCustomJSONError<T>(
    _ operation: () async throws -> T
) async -> AgentChannelCustomJSONRunnerError? {
    do {
        _ = try await operation()
        Issue.record("Expected AgentChannelCustomJSONRunnerError")
        return nil
    } catch let error as AgentChannelCustomJSONRunnerError {
        return error
    } catch {
        Issue.record("Expected AgentChannelCustomJSONRunnerError, got \(error)")
        return nil
    }
}

private func withIsolatedAgentChannelConfiguration(
    body: @Sendable () async throws -> Void
) async throws {
    try await StoragePathsTestLock.shared.run {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-agent-channel-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousDirectory = AgentChannelConfigurationStore.overrideDirectory
        AgentChannelConfigurationStore.overrideDirectory = directory
        defer {
            AgentChannelConfigurationStore.overrideDirectory = previousDirectory
            try? FileManager.default.removeItem(at: directory)
        }
        try await body()
    }
}

private func jsonResponse(
    for request: URLRequest,
    body: String,
    status: Int = 200
) -> (Data, URLResponse) {
    let response = HTTPURLResponse(
        url: request.url ?? URL(string: "https://api.example.com")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["content-type": "application/json"]
    )!
    return (Data(body.utf8), response)
}

private final class RecordingAgentChannelHTTPClient: AgentChannelHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private var capturedRequests: [URLRequest] = []

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    var requestCount: Int {
        lock.withLock { capturedRequests.count }
    }

    var requests: [URLRequest] {
        lock.withLock { capturedRequests }
    }

    private var capturedResponseLimits: [Int] = []

    var responseLimits: [Int] {
        lock.withLock { capturedResponseLimits }
    }

    func agentChannelData(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { capturedRequests.append(request) }
        return try await handler(request)
    }

    func agentChannelData(for request: URLRequest, maxResponseBytes: Int) async throws -> (Data, URLResponse) {
        lock.withLock {
            capturedRequests.append(request)
            capturedResponseLimits.append(maxResponseBytes)
        }
        let (data, response) = try await handler(request)
        guard data.count <= maxResponseBytes else {
            throw AgentChannelHTTPResponseTooLargeError(maxBytes: maxResponseBytes)
        }
        return (data, response)
    }
}

private struct StaticAgentChannelSecretResolver: AgentChannelSecretResolving {
    var secrets: [String: String]

    func secret(named name: String, keychainId: String, connection: AgentChannelConnection) -> String? {
        secrets[name] ?? secrets[keychainId]
    }
}

private final class DenyingAgentChannelAuthorizationPolicy: AgentChannelCustomJSONAuthorizationPolicy, @unchecked Sendable {
    private let lock = NSLock()
    private let message: String
    private var capturedRequests: [AgentChannelCustomJSONAuthorizationRequest] = []

    init(message: String) {
        self.message = message
    }

    var requests: [AgentChannelCustomJSONAuthorizationRequest] {
        lock.withLock { capturedRequests }
    }

    func authorize(_ request: AgentChannelCustomJSONAuthorizationRequest) throws {
        lock.withLock { capturedRequests.append(request) }
        throw DeniedAgentChannelAuthorization(message: message)
    }
}

private struct DeniedAgentChannelAuthorization: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

private struct EchoingTransportError: LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}
