//
//  MCPHTTPTransportBuilder.swift
//  osaurus
//
//  Single construction point for remote MCP HTTP transports so the
//  connect path, the test-connection path, and the probe path all get
//  the same timeout and header semantics.
//

import Foundation
import MCP

enum MCPHTTPTransportBuilder {
    /// Floor for the URLSession per-request (idle) timeout. The logical MCP
    /// timeouts (discovery / tool call) are enforced above the transport by
    /// `withTimeout` races, so the session-level timeout only needs to catch
    /// truly dead connections — it must never be shorter than the logical
    /// timeouts or it wins the race and long tool calls die early.
    static let minimumRequestTimeout: TimeInterval = 60

    /// Build the URLSession configuration for a remote MCP provider.
    ///
    /// Two deliberate differences from the historical behavior:
    /// - `timeoutIntervalForRequest` is the max of the logical timeouts (with
    ///   a floor), not the discovery timeout alone. The old value (default
    ///   20s) applied to every request in the session, so a tool call that
    ///   produced no bytes for 20s was killed even though the tool-call
    ///   timeout was 45s.
    /// - `timeoutIntervalForResource` is left at the URLSession default
    ///   (7 days). The old cap of `max(discovery, toolCall)` hard-killed the
    ///   long-lived SSE GET stream every ~45 seconds, forcing a permanent
    ///   reconnect churn loop for streaming providers.
    ///
    /// Headers are intentionally NOT set here: `httpAdditionalHeaders` is
    /// documented by Apple as unsupported for `Authorization`, so auth and
    /// custom headers ride on each request via `requestModifier(headers:)`.
    static func sessionConfiguration(
        discoveryTimeout: TimeInterval,
        toolCallTimeout: TimeInterval
    ) -> URLSessionConfiguration {
        let configuration = GlobalProxySettings.makeConfiguration(base: .default)
        configuration.timeoutIntervalForRequest = max(
            discoveryTimeout, toolCallTimeout, minimumRequestTimeout
        )
        return configuration
    }

    /// Per-request header injection with `httpAdditionalHeaders` semantics:
    /// a header already present on the request (the SDK sets Accept,
    /// Content-Type, MCP-Session-Id, ...) is never overwritten.
    static func requestModifier(headers: [String: String]) -> @Sendable (URLRequest) -> URLRequest {
        guard !headers.isEmpty else { return { $0 } }
        return { request in
            var modified = request
            for (key, value) in headers where modified.value(forHTTPHeaderField: key) == nil {
                modified.setValue(value, forHTTPHeaderField: key)
            }
            return modified
        }
    }

    /// Build the transport used by connect, test-connection, and HTTP probes.
    static func makeTransport(
        endpoint: URL,
        headers: [String: String],
        streaming: Bool,
        discoveryTimeout: TimeInterval,
        toolCallTimeout: TimeInterval
    ) -> HTTPClientTransport {
        HTTPClientTransport(
            endpoint: endpoint,
            configuration: sessionConfiguration(
                discoveryTimeout: discoveryTimeout,
                toolCallTimeout: toolCallTimeout
            ),
            streaming: streaming,
            requestModifier: requestModifier(headers: headers)
        )
    }
}
