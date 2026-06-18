//
//  MarkdownRemoteImageGlobalProxyTests.swift
//  OsaurusCoreTests
//

import CFNetwork
import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct MarkdownRemoteImageGlobalProxyTests {
    @Test func swiftUIRemoteImageLoaderUsesGlobalProxySetting() async throws {
        try await withMarkdownImageProxyRoot(proxyURL: "socks5://proxy.example.com:1080") {
            let session = ImageLoader.makeRemoteImageSession()
            let dictionary = session.configuration.connectionProxyDictionary

            #expect(dictionary?[proxyKey(kCFNetworkProxiesSOCKSEnable)] as? Int == 1)
            #expect(dictionary?[proxyKey(kCFNetworkProxiesSOCKSProxy)] as? String == "proxy.example.com")
            #expect(dictionary?[proxyKey(kCFNetworkProxiesSOCKSPort)] as? Int == 1080)
        }
    }

    @Test func nativeRemoteImageLoaderUsesGlobalProxySetting() async throws {
        try await withMarkdownImageProxyRoot(proxyURL: "https://proxy.example.com:8443") {
            let session = NativeMarkdownView.makeRemoteImageSession()
            let dictionary = session.configuration.connectionProxyDictionary

            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPSEnable)] as? Int == 1)
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPSProxy)] as? String == "proxy.example.com")
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPSPort)] as? Int == 8443)
        }
    }
}

private func withMarkdownImageProxyRoot(
    proxyURL: String,
    _ body: @Sendable () throws -> Void
) async throws {
    try await StoragePathsTestLock.shared.run {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-markdown-image-proxy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousRoot = OsaurusPaths.overrideRoot
        OsaurusPaths.overrideRoot = root
        defer {
            OsaurusPaths.overrideRoot = previousRoot
            _ = ImageLoader.makeRemoteImageSession()
            try? FileManager.default.removeItem(at: root)
        }

        try OsaurusPaths.ensureExists(OsaurusPaths.config())
        var configuration = ServerConfiguration.default
        configuration.globalProxyURL = proxyURL
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: OsaurusPaths.serverConfigFile(), options: .atomic)

        try body()
    }
}

private func proxyKey(_ value: CFString) -> AnyHashable {
    AnyHashable(value as String)
}
