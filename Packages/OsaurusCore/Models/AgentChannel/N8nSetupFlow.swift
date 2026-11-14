//
//  N8nSetupFlow.swift
//  osaurus
//
//  n8n-only setup rail, pairing readiness, and copyable workflow recipe.
//  Kept out of the shared Discord/Slack/Telegram section enum so those
//  sheets stay unchanged.
//

import Foundation

// MARK: - Setup sections

/// The five n8n-shaped steps in the order a first-time operator thinks:
/// name it, say where n8n runs, pick who answers, pair, prove it. Every
/// input the pairing code needs (id, location, bound agent, relay) is
/// collected before Pair issues it. Live check stays optional so a
/// configured channel opens on Prove it.
enum N8nSetupSection: String, CaseIterable, Sendable {
    case basics = "basics"
    case location = "location"
    case howOsaurusReplies = "reply"
    case connect = "connect"
    case liveCheck = "live"

    var title: String {
        switch self {
        case .basics: return L("Name it")
        case .location: return L("Where is your n8n?")
        case .howOsaurusReplies: return L("Who answers?")
        case .connect: return L("Pair")
        case .liveCheck: return L("Prove it")
        }
    }

    var icon: String {
        switch self {
        case .basics: return "tag"
        case .location: return "network"
        case .howOsaurusReplies: return "person.crop.circle"
        case .connect: return "link"
        case .liveCheck: return "checkmark.seal"
        }
    }

    var caption: String {
        switch self {
        case .basics: return L("Display name and id")
        case .location: return L("This Mac, Docker, LAN, or remote")
        case .howOsaurusReplies: return L("Agent, encryption, optional push")
        case .connect: return L("Pairing code")
        case .liveCheck: return L("Approve workflows, verify")
        }
    }

    var setupSection: AgentChannelSetupSection {
        AgentChannelSetupSection(id: rawValue, title: title, icon: icon, caption: caption)
    }

    static var sections: [AgentChannelSetupSection] {
        allCases.map(\.setupSection)
    }

    static var requiredSectionIds: [String] {
        [Self.basics.rawValue, Self.location.rawValue, Self.howOsaurusReplies.rawValue, Self.connect.rawValue]
    }

    static var fallbackSectionId: String {
        Self.liveCheck.rawValue
    }
}

// MARK: - Connection id slug

enum N8nConnectionSlug {
    static let prefix = "n8n-"

    /// `"Accounting Channel"` -> `"n8n-accounting-channel"`. Lowercase ASCII
    /// letters and digits survive; every other run collapses to one dash.
    /// Empty input yields an empty slug so the field stays blank until the
    /// operator types a name.
    static func make(from name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en"))
            .lowercased()
        var out = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            let isAlnum = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            if isAlnum {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        guard !out.isEmpty else { return "" }
        if out.hasPrefix("n8n-") || out == "n8n" { return out }
        return prefix + out
    }
}

// MARK: - Recipe

/// Copyable HTTP Request / HMAC / curl fragments that match the wire
/// contract. Pure functions so the sheet and tests share one source.
enum N8nSetupRecipe {
    static func origin(port: Int, location: AgentChannelN8nCallerLocation, relayURL: String? = nil) -> String {
        switch location {
        case .thisMac:
            return "http://127.0.0.1:\(port)"
        case .dockerDesktop:
            return "http://host.docker.internal:\(port)"
        case .lan:
            return "http://<this-mac-ip>:\(port)"
        case .remote:
            if let relayURL, !relayURL.isEmpty {
                return relayURL.hasSuffix("/") ? String(relayURL.dropLast()) : relayURL
            }
            return "https://<relay-url>"
        }
    }

    static func inboundURL(
        connectionId: String,
        port: Int,
        location: AgentChannelN8nCallerLocation,
        relayURL: String? = nil
    ) -> String {
        "\(origin(port: port, location: location, relayURL: relayURL))/channels/n8n/\(connectionId)/inbound"
    }

    static func pollURL(
        connectionId: String,
        port: Int,
        location: AgentChannelN8nCallerLocation,
        relayURL: String? = nil
    ) -> String {
        "\(origin(port: port, location: location, relayURL: relayURL))/channels/n8n/\(connectionId)/tasks/{task_id}"
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
