//
//  CustomProviderSetupSuccessGateTests.swift
//  OsaurusCoreTests
//

import Testing

@testable import OsaurusCore

@Suite
struct CustomProviderSetupSuccessGateTests {
    @Test func unchangedGreenSnapshotAllowsAdd() {
        let tested = Self.snapshot()
        var gate = CustomProviderSetupSuccessGate()
        gate.recordSuccess(tested)

        #expect(gate.allowsAdd(current: tested))
    }

    @Test func greenTestThenOrdinaryHostEditRefusesAdd() {
        let tested = Self.snapshot()
        var gate = CustomProviderSetupSuccessGate()
        gate.recordSuccess(tested)
        var edited = tested
        edited.hostInput = "api.changed.example"
        edited.provider.host = "api.changed.example"

        #expect(!gate.allowsAdd(current: edited))
    }

    @Test func greenTestThenOrdinaryPortEditRefusesAdd() {
        let tested = Self.snapshot()
        var gate = CustomProviderSetupSuccessGate()
        gate.recordSuccess(tested)
        var edited = tested
        // Both strings resolve to the same numeric port, so the raw field must
        // remain part of the tested identity.
        edited.portInput = "0443"

        #expect(!gate.allowsAdd(current: edited))
    }

    @Test func greenTestThenOrdinaryBasePathEditRefusesAdd() {
        let tested = Self.snapshot()
        var gate = CustomProviderSetupSuccessGate()
        gate.recordSuccess(tested)
        var edited = tested
        edited.basePathInput = "/v2"
        edited.provider.basePath = "/v2"

        #expect(!gate.allowsAdd(current: edited))
    }

    @Test func credentialHeaderTimeoutModelAndConnectionDriftRefuseAdd() {
        let tested = Self.snapshot()
        var gate = CustomProviderSetupSuccessGate()
        gate.recordSuccess(tested)

        var apiKey = tested
        apiKey.apiKeyInput = "sk-new-key-123456789"
        #expect(!gate.allowsAdd(current: apiKey))

        var authType = tested
        authType.provider.authType = .none
        #expect(!gate.allowsAdd(current: authType))

        var header = tested
        header.headers[0].value = "changed-header"
        #expect(!gate.allowsAdd(current: header))

        var timeout = tested
        timeout.provider.timeout = 120
        #expect(!gate.allowsAdd(current: timeout))

        var disableTimeout = tested
        disableTimeout.provider.disableTimeout = true
        #expect(!gate.allowsAdd(current: disableTimeout))

        var models = tested
        models.manualModelIdsInput = "model-b"
        models.provider.manualModelIds = ["model-b"]
        #expect(!gate.allowsAdd(current: models))

        var providerProtocol = tested
        providerProtocol.provider.providerProtocol = .http
        #expect(!gate.allowsAdd(current: providerProtocol))
    }

    @Test func aNewTestInvalidatesThePreviousGreenSnapshot() {
        let tested = Self.snapshot()
        var gate = CustomProviderSetupSuccessGate()
        gate.recordSuccess(tested)
        gate.invalidate()

        #expect(!gate.allowsAdd(current: tested))
    }

    private static func snapshot() -> CustomProviderSetupTestSnapshot {
        let headers = [HeaderEntry(key: "X-Tenant", value: "tenant-a", isSecret: false)]
        let provider = RemoteProvider(
            name: "Example",
            host: "api.example.com",
            providerProtocol: .https,
            port: 443,
            basePath: "/v1",
            customHeaders: HeaderEntry.partition(headers).regular,
            authType: .apiKey,
            providerType: .openaiLegacy,
            timeout: 60,
            disableTimeout: false,
            manualModelIds: ["model-a"]
        )
        return CustomProviderSetupTestSnapshot(
            provider: provider,
            nameInput: "Example",
            hostInput: "api.example.com",
            portInput: "443",
            basePathInput: "/v1",
            apiKeyInput: "sk-tested-key-123456789",
            manualModelIdsInput: "model-a",
            headers: headers
        )
    }
}
