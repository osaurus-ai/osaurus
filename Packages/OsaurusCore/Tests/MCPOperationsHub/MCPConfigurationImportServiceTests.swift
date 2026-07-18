//
//  MCPConfigurationImportServiceTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct MCPConfigurationImportServiceTests {
    @Test func importsStdioAndHTTPServersWithoutPersistingSecretsInPreview() throws {
        let servers = try parse(
            """
            {
              "mcpServers": {
                "files": {
                  "type": "stdio",
                  "command": "/opt/homebrew/bin/uvx",
                  "args": ["server", "/Users/alice/private"],
                  "cwd": "/Users/alice/work",
                  "env": {
                    "GITHUB_TOKEN": "secret-token-value",
                    "LOG_LEVEL": "info"
                  }
                },
                "remote": {
                  "type": "sse",
                  "url": "https://mcp.example.test/events?tenant=private",
                  "headers": {
                    "Authorization": "Bearer secret-header-value",
                    "X-Mode": "test"
                  }
                }
              }
            }
            """
        )

        #expect(servers.count == 2)
        let files = try #require(servers.first { $0.name == "files" })
        #expect(files.transport == .stdio)
        #expect(files.referencesHostPaths)
        #expect(files.environment.first { $0.key == "GITHUB_TOKEN" }?.isSecret == true)
        #expect(files.environment.first { $0.key == "LOG_LEVEL" }?.isSecret == false)
        #expect(!files.reporterSafeSummary.contains("secret-token-value"))
        #expect(!files.reporterSafeSummary.contains("/Users/alice"))

        let remote = try #require(servers.first { $0.name == "remote" })
        #expect(remote.transport == .http)
        #expect(remote.streamingEnabled)
        #expect(remote.headers.first { $0.key == "Authorization" }?.isSecret == true)
        #expect(!remote.reporterSafeSummary.contains("secret-header-value"))
        #expect(!remote.reporterSafeSummary.contains("mcp.example.test"))
    }

    @Test func importsSingleNamedServerAndStreamableHTTP() throws {
        let server = try #require(
            parse(
                """
                {
                  "name": "company-search",
                  "type": "streamable-http",
                  "url": "https://mcp.example.test/mcp"
                }
                """
            ).first
        )

        #expect(server.name == "company-search")
        #expect(server.transport == .http)
        #expect(!server.streamingEnabled)
    }

    @Test func rejectsDuplicateKeysIncludingEscapedAliases() {
        expectFailure(.duplicateKey, json: #"{"mcpServers":{"a":{"command":"one","\u0063ommand":"two"}}}"#)
    }

    @Test func rejectsMixedAndConflictingTransportShapes() {
        expectFailure(
            .mixedTransport,
            json: #"{"name":"mixed","command":"npx","url":"https://example.test"}"#
        )
        expectFailure(
            .mixedTransport,
            json: #"{"name":"wrong","type":"stdio","url":"https://example.test"}"#
        )
        expectFailure(
            .unsupportedTransport,
            json: #"{"name":"wrong","type":"websocket","url":"https://example.test"}"#
        )
    }

    @Test func rejectsUnsafeHeadersAndEmbeddedURLCredentials() {
        expectFailure(
            .unsafeValue,
            json: "{\"name\":\"bad\",\"url\":\"https://example.test\",\"headers\":{\"X-Test\":\"ok\\r\\nInjected: yes\"}}"
        )
        expectFailure(
            .invalidURL,
            json: #"{"name":"bad","url":"https://user:password@example.test/mcp"}"#
        )
    }

    @Test func rejectsNonStringValuesAndOversizedCollections() throws {
        expectFailure(
            .invalidField,
            json: #"{"name":"bad","command":"npx","args":[1]}"#
        )
        expectFailure(
            .invalidField,
            json: #"{"name":"bad","command":"npx","args":"--version"}"#
        )
        expectFailure(
            .invalidField,
            json: #"{"name":"bad","command":"npx","env":[]}"#
        )
        let args = Array(repeating: "x", count: MCPConfigurationImportService.maximumArguments + 1)
        let object: [String: Any] = ["name": "large", "command": "npx", "args": args]
        let data = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try MCPConfigurationImportService.parse(data)
            Issue.record("Expected oversized argument list to fail")
        } catch let error as MCPConfigurationImportFailure {
            #expect(error.reason == .tooManyValues)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func classifiesCommonSecretNamesConservatively() {
        for key in [
            "API_KEY", "APIKEY", "OPENAI_APIKEY", "OPENAI_KEY", "GH_PAT",
            "client-secret", "AUTH_TOKEN", "PASSWORD", "SUPABASE_SERVICE_ROLE",
            "AWS_ACCESS_KEY_ID", "AZURE_CLIENT_ID", "DATABASE_URL", "MYSQL_PWD",
            "SESSION_ID",
        ] {
            #expect(MCPConfigurationImportService.likelySecretKey(key))
        }
        for header in ["Authorization", "X-ApiKey", "X-Secret", "X-Password"] {
            #expect(MCPConfigurationImportService.likelySecretKey(header, isHeader: true))
        }
        #expect(!MCPConfigurationImportService.likelySecretKey("LOG_LEVEL"))
        #expect(!MCPConfigurationImportService.likelySecretKey("Accept", isHeader: true))
    }

    @Test func setupFingerprintChangesForEverySecretAndProviderInput() {
        let provider = MCPProvider(
            name: "fixture",
            url: "",
            authType: .none,
            transport: .stdio,
            command: "/usr/bin/env",
            args: ["node", "server.js"],
            env: ["LOG_LEVEL": "info"],
            secretEnvKeys: ["TOKEN"]
        )
        let original = MCPProviderSetupFingerprint.make(
            provider: provider,
            bearerToken: nil,
            secretHeaderValues: [:],
            secretEnvironmentValues: ["TOKEN": "one"]
        )
        let changedSecret = MCPProviderSetupFingerprint.make(
            provider: provider,
            bearerToken: nil,
            secretHeaderValues: [:],
            secretEnvironmentValues: ["TOKEN": "two"]
        )
        var changedProvider = provider
        changedProvider.args.append("--verbose")
        let changedArgument = MCPProviderSetupFingerprint.make(
            provider: changedProvider,
            bearerToken: nil,
            secretHeaderValues: [:],
            secretEnvironmentValues: ["TOKEN": "one"]
        )

        #expect(original != changedSecret)
        #expect(original != changedArgument)
        #expect(!original.contains("one"))
    }

    @Test func draftSecretOverridesReachOnlyDeclaredSecretEnvironmentKeys() {
        let provider = MCPProvider(
            name: "fixture",
            url: "",
            authType: .none,
            transport: .stdio,
            command: "/usr/bin/env",
            env: ["LOG_LEVEL": "info"],
            secretEnvKeys: ["TOKEN"]
        )

        let environment = MCPStdioEnvironmentResolver.providerEnvironment(
            provider: provider,
            secretEnvOverrides: [
                "TOKEN": "in-memory-only",
                "UNDECLARED": "must-not-pass",
            ]
        )

        #expect(environment["LOG_LEVEL"] == "info")
        #expect(environment["TOKEN"] == "in-memory-only")
        #expect(environment["UNDECLARED"] == nil)
        #expect(provider.env["TOKEN"] == nil)
    }

    @Test func probeGateRejectsStaleCompletionAndBindsSuccessToCurrentInputs() {
        var gate = MCPProviderProbeGate()
        let first = gate.start(fingerprint: "first")
        let second = gate.start(fingerprint: "second")

        let acceptedFirst = gate.accept(first, currentFingerprint: "second", succeeded: true)
        #expect(!acceptedFirst)
        #expect(!gate.hasCurrentSuccess(fingerprint: "first"))
        let acceptedEdited = gate.accept(second, currentFingerprint: "edited", succeeded: true)
        #expect(!acceptedEdited)
        let acceptedSecond = gate.accept(second, currentFingerprint: "second", succeeded: true)
        #expect(acceptedSecond)
        #expect(gate.hasCurrentSuccess(fingerprint: "second"))
        #expect(!gate.hasCurrentSuccess(fingerprint: "edited"))

        let failedRetry = gate.start(fingerprint: "second")
        let acceptedFailure = gate.accept(
            failedRetry,
            currentFingerprint: "second",
            succeeded: false
        )
        #expect(acceptedFailure)
        #expect(!gate.hasCurrentSuccess(fingerprint: "second"))

        let invalidated = gate.start(fingerprint: "second")
        gate.invalidate()
        let acceptedInvalidated = gate.accept(
            invalidated,
            currentFingerprint: "second",
            succeeded: true
        )
        #expect(!acceptedInvalidated)
    }

    private func parse(_ json: String) throws -> [MCPImportedServerConfiguration] {
        try MCPConfigurationImportService.parse(Data(json.utf8))
    }

    private func expectFailure(_ reason: MCPConfigurationImportReason, json: String) {
        do {
            _ = try? JSONSerialization.jsonObject(with: Data(json.utf8))
            _ = try MCPConfigurationImportService.parse(Data(json.utf8))
            Issue.record("Expected import to fail with \(reason.rawValue)")
        } catch let error as MCPConfigurationImportFailure {
            #expect(error.reason == reason)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
