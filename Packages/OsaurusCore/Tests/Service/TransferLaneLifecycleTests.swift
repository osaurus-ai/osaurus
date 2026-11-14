import Foundation
import Network
import Testing

@testable import OsaurusCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct TransferLaneLifecycleTests {
    @Test func sequentialRangesReuseLaneAndPreserveBytes() async throws {
        let server = try await LaneRangeFixture.start(holdBody: false)
        defer { server.stop() }
        let lane = TransferLane()
        defer { lane.invalidate() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        for start in [0, 4] {
            try handle.seek(toOffset: UInt64(start))
            try await lane.fetch(
                url: server.url, range: "bytes=\(start)-\(start + 3)",
                handle: handle, expected: 4, onBytes: { _ in }
            )
        }
        #expect(try Data(contentsOf: file) == Data("abcdefgh".utf8))
        #expect(server.ranges == ["bytes=0-3", "bytes=4-7"])
    }

    @Test func admittedFetchCompletesCancellationAndRejectsReuse() async throws {
        let server = try await LaneRangeFixture.start(holdBody: true)
        defer { server.stop() }
        let lane = TransferLane()
        defer { lane.invalidate() }
        let fetch = Task {
            try await lane.fetch(
                url: server.url, range: "bytes=0-3", handle: .nullDevice,
                expected: 4, onBytes: { _ in }
            )
        }
        do {
            try await server.waitForRequests(1)
        } catch {
            lane.invalidate()
            server.stop()
            _ = await fetch.result
            throw error
        }
        lane.invalidate()
        lane.invalidate()
        do {
            try await fetch.value
            Issue.record("An incomplete admitted response unexpectedly succeeded")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        } catch {
            Issue.record("Expected admitted URLSession cancellation, received \(error)")
        }
        do {
            try await lane.fetch(
                url: server.url, range: "bytes=4-7", handle: .nullDevice,
                expected: 4, onBytes: { _ in }
            )
            Issue.record("Terminal lane admitted another request")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected terminal CancellationError, received \(error)")
        }
        #expect(server.ranges == ["bytes=0-3"])
    }

    @Test func concurrentInvalidationAndTaskCreationCompleteWithoutException() async throws {
        let server = try await LaneRangeFixture.start(holdBody: true)
        defer { server.stop() }
        for _ in 0 ..< 32 {
            let lane = TransferLane()
            let fetch = Task {
                try await lane.fetch(
                    url: server.url, range: "bytes=0-3", handle: .nullDevice,
                    expected: 4, onBytes: { _ in }
                )
            }
            let invalidation = Task.detached {
                lane.invalidate()
                lane.invalidate()
            }
            await invalidation.value
            do {
                try await fetch.value
                Issue.record("A held response unexpectedly completed")
            } catch is CancellationError {
                // Invalidation won admission.
            } catch let error as URLError {
                // Task creation won admission; URLSession owns cancellation.
                #expect(error.code == .cancelled)
            } catch {
                Issue.record("Unexpected race outcome: \(error)")
            }
        }
    }
}

/// A real loopback HTTP server, not a replacement transfer-lane implementation.
/// All mutable fixture state is protected by lock. Connections run on queue;
/// partial request headers are accumulated before parsing.
private final class LaneRangeFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "TransferLaneLifecycleTests.http")
    private let listener: NWListener
    private let holdBody: Bool
    private var ready = false
    private var failed = false
    private var stopped = false
    private var connections: [NWConnection] = []
    private var headers: [ObjectIdentifier: Data] = [:]
    private var observedRanges: [String] = []

    private init(holdBody: Bool) throws {
        self.holdBody = holdBody
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var url: URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/range")!
    }

    var ranges: [String] { lock.withLock { observedRanges } }

    static func start(holdBody: Bool) async throws -> LaneRangeFixture {
        let fixture = try LaneRangeFixture(holdBody: holdBody)
        fixture.listener.stateUpdateHandler = { [weak fixture] state in
            guard let fixture else { return }
            fixture.lock.withLock {
                switch state {
                case .ready: fixture.ready = true
                case .failed: fixture.failed = true
                default: break
                }
            }
        }
        fixture.listener.newConnectionHandler = { [weak fixture] connection in
            guard let fixture else { connection.cancel(); return }
            let accepted = fixture.lock.withLock {
                guard !fixture.stopped else { return false }
                fixture.connections.append(connection)
                return true
            }
            guard accepted else { connection.cancel(); return }
            connection.start(queue: fixture.queue)
            fixture.receiveHeader(connection)
        }
        fixture.listener.start(queue: fixture.queue)
        do {
            try await fixture.waitUntil { fixture.lock.withLock { fixture.ready || fixture.failed } }
            guard fixture.lock.withLock({ fixture.ready }) else { throw URLError(.cannotConnectToHost) }
            return fixture
        } catch {
            fixture.stop()
            throw error
        }
    }

    func waitForRequests(_ count: Int) async throws {
        try await waitUntil { self.ranges.count >= count }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func stop() {
        let active = lock.withLock {
            stopped = true
            let active = connections
            connections.removeAll()
            headers.removeAll()
            return active
        }
        listener.cancel()
        for connection in active { connection.cancel() }
    }

    private func receiveHeader(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            guard error == nil, let data, !data.isEmpty else { connection.cancel(); return }
            let request: Data? = self.lock.withLock {
                let key = ObjectIdentifier(connection)
                self.headers[key, default: Data()].append(data)
                guard let accumulated = self.headers[key] else { return nil }
                if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.headers.removeValue(forKey: key)
                    return accumulated
                }
                return nil
            }
            guard let request else {
                if complete { connection.cancel() } else { self.receiveHeader(connection) }
                return
            }
            let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
            let range = lines.first { $0.lowercased().hasPrefix("range:") }?
                .split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces) ?? "missing"
            self.lock.withLock { self.observedRanges.append(range) }
            let body = range == "bytes=0-3" ? "abcd" : "efgh"
            guard range == "bytes=0-3" || range == "bytes=4-7" else {
                connection.cancel()
                return
            }
            let bounds = range.replacingOccurrences(of: "bytes=", with: "")
            let header = "HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nContent-Range: bytes \(bounds)/8\r\nConnection: close\r\n\r\n"
            let payload = header + (self.holdBody ? String(body.prefix(1)) : body)
            connection.send(content: Data(payload.utf8), completion: .contentProcessed { error in
                if error != nil || !self.holdBody { connection.cancel() }
            })
        }
    }
}
