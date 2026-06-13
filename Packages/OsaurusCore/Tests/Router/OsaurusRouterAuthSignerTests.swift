import Foundation
import Testing

@testable import OsaurusCore

struct OsaurusRouterAuthSignerTests {
    @Test func evmAddress_matchesExistingIdentityAddressDerivation() throws {
        let address = try OsaurusRouterAuthSigner.evmAddress(privateKey: TestKeys.alicePrivateKey)
        #expect(address == TestKeys.aliceAddress)
        #expect(address.hasPrefix("0x"))
        #expect(address.count == 42)
    }

    @Test func authMessage_bindsMethodPathQueryTimestampBodyAndNonce() {
        let body = Data(#"{"max_tokens":16,"model":"venice/model"}"#.utf8)
        let hash = OsaurusRouterAuthSigner.sha256Hex(body)
        let message = OsaurusRouterAuthSigner.authMessage(
            address: TestKeys.aliceAddress,
            method: "post",
            pathAndQuery: "/credits/usage?limit=2",
            bodyHash: hash,
            timestamp: 1_717_171_717,
            nonce: "nonce-1"
        )

        #expect(
            message
                == "osaurus-credits:\(TestKeys.aliceAddress.lowercased()):POST:/credits/usage?limit=2:1717171717:\(hash):nonce-1"
        )
    }

    @Test func signHeaders_recoversToWalletAddress() throws {
        let body = Data(#"{"amount_micro":"5000000"}"#.utf8)
        let headers = try OsaurusRouterAuthSigner.signHeaders(
            method: "POST",
            pathAndQuery: "/credits/checkout",
            body: body,
            timestamp: 1_717_171_717,
            privateKey: TestKeys.alicePrivateKey
        )

        #expect(headers.address == TestKeys.aliceAddress.lowercased())
        #expect(headers.signature.hasPrefix("0x"))
        #expect(headers.signature.count == 132)

        let bodyHash = OsaurusRouterAuthSigner.sha256Hex(body)
        let message = OsaurusRouterAuthSigner.authMessage(
            address: headers.address,
            method: "POST",
            pathAndQuery: "/credits/checkout",
            bodyHash: bodyHash,
            timestamp: headers.timestamp
        )
        let signature = try #require(Data(hexEncoded: String(headers.signature.dropFirst(2))))
        let recovered = try recoverAddress(
            payload: Data(message.utf8),
            signature: signature,
            domainPrefix: "Ethereum Signed Message"
        )
        #expect(recovered.lowercased() == headers.address)
    }

    @Test func pathAndQuery_includesQueryExactlyAsSent() throws {
        let url = try #require(URL(string: "https://router.osaurus.ai/credits/usage?limit=2&cursor=abc"))
        #expect(OsaurusRouterAuthSigner.pathAndQuery(for: url) == "/credits/usage?limit=2&cursor=abc")
    }
}
