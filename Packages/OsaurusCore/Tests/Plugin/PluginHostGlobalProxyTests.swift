//
//  PluginHostGlobalProxyTests.swift
//  OsaurusCoreTests
//
//  Plugin host HTTP transport should honor the app-wide proxy setting while
//  keeping its custom no-redirect delegate for SSRF-checked redirect handling.
//

import CFNetwork
import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct PluginHostGlobalProxyTests {
    @Test func httpTransportUsesGlobalProxySetting() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try makeTemporaryPluginProxyRoot()
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
                _ = PluginHostContext.noRedirectSession()
            }

            try writePluginProxyServerConfiguration(proxyURL: "https://proxy.example.com:8443")

            let session = PluginHostContext.noRedirectSession()
            let dictionary = session.configuration.connectionProxyDictionary

            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPSEnable)] as? Int == 1)
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPSProxy)] as? String == "proxy.example.com")
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPSPort)] as? Int == 8443)
        }
    }

    @Test func httpTransportRebuildsWhenGlobalProxyChanges() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try makeTemporaryPluginProxyRoot()
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
                _ = PluginHostContext.noRedirectSession()
            }

            try writePluginProxyServerConfiguration(proxyURL: "http://proxy-one.example.com:8080")
            let first = PluginHostContext.noRedirectSession()

            try writePluginProxyServerConfiguration(proxyURL: "socks5://proxy-two.example.com:1080")
            let second = PluginHostContext.noRedirectSession()
            let dictionary = second.configuration.connectionProxyDictionary

            #expect(first !== second)
            #expect(dictionary?[proxyKey(kCFNetworkProxiesSOCKSEnable)] as? Int == 1)
            #expect(dictionary?[proxyKey(kCFNetworkProxiesSOCKSProxy)] as? String == "proxy-two.example.com")
            #expect(dictionary?[proxyKey(kCFNetworkProxiesSOCKSPort)] as? Int == 1080)
        }
    }
}

private func makeTemporaryPluginProxyRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "osaurus-plugin-host-proxy-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writePluginProxyServerConfiguration(proxyURL: String?) throws {
    try OsaurusPaths.ensureExists(OsaurusPaths.config())
    var configuration = ServerConfiguration.default
    configuration.globalProxyURL = proxyURL
    let data = try JSONEncoder().encode(configuration)
    try data.write(to: OsaurusPaths.serverConfigFile(), options: .atomic)
}

private func proxyKey(_ value: CFString) -> AnyHashable {
    AnyHashable(value as String)
}
