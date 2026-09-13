//
//  AgentChannelN8nPreset.swift
//  osaurus
//
//  Pre-baked outbound configuration for `n8n` connections. The optional push
//  path is expressed as ordinary custom HTTP actions so every runner gate
//  (C2 host policy, confirm_send, write allowlists, kill switch, idempotency
//  ledger, redaction) applies unchanged; nothing here talks to the network.
//

import Foundation

enum AgentChannelN8nPreset {
    /// Outbound envelope version posted to the n8n Webhook trigger.
    static let outboundEnvelopeVersion = 1

    /// Splits an absolute webhook URL into the runner's `baseURL` (scheme,
    /// host, port) and the action path/query. Returns `nil` for anything
    /// that is not an absolute http(s) URL with a host.
    static func splitWebhookURL(_ webhookURL: String) -> (baseURL: String, path: String, query: [String: String])? {
        guard let components = URLComponents(string: webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil
        else { return nil }
        var base = URLComponents()
        base.scheme = scheme
        base.host = host
        base.port = components.port
        guard let baseURL = base.string else { return nil }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return (baseURL, path, query)
    }

    /// Custom HTTP configuration carrying `send_message` and `reply_thread`
    /// actions that post the outbound envelope to `webhookURL`.
    static func customHTTPConfiguration(
        webhookURL: String,
        secretName: String,
        signBodies: Bool
    ) -> AgentChannelCustomHTTPConfiguration? {
        guard let parts = splitWebhookURL(webhookURL) else { return nil }
        let signature = signBodies ? AgentChannelCustomHTTPBodySignature(secretName: secretName) : nil
        let idempotency = AgentChannelCustomHTTPIdempotency(header: "Idempotency-Key")
        let headers = [
            "Content-Type": "application/json",
            "X-Osaurus-Channel-Kind": AgentChannelKind.n8n.rawValue,
            "X-Osaurus-Connection-Id": "{{connection.id}}",
        ]
        let sendMessage = AgentChannelCustomHTTPAction(
            method: "POST",
            path: parts.path,
            query: parts.query,
            headers: headers,
            bodyTemplate: Self.bodyTemplate(threaded: false),
            responseMapping: AgentChannelCustomHTTPResponseMapping(idPath: "id"),
            idempotency: idempotency,
            bodySignature: signature
        )
        let replyThread = AgentChannelCustomHTTPAction(
            method: "POST",
            path: parts.path,
            query: parts.query,
            headers: headers,
            bodyTemplate: Self.bodyTemplate(threaded: true),
            responseMapping: AgentChannelCustomHTTPResponseMapping(idPath: "id"),
            idempotency: idempotency,
            bodySignature: signature
        )
        return AgentChannelCustomHTTPConfiguration(
            baseURL: parts.baseURL,
            allowedMethods: ["POST"],
            allowInsecureHTTP: parts.baseURL.hasPrefix("http://"),
            actions: [
                AgentChannelAction.sendMessage.rawValue: sendMessage,
                AgentChannelAction.replyThread.rawValue: replyThread,
            ]
        )
    }

    /// Outbound envelope (section 6.2): `event_id` is the runner's stable
    /// idempotency key so n8n can dedupe retries. `reply_token` is not
    /// available on this path; correlate on `conversation_id`/`thread_id`.
    static func bodyTemplate(threaded: Bool) -> String {
        // Placeholders are unquoted: in JSON body mode the renderer inserts a
        // complete JSON literal (quotes and escaping included).
        let conversation = threaded ? "{{input.thread_id}}" : "{{input.room_id}}"
        var fields = [
            "\"v\":\(outboundEnvelopeVersion)",
            "\"event_id\":{{idempotency.key}}",
            "\"connection_id\":{{connection.id}}",
            "\"conversation_id\":\(conversation)",
        ]
        if threaded {
            fields.append("\"thread_id\":{{input.thread_id}}")
        }
        fields.append("\"sender\":{\"id\":\"osaurus\",\"display\":\"Osaurus\",\"is_bot\":true}")
        fields.append("\"content\":{{input.content}}")
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Projects the n8n block onto the generic connection fields the runner
    /// reads: secrets reference, custom HTTP actions, supported actions and
    /// write allowlists. Idempotent; call before every save.
    static func applyingOutbound(to connection: AgentChannelConnection) -> AgentChannelConnection {
        guard connection.kind == .n8n, let n8n = connection.n8n else { return connection }
        var updated = connection
        let secretReference = AgentChannelSecretReference(name: n8n.secretName, keychainId: n8n.secretName)
        if !updated.secrets.contains(where: { $0.name == n8n.secretName }) {
            updated.secrets.append(secretReference)
        }
        updated.spaceAllowlist = Array(Set(updated.spaceAllowlist + [AgentChannelN8nConfiguration.spaceId])).sorted()
        var actions = Set(updated.supportedActions)
        actions.insert(.diagnostics)
        if let webhookURL = n8n.outbound.webhookURL,
            let customHTTP = customHTTPConfiguration(
                webhookURL: webhookURL,
                secretName: n8n.secretName,
                signBodies: n8n.outbound.signBodies
            )
        {
            updated.customHTTP = customHTTP
            actions.insert(.sendMessage)
            actions.insert(.replyThread)
            updated.writeEnabled = true
            // Outbound targets are the same conversations we accept inbound from.
            updated.writeRoomAllowlist = updated.inboundAuthorization.roomAllowlist
        } else {
            updated.customHTTP = nil
            actions.remove(.sendMessage)
            actions.remove(.replyThread)
            updated.writeEnabled = false
            updated.writeRoomAllowlist = []
        }
        updated.supportedActions = AgentChannelAction.allCases.filter(actions.contains)
        return updated
    }

    /// Reply handler installed on the webhook ingress: posts the agent's
    /// reply to the connection's outbound webhook through the custom runner
    /// (so C2, confirm_send, allowlists, kill switch and idempotency all
    /// apply). `nil` when the connection has no outbound webhook or auto-reply
    /// is off, in which case replies remain poll-only.
    static func replyHandler(
        for connection: AgentChannelConnection,
        envelope: AgentChannelN8nEnvelope,
        runner: any AgentChannelCustomJSONRunning,
        ingress: AgentChannelWebhookIngress
    ) -> AgentChannelInboundReplyHandler? {
        guard let n8n = connection.n8n,
            n8n.outbound.isConfigured,
            n8n.inboundDispatch.autoReplyEnabled,
            connection.customHTTP != nil
        else { return nil }
        let conversationId = envelope.conversationId
        let connectionId = connection.id
        return { text in
            do {
                _ = try await runner.sendMessage(
                    connection: connection,
                    roomId: conversationId,
                    content: text,
                    confirmSend: true
                )
                await ingress.recordOutbound(connectionId: connectionId, succeeded: true)
            } catch {
                await ingress.recordOutbound(connectionId: connectionId, succeeded: false)
                throw error
            }
        }
    }
}
