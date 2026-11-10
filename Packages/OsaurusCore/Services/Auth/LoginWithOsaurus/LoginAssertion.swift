//
//  LoginAssertion.swift
//  OsaurusCore
//
//  The token a website receives from "Log in with Osaurus":
//
//    osl-v1.<base64url(payload JSON)>.0x<hex 65-byte signature>
//
//  The signature is EIP-191 `personal_sign` by the master key over the
//  UTF-8 string `osaurus-login-v1.<base64url(payload JSON)>`, so any
//  Ethereum library (viem, ethers) verifies it and recovers the address.
//  `verify` here is the Swift reference for the checks every website must
//  make; see docs/LOGIN_WITH_OSAURUS.md.
//

import Foundation

public struct LoginAssertionPayload: Codable, Equatable, Sendable {
    public static let type = "osaurus-login"
    public static let version = 1
    public static let lifetime = 300

    public let typ: String
    public let ver: Int
    /// Lowercase master address (`0x…`).
    public let iss: String
    /// The website origin the assertion is for (the request's `client_id`).
    public let aud: String
    public let redirectURI: String
    public let nonce: String
    public let iat: Int
    public let exp: Int
    /// Unique per assertion.
    public let jti: String
    /// The claimed Osaurus ID (no `@`), as this Mac last saw it. A display
    /// hint only: it is not proof of the handle.
    public let osaurusID: String?
    /// This Mac's device id.
    public let dev: String?

    enum CodingKeys: String, CodingKey {
        case typ, ver, iss, aud, nonce, iat, exp, jti, dev
        case redirectURI = "redirect_uri"
        case osaurusID = "osaurus_id"
    }
}

public struct LoginAssertion: Equatable, Sendable {
    public static let tokenPrefix = "osl-v1"
    public static let messagePrefix = "osaurus-login-v1."

    public let token: String
    public let payload: LoginAssertionPayload

    public enum VerificationError: Error, Equatable, Sendable {
        case malformed
        case badSignature
        case wrongType
        case issuerMismatch
        case audienceMismatch
        case redirectURIMismatch
        case nonceMismatch
        case expired
        case issuedInFuture
        case lifetimeTooLong
    }

    /// The exact string the master key signs for `encodedPayload`.
    public static func message(encodedPayload: String) -> String {
        messagePrefix + encodedPayload
    }

    static func encode(_ payload: LoginAssertionPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload).base64urlEncoded
    }

    /// Signs `payload` with `privateKey`. `payload.iss` must be the key's
    /// own address.
    static func sign(payload: LoginAssertionPayload, privateKey: Data) throws -> LoginAssertion {
        let encoded = try encode(payload)
        let signature = try signEIP191Message(message(encodedPayload: encoded), privateKey: privateKey)
        return LoginAssertion(token: "\(tokenPrefix).\(encoded).0x\(signature.hexEncodedString)", payload: payload)
    }

    /// Builds and signs the assertion answering `request`.
    static func sign(
        request: LoginWithOsaurusRequest,
        privateKey: Data,
        osaurusID: String?,
        deviceID: String?,
        now: Date,
        jti: String = UUID().uuidString.lowercased()
    ) throws -> LoginAssertion {
        let iat = Int(now.timeIntervalSince1970)
        let payload = LoginAssertionPayload(
            typ: LoginAssertionPayload.type,
            ver: LoginAssertionPayload.version,
            iss: try deriveOsaurusId(from: privateKey).lowercased(),
            aud: request.clientID,
            redirectURI: request.redirectURI.absoluteString,
            nonce: request.nonce,
            iat: iat,
            exp: iat + LoginAssertionPayload.lifetime,
            jti: jti,
            osaurusID: osaurusID,
            dev: deviceID
        )
        return try sign(payload: payload, privateKey: privateKey)
    }

    /// Verifies the signature and every claim a website must check. Nonce
    /// single-use is the caller's job: consume `nonce` only after this
    /// succeeds.
    public static func verify(
        _ token: String,
        audience: String,
        redirectURI: String,
        nonce: String,
        now: Date = Date(),
        clockSkew: Int = 60
    ) throws -> LoginAssertionPayload {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == tokenPrefix,
            let payloadData = Data(base64urlEncoded: String(parts[1])),
            parts[2].hasPrefix("0x"),
            let signature = Data(hexEncoded: String(parts[2].dropFirst(2))), signature.count == 65
        else { throw VerificationError.malformed }

        let payload: LoginAssertionPayload
        do {
            payload = try JSONDecoder().decode(LoginAssertionPayload.self, from: payloadData)
        } catch {
            throw VerificationError.malformed
        }

        let recovered: String
        do {
            recovered = try recoverAddress(
                payload: Data(message(encodedPayload: String(parts[1])).utf8),
                signature: signature,
                domainPrefix: "Ethereum Signed Message")
        } catch {
            throw VerificationError.badSignature
        }

        guard payload.typ == LoginAssertionPayload.type, payload.ver == LoginAssertionPayload.version else {
            throw VerificationError.wrongType
        }
        guard recovered.lowercased() == payload.iss.lowercased() else { throw VerificationError.issuerMismatch }
        guard payload.aud == audience else { throw VerificationError.audienceMismatch }
        guard payload.redirectURI == redirectURI else { throw VerificationError.redirectURIMismatch }
        guard payload.nonce == nonce else { throw VerificationError.nonceMismatch }

        let nowSeconds = Int(now.timeIntervalSince1970)
        guard payload.exp - payload.iat <= LoginAssertionPayload.lifetime else {
            throw VerificationError.lifetimeTooLong
        }
        guard payload.iat <= nowSeconds + clockSkew else { throw VerificationError.issuedInFuture }
        guard payload.exp > nowSeconds - clockSkew else { throw VerificationError.expired }
        return payload
    }
}

// MARK: - Redirects

/// Builds the URLs the app opens to hand the answer back to the website.
public enum LoginWithOsaurusResponse {
    public static func successURL(for request: LoginWithOsaurusRequest, assertion: LoginAssertion) -> URL? {
        url(
            target: request.replyTarget,
            parameters: [("assertion", assertion.token), ("state", request.state)])
    }

    public static func errorURL(target: LoginWithOsaurusReplyTarget, error: LoginWithOsaurusError) -> URL? {
        var parameters = [("error", error.oauthCode)]
        if let detail = error.detail { parameters.append(("error_description", detail)) }
        if let state = target.state { parameters.append(("state", state)) }
        return url(target: target, parameters: parameters)
    }

    static func url(target: LoginWithOsaurusReplyTarget, parameters: [(String, String)]) -> URL? {
        guard var components = URLComponents(url: target.redirectURI, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let encoded = parameters.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        switch target.responseMode {
        case .fragment:
            components.percentEncodedFragment = encoded
        case .query:
            if let existing = components.percentEncodedQuery, !existing.isEmpty {
                components.percentEncodedQuery = existing + "&" + encoded
            } else {
                components.percentEncodedQuery = encoded
            }
        }
        return components.url
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
