import Testing
@testable import OsaurusEvalsKit

@Suite @MainActor
struct RemoteProviderBootstrapTests {
    @Test func customEndpointUsesItsOwnRoutingPrefixAndCredentialName() throws {
        let value = try #require(EvalRemoteProviderBootstrap.preset(
            prefix: "lab", environment: ["LAB_BASE_URL": "https://models.example:8443/api/v1"]))
        #expect(value.name == "lab")
        #expect(value.host == "models.example")
        #expect(value.port == 8443)
        #expect(value.basePath == "/api/v1")
        #expect(value.envKey == "LAB_API_KEY")
        #expect(value.providerProtocol == .https)
        #expect(value.headers("fixture-key")["Authorization"] == "Bearer fixture-key")
        #expect(value.headers("fixture-key")["User-Agent"] == "OsaurusEvals/1.0")
    }

    @Test func knownNativeProviderKeepsItsAuthenticationAndWireFormat() throws {
        let value = try #require(EvalRemoteProviderBootstrap.preset(
            prefix: "anthropic", environment: ["ANTHROPIC_BASE_URL": "https://gateway.example/messages"]))
        #expect(value.name == "Anthropic")
        #expect(value.envKey == "ANTHROPIC_API_KEY")
        #expect(value.providerType == .anthropic)
        #expect(value.headers("fixture-key")["x-api-key"] == "fixture-key")
        #expect(value.headers("fixture-key")["Authorization"] == nil)
    }

    @Test(arguments: ["", "not-a-url", "http://remote.example/v1", "https://user:pass@host.example/v1",
        "https://host.example/v1?key=secret", "https://host.example/v1#fragment", "ftp://host.example/v1"])
    func invalidOverrideNeverFallsBackToPublicHost(_ url: String) {
        #expect(EvalRemoteProviderBootstrap.preset(prefix: "openai", environment: ["OPENAI_BASE_URL": url]) == nil)
    }

    @Test func loopbackHTTPAndUnchangedPresetsRemainAvailable() throws {
        let local = try #require(EvalRemoteProviderBootstrap.preset(
            prefix: "lab", environment: ["LAB_BASE_URL": "http://127.0.0.1:8080/v1"]))
        #expect(local.providerProtocol == .http)
        #expect(local.port == 8080)
        let known = try #require(EvalRemoteProviderBootstrap.preset(prefix: "openai", environment: [:]))
        #expect(known.host == "api.openai.com")
        #expect(known.envKey == "OPENAI_API_KEY")
        #expect(EvalRemoteProviderBootstrap.preset(prefix: "lab", environment: [:]) == nil)
    }
}
