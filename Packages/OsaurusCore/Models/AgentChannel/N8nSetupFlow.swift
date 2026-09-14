//
//  N8nSetupFlow.swift
//  osaurus
//
//  n8n-only setup rail, topology, and copyable workflow recipe. Kept out of
//  the shared Discord/Slack/Telegram section enum so those sheets stay
//  unchanged.
//

import Foundation

// MARK: - Topology

/// Where the operator's n8n instance lives relative to this Mac. Drives
/// which inbound URL the sheet shows; it is UI state, not a stored field.
enum N8nTopology: String, CaseIterable, Equatable, Hashable, Sendable {
    case thisMac
    case dockerDesktop
    case lan
    case remote

    var title: String {
        switch self {
        case .thisMac: return L("This Mac")
        case .dockerDesktop: return L("Docker Desktop on this Mac")
        case .lan: return L("Another machine on the LAN")
        case .remote: return L("Remote (Secure Channel)")
        }
    }

    /// True when the operator should see the plaintext-HTTP toggle.
    var revealsPlaintextToggle: Bool {
        self == .lan || self == .remote
    }

    /// True when Share Agent / osk-v1 is relevant (and must be labeled as
    /// not the inbound webhook secret).
    var revealsSecureChannel: Bool {
        self == .remote
    }

    /// Sensible first pick when reopening a saved connection.
    static func inferred(plaintextAllowed: Bool) -> N8nTopology {
        plaintextAllowed ? .lan : .thisMac
    }
}

// MARK: - Setup sections

/// The five n8n-shaped steps. Required rail IDs are `where`, `call`, and
/// `who`; reply and live stay optional so a configured channel opens on
/// Live check.
enum N8nSetupSection: String, CaseIterable, Sendable {
    case whereIsN8n = "where"
    case howN8nCalls = "call"
    case whoMaySpeak = "who"
    case howOsaurusReplies = "reply"
    case liveCheck = "live"

    var title: String {
        switch self {
        case .whereIsN8n: return L("Where is n8n?")
        case .howN8nCalls: return L("How n8n calls Osaurus")
        case .whoMaySpeak: return L("Who may speak")
        case .howOsaurusReplies: return L("How Osaurus replies")
        case .liveCheck: return L("Live check")
        }
    }

    var icon: String {
        switch self {
        case .whereIsN8n: return "desktopcomputer"
        case .howN8nCalls: return "arrow.down.circle"
        case .whoMaySpeak: return "person.2"
        case .howOsaurusReplies: return "arrow.uturn.left"
        case .liveCheck: return "checkmark.seal"
        }
    }

    var caption: String {
        switch self {
        case .whereIsN8n: return L("Topology")
        case .howN8nCalls: return L("Webhook")
        case .whoMaySpeak: return L("Allowlists")
        case .howOsaurusReplies: return L("Poll or push")
        case .liveCheck: return L("Verify")
        }
    }

    var setupSection: AgentChannelSetupSection {
        AgentChannelSetupSection(id: rawValue, title: title, icon: icon, caption: caption)
    }

    static var sections: [AgentChannelSetupSection] {
        allCases.map(\.setupSection)
    }

    static var requiredSectionIds: [String] {
        [Self.whereIsN8n.rawValue, Self.howN8nCalls.rawValue, Self.whoMaySpeak.rawValue]
    }

    static var fallbackSectionId: String {
        Self.liveCheck.rawValue
    }
}

// MARK: - Recipe

/// Copyable HTTP Request / HMAC / curl fragments that match the wire
/// contract. Pure functions so the sheet and tests share one source.
enum N8nSetupRecipe {
    static func origin(port: Int, topology: N8nTopology) -> String {
        switch topology {
        case .thisMac:
            return "http://127.0.0.1:\(port)"
        case .dockerDesktop:
            return "http://host.docker.internal:\(port)"
        case .lan, .remote:
            return "http://<this-mac-ip>:\(port)"
        }
    }

    static func inboundURL(connectionId: String, port: Int, topology: N8nTopology) -> String {
        "\(origin(port: port, topology: topology))/channels/n8n/\(connectionId)/inbound"
    }

    static func pollURL(connectionId: String, port: Int, topology: N8nTopology) -> String {
        "\(origin(port: port, topology: topology))/channels/n8n/\(connectionId)/tasks/{task_id}"
    }

    /// Compact v1 envelope the HTTP Request node can paste as JSON.
    /// Attachments are omitted: the ingress stores metadata only.
    static func sampleEnvelope(conversationId: String, senderId: String) -> String {
        let conversation = escapedJSONString(conversationId)
        let sender = escapedJSONString(senderId)
        return
            #"{"v":1,"event_id":"evt-1","conversation_id":"\#(conversation)","sender":{"id":"\#(sender)"},"content":"Reply with the single word PONG"}"#
    }

    /// Method, URL, Content-Type, and the verify header n8n must send.
    static func httpRequestRecipe(
        inboundURL: String,
        headerName: String,
        method: AgentChannelSourceVerificationMethod
    ) -> String {
        let headerLine: String
        switch method {
        case .hmacSHA256:
            headerLine = "\(headerName): sha256=<HMAC-SHA256 of the raw JSON body>"
        case .sharedSecretHeader, .none:
            headerLine = "\(headerName): <channel secret>"
        }
        return """
            POST \(inboundURL)
            Content-Type: application/json
            \(headerLine)
            """
    }

    /// Four-line n8n Code / Crypto fragment. Poll signs the empty body.
    static func hmacCodeSnippet() -> String {
        """
        const crypto = require('crypto');
        const raw = $input.first().json.bodyRaw ?? JSON.stringify($json);
        const sig = 'sha256=' + crypto.createHmac('sha256', secret).update(raw).digest('hex');
        // Poll GET signs the empty body: createHmac('sha256', secret).update('').digest('hex')
        """
    }

    static func curlExample(
        inboundURL: String,
        headerName: String,
        method: AgentChannelSourceVerificationMethod,
        conversationId: String,
        senderId: String
    ) -> String {
        let body = sampleEnvelope(conversationId: conversationId, senderId: senderId)
        switch method {
        case .hmacSHA256:
            return
                "BODY='\(body)'; SIG=$(printf '%s' \"$BODY\" | openssl dgst -sha256 -hmac \"SECRET\" | awk '{print $NF}'); curl -sS -X POST \(inboundURL) -H 'Content-Type: application/json' -H \"\(headerName): sha256=$SIG\" --data \"$BODY\""
        case .sharedSecretHeader, .none:
            return
                "curl -sS -X POST \(inboundURL) -H 'Content-Type: application/json' -H '\(headerName): SECRET' --data '\(body)'"
        }
    }

    /// Short chip for the Connection Center badge.
    static func verifyModeChip(for method: AgentChannelSourceVerificationMethod) -> String {
        switch method {
        case .hmacSHA256:
            return L("HMAC")
        case .sharedSecretHeader, .none:
            return L("Header")
        }
    }

    private static func escapedJSONString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
