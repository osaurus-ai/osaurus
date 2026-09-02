//
//  CustomProviderFormParseTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Onboarding custom endpoint URL parse")
struct CustomProviderFormParseTests {
    @Test func fullURLPassesThroughSharedParser() {
        let form = CustomProviderForm.parse("https://api.example.test:8443/openai/v1")
        #expect(form.protocolKind == .https)
        #expect(form.host == "api.example.test")
        #expect(form.port == "8443")
        #expect(form.basePath == "/openai/v1")
    }

    @Test func schemelessLocalhostDefaultsToHTTPAndV1() {
        let form = CustomProviderForm.parse("localhost:11434")
        #expect(form.protocolKind == .http)
        #expect(form.host == "localhost")
        #expect(form.port == "11434")
        #expect(form.basePath == "/v1")
    }

    @Test func bareHostIsAcceptedVerbatim() {
        let form = CustomProviderForm.parse("localhost")
        #expect(form.host == "localhost")
        #expect(form.protocolKind == .http)
        #expect(form.basePath == "/v1")
    }

    @Test func lanAddressDefaultsToHTTPPublicDomainToHTTPS() {
        #expect(CustomProviderForm.parse("192.168.1.20:1234").protocolKind == .http)
        #expect(CustomProviderForm.parse("api.example.test/v1").protocolKind == .https)
    }

    @Test func operationSuffixIsNormalizedAway() {
        let form = CustomProviderForm.parse("http://localhost:8080/v1/chat/completions")
        #expect(form.basePath == "/v1")
    }

    @Test func bracketedIPv6CountsAsLocalhost() {
        let form = CustomProviderForm.parse("[::1]:8080")
        #expect(form.host == "[::1]")
        #expect(form.port == "8080")
        #expect(form.isLocalhost)
        #expect(form.protocolKind == .http)
    }

    @Test func unparsableInputKeepsHostEmpty() {
        #expect(CustomProviderForm.parse("").host.isEmpty)
        #expect(CustomProviderForm.parse("http://").host.isEmpty)
        #expect(CustomProviderForm.parse("not a url").host.isEmpty)
    }
}
