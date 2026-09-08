//
//  OsaurusRelayPresenceSignal.swift
//  osaurus
//
//  The relay (`*.agent.osaurus.ai`) is the authoritative presence source: a
//  host is online exactly when it holds a live tunnel. The router's roster
//  `online` flag is derived from the relay's internal `/presence` endpoint,
//  but that endpoint is router-only and Redis-backed with a 120 s claim TTL,
//  so the roster can lag a dead tunnel by up to two minutes and a live one
//  by a poll interval.
//
//  Every request this client sends *through* the relay already carries the
//  fresh answer, for free:
//    - `502 {"error":"agent_offline"}`      → no tunnel: the host is down.
//    - `502 {"error":"tunnel_send_failed"}` / `504 gateway_timeout` → the
//      tunnel died mid-request.
//    - Anything else (200, or a 4xx *from the host*) → the tunnel is up.
//  This helper turns those into `WorkspaceRosterStore` presence flips so the
//  composer locks/unlocks immediately instead of waiting on the poll.
//

import Foundation

enum OsaurusRelayPresenceSignal {
    static let relayBaseDomain = "agent.osaurus.ai"

    /// Relay error strings that mean the host is not reachable right now.
    static let unreachableErrors: Set<String> = ["agent_offline", "tunnel_send_failed", "gateway_timeout"]

    /// The shared-agent address when `url` targets the relay
    /// (`https://0x….agent.osaurus.ai/...`); nil for any other host.
    static func agentAddress(fromRelayURL url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), host.hasSuffix("." + relayBaseDomain) else { return nil }
        let sub = String(host.dropLast(relayBaseDomain.count + 1))
        guard sub.count == 42, sub.hasPrefix("0x"),
            sub.dropFirst(2).allSatisfy({ $0.isHexDigit })
        else { return nil }
        return sub
    }

    /// The relay's own error token (`{"error":"agent_offline"}`), or nil when
    /// the body is not a relay envelope (host bodies use `{"error":{…}}`).
    static func relayError(in body: Data?) -> String? {
        guard let body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let error = json["error"] as? String
        else { return nil }
        return error
    }

    /// True when the response says the relay could not reach the host.
    static func indicatesHostUnreachable(statusCode: Int, body: Data?) -> Bool {
        guard statusCode == 502 || statusCode == 504 else { return false }
        guard let error = relayError(in: body) else { return false }
        return unreachableErrors.contains(error)
    }

    /// User-facing copy for a relay unreachable verdict; nil for other bodies.
    static func unreachableMessage(statusCode: Int, body: Data?) -> String? {
        guard indicatesHostUnreachable(statusCode: statusCode, body: body) else { return nil }
        return L("The agent's host is offline. Ask its owner to open Osaurus.")
    }

    /// Feed an HTTP response from a relay-routed request into workspace
    /// presence. No-op for non-relay hosts. Safe from any context.
    static func observe(url: URL?, statusCode: Int, body: Data?) {
        guard let address = agentAddress(fromRelayURL: url) else { return }
        let unreachable = indicatesHostUnreachable(statusCode: statusCode, body: body)
        Task { @MainActor in
            if unreachable {
                WorkspaceRosterStore.shared.noteHostUnreachable(agentAddress: address)
            } else {
                WorkspaceRosterStore.shared.noteHostReachable(agentAddress: address)
            }
        }
    }

    // Transport failures (no HTTP response) deliberately do NOT flip
    // presence: a timeout or DNS failure reaching the relay says more about
    // this Mac's network than about the teammate's host. Only the relay's
    // own verdict is authoritative.
}
