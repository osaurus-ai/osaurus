import CryptoKit
import Foundation
import LocalAuthentication

struct OsaurusRouterAuthSigner: Sendable {
    struct SignedHeaders: Equatable, Sendable {
        let address: String
        let timestamp: Int
        let signature: String
        let nonce: String?

        var values: [String: String] {
            var headers = [
                "x-wallet-address": address,
                "x-wallet-timestamp": String(timestamp),
                "x-wallet-signature": signature,
            ]
            if let nonce, !nonce.isEmpty {
                headers["x-wallet-nonce"] = nonce
            }
            return headers
        }
    }

    var now: @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }

    func sign(request: inout URLRequest, body: Data? = nil, nonce: String? = nil) async throws {
        guard OsaurusIdentity.exists() else {
            throw OsaurusRouterAPIError.noIdentity
        }

        var privateKey = try await Task.detached(priority: .userInitiated) {
            let context = LAContext()
            context.touchIDAuthenticationAllowableReuseDuration = 300
            return try MasterKey.getPrivateKey(context: context)
        }.value
        defer { privateKey.zeroOut() }

        guard let url = request.url else { throw OsaurusRouterAPIError.invalidURL }
        let method = request.httpMethod ?? "GET"
        let rawBody = body ?? request.httpBody ?? Data()
        let headers = try Self.signHeaders(
            method: method,
            pathAndQuery: Self.pathAndQuery(for: url),
            body: rawBody,
            timestamp: now(),
            nonce: nonce,
            privateKey: privateKey
        )

        for (name, value) in headers.values {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    static func signHeaders(
        method: String,
        pathAndQuery: String,
        body: Data,
        timestamp: Int,
        nonce: String? = nil,
        privateKey: Data
    ) throws -> SignedHeaders {
        let address = try evmAddress(privateKey: privateKey).lowercased()
        let bodyHash = sha256Hex(body)
        let nonceValue = nonce ?? ""
        let message = authMessage(
            address: address,
            method: method,
            pathAndQuery: pathAndQuery,
            bodyHash: bodyHash,
            timestamp: timestamp,
            nonce: nonceValue
        )
        let signature = try signEIP191Message(message, privateKey: privateKey).hexEncodedString
        return SignedHeaders(
            address: address,
            timestamp: timestamp,
            signature: "0x\(signature)",
            nonce: nonceValue.isEmpty ? nil : nonceValue
        )
    }

    static func authMessage(
        address: String,
        method: String,
        pathAndQuery: String,
        bodyHash: String,
        timestamp: Int,
        nonce: String? = nil
    ) -> String {
        "osaurus-credits:\(address.lowercased()):\(method.uppercased()):\(pathAndQuery):\(timestamp):\(bodyHash):\(nonce ?? "")"
    }

    static func evmAddress(privateKey: Data) throws -> String {
        try deriveOsaurusId(from: privateKey)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func pathAndQuery(for url: URL) -> String {
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            path += "?\(query)"
        }
        return path
    }
}
