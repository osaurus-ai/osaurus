//
//  RepositoryGlobalProxySettingsTests.swift
//  OsaurusRepository
//

import CFNetwork
import Foundation
import Network
import XCTest

@testable import OsaurusRepository

final class RepositoryGlobalProxySettingsTests: XCTestCase {
    func testSharedSessionAppliesProxyFromServerConfiguration() throws {
        try withTemporaryToolsRoot { root in
            try writeServerConfiguration(
                root: root,
                proxyURL: "https://proxy.example.com:8443"
            )

            let session = RepositoryGlobalProxySettings.sharedSession()
            let dictionary = session.configuration.connectionProxyDictionary

            XCTAssertEqual(dictionary?[proxyKey(kCFNetworkProxiesHTTPSEnable)] as? Int, 1)
            XCTAssertEqual(dictionary?[proxyKey(kCFNetworkProxiesHTTPSProxy)] as? String, "proxy.example.com")
            XCTAssertEqual(dictionary?[proxyKey(kCFNetworkProxiesHTTPSPort)] as? Int, 8443)
        }
    }

    func testSharedSessionRebuildsWhenProxyChanges() throws {
        try withTemporaryToolsRoot { root in
            try writeServerConfiguration(
                root: root,
                proxyURL: "http://proxy-one.example.com:8080"
            )

            let first = RepositoryGlobalProxySettings.sharedSession()
            XCTAssertEqual(
                first.configuration.connectionProxyDictionary?[proxyKey(kCFNetworkProxiesHTTPProxy)] as? String,
                "proxy-one.example.com"
            )

            try writeServerConfiguration(
                root: root,
                proxyURL: "socks5://proxy-two.example.com:1080"
            )

            let second = RepositoryGlobalProxySettings.sharedSession()
            XCTAssertFalse(first === second)
            XCTAssertEqual(
                second.configuration.connectionProxyDictionary?[proxyKey(kCFNetworkProxiesSOCKSProxy)] as? String,
                "proxy-two.example.com"
            )
            XCTAssertNil(second.configuration.connectionProxyDictionary?[proxyKey(kCFNetworkProxiesHTTPProxy)])
        }
    }

    func testSessionReturnedBeforeConcurrentProxyRefreshRemainsUsable() async throws {
        try await withTemporaryToolsRoot { root in
            try writeServerConfiguration(root: root, proxyURL: nil)
            let retainedSession = RepositoryGlobalProxySettings.sharedSession()
            let server = try await RepositoryProxyHTTPTestServer.start()
            defer { server.stop() }

            try writeServerConfiguration(
                root: root,
                proxyURL: "https://proxy.example.com:8443"
            )

            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 20 {
                    group.addTask {
                        _ = RepositoryGlobalProxySettings.sharedSession()
                    }
                }
            }

            let (data, response) = try await retainedSession.data(from: server.url)

            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        }
    }

    func testInvalidProxyFallsBackToDirectNetworking() throws {
        try withTemporaryToolsRoot { root in
            try writeServerConfiguration(root: root, proxyURL: "http://localhost:8080")

            let session = RepositoryGlobalProxySettings.sharedSession()

            XCTAssertNil(session.configuration.connectionProxyDictionary)
        }
    }

    func testLegacyServerConfigurationPathIsReadWhenNewPathIsAbsent() throws {
        try withTemporaryToolsRoot { root in
            let data = Data(#"{"globalProxyURL":"socks5://proxy.example.com:1080"}"#.utf8)
            try data.write(
                to: root.appendingPathComponent("ServerConfiguration.json"),
                options: .atomic
            )

            let session = RepositoryGlobalProxySettings.sharedSession()
            let dictionary = session.configuration.connectionProxyDictionary

            XCTAssertEqual(dictionary?[proxyKey(kCFNetworkProxiesSOCKSEnable)] as? Int, 1)
            XCTAssertEqual(dictionary?[proxyKey(kCFNetworkProxiesSOCKSProxy)] as? String, "proxy.example.com")
            XCTAssertEqual(dictionary?[proxyKey(kCFNetworkProxiesSOCKSPort)] as? Int, 1080)
        }
    }

    private func withTemporaryToolsRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-repository-proxy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousRoot = ToolsPaths.overrideRoot
        ToolsPaths.overrideRoot = root
        defer {
            ToolsPaths.overrideRoot = previousRoot
            _ = RepositoryGlobalProxySettings.sharedSession()
            try? FileManager.default.removeItem(at: root)
        }

        try body(root)
    }

    private func withTemporaryToolsRoot(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-repository-proxy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousRoot = ToolsPaths.overrideRoot
        ToolsPaths.overrideRoot = root
        defer {
            ToolsPaths.overrideRoot = previousRoot
            _ = RepositoryGlobalProxySettings.sharedSession()
            try? FileManager.default.removeItem(at: root)
        }

        try await body(root)
    }

    private func writeServerConfiguration(root: URL, proxyURL: String?) throws {
        let configDir = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        var object: [String: Any] = [:]
        if let proxyURL {
            object["globalProxyURL"] = proxyURL
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: configDir.appendingPathComponent("server.json"), options: .atomic)
    }

    private func proxyKey(_ value: CFString) -> AnyHashable {
        AnyHashable(value as String)
    }
}

private final class RepositoryProxyHTTPTestServer: @unchecked Sendable {
    let url: URL

    private let listener: NWListener

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.url = URL(string: "http://127.0.0.1:\(port)/proxy-refresh")!
    }

    static func start() async throws -> RepositoryProxyHTTPTestServer {
        let listener = try NWListener(using: .tcp, on: .any)
        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "RepositoryProxyHTTPTestServer.start")
            let resumeGate = RepositoryProxyResumeGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumeGate.claim(), let port = listener.port?.rawValue else { return }
                    continuation.resume(
                        returning: RepositoryProxyHTTPTestServer(listener: listener, port: port)
                    )
                case .failed(let error):
                    guard resumeGate.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                    let body = Data("ok".utf8)
                    let headers = Data(
                        "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
                    )
                    connection.send(
                        content: headers + body,
                        completion: .contentProcessed { _ in
                            connection.cancel()
                        }
                    )
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }
}

private final class RepositoryProxyResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}
