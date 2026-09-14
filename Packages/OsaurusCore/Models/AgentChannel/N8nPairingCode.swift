//
//  N8nPairingCode.swift
//  osaurus
//
//  One copyable artifact that carries everything the `n8n-nodes-osaurus`
//  Channel credential needs: the URL candidates to try, the connection id,
//  the channel secret, the verification method, and (when a local agent is
//  bound) the agent address the node pins for Secure Channel. The sheet
//  encodes it; the node decodes it. Format:
//
//      osrs-n8n-1.<base64url(compact JSON, sorted keys)>
//
//  The payload contains the channel secret and must be handled like one.
//

import Foundation

enum N8nPairingCodeError: Error, Equatable {
    case missingPrefix
    case malformedPayload
    case unsupportedVersion(Int)
    case missingField(String)
}

struct N8nPairingCode: Codable, Equatable, Sendable {
    static let version = 1
    static let prefix = "osrs-n8n-\(version)."

    /// Schema version.
    let v: Int
    /// Ordered base-URL candidates; the node tries them first-to-last.
    let urls: [String]
    /// Connection id (path segment of `/channels/n8n/{cid}/…`).
    let cid: String
    /// Channel secret (HMAC key or shared-secret header value).
    let secret: String
    /// `hmac_sha256` or `shared_secret_header`.
    let vfy: String
    /// Header-name override, only when the sheet set one.
    let hdr: String?
    /// Pinned agent address (`0x…`). Present means the node speaks Secure
    /// Channel to every candidate; absent means plaintext HTTP.
    let addr: String?
    /// Display name for the credential.
    let name: String?

    init(
        urls: [String],
        cid: String,
        secret: String,
        vfy: AgentChannelSourceVerificationMethod,
        hdr: String? = nil,
        addr: String? = nil,
        name: String? = nil
    ) {
        self.v = Self.version
        self.urls = urls
        self.cid = cid
        self.secret = secret
        self.vfy = (vfy == .none ? .hmacSHA256 : vfy).rawValue
        self.hdr = Self.normalized(hdr)
        self.addr = Self.normalized(addr)?.lowercased()
        self.name = Self.normalized(name)
    }

    var verificationMethod: AgentChannelSourceVerificationMethod {
        AgentChannelSourceVerificationMethod(rawValue: vfy) ?? .hmacSHA256
    }

    /// True when the node will use Secure Channel.
    var isEndToEndEncrypted: Bool { addr != nil }

    // MARK: Encoding

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a flat Codable struct of strings cannot fail.
        let data = (try? encoder.encode(self)) ?? Data()
        return Self.prefix + data.base64urlEncoded
    }

    static func decode(_ string: String) throws -> N8nPairingCode {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("osrs-n8n-") else { throw N8nPairingCodeError.missingPrefix }
        guard let dot = trimmed.firstIndex(of: ".") else { throw N8nPairingCodeError.malformedPayload }
        let versionText = trimmed[trimmed.index(trimmed.startIndex, offsetBy: "osrs-n8n-".count)..<dot]
        guard let parsedVersion = Int(versionText) else { throw N8nPairingCodeError.malformedPayload }
        guard parsedVersion == version else { throw N8nPairingCodeError.unsupportedVersion(parsedVersion) }
        let payload = String(trimmed[trimmed.index(after: dot)...])
        guard let data = Data(base64urlEncoded: payload),
            let code = try? JSONDecoder().decode(N8nPairingCode.self, from: data)
        else {
            throw N8nPairingCodeError.malformedPayload
        }
        guard code.v == version else { throw N8nPairingCodeError.unsupportedVersion(code.v) }
        guard !code.cid.isEmpty else { throw N8nPairingCodeError.missingField("cid") }
        guard !code.secret.isEmpty else { throw N8nPairingCodeError.missingField("secret") }
        guard !code.urls.isEmpty else { throw N8nPairingCodeError.missingField("urls") }
        return code
    }

    // MARK: Builder

    /// Everything the sheet knows about how this Mac can be reached.
    struct Reachability: Equatable, Sendable {
        var port: Int
        /// Server bound to 0.0.0.0 (Server settings → Expose to network).
        var exposedToNetwork: Bool
        /// LAN address when exposed; ignored otherwise.
        var lanAddress: String?
        /// Public relay URL (`https://0x….agent.osaurus.ai`) once the relay
        /// reports the route is live.
        var relayURL: String?
        /// Address of the local agent bound as the inbound dispatch target.
        var agentAddress: String?

        init(
            port: Int,
            exposedToNetwork: Bool = false,
            lanAddress: String? = nil,
            relayURL: String? = nil,
            agentAddress: String? = nil
        ) {
            self.port = port
            self.exposedToNetwork = exposedToNetwork
            self.lanAddress = lanAddress
            self.relayURL = relayURL
            self.agentAddress = agentAddress
        }
    }

    /// Ordered candidates: loopback, Docker Desktop host alias, LAN address
    /// (only when the server is exposed), relay (only when live).
    static func urlCandidates(_ reachability: Reachability) -> [String] {
        var urls = [
            "http://127.0.0.1:\(reachability.port)",
            "http://host.docker.internal:\(reachability.port)",
        ]
        if reachability.exposedToNetwork,
            let lan = normalized(reachability.lanAddress),
            lan != "127.0.0.1", lan != "0.0.0.0"
        {
            urls.append("http://\(lan):\(reachability.port)")
        }
        if let relay = normalized(reachability.relayURL) {
            urls.append(relay.hasSuffix("/") ? String(relay.dropLast()) : relay)
        }
        return urls
    }

    static func make(
        connectionId: String,
        name: String,
        secret: String,
        verification: AgentChannelN8nInboundVerification,
        reachability: Reachability
    ) -> N8nPairingCode {
        N8nPairingCode(
            urls: urlCandidates(reachability),
            cid: AgentChannelConnection.normalizedId(connectionId),
            secret: secret,
            vfy: verification.method,
            hdr: verification.headerName,
            addr: reachability.agentAddress,
            name: name
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
