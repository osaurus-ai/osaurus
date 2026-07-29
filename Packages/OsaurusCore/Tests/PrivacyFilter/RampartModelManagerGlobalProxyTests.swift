//
//  RampartModelManagerGlobalProxyTests.swift
//  OsaurusCoreTests
//

import CFNetwork
import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct RampartModelManagerGlobalProxyTests {
    @Test func downloadSessionUsesGlobalProxySetting() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-rampart-proxy-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }

            try OsaurusPaths.ensureExists(OsaurusPaths.config())
            var configuration = ServerConfiguration.default
            configuration.globalProxyURL = "https://proxy.example.com:8443"
            try JSONEncoder().encode(configuration).write(to: OsaurusPaths.serverConfigFile(), options: .atomic)

            let delegate = TaskDelegate()
            let session = RampartModelManager.makeDownloadSession(delegate: delegate)
            defer { session.invalidateAndCancel() }

            let dictionary = session.configuration.connectionProxyDictionary
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPSEnable)] as? Int == 1)
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPSProxy)] as? String == "proxy.example.com")
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPSPort)] as? Int == 8443)
        }
    }
}

private final class TaskDelegate: NSObject, URLSessionTaskDelegate {}

private func proxyKey(_ value: CFString) -> AnyHashable {
    AnyHashable(value as String)
}
