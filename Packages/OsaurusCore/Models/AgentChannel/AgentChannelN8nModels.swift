//
//  AgentChannelN8nModels.swift
//  osaurus
//
//  Connection configuration and wire contract for the `n8n` Agent Channel
//  kind: a generic, secret-verified inbound webhook riding the Async Channel
//  Substrate with pull-based (pollable) replies, plus optional HMAC-signed
//  outbound pushes over the custom JSON runner.
//

import Foundation

// MARK: - Connection configuration

/// Transport policy for callers that are not on loopback. The Osaurus
/// default is end-to-end encryption (`/secure/call`); operators running n8n
/// inside Docker on the same Mac (whose traffic arrives from the bridge
/// network, not loopback) can opt into plaintext HTTP because the request is
/// still authenticated by the connection secret.
enum AgentChannelN8nRemoteTransportPolicy: String, Codable, CaseIterable, Sendable {
    case secureChannelRequired = "secure_channel_required"
    case plaintextAllowed = "plaintext_allowed"
}

/// Where the operator's n8n instance runs relative to this Mac. Chosen in the
/// setup sheet's "Where is your n8n?" step and persisted so a reopened
/// channel regenerates a pairing code with exactly the URLs that can reach
/// this Mac from there: loopback, the Docker Desktop host alias, the LAN
/// address, or the public relay URL.
enum AgentChannelN8nCallerLocation: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case thisMac = "this_mac"
    case dockerDesktop = "docker_desktop"
    case lan = "lan"
    case remote = "remote"

    var title: String {
        switch self {
        case .thisMac: return L("This Mac")
        case .dockerDesktop: return L("Docker Desktop on this Mac")
        case .lan: return L("Another machine on my network")
        case .remote: return L("Remote (hosted or another network)")
        }
    }

    /// One-line consequence shown under the picker.
    var summary: String {
        switch self {
        case .thisMac:
            return L("n8n calls 127.0.0.1. Nothing leaves this Mac.")
        case .dockerDesktop:
            return L("n8n calls host.docker.internal; Docker Desktop delivers it as a same-Mac request.")
        case .lan:
            return L("n8n calls this Mac's LAN address. The server must be exposed to the network.")
        case .remote:
            return L("n8n reaches this Mac through the Osaurus relay, end-to-end encrypted. No ports to open.")
        }
    }

    /// Best guess for connections saved before the location was stored.
    static func inferred(plaintextAllowed: Bool) -> AgentChannelN8nCallerLocation {
        plaintextAllowed ? .lan : .thisMac
    }
}

/// How inbound requests prove they came from the paired n8n workflow.
struct AgentChannelN8nInboundVerification: Codable, Equatable, Sendable {
    static let defaultSharedSecretHeader = "X-Osaurus-Channel-Secret"
    static let defaultSignatureHeader = "X-Osaurus-Channel-Signature"
    static let defaultSignaturePrefix = "sha256="

    var method: AgentChannelSourceVerificationMethod
    var headerName: String?
    var signaturePrefix: String?

    init(
        method: AgentChannelSourceVerificationMethod = .hmacSHA256,
        headerName: String? = nil,
        signaturePrefix: String? = nil
    ) {
        // `.none` is never a valid n8n verification method: the route is
        // bearer-exempt, so the secret is the only authentication.
        self.method = method == .none ? .hmacSHA256 : method
        self.headerName = Self.normalizedOptional(headerName)
        self.signaturePrefix = Self.normalizedOptional(signaturePrefix)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            method: try container.decodeIfPresent(AgentChannelSourceVerificationMethod.self, forKey: .method)
                ?? .hmacSHA256,
            headerName: try container.decodeIfPresent(String.self, forKey: .headerName),
            signaturePrefix: try container.decodeIfPresent(String.self, forKey: .signaturePrefix)
        )
    }

    /// The header the caller must send for this method.
    var effectiveHeaderName: String {
        if let headerName { return headerName }
        switch method {
        case .hmacSHA256: return Self.defaultSignatureHeader
        case .sharedSecretHeader, .none: return Self.defaultSharedSecretHeader
        }
    }

    /// Substrate policy with the resolved secret attached.
    func policy(secret: String?) -> AgentChannelSourceVerificationPolicy {
        AgentChannelSourceVerificationPolicy(
            method: method,
            headerName: effectiveHeaderName,
            secret: secret,
            signaturePrefix: signaturePrefix ?? Self.defaultSignaturePrefix
        )
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Optional outbound push. Replies are always available by polling; a push
/// additionally posts them to an n8n Webhook trigger. The URL must pass the
/// custom JSON runner's host policy (public HTTPS; loopback/RFC1918 refused).
struct AgentChannelN8nOutboundConfiguration: Codable, Equatable, Sendable {
    var webhookURL: String?
    var signBodies: Bool

    init(webhookURL: String? = nil, signBodies: Bool = true) {
        let trimmed = webhookURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.webhookURL = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.signBodies = signBodies
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            webhookURL: try container.decodeIfPresent(String.self, forKey: .webhookURL),
            signBodies: try container.decodeIfPresent(Bool.self, forKey: .signBodies) ?? true
        )
    }

    var isConfigured: Bool { webhookURL != nil }
}

/// Everything specific to an `n8n` connection. Lives next to the generic
/// allowlists/`inboundAuthorization` on `AgentChannelConnection`.
struct AgentChannelN8nConfiguration: Codable, Equatable, Sendable {
    static let defaultSecretName = "webhook"
    /// Provider "space" id every n8n event is scoped to; the connection's
    /// `spaceAllowlist` must contain it (or `allowUnscopedSpaces`).
    static let spaceId = "n8n"

    var inboundVerification: AgentChannelN8nInboundVerification
    /// Keychain secret name under `osaurus.agent-channel.<connection_id>`.
    var secretName: String
    var inboundDispatch: AgentChannelInboundDispatchConfiguration
    var remoteTransportPolicy: AgentChannelN8nRemoteTransportPolicy
    var outbound: AgentChannelN8nOutboundConfiguration
    /// Where n8n runs; nil on rows saved before the setup step existed.
    var callerLocation: AgentChannelN8nCallerLocation?

    init(
        inboundVerification: AgentChannelN8nInboundVerification = AgentChannelN8nInboundVerification(),
        secretName: String = AgentChannelN8nConfiguration.defaultSecretName,
        inboundDispatch: AgentChannelInboundDispatchConfiguration = AgentChannelInboundDispatchConfiguration(),
        remoteTransportPolicy: AgentChannelN8nRemoteTransportPolicy = .secureChannelRequired,
        outbound: AgentChannelN8nOutboundConfiguration = AgentChannelN8nOutboundConfiguration(),
        callerLocation: AgentChannelN8nCallerLocation? = nil
    ) {
        self.inboundVerification = inboundVerification
        let trimmedName = secretName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secretName = trimmedName.isEmpty ? Self.defaultSecretName : trimmedName
        // n8n has no mention concept; the workflow already decided this
        // message is for the agent.
        var dispatch = inboundDispatch
        dispatch.requireMention = false
        self.inboundDispatch = dispatch
        self.remoteTransportPolicy = remoteTransportPolicy
        self.outbound = outbound
        self.callerLocation = callerLocation
    }

    /// Stored location, or the inference for legacy rows.
    var effectiveCallerLocation: AgentChannelN8nCallerLocation {
        callerLocation ?? .inferred(plaintextAllowed: remoteTransportPolicy == .plaintextAllowed)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            inboundVerification: try container.decodeIfPresent(
                AgentChannelN8nInboundVerification.self,
                forKey: .inboundVerification
            ) ?? AgentChannelN8nInboundVerification(),
            secretName: try container.decodeIfPresent(String.self, forKey: .secretName)
                ?? Self.defaultSecretName,
            inboundDispatch: try container.decodeIfPresent(
                AgentChannelInboundDispatchConfiguration.self,
                forKey: .inboundDispatch
            ) ?? AgentChannelInboundDispatchConfiguration(),
            remoteTransportPolicy: try container.decodeIfPresent(
                AgentChannelN8nRemoteTransportPolicy.self,
                forKey: .remoteTransportPolicy
            ) ?? .secureChannelRequired,
            outbound: try container.decodeIfPresent(
                AgentChannelN8nOutboundConfiguration.self,
                forKey: .outbound
            ) ?? AgentChannelN8nOutboundConfiguration(),
            callerLocation: try container.decodeIfPresent(
                AgentChannelN8nCallerLocation.self,
                forKey: .callerLocation
            )
        )
    }

    var normalized: AgentChannelN8nConfiguration {
        AgentChannelN8nConfiguration(
            inboundVerification: inboundVerification,
            secretName: secretName,
            inboundDispatch: inboundDispatch,
            remoteTransportPolicy: remoteTransportPolicy,
            outbound: outbound,
            callerLocation: callerLocation
        )
    }
}

// MARK: - Envelope v1 (inbound wire contract)

enum AgentChannelN8nEnvelopeError: Error, Equatable, Sendable {
    case invalidJSON
    case unsupportedVersion(Int)
    case missingField(String)
    case emptyContent
    case contentTooLarge(limit: Int)

    var code: String {
        switch self {
        case .unsupportedVersion: return "unsupported_envelope_version"
        case .invalidJSON, .missingField, .emptyContent, .contentTooLarge: return "invalid_payload"
        }
    }

    var message: String {
        switch self {
        case .invalidJSON:
            return "Body must be a JSON object."
        case .unsupportedVersion(let version):
            return "Envelope version \(version) is not supported; send v=1."
        case .missingField(let field):
            return "Missing or empty required field: \(field)."
        case .emptyContent:
            return "content must be a non-empty string."
        case .contentTooLarge(let limit):
            return "content exceeds \(limit) characters."
        }
    }
}

struct AgentChannelN8nEnvelopeSender: Equatable, Sendable {
    var id: String
    var display: String?
    var isBot: Bool
}

struct AgentChannelN8nEnvelopeAttachment: Equatable, Sendable {
    var id: String
    var filename: String?
    var contentType: String?
    var sizeBytes: Int?
    var url: String?

    var stored: AgentChannelStoredAttachment {
        let kind: AgentChannelStoredAttachmentKind
        if let contentType = contentType?.lowercased() {
            if contentType.hasPrefix("image/") {
                kind = .image
            } else if contentType.hasPrefix("audio/") {
                kind = .audio
            } else if contentType.hasPrefix("video/") {
                kind = .video
            } else {
                kind = .file
            }
        } else {
            kind = .file
        }
        return AgentChannelStoredAttachment(
            providerId: id,
            kind: kind,
            filename: filename,
            contentType: contentType,
            sizeBytes: sizeBytes,
            remoteURL: url
        )
    }
}

/// The message an n8n workflow posts to Osaurus. Parsed only AFTER the
/// request has been verified against the connection secret.
struct AgentChannelN8nEnvelope: Equatable, Sendable {
    static let supportedVersion = 1
    static let maxContentCharacters = 32_000
    static let maxAttachments = 20

    var version: Int
    var eventId: String
    var conversationId: String
    var threadId: String?
    var sender: AgentChannelN8nEnvelopeSender
    var content: String
    var attachments: [AgentChannelN8nEnvelopeAttachment]
    var replyToken: String?
    /// Raw body, re-serialized, for the stored message snapshot.
    var payloadJSON: String

    static func parse(_ data: Data) throws -> AgentChannelN8nEnvelope {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentChannelN8nEnvelopeError.invalidJSON
        }
        let version = (object["v"] as? Int) ?? (object["v"] as? Double).map(Int.init) ?? 0
        guard version == supportedVersion else {
            throw AgentChannelN8nEnvelopeError.unsupportedVersion(version)
        }
        guard let eventId = requiredString(object["event_id"]) else {
            throw AgentChannelN8nEnvelopeError.missingField("event_id")
        }
        guard let conversationId = requiredString(object["conversation_id"]) else {
            throw AgentChannelN8nEnvelopeError.missingField("conversation_id")
        }
        guard let senderObject = object["sender"] as? [String: Any],
            let senderId = requiredString(senderObject["id"])
        else {
            throw AgentChannelN8nEnvelopeError.missingField("sender.id")
        }
        guard let rawContent = object["content"] as? String else {
            throw AgentChannelN8nEnvelopeError.missingField("content")
        }
        let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw AgentChannelN8nEnvelopeError.emptyContent
        }
        guard content.count <= maxContentCharacters else {
            throw AgentChannelN8nEnvelopeError.contentTooLarge(limit: maxContentCharacters)
        }

        var attachments: [AgentChannelN8nEnvelopeAttachment] = []
        if let rawAttachments = object["attachments"] as? [[String: Any]] {
            for raw in rawAttachments.prefix(maxAttachments) {
                guard let id = requiredString(raw["id"]) else { continue }
                attachments.append(
                    AgentChannelN8nEnvelopeAttachment(
                        id: id,
                        filename: optionalString(raw["filename"]),
                        contentType: optionalString(raw["content_type"]),
                        sizeBytes: raw["size_bytes"] as? Int,
                        url: optionalString(raw["url"])
                    )
                )
            }
        }

        let payloadJSON: String
        if let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            payloadJSON = String(decoding: canonical, as: UTF8.self)
        } else {
            payloadJSON = "{}"
        }

        return AgentChannelN8nEnvelope(
            version: version,
            eventId: eventId,
            conversationId: conversationId,
            threadId: optionalString(object["thread_id"]),
            sender: AgentChannelN8nEnvelopeSender(
                id: senderId,
                display: optionalString(senderObject["display"]),
                isBot: (senderObject["is_bot"] as? Bool) ?? false
            ),
            content: content,
            attachments: attachments,
            replyToken: optionalString(object["reply_token"]),
            payloadJSON: payloadJSON
        )
    }

    /// Normalized snapshot persisted by `AgentChannelMessageStore`.
    func storedMessage(connectionId: String, receivedAt: Date = Date()) -> AgentChannelStoredMessage {
        AgentChannelStoredMessage(
            connectionId: connectionId,
            roomId: conversationId,
            providerMessageId: eventId,
            direction: .inbound,
            threadId: threadId,
            authorId: sender.id,
            authorName: sender.display,
            content: content,
            attachments: attachments.map(\.stored),
            payloadJSON: payloadJSON,
            providerTimestamp: nil,
            receivedAt: receivedAt
        )
    }

    private static func requiredString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func optionalString(_ value: Any?) -> String? {
        requiredString(value)
    }
}
