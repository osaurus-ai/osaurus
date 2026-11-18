import Testing
@testable import OsaurusCore

@Suite("Design provider credential isolation")
struct DesignProviderCredentialGateTests {
    @Test func offlineProofCannotUseProviderKeychain() {
        #expect(KeychainQueryHelpers.providerServiceIsDisabled(
            KeychainQueryHelpers.designProviderService, processDisabled: true, connectedDesignProviders: false))
    }
    @Test func connectedDesignAllowsOnlyItsOwnProviderService() {
        #expect(!KeychainQueryHelpers.providerServiceIsDisabled(
            KeychainQueryHelpers.designProviderService, processDisabled: true, connectedDesignProviders: true))
        for service in ["ai.osaurus.remote", "com.osaurus.storage", "com.osaurus.masterkey", "Claude Code-credentials"] {
            #expect(KeychainQueryHelpers.providerServiceIsDisabled(service,
                processDisabled: true, connectedDesignProviders: true))
        }
    }
    @Test func ordinaryAppKeychainPolicyIsUnchanged() {
        #expect(!KeychainQueryHelpers.providerServiceIsDisabled("ai.osaurus.remote",
            processDisabled: false, connectedDesignProviders: false))
    }
}
