//
//  SupportReportBuilder.swift
//  osaurus
//
//  Assembles everything a bug report carries besides the user's own words:
//  the app and macOS version, the Mac's model / chip / memory, and the
//  metadata-only `SupportDiagnosticsBundle`.
//
//  Two rules shape this file:
//  - The user sees exactly what is sent. Diagnostics are serialized once into
//    a `JSONValue`; the "What's Included" preview and the request body are
//    both rendered from that one value.
//  - The router rejects diagnostics over 200 KB. Rather than fail the report,
//    the builder drops the oldest recent requests until the bundle fits, and
//    sends the report without diagnostics if it still cannot.
//

import Foundation

/// The attachments of one bug report, ready to preview and to send.
struct SupportReport: Equatable, Sendable {
    let app: OsaurusRouterSupportReportBody.App
    let hardware: OsaurusRouterSupportReportBody.Hardware
    /// Nil only when the bundle could not be made to fit the router's cap.
    let diagnostics: JSONValue?
    /// Serialized size of `diagnostics`, in bytes (0 when nil).
    let diagnosticsBytes: Int

    /// The request body for `POST /support/threads`. Only call once the
    /// user has ticked the Terms and Privacy box: `consent` is sent as true.
    func body(description: String) -> OsaurusRouterSupportReportBody {
        OsaurusRouterSupportReportBody(
            description: description,
            consent: true,
            app: app,
            hardware: hardware,
            diagnostics: diagnostics
        )
    }

    /// Pretty-printed JSON of everything sent alongside the description, for
    /// the "What's Included" disclosure. Same values as `body(description:)`.
    var previewJSON: String {
        struct Preview: Encodable {
            let app: OsaurusRouterSupportReportBody.App
            let hardware: OsaurusRouterSupportReportBody.Hardware
            let diagnostics: JSONValue?
        }
        let preview = Preview(app: app, hardware: hardware, diagnostics: diagnostics)
        guard let data = try? JSONEncoder.osaurusCanonical(prettyPrinted: true).encode(preview),
            let text = String(bytes: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}

enum SupportReportBuilder {
    /// Recent request rows included by default. Enough to see the failure
    /// and what led to it, small enough to stay far below the size cap.
    static let recentLogLimit = 25

    /// Client-side ceiling for the serialized diagnostics. Slightly under the
    /// router's 200 KB so a difference in JSON escaping between the two
    /// serializers can never turn a report into a rejected request.
    static let maxDiagnosticsBytes = OsaurusRouterSupportLimits.maxDiagnosticsBytes - 8 * 1024

    /// Build the report for the current app state. Context (session, agent,
    /// model) comes from the chat window the user was last in, and reaches
    /// the bundle only as fingerprints and the model id.
    @MainActor
    static func buildCurrent(generatedAt: Date = Date()) async -> SupportReport {
        let manager = ChatWindowManager.shared
        let session = manager.lastFocusedWindowId.flatMap { manager.windowState(id: $0) }?.session
        let agentId = session?.agentId
        let agent = agentId.flatMap { AgentManager.shared.agent(for: $0) }

        let bundle = await SupportDiagnosticsBundleBuilder.buildCurrent(
            generatedAt: generatedAt,
            sessionId: session?.sessionId?.uuidString,
            agentId: agentId,
            agentAddress: agent?.agentAddress,
            agentName: agent?.name,
            modelId: session?.selectedModel,
            recentLogLimit: recentLogLimit
        )
        return make(bundle: bundle, profile: MacProfile.current())
    }

    /// Pure assembly, for tests and already-snapshotted inputs.
    static func make(
        bundle: SupportDiagnosticsBundle,
        profile: MacProfile,
        maxDiagnosticsBytes: Int = SupportReportBuilder.maxDiagnosticsBytes
    ) -> SupportReport {
        let fitted = fittedDiagnostics(bundle, maxBytes: maxDiagnosticsBytes)
        return SupportReport(
            app: .init(
                version: bundle.app.version,
                build: bundle.app.build,
                osVersion: bundle.app.osVersion
            ),
            hardware: .init(
                model: profile.modelName,
                chip: profile.chip,
                memoryGB: profile.memoryGB > 0 ? profile.memoryGB : nil
            ),
            diagnostics: fitted?.value,
            diagnosticsBytes: fitted?.bytes ?? 0
        )
    }

    /// The bundle as a JSON value no larger than `maxBytes` once serialized.
    /// Oldest recent requests go first (the list is newest-first), then the
    /// full tool registry (the enabled-name lists stay). Nil when even the
    /// smallest form is too large.
    static func fittedDiagnostics(
        _ bundle: SupportDiagnosticsBundle,
        maxBytes: Int
    ) -> (value: JSONValue, bytes: Int)? {
        var candidate = bundle
        while true {
            if let encoded = encode(candidate), encoded.bytes <= maxBytes { return encoded }
            if !candidate.recentRequests.isEmpty {
                let keep = candidate.recentRequests.count / 2
                candidate = replacing(candidate, recentRequests: Array(candidate.recentRequests.prefix(keep)))
            } else if !candidate.tools.registered.isEmpty {
                candidate = replacing(candidate, registeredTools: [])
            } else {
                return nil
            }
        }
    }

    /// ISO 8601 dates and sorted keys, then lifted into a `JSONValue` so the
    /// preview and the signed request body share one representation.
    private static func encode(_ bundle: SupportDiagnosticsBundle) -> (value: JSONValue, bytes: Int)? {
        let encoder = JSONEncoder.osaurusCanonical(prettyPrinted: false)
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(bundle),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data),
            // Measure what will actually be sent: the re-serialized value.
            let sent = try? JSONEncoder.osaurusCanonical(prettyPrinted: false).encode(value)
        else { return nil }
        return (value, sent.count)
    }

    private static func replacing(
        _ bundle: SupportDiagnosticsBundle,
        recentRequests: [SupportDiagnosticsBundle.RequestSnapshot]
    ) -> SupportDiagnosticsBundle {
        SupportDiagnosticsBundle(
            schemaVersion: bundle.schemaVersion,
            generatedAt: bundle.generatedAt,
            app: bundle.app,
            context: bundle.context,
            tools: bundle.tools,
            recentRequests: recentRequests,
            privacy: bundle.privacy
        )
    }

    private static func replacing(
        _ bundle: SupportDiagnosticsBundle,
        registeredTools: [SupportDiagnosticsBundle.ToolRecord]
    ) -> SupportDiagnosticsBundle {
        SupportDiagnosticsBundle(
            schemaVersion: bundle.schemaVersion,
            generatedAt: bundle.generatedAt,
            app: bundle.app,
            context: bundle.context,
            tools: .init(
                registered: registeredTools,
                enabledNames: bundle.tools.enabledNames,
                dynamicNames: bundle.tools.dynamicNames,
                loadedNames: bundle.tools.loadedNames,
                initialAlwaysLoadedNames: bundle.tools.initialAlwaysLoadedNames,
                sessionFingerprint: bundle.tools.sessionFingerprint
            ),
            recentRequests: bundle.recentRequests,
            privacy: bundle.privacy
        )
    }
}
