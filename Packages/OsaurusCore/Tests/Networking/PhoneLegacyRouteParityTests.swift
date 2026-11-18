//
//  PhoneLegacyRouteParityTests.swift
//  OsaurusCoreTests
//
//  The iPhone app shipped against upstream main talks to these routes over
//  HTTP (docs/MOBILE_PROTOCOL.md). For one release this fork keeps them
//  beside Sync, so each one must answer as upstream main does: same status,
//  same error code, and at least the JSON keys upstream sends (extra keys are
//  fine; the app's decoders ignore them).
//
//  `PhoneLegacyFixtures/upstream-routes.json` and `upstream-sse.json` were
//  recorded by running this file on upstream main with
//  `OSAURUS_PHONE_PARITY_RECORD=<dir>`; the recording SHA is in each
//  fixture. Every route the app calls is listed, as the owner on loopback
//  (the Secure Channel hands the same handler its decrypted request), with
//  bodies that can't start a run or change state. The SSE extension events
//  a phone run streams are written by the real `SSEResponseWriter`.
//

import Foundation
import NIO
import NIOEmbedded
import NIOHTTP1
import Testing

@testable import OsaurusCore

@Suite("Phone routes answer as on upstream main", .serialized)
struct PhoneLegacyRouteParityTests {
    struct Probe: Sendable {
        let id: String
        let method: String
        let path: String
        var body: String? = nil
    }

    struct Observed: Codable, Equatable {
        let id: String
        let status: Int
        let json: Bool
        let keys: [String]
        let error: String?
        /// Keys of the first element of each top-level array, when it has one.
        let elementKeys: [String: [String]]
    }

    struct Fixture: Codable {
        let upstreamSHA: String
        let routes: [Observed]
    }

    static let agent = "00000000-0000-0000-0000-0000000000aa"
    static let session = "00000000-0000-0000-0000-0000000000bb"
    static let prompt = "00000000-0000-0000-0000-0000000000cc"
    static let turn = "00000000-0000-0000-0000-0000000000dd"

    /// Every call in iOSaurus `OsaurusClient` / `PairingClient` that isn't
    /// the Secure Channel itself.
    static let probes: [Probe] = [
        Probe(id: "health", method: "GET", path: "/health"),
        Probe(id: "agents.list", method: "GET", path: "/agents"),
        Probe(id: "agents.create.badBody", method: "POST", path: "/agents", body: "not json"),
        Probe(id: "agents.get.unknown", method: "GET", path: "/agents/\(agent)"),
        Probe(id: "agents.patch.unknown", method: "PATCH", path: "/agents/\(agent)", body: #"{"name":"x"}"#),
        Probe(id: "agents.delete.unknown", method: "DELETE", path: "/agents/\(agent)"),
        Probe(id: "agents.avatar.unknown", method: "GET", path: "/agents/\(agent)/avatar"),
        Probe(id: "agents.model.unknown", method: "PUT", path: "/agents/\(agent)/model", body: #"{"model":"x"}"#),
        Probe(id: "agents.tools.unknown", method: "GET", path: "/agents/\(agent)/tools"),
        Probe(
            id: "agents.tool.patch.unknown", method: "PATCH", path: "/agents/\(agent)/tools/web_fetch",
            body: #"{"enabled":true}"#),
        Probe(
            id: "agents.tools.preset.unknown", method: "POST", path: "/agents/\(agent)/tools/preset",
            body: #"{"preset":"default"}"#),
        Probe(id: "agents.warm.unknown", method: "POST", path: "/agents/\(agent)/warm", body: "{}"),
        Probe(id: "agents.run.badBody", method: "POST", path: "/agents/\(agent)/run", body: "not json"),
        Probe(id: "models.picker", method: "GET", path: "/models/picker"),
        Probe(id: "models.favorites.badBody", method: "PUT", path: "/models/favorites", body: "not json"),
        Probe(id: "models.options.badBody", method: "POST", path: "/models/options", body: "not json"),
        Probe(id: "sessions.list", method: "GET", path: "/sessions"),
        Probe(id: "sessions.get.unknown", method: "GET", path: "/sessions/\(session)"),
        Probe(id: "sessions.patch.unknown", method: "PATCH", path: "/sessions/\(session)", body: #"{"title":"x"}"#),
        Probe(id: "sessions.delete.unknown", method: "DELETE", path: "/sessions/\(session)"),
        Probe(
            id: "sessions.truncate.unknown", method: "POST", path: "/sessions/\(session)/truncate",
            body: #"{"from_turn_id":"\#(turn)"}"#),
        Probe(id: "sessions.context.unknown", method: "GET", path: "/sessions/\(session)/context?agent_id=\(agent)"),
        Probe(id: "sessions.image.unknown", method: "GET", path: "/sessions/\(session)/turns/\(turn)/images/0"),
        Probe(id: "runs.events.unknown", method: "GET", path: "/runs/\(prompt)/events?after=0"),
        Probe(id: "runs.stop.unknown", method: "POST", path: "/runs/\(prompt)/stop", body: "{}"),
        Probe(id: "projects", method: "GET", path: "/projects"),
        Probe(id: "privacy.reviews", method: "GET", path: "/privacy/reviews"),
        Probe(
            id: "privacy.answer.unknown", method: "POST", path: "/privacy/reviews/\(prompt)",
            body: #"{"decision":"cancel"}"#),
        Probe(id: "config.approvals", method: "GET", path: "/config/approvals"),
        Probe(
            id: "config.answer.unknown", method: "POST", path: "/config/approvals/\(prompt)",
            body: #"{"decision":"cancel"}"#),
        Probe(id: "computerUse.prompts", method: "GET", path: "/computer-use/prompts"),
        Probe(
            id: "computerUse.answer.unknown", method: "POST", path: "/computer-use/prompts/\(prompt)",
            body: #"{"decision":"deny"}"#),
        Probe(
            id: "computerUse.answer.notUUID", method: "POST", path: "/computer-use/prompts/nope",
            body: #"{"decision":"deny"}"#),
        Probe(id: "secrets.prompts", method: "GET", path: "/secrets/prompts"),
        Probe(
            id: "secrets.answer.unknown", method: "POST", path: "/secrets/prompts/\(prompt)",
            body: #"{"decision":"cancel"}"#),
        Probe(id: "approvals", method: "GET", path: "/approvals"),
        Probe(
            id: "approvals.answer.unknown", method: "POST", path: "/approvals/\(prompt)",
            body: #"{"decision":"deny"}"#),
        Probe(
            id: "approvals.answer.typo", method: "POST", path: "/approvals/\(prompt)",
            body: #"{"decision":"allow"}"#),
        Probe(id: "workspaces.agents", method: "GET", path: "/workspaces/agents"),
        Probe(id: "workspaceAgent.run.badBody", method: "POST", path: "/workspace-agents/w/0xabc/run", body: "not json"),
        Probe(id: "images.events.unknown", method: "GET", path: "/images/jobs/nope/events?after=0"),
        Probe(id: "images.cancel.badBody", method: "POST", path: "/images/cancel", body: "not json"),
        Probe(id: "artifacts.unknown", method: "GET", path: "/artifacts/nope/nope.txt"),
        Probe(id: "pair.hello", method: "GET", path: "/pair/hello"),
        Probe(id: "pair.code.empty", method: "POST", path: "/pair/code", body: "{}"),
        Probe(id: "pair.confirm.empty", method: "POST", path: "/pair/confirm", body: "{}"),
        Probe(id: "pair.unpair.owner", method: "POST", path: "/pair/unpair", body: "{}"),
    ]

    static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("PhoneLegacyFixtures")

    /// Writes `observed` when recording on upstream main; otherwise compares
    /// it with the recorded fixture.
    static func check(_ observed: [Observed], fixture name: String, ids: [String]) throws {
        if let recordDir = ProcessInfo.processInfo.environment["OSAURUS_PHONE_PARITY_RECORD"] {
            let sha = ProcessInfo.processInfo.environment["OSAURUS_PHONE_PARITY_SHA"] ?? "unknown"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Fixture(upstreamSHA: sha, routes: observed))
                .write(to: URL(fileURLWithPath: recordDir).appendingPathComponent(name))
            return
        }
        let fixture = try JSONDecoder().decode(
            Fixture.self, from: Data(contentsOf: fixturesDir.appendingPathComponent(name)))
        #expect(fixture.routes.map(\.id) == ids, "\(name) covers every probe")
        let differences = Self.differences(upstream: fixture.routes, ours: observed)
        #expect(differences.isEmpty, "differences from upstream main:\n\(differences.joined(separator: "\n"))")
    }

    @Test func everyPhoneRouteAnswersAsOnUpstreamMain() async throws {
        try Self.check(try await Self.observeAll(), fixture: "upstream-routes.json", ids: Self.probes.map(\.id))
    }

    @Test func theSSEExtensionEventsMatchUpstreamMain() throws {
        let observed = try Self.observeSSE()
        try Self.check(observed, fixture: "upstream-sse.json", ids: observed.map(\.id))
    }

    @Test func theComparisonCatchesADifference() {
        let upstream = Observed(
            id: "x", status: 200, json: true, keys: ["prompts"], error: nil, elementKeys: ["prompts": ["id", "kind"]])
        #expect(Self.differences(upstream: [upstream], ours: [upstream]).isEmpty)
        let extraKeys = Observed(
            id: "x", status: 200, json: true, keys: ["prompts", "v"], error: nil,
            elementKeys: ["prompts": ["id", "kind", "detail"]])
        #expect(Self.differences(upstream: [upstream], ours: [extraKeys]).isEmpty, "extra keys are compatible")
        let changed = [
            Observed(id: "x", status: 404, json: true, keys: ["prompts"], error: nil, elementKeys: [:]),
            Observed(id: "x", status: 200, json: true, keys: ["items"], error: nil, elementKeys: [:]),
            Observed(id: "x", status: 200, json: true, keys: ["prompts"], error: "gone", elementKeys: [:]),
            Observed(id: "x", status: 200, json: true, keys: ["prompts"], error: nil, elementKeys: ["prompts": ["id"]]),
        ]
        for ours in changed {
            #expect(Self.differences(upstream: [upstream], ours: [ours]).count == 1, "\(ours)")
        }
        #expect(Self.differences(upstream: [upstream], ours: []).count == 1, "a missing route")
    }

    /// One line per way `ours` would break a client written against
    /// `upstream`: another status or error code, a missing key, a missing
    /// key in a list's elements, or a route not answered at all.
    static func differences(upstream: [Observed], ours: [Observed]) -> [String] {
        let byId = Dictionary(uniqueKeysWithValues: ours.map { ($0.id, $0) })
        var out: [String] = []
        for expected in upstream {
            guard let actual = byId[expected.id] else {
                out.append("\(expected.id): not probed")
                continue
            }
            if actual.status != expected.status {
                out.append("\(expected.id): status \(actual.status), upstream \(expected.status)")
            }
            if actual.json != expected.json { out.append("\(expected.id): JSON body \(actual.json)") }
            if actual.error != expected.error {
                out.append("\(expected.id): error \(actual.error ?? "nil"), upstream \(expected.error ?? "nil")")
            }
            let missing = Set(expected.keys).subtracting(actual.keys)
            if !missing.isEmpty { out.append("\(expected.id): missing keys \(missing.sorted())") }
            for (key, upstreamKeys) in expected.elementKeys.sorted(by: { $0.key < $1.key }) {
                guard let elementKeys = actual.elementKeys[key] else { continue }
                let missingInElement = Set(upstreamKeys).subtracting(elementKeys)
                if !missingInElement.isEmpty {
                    out.append("\(expected.id).\(key)[0]: missing keys \(missingInElement.sorted())")
                }
            }
        }
        return out
    }

    // MARK: - Harness

    static func observeSSE() throws -> [Observed] {
        let channel = EmbeddedChannel(handler: ParityContextHandler())
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
        let writer = SSEResponseWriter()
        let context = try channel.pipeline.syncOperations.context(handlerType: ParityContextHandler.self)
        writer.writeHeaders(context, extraHeaders: nil)
        _ = try channel.readOutbound(as: HTTPServerResponsePart.self)

        func next(_ id: String) throws -> Observed {
            guard case .body(.byteBuffer(var buffer))? = try channel.readOutbound(as: HTTPServerResponsePart.self),
                let text = buffer.readString(length: buffer.readableBytes),
                let payload = text.split(separator: "\n").first(where: { $0.hasPrefix("data: ") })?.dropFirst(6),
                let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            else { return Observed(id: id, status: 0, json: false, keys: [], error: nil, elementKeys: [:]) }
            var elementKeys: [String: [String]] = [:]
            for (key, value) in object where key.hasPrefix("osaurus_") {
                if let nested = value as? [String: Any] { elementKeys[key] = nested.keys.sorted() }
                if let first = (value as? [Any])?.first as? [String: Any] { elementKeys[key] = first.keys.sorted() }
            }
            return Observed(id: id, status: 0, json: true, keys: object.keys.sorted(), error: nil, elementKeys: elementKeys)
        }

        var out: [Observed] = []
        writer.writeAgentToolTrace(
            phase: "started", toolName: "web_fetch", callId: "call_1", model: "m", responseId: "r", created: 0,
            context: context)
        out.append(try next("agentTool.started.plain"))
        writer.writeAgentToolTrace(
            phase: "completed", toolName: "web_fetch", callId: "call_1", isError: false, endRun: false,
            detail: AgentToolTraceDetail(
                label: "Fetched", category: "web", icon: "globe", arguments: "{}", result: "ok",
                resultTruncated: false, durationMs: 12),
            model: "m", responseId: "r", created: 0, context: context)
        out.append(try next("agentTool.completed.detail"))
        writer.writePrefillProgress(
            PrefillProgressState(stage: .prefill, completedUnitCount: 1, totalUnitCount: 4, detail: "x"),
            model: "m", responseId: "r", created: 0, context: context)
        out.append(try next("prefill"))
        var omitted = RemoteRunArtifact(name: "big.bin", mime: "application/octet-stream", description: nil, size_bytes: 9)
        omitted.omitted_reason = "too_large"
        var inline = RemoteRunArtifact(name: "a.txt", mime: "text/plain", description: "d", size_bytes: 2)
        inline.bytes_base64 = "aGk="
        writer.writeArtifactsChunk([inline, omitted], model: "m", responseId: "r", created: 0, context: context)
        out.append(try next("artifacts"))
        return out
    }

    static func observeAll() async throws -> [Observed] {
        let lease = await HTTPServerTestLock.shared.acquire()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel: Channel
        do {
            channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(
                            HTTPHandler(
                                configuration: .default,
                                apiKeyValidator: .empty,
                                eventLoop: channel.eventLoop,
                                trustLoopback: true,
                                localKeyRequiredProvider: { false }
                            )
                        )
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .bind(host: "127.0.0.1", port: 0).get()
        } catch {
            try? await group.shutdownGracefully()
            await lease.release()
            throw error
        }
        let port = channel.localAddress?.port ?? 0
        var results: [Observed] = []
        for probe in probes {
            results.append(await observe(probe, port: port))
        }
        _ = try? await channel.close()
        try? await group.shutdownGracefully()
        await lease.release()
        return results
    }

    static func observe(_ probe: Probe, port: Int) async -> Observed {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(probe.path)")!)
        request.httpMethod = probe.method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = probe.body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return Observed(id: probe.id, status: -1, json: false, keys: [], error: nil, elementKeys: [:])
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Observed(id: probe.id, status: status, json: false, keys: [], error: nil, elementKeys: [:])
        }
        var elementKeys: [String: [String]] = [:]
        for (key, value) in object {
            if let first = (value as? [Any])?.first as? [String: Any] { elementKeys[key] = first.keys.sorted() }
        }
        let error: String? =
            (object["error"] as? String) ?? ((object["error"] as? [String: Any])?["code"] as? String)
        return Observed(
            id: probe.id, status: status, json: true, keys: object.keys.sorted(), error: error,
            elementKeys: elementKeys)
    }
}

private final class ParityContextHandler: ChannelInboundHandler {
    typealias InboundIn = Never
}
