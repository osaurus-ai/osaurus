//
//  GitHubSkillServiceGlobalProxyTests.swift
//  OsaurusCoreTests
//

import CFNetwork
import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct GitHubSkillServiceGlobalProxyTests {
    @MainActor
    @Test func defaultSessionUsesGlobalProxySetting() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-github-skill-proxy-\(UUID().uuidString)",
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
            configuration.globalProxyURL = "http://proxy.example.com:8080"
            try JSONEncoder().encode(configuration).write(to: OsaurusPaths.serverConfigFile(), options: .atomic)

            let session = GitHubSkillService.makeSession()
            defer { session.invalidateAndCancel() }

            let dictionary = session.configuration.connectionProxyDictionary
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPEnable)] as? Int == 1)
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPProxy)] as? String == "proxy.example.com")
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPPort)] as? Int == 8080)
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPSEnable)] as? Int == 1)
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPSProxy)] as? String == "proxy.example.com")
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPSPort)] as? Int == 8080)
            #expect(session.configuration.timeoutIntervalForRequest == 30)
            #expect(session.configuration.timeoutIntervalForResource == 60)
        }
    }
}

private func proxyKey(_ value: CFString) -> AnyHashable {
    AnyHashable(value as String)
}
