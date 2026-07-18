//
//  KnownProviderSetupSuccessGateTests.swift
//  OsaurusCoreTests
//


import Testing

@testable import OsaurusCore

@Suite
struct KnownProviderSetupSuccessGateTests {
    @Test func unchangedGreenSnapshotIsVerified() {
        let tested = Self.snapshot()
        var gate = KnownProviderSetupSuccessGate()
        gate.recordSuccess(tested)

        let authorization = gate.authorization(
            current: tested,
            hasSuccessfulResult: true,
            allowsUnverifiedAzureSave: false
        )

        #expect(authorization == .verified)
        #expect(authorization.allowsSave)
    }

    @Test func protocolEditInvalidatesVerifiedKnownProvider() {
        let tested = Self.snapshot()
        var gate = KnownProviderSetupSuccessGate()
        gate.recordSuccess(tested)
        var edited = tested
        edited.provider.providerProtocol = .http

        #expect(Self.authorization(gate, current: edited) == .denied)
    }

    @Test func timeoutEditsInvalidateVerifiedKnownProvider() {
        let tested = Self.snapshot()
        var gate = KnownProviderSetupSuccessGate()
        gate.recordSuccess(tested)

        var timeout = tested
        timeout.provider.timeout = 120
        #expect(Self.authorization(gate, current: timeout) == .denied)

        var disableTimeout = tested
        disableTimeout.provider.disableTimeout = true
        #expect(Self.authorization(gate, current: disableTimeout) == .denied)
    }

    @Test func customHeaderEditsInvalidateVerifiedKnownProvider() {
        let tested = Self.snapshot()
        var gate = KnownProviderSetupSuccessGate()
        gate.recordSuccess(tested)

        var value = tested
        value.headers[0].value = "tenant-b"
        value.provider.customHeaders["X-Tenant"] = "tenant-b"
        #expect(Self.authorization(gate, current: value) == .denied)

        var secret = tested
        secret.headers[0].isSecret = true
        secret.provider.customHeaders = [:]
        secret.provider.secretHeaderKeys = ["X-Tenant"]
        #expect(Self.authorization(gate, current: secret) == .denied)

        var added = tested
        added.headers.append(HeaderEntry(key: "X-Region", value: "us-east", isSecret: false))
        added.provider.customHeaders["X-Region"] = "us-east"
        #expect(Self.authorization(gate, current: added) == .denied)
    }

    @Test func endpointCredentialAndModelEditsInvalidateVerifiedKnownProvider() {
        let tested = Self.snapshot()
        var gate = KnownProviderSetupSuccessGate()
        gate.recordSuccess(tested)

        var host = tested
        host.provider.host = "gateway.example.com"
        #expect(Self.authorization(gate, current: host) == .denied)

        var port = tested
        port.provider.port = 8443
        #expect(Self.authorization(gate, current: port) == .denied)

        var basePath = tested
        basePath.provider.basePath = "/v2"
        #expect(Self.authorization(gate, current: basePath) == .denied)

        var credential = tested
        credential.credential = .apiKey("sk-replacement-123456789")
        #expect(Self.authorization(gate, current: credential) == .denied)

        var models = tested
        models.provider.manualModelIds = ["model-b"]
        #expect(Self.authorization(gate, current: models) == .denied)
    }

    @Test func directSaveGuardRequiresCurrentGreenSnapshot() {
        let tested = Self.snapshot()
        var gate = KnownProviderSetupSuccessGate()
        gate.recordSuccess(tested)

        let missingGreenResult = gate.authorization(
            current: tested,
            hasSuccessfulResult: false,
            allowsUnverifiedAzureSave: false
        )
        var stale = tested
        stale.provider.timeout = 180
        let staleGreenResult = gate.authorization(
            current: stale,
            hasSuccessfulResult: true,
            allowsUnverifiedAzureSave: false
        )

        #expect(missingGreenResult == .denied)
        #expect(!missingGreenResult.allowsSave)
        #expect(staleGreenResult == .denied)
        #expect(!staleGreenResult.allowsSave)
    }

    @Test func browserOAuthIdentityDoesNotDependOnMintedCredentialValue() {
        let tested = Self.snapshot(credential: .oauth(.openRouter))
        var gate = KnownProviderSetupSuccessGate()
        gate.recordSuccess(tested)

        #expect(Self.authorization(gate, current: tested) == .verified)
    }

    @Test func azureManualModelBypassRemainsExplicitlyUnverified() {
        let current = Self.snapshot(preset: .azureOpenAI)
        let gate = KnownProviderSetupSuccessGate()

        let authorization = gate.authorization(
            current: current,
            hasSuccessfulResult: false,
            allowsUnverifiedAzureSave: true
        )

        #expect(authorization == .unverifiedAzureManualModels)
        #expect(authorization.allowsSave)
        #expect(authorization != .verified)
    }

    private static func authorization(
        _ gate: KnownProviderSetupSuccessGate,
        current: KnownProviderSetupTestSnapshot
    ) -> KnownProviderSetupSaveAuthorization {
        gate.authorization(
            current: current,
            hasSuccessfulResult: true,
            allowsUnverifiedAzureSave: false
        )
    }

    private static func snapshot(
        preset: ProviderPreset = .anthropic,
        credential: KnownProviderSetupCredentialIdentity = .apiKey("sk-tested-key-123456789")
    ) -> KnownProviderSetupTestSnapshot {
        let headers = [HeaderEntry(key: "X-Tenant", value: "tenant-a", isSecret: false)]
        let provider = RemoteProvider(
            name: "Anthropic",
            host: "api.anthropic.com",
            providerProtocol: .https,
            port: 443,
            basePath: "/v1",
            customHeaders: HeaderEntry.partition(headers).regular,
            authType: .apiKey,
            providerType: .anthropic,
            timeout: 60,
            disableTimeout: false,
            manualModelIds: ["model-a"]
        )
        return KnownProviderSetupTestSnapshot(
            preset: preset,
            provider: provider,
            credential: credential,
            headers: headers
        )
    }
}
