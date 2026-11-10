//
//  EvalFixtureServer.swift
//  OsaurusEvalsKit
//
//  A loopback HTTP API for Architect cases: the workflow the Architect
//  builds calls it the way it would call a real service, so a case can
//  exercise paging, bearer auth, flaky endpoints, and per-record lookups
//  without the network. Routes come from the case file; every request is
//  counted so a case can assert the workflow really made the calls.
//

import Foundation
import Network
import OsaurusCore

public struct EvalFixtureAPI: Sendable, Codable {
    public let routes: [Route]

    public struct Route: Sendable, Codable {
        /// Exact path, or a prefix ending in `/*` that matches any last segment.
        public let path: String
        /// nil matches any method.
        public let method: String?
        /// Required `Authorization: Bearer <token>`; anything else gets 401.
        public let bearer: String?
        /// Default 200.
        public let status: Int?
        public let body: JSONValue?
        /// Served one per request in order: `cursor` puts the next cursor in
        /// the body at `cursorField` (read back from the `cursorParam` query
        /// parameter); `link` sends a `Link: <…>; rel="next"` header and
        /// reads the `page` query parameter.
        public let pages: [JSONValue]?
        public let paging: String?
        public let cursorParam: String?
        public let cursorField: String?
        /// The first N authorized requests fail with `failStatus` (default 500).
        public let failFirst: Int?
        public let failStatus: Int?
        /// For a `/*` path: last segment -> body; other segments get 404.
        public let byKey: [String: JSONValue]?
        /// Answer `{"ok": true, "received": <request body>}`.
        public let echo: Bool?
    }
}

final class EvalFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "osaurus-evals.fixture-api")
    private let routes: [EvalFixtureAPI.Route]
    private var authorizedHits: [Int: Int] = [:]
    private var counts: [String: Int] = [:]
    private var bodies: [String: [JSONValue]] = [:]
    private var baseURL = ""

    init(_ api: EvalFixtureAPI) throws {
        routes = api.routes
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns the base URL, e.g. `http://127.0.0.1:51234`.
    func start() async throws -> String {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        let url = "http://127.0.0.1:\(port)"
        queue.sync { baseURL = url }
        return url
    }

    func stop() { listener.cancel() }

    /// Requests seen per route path.
    func requestCounts() -> [String: Int] { queue.sync { counts } }

    /// Request bodies received per route path, parsed as JSON when they are.
    func receivedBodies() -> [String: [JSONValue]] { queue.sync { bodies } }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Request(buffer) {
                let response = self.respond(to: request)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if done || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data

        /// nil until the whole request has arrived.
        init?(_ data: Data) {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)),
                let head = String(data: data[..<end.lowerBound], encoding: .utf8)
            else { return nil }
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
            guard requestLine.count >= 2 else { return nil }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "") ?? 0
            let bodyStart = end.upperBound
            guard data.count - bodyStart >= length else { return nil }
            let components = URLComponents(string: "http://fixture" + requestLine[1])
            method = requestLine[0].uppercased()
            path = components?.path ?? requestLine[1]
            query = Dictionary(
                (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            self.headers = headers
            body = data.subdata(in: bodyStart..<(bodyStart + length))
        }
    }

    // MARK: - Routing

    private func route(for request: Request) -> (Int, EvalFixtureAPI.Route)? {
        for (index, route) in routes.enumerated() {
            if let method = route.method, method.uppercased() != request.method { continue }
            if route.path.hasSuffix("/*") {
                let prefix = String(route.path.dropLast())
                if request.path.hasPrefix(prefix), request.path.count > prefix.count { return (index, route) }
            } else if route.path == request.path {
                return (index, route)
            }
        }
        return nil
    }

    private func respond(to request: Request) -> Data {
        guard let (index, route) = route(for: request) else {
            return Self.response(404, .object(["error": .string("no such endpoint: \(request.path)")]))
        }
        counts[route.path, default: 0] += 1
        if !request.body.isEmpty {
            let parsed =
                (try? JSONDecoder().decode(JSONValue.self, from: request.body))
                ?? .string(String(decoding: request.body, as: UTF8.self))
            bodies[route.path, default: []].append(parsed)
        }
        if let token = route.bearer, request.headers["authorization"] != "Bearer \(token)" {
            return Self.response(401, .object(["error": .string("missing or wrong bearer token")]))
        }
        authorizedHits[index, default: 0] += 1
        if let failFirst = route.failFirst, authorizedHits[index, default: 0] <= failFirst {
            let status = route.failStatus ?? 500
            return Self.response(
                status, .object(["error": .string(status == 429 ? "rate limited" : "temporarily unavailable")]),
                headers: status == 429 ? ["Retry-After": "1"] : [:])
        }
        if let pages = route.pages, !pages.isEmpty {
            return page(pages, route: route, request: request)
        }
        if let byKey = route.byKey {
            let key = request.path.split(separator: "/").last.map(String.init) ?? ""
            guard let body = byKey[key] else {
                return Self.response(404, .object(["error": .string("no record \(key)")]))
            }
            return Self.response(route.status ?? 200, body)
        }
        if route.echo == true {
            let received = bodies[route.path]?.last ?? .null
            return Self.response(route.status ?? 200, .object(["ok": .bool(true), "received": received]))
        }
        return Self.response(route.status ?? 200, route.body ?? .object([:]))
    }

    private func page(_ pages: [JSONValue], route: EvalFixtureAPI.Route, request: Request) -> Data {
        if route.paging == "link" {
            let number = max(1, Int(request.query["page"] ?? "") ?? 1)
            let body = number <= pages.count ? pages[number - 1] : .array([])
            var headers: [String: String] = [:]
            if number < pages.count {
                headers["Link"] = "<\(baseURL)\(request.path)?page=\(number + 1)>; rel=\"next\""
            }
            return Self.response(200, body, headers: headers)
        }
        let param = route.cursorParam ?? "cursor"
        let field = route.cursorField ?? "next_cursor"
        let index = request.query[param].flatMap { $0.hasPrefix("c") ? Int($0.dropFirst()) : nil } ?? 0
        guard index < pages.count else { return Self.response(400, .object(["error": .string("bad cursor")])) }
        var body = pages[index]
        if case .object(var object) = body {
            object[field] = index + 1 < pages.count ? .string("c\(index + 1)") : .null
            body = .object(object)
        }
        return Self.response(200, body)
    }

    static func response(_ status: Int, _ body: JSONValue, headers: [String: String] = [:]) -> Data {
        let payload = Data(body.compactJSONString.utf8)
        let reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\nConnection: close\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + payload
    }
}
