//
//  SandboxPluginGlobalProxyTests.swift
//  OsaurusCoreTests
//

import CFNetwork
import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SandboxPluginGlobalProxyTests {
    @Test func manifestFetchSessionUsesGlobalProxySetting() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-sandbox-plugin-proxy-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                _ = SandboxPlugin.makeManifestFetchSession()
                try? FileManager.default.removeItem(at: root)
            }

            try OsaurusPaths.ensureExists(OsaurusPaths.config())
            var configuration = ServerConfiguration.default
            configuration.globalProxyURL = "socks5://proxy.example.com:1080"
            try JSONEncoder().encode(configuration).write(to: OsaurusPaths.serverConfigFile(), options: .atomic)

            let session = SandboxPlugin.makeManifestFetchSession()

            let dictionary = session.configuration.connectionProxyDictionary
            #expect(dictionary?[proxyKey(kCFNetworkProxiesSOCKSEnable)] as? Int == 1)
            #expect(dictionary?[proxyKey(kCFNetworkProxiesSOCKSProxy)] as? String == "proxy.example.com")
            #expect(dictionary?[proxyKey(kCFNetworkProxiesSOCKSPort)] as? Int == 1080)
        }
    }
}

private func proxyKey(_ value: CFString) -> AnyHashable {
    AnyHashable(value as String)
}
