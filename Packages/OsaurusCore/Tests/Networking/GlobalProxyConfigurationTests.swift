//
//  GlobalProxyConfigurationTests.swift
//  osaurusTests
//

import CFNetwork
import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct GlobalProxyConfigurationTests {

    @Test func acceptsHTTPProxyURL() throws {
        let proxy = try GlobalProxyConfiguration(
            urlString: " http://proxy.example.com:8080/ "
        )

        #expect(proxy.scheme == .http)
        #expect(proxy.host == "proxy.example.com")
        #expect(proxy.port == 8080)
        #expect(proxy.redactedDescription == "http://proxy.example.com:8080")
    }

    @Test func acceptsHTTPSProxyURL() throws {
        let proxy = try GlobalProxyConfiguration(
            urlString: "https://secure-proxy.example.com:8443"
        )

        #expect(proxy.scheme == .https)
        #expect(proxy.host == "secure-proxy.example.com")
        #expect(proxy.port == 8443)
    }

    @Test func acceptsSOCKSProxyURLAliases() throws {
        let socks = try GlobalProxyConfiguration(urlString: "socks://proxy.example.com:1080")
        let socks5 = try GlobalProxyConfiguration(urlString: "socks5://proxy.example.com:1080")

        #expect(socks.scheme == .socks)
        #expect(socks5.scheme == .socks)
    }

    @Test func shapesHTTPProxyDictionaryForWebTraffic() throws {
        let proxy = try GlobalProxyConfiguration(urlString: "http://proxy.example.com:8080")
        let dictionary = proxy.connectionProxyDictionary

        #expect(dictionary[key(kCFNetworkProxiesHTTPEnable)] as? Int == 1)
        #expect(dictionary[key(kCFNetworkProxiesHTTPProxy)] as? String == "proxy.example.com")
        #expect(dictionary[key(kCFNetworkProxiesHTTPPort)] as? Int == 8080)
        #expect(dictionary[key(kCFNetworkProxiesHTTPSEnable)] as? Int == 1)
        #expect(dictionary[key(kCFNetworkProxiesHTTPSProxy)] as? String == "proxy.example.com")
        #expect(dictionary[key(kCFNetworkProxiesHTTPSPort)] as? Int == 8080)
        #expect(dictionary[key(kCFNetworkProxiesSOCKSEnable)] == nil)
    }

    @Test func shapesSOCKSProxyDictionary() throws {
        let proxy = try GlobalProxyConfiguration(urlString: "socks5://proxy.example.com:1080")
        let dictionary = proxy.connectionProxyDictionary

        #expect(dictionary[key(kCFNetworkProxiesSOCKSEnable)] as? Int == 1)
        #expect(dictionary[key(kCFNetworkProxiesSOCKSProxy)] as? String == "proxy.example.com")
        #expect(dictionary[key(kCFNetworkProxiesSOCKSPort)] as? Int == 1080)
        #expect(dictionary[key(kCFNetworkProxiesHTTPEnable)] == nil)
        #expect(dictionary[key(kCFNetworkProxiesHTTPSEnable)] == nil)
    }

    @Test func appliesProxyDictionaryToCopiedConfiguration() throws {
        let base = URLSessionConfiguration.ephemeral
        base.timeoutIntervalForRequest = 12
        let proxy = try GlobalProxyConfiguration(urlString: "http://proxy.example.com:8080")

        let configuration = GlobalProxyURLSessionFactory.makeConfiguration(
            base: base,
            proxy: proxy
        )

        #expect(configuration !== base)
        #expect(configuration.timeoutIntervalForRequest == 12)
        #expect(base.connectionProxyDictionary == nil)
        #expect(
            configuration.connectionProxyDictionary?[key(kCFNetworkProxiesHTTPProxy)] as? String == "proxy.example.com"
        )
    }

    @Test func buildsURLSessionWithProxyDictionary() throws {
        let proxy = try GlobalProxyConfiguration(urlString: "socks5://proxy.example.com:1080")

        let session = GlobalProxyURLSessionFactory.makeSession(
            base: .ephemeral,
            proxy: proxy
        )

        #expect(
            session.configuration.connectionProxyDictionary?[key(kCFNetworkProxiesSOCKSProxy)] as? String
                == "proxy.example.com"
        )
    }

    @Test func settingsResolverNormalizesPersistedProxyURL() throws {
        var configuration = ServerConfiguration.default
        configuration.globalProxyURL = " socks5://Proxy.EXAMPLE.com:1080/ "

        let proxy = try #require(GlobalProxySettings.configuration(from: configuration))

        #expect(proxy.redactedDescription == "socks://proxy.example.com:1080")
    }

    @Test func settingsResolverIgnoresMissingAndInvalidProxyURL() {
        var configuration = ServerConfiguration.default
        #expect(GlobalProxySettings.configuration(from: configuration) == nil)

        configuration.globalProxyURL = "http://localhost:8080"
        #expect(GlobalProxySettings.configuration(from: configuration) == nil)
    }

    @Test func settingsResolverReadsDiskBackedServerConfiguration() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-proxy-settings-\(UUID().uuidString)",
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
            let data = try JSONEncoder().encode(configuration)
            try data.write(to: OsaurusPaths.serverConfigFile(), options: .atomic)

            let proxy = try #require(GlobalProxySettings.currentConfiguration())
            #expect(proxy.redactedDescription == "https://proxy.example.com:8443")
        }
    }

    @Test func sharedSessionRebuildsWhenPersistedProxyChanges() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-shared-proxy-session-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                _ = GlobalProxySettings.sharedSession()
                try? FileManager.default.removeItem(at: root)
            }

            try OsaurusPaths.ensureExists(OsaurusPaths.config())
            var configuration = ServerConfiguration.default
            configuration.globalProxyURL = "http://proxy-a.example.com:8080"
            try JSONEncoder().encode(configuration).write(to: OsaurusPaths.serverConfigFile(), options: .atomic)

            let first = GlobalProxySettings.sharedSession()
            #expect(
                first.configuration.connectionProxyDictionary?[key(kCFNetworkProxiesHTTPProxy)] as? String
                    == "proxy-a.example.com"
            )

            configuration.globalProxyURL = "socks5://proxy-b.example.com:1080"
            try JSONEncoder().encode(configuration).write(to: OsaurusPaths.serverConfigFile(), options: .atomic)

            let second = GlobalProxySettings.sharedSession()
            #expect(first !== second)
            #expect(
                second.configuration.connectionProxyDictionary?[key(kCFNetworkProxiesSOCKSProxy)] as? String
                    == "proxy-b.example.com"
            )
            #expect(second.configuration.connectionProxyDictionary?[key(kCFNetworkProxiesHTTPProxy)] == nil)
        }
    }

    @Test func rejectsUnsafeProxyURLInput() {
        let cases: [(String, GlobalProxyConfiguration.ValidationError)] = [
            ("", .empty),
            ("/tmp/proxy.sock", .unsupportedScheme(nil)),
            ("file:///tmp/proxy", .unsupportedScheme("file")),
            ("ftp://proxy.example.com:21", .unsupportedScheme("ftp")),
            ("http://proxy.example.com", .missingPort),
            ("http://proxy.example.com:8080/path", .unsupportedURLComponents),
            ("http://proxy.example.com:8080?token=secret", .unsupportedURLComponents),
            ("http://proxy.example.com:8080#fragment", .unsupportedURLComponents),
            ("http://user:pass@proxy.example.com:8080", .credentialsInURL),
            ("http://localhost:8080", .unsafeHost("localhost")),
            ("http://127.0.0.1:8080", .unsafeHost("127.0.0.1")),
            ("socks5://[::1]:1080", .unsafeHost("::1")),
        ]

        for (rawURL, expectedError) in cases {
            #expect(throws: expectedError) {
                try GlobalProxyConfiguration(urlString: rawURL)
            }
        }
    }

    private func key(_ value: CFString) -> AnyHashable {
        AnyHashable(value as String)
    }
}
