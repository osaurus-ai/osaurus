//
//  SupportReportBuilderTests.swift
//  osaurusTests
//
//  What a Help report carries besides the user's words: that the preview is
//  the request, that nothing private rides along, and that an oversized
//  bundle shrinks instead of failing the send.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Help report builder", .serialized)
struct SupportReportBuilderTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let app = SupportDiagnosticsBundle.AppSnapshot(
        name: "OsaurusTests", version: "1.2.3", build: "456", osVersion: "Version 26.5 (Build 25F71)")
    private static let profile = MacProfile(modelName: "MacBook Air", chip: "M4", memoryGB: 24)

    private func log(_ index: Int, path: String = "/v1/chat/completions") -> RequestLog {
        RequestLog(
            timestamp: Self.now.addingTimeInterval(TimeInterval(-index)),
            source: .chatUI,
            method: "POST",
            path: path,
            statusCode: 200,
            durationMs: 120,
            model: "provider/model-\(index)",
            inputTokens: 10,
            outputTokens: 5
        )
    }

    private func bundle(
        logs: [RequestLog] = [],
        tools: [SupportDiagnosticsToolInput] = [SupportDiagnosticsToolInput(name: "web_search", enabled: true)],
        recentLogLimit: Int = SupportReportBuilder.recentLogLimit
    ) -> SupportDiagnosticsBundle {
        SupportDiagnosticsBundleBuilder.make(
            generatedAt: Self.now,
            app: Self.app,
            sessionId: "session-raw-value",
            agentName: "Research",
            modelId: "provider/model",
            registeredTools: tools,
            logs: logs,
            recentLogLimit: recentLogLimit
        )
    }

    private func encoded(_ body: OsaurusRouterSupportReportBody) throws -> String {
        String(decoding: try JSONEncoder.osaurusCanonical().encode(body), as: UTF8.self)
    }

    private func object(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let fields)? = value { return fields }
        return [:]
    }

    private func array(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let items)? = value { return items }
        return []
    }

    // MARK: - Shape

    @Test func mapsAppAndHardwareToTheWireShape() throws {
        let report = SupportReportBuilder.make(bundle: bundle(), profile: Self.profile)
        #expect(report.app == .init(version: "1.2.3", build: "456", osVersion: "Version 26.5 (Build 25F71)"))
        #expect(report.hardware == .init(model: "MacBook Air", chip: "M4", memoryGB: 24))
        #expect(report.diagnostics != nil)
        #expect(report.diagnosticsBytes > 0)

        let json = try encoded(report.body(description: "It broke when I did X"))
        #expect(json.contains(#""consent":true"#))
        #expect(json.contains(#""description":"It broke when I did X""#))
        #expect(json.contains(#""os_version":"Version 26.5 (Build 25F71)""#))
        #expect(json.contains(#""memory_gb":24"#))
        #expect(json.contains(#""model":"MacBook Air""#))
    }

    /// Memory that could not be read is left out, not sent as 0 GB.
    @Test func unknownHardwareIsOmittedNotZeroed() throws {
        let report = SupportReportBuilder.make(
            bundle: bundle(), profile: MacProfile(modelName: "Mac", chip: nil, memoryGB: 0))
        #expect(report.hardware.memoryGB == nil)
        #expect(report.hardware.chip == nil)
        let json = try encoded(report.body(description: "It broke when I did X"))
        #expect(!json.contains("memory_gb"))
        #expect(!json.contains(#""chip""#))
    }

    // MARK: - What you see is what is sent

    /// The "What's Included" text is rendered from the same value the request
    /// carries: decoding the preview gives back the request's fields.
    @Test func previewIsTheRequestMinusTheDescription() throws {
        let report = SupportReportBuilder.make(
            bundle: bundle(logs: (0 ..< 3).map { log($0) }), profile: Self.profile)

        let preview = try JSONDecoder().decode(JSONValue.self, from: Data(report.previewJSON.utf8))
        let body = try JSONDecoder().decode(
            JSONValue.self,
            from: JSONEncoder.osaurusCanonical().encode(report.body(description: "It broke when I did X")))

        var sent = object(body)
        let description = sent.removeValue(forKey: "description")
        let consent = sent.removeValue(forKey: "consent")
        #expect(description == .string("It broke when I did X"))
        #expect(consent == .bool(true))
        #expect(JSONValue.object(sent) == preview)
        #expect(Set(object(preview).keys) == ["app", "hardware", "diagnostics"])
        // The preview never claims consent or shows the user's own text.
        #expect(!report.previewJSON.contains("consent"))
    }

    /// Dates are ISO 8601 text, which is what the admin console and a person
    /// reading the preview can make sense of.
    @Test func diagnosticsDatesAreISO8601() {
        let report = SupportReportBuilder.make(bundle: bundle(logs: [log(0)]), profile: Self.profile)
        let diagnostics = object(report.diagnostics)
        #expect(diagnostics["generatedAt"] == .string("2027-01-15T08:00:00Z"))
        let request = object(array(diagnostics["recentRequests"]).first)
        #expect(request["timestamp"] == .string("2027-01-15T08:00:00Z"))
    }

    // MARK: - Privacy

    /// Prompts, responses, wire bodies, tool arguments and results, error
    /// text and raw identifiers never reach the request.
    @Test func reportCarriesNoBodiesSecretsOrRawIdentifiers() throws {
        let secret = "live-secret-token-do-not-export"
        let prompt = "please search the private account history"
        let response = "private diagnosis response"
        let toolArgument = "private account lookup"
        let errorText = "provider rejected bearer sk-test-do-not-export"
        let sessionId = "session-raw-value-do-not-export"
        let agentAddress = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let noisy = RequestLog(
            timestamp: Self.now,
            source: .chatUI,
            requestId: "router-request-do-not-export",
            method: "POST",
            path: "/agents/\(agentAddress)/run?token=\(secret)",
            statusCode: 500,
            durationMs: 250,
            requestBody: #"{"prompt":"\#(prompt)","api_key":"\#(secret)"}"#,
            responseBody: response,
            model: "provider/model",
            toolCalls: [
                ToolCallLog(
                    name: "web_search",
                    arguments: #"{"query":"\#(toolArgument)"}"#,
                    result: "result with \(secret)",
                    durationMs: 10,
                    isError: true
                )
            ],
            finishReason: .error,
            errorMessage: errorText,
            wireRequestBody: "wire \(prompt)",
            wireResponseBody: "wire \(response)"
        )
        let bundle = SupportDiagnosticsBundleBuilder.make(
            generatedAt: Self.now,
            app: Self.app,
            sessionId: sessionId,
            agentAddress: agentAddress,
            agentName: "Research",
            modelId: "provider/model",
            registeredTools: [SupportDiagnosticsToolInput(name: "web_search", enabled: true)],
            logs: [noisy]
        )
        let report = SupportReportBuilder.make(bundle: bundle, profile: Self.profile)
        let json = try encoded(report.body(description: "It broke when I did X"))

        for forbidden in [
            secret, prompt, response, toolArgument, errorText, sessionId, agentAddress,
            "router-request-do-not-export", "sk-test-do-not-export",
        ] {
            #expect(!json.contains(forbidden), "report leaked: \(forbidden)")
            #expect(!report.previewJSON.contains(forbidden), "preview leaked: \(forbidden)")
        }
        // What is there instead: names, counts and fingerprints.
        #expect(json.contains("web_search"))
        #expect(json.contains("sha256:"))
        #expect(json.contains(#""errorMessageCaptured":true"#))
    }

    // MARK: - Size cap

    @Test func defaultCeilingLeavesHeadroomUnderTheRouterLimit() {
        #expect(SupportReportBuilder.maxDiagnosticsBytes < OsaurusRouterSupportLimits.maxDiagnosticsBytes)
        #expect(SupportReportBuilder.maxDiagnosticsBytes > 100 * 1024)
        #expect(SupportReportBuilder.recentLogLimit == 25)
    }

    /// The reported size is the size of what is sent.
    @Test func reportedBytesMatchTheSerializedDiagnostics() throws {
        let report = SupportReportBuilder.make(
            bundle: bundle(logs: (0 ..< 10).map { log($0) }), profile: Self.profile)
        let diagnostics = try #require(report.diagnostics)
        let sent = try JSONEncoder.osaurusCanonical().encode(diagnostics)
        #expect(report.diagnosticsBytes == sent.count)
        #expect(report.diagnosticsBytes <= SupportReportBuilder.maxDiagnosticsBytes)
    }

    /// Too many recent requests: the oldest go first, the newest stay, and
    /// the tool list is untouched.
    @Test func oversizedBundleDropsOldestRequestsFirst() throws {
        let full = bundle(logs: (0 ..< 400).map { log($0) }, recentLogLimit: 400)
        #expect(full.recentRequests.count == 400)
        let fullSize = try #require(SupportReportBuilder.fittedDiagnostics(full, maxBytes: .max)).bytes
        let cap = fullSize / 3

        let fitted = try #require(SupportReportBuilder.fittedDiagnostics(full, maxBytes: cap))
        #expect(fitted.bytes <= cap)
        let diagnostics = object(fitted.value)
        let kept = array(diagnostics["recentRequests"])
        #expect(kept.count < 400)
        #expect(!kept.isEmpty)
        // Newest first: the first kept row is the most recent request.
        #expect(object(kept.first)["model"] == .string("provider/model-0"))
        #expect(array(object(diagnostics["tools"])["registered"]).count == 1)

        let report = SupportReportBuilder.make(bundle: full, profile: Self.profile, maxDiagnosticsBytes: cap)
        #expect(report.diagnosticsBytes == fitted.bytes)
        #expect(report.diagnostics == fitted.value)
    }

    /// Still too large with no requests: the per-tool records go, the
    /// enabled-name list (the part that explains tool problems) stays.
    @Test func thenDropsTheToolRegistryButKeepsEnabledNames() throws {
        let tools = (0 ..< 300).map {
            SupportDiagnosticsToolInput(name: "tool_number_\($0)", enabled: true, groupName: "group_\($0)")
        }
        let large = bundle(tools: tools)
        let withoutRegistry = SupportDiagnosticsBundle(
            schemaVersion: large.schemaVersion, generatedAt: large.generatedAt, app: large.app,
            context: large.context,
            tools: .init(
                registered: [], enabledNames: large.tools.enabledNames, dynamicNames: large.tools.dynamicNames,
                loadedNames: large.tools.loadedNames,
                initialAlwaysLoadedNames: large.tools.initialAlwaysLoadedNames,
                sessionFingerprint: large.tools.sessionFingerprint),
            recentRequests: [], privacy: large.privacy)
        let floor = try #require(SupportReportBuilder.fittedDiagnostics(withoutRegistry, maxBytes: .max)).bytes

        let fitted = try #require(SupportReportBuilder.fittedDiagnostics(large, maxBytes: floor))
        let toolsValue = object(object(fitted.value)["tools"])
        #expect(array(toolsValue["registered"]).isEmpty)
        #expect(array(toolsValue["enabledNames"]).count == 300)
        #expect(fitted.bytes == floor)
    }

    /// Nothing left to drop: the report goes without diagnostics rather than
    /// not at all, and says so through a nil value and a zero size.
    @Test func impossibleCapSendsTheReportWithoutDiagnostics() throws {
        #expect(SupportReportBuilder.fittedDiagnostics(bundle(logs: [log(0)]), maxBytes: 64) == nil)

        let report = SupportReportBuilder.make(
            bundle: bundle(logs: [log(0)]), profile: Self.profile, maxDiagnosticsBytes: 64)
        #expect(report.diagnostics == nil)
        #expect(report.diagnosticsBytes == 0)

        let json = try encoded(report.body(description: "It broke when I did X"))
        #expect(!json.contains("diagnostics"))
        #expect(json.contains(#""consent":true"#))
        #expect(json.contains(#""version":"1.2.3""#))
    }
}
