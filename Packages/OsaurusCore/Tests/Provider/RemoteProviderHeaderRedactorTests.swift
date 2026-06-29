//
//  RemoteProviderHeaderRedactorTests.swift
//  OsaurusCoreTests
//
//  Keeps provider connection diagnostics from leaking user-supplied secrets.
//

import Testing

@testable import OsaurusCore

@Suite("RemoteProviderHeaderRedactor")
struct RemoteProviderHeaderRedactorTests {
    @Test func redactsBuiltInProviderCredentialHeaders() {
        for header in [
            "Authorization", "x-api-key", "x-goog-api-key", "api-key",
            "Proxy-Authorization", "Cookie", "Set-Cookie",
        ] {
            #expect(
                RemoteProviderHeaderRedactor.valueForLogging(headerName: header, value: "super-secret")
                    == RemoteProviderHeaderRedactor.redactedValue
            )
        }
    }

    @Test func redactsConfiguredSecretHeaderKeysCaseInsensitively() {
        #expect(
            RemoteProviderHeaderRedactor.valueForLogging(
                headerName: "X-Custom-Provider-Secret",
                value: "private",
                configuredSecretHeaderKeys: ["x-custom-provider-secret"]
            ) == RemoteProviderHeaderRedactor.redactedValue
        )
    }

    @Test func redactsLikelySecretHeaderNames() {
        for header in ["X-Session-Token", "provider-password", "vendor-secret", "subscription-key"] {
            #expect(
                RemoteProviderHeaderRedactor.valueForLogging(headerName: header, value: "private")
                    == RemoteProviderHeaderRedactor.redactedValue
            )
        }
    }

    @Test func preservesNonSecretDiagnostics() {
        #expect(
            RemoteProviderHeaderRedactor.valueForLogging(headerName: "anthropic-version", value: "2023-06-01")
                == "2023-06-01"
        )
        #expect(
            RemoteProviderHeaderRedactor.valueForLogging(headerName: "Accept", value: "application/json")
                == "application/json"
        )
    }
}
