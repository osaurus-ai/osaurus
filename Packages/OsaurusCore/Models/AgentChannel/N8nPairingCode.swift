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
        /// Where the operator said n8n runs; scopes the URL list.
        var callerLocation: AgentChannelN8nCallerLocation
        /// Server bound to 0.0.0.0 (Server settings → Expose to network).
        var exposedToNetwork: Bool
        /// LAN address when exposed; ignored otherwise.
        var lanAddress: String?
        /// Public relay URL (`https://0x….agent.osaurus.ai`) once the relay
        /// reports the route is live.
        var relayURL: String?
        /// Address of the local agent bound as the inbound dispatch target.
        var agentAddress: String?
        /// Connection allows plaintext HTTP from other machines.
        var plaintextAllowed: Bool

        init(
            port: Int,
            callerLocation: AgentChannelN8nCallerLocation = .thisMac,
            exposedToNetwork: Bool = false,
            lanAddress: String? = nil,
            relayURL: String? = nil,
            agentAddress: String? = nil,
            plaintextAllowed: Bool = false
        ) {
            self.port = port
            self.callerLocation = callerLocation
            self.exposedToNetwork = exposedToNetwork
            self.lanAddress = lanAddress
            self.relayURL = relayURL
            self.agentAddress = agentAddress
            self.plaintextAllowed = plaintextAllowed
        }
    }

    /// Why the sheet cannot issue a working code yet. Each case names the
    /// step that unblocks it so the UI can jump there.
    enum Blocker: Equatable, Sendable {
        /// Remote needs a bound local agent for Secure Channel + relay.
        case needsBoundAgent
        /// Remote: the bound agent's relay is not connected yet.
        case needsRelay
        /// LAN: server is not bound to the network / no LAN address.
        case needsExposeToNetwork
        /// LAN without a bound agent: plaintext from other machines is off,
        /// so a remote caller would be refused with 426.
        case needsPlaintextOrAgent
    }

    enum Readiness: Equatable, Sendable {
        case ready
        case blocked(Blocker)

        var blocker: Blocker? {
            if case .blocked(let blocker) = self { return blocker }
            return nil
        }
    }

    /// Only the URLs that can reach this Mac from the chosen location. An
    /// empty list means the code must not be issued yet (see `readiness`).
    static func urlCandidates(_ reachability: Reachability) -> [String] {
        switch reachability.callerLocation {
        case .thisMac:
            return ["http://127.0.0.1:\(reachability.port)"]
        case .dockerDesktop:
            return ["http://host.docker.internal:\(reachability.port)"]
        case .lan:
            guard reachability.exposedToNetwork,
                let lan = normalized(reachability.lanAddress),
                lan != "127.0.0.1", lan != "0.0.0.0"
            else { return [] }
            return ["http://\(lan):\(reachability.port)"]
        case .remote:
            guard let relay = normalized(reachability.relayURL) else { return [] }
            return [relay.hasSuffix("/") ? String(relay.dropLast()) : relay]
        }
    }

    /// Whether a code built from `reachability` would work from the chosen
    /// location, and if not, what the operator must do first.
    static func readiness(_ reachability: Reachability) -> Readiness {
        switch reachability.callerLocation {
        case .thisMac, .dockerDesktop:
            return .ready
        case .lan:
            if urlCandidates(reachability).isEmpty { return .blocked(.needsExposeToNetwork) }
            if normalized(reachability.agentAddress) == nil, !reachability.plaintextAllowed {
                return .blocked(.needsPlaintextOrAgent)
            }
            return .ready
        case .remote:
            if normalized(reachability.agentAddress) == nil { return .blocked(.needsBoundAgent) }
            if urlCandidates(reachability).isEmpty { return .blocked(.needsRelay) }
            return .ready
        }
    }

    /// Nil when there is no URL that can work from the chosen location; the
    /// sheet shows the blocker instead of a code that can never connect.
    static func make(
        connectionId: String,
        name: String,
        secret: String,
        verification: AgentChannelN8nInboundVerification,
        reachability: Reachability
    ) -> N8nPairingCode? {
        let urls = urlCandidates(reachability)
        guard !urls.isEmpty else { return nil }
        return N8nPairingCode(
            urls: urls,
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
