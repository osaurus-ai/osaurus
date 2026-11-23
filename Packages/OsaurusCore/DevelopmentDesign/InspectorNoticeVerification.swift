#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// Original notices with local presentation state. No retry, host, connection,
/// account, or model request is started by this display route.
struct InspectorNoticeVerification: View {
    private static let localID = UUID(uuidString: "ABC00000-0000-4000-8000-000000000040")!
    @State private var selected = "None"
    @State private var expandedSummary = false
    @State private var stopped = false
    @Environment(\.theme) private var theme
    var body: some View {
        SettingsSection(title: "Chat · notices and conversation markers", layout: .plain, verbatimTitle: true) {
            Text("Connection to a remote agent").font(.headline)
            RemoteAgentConnectionStatusNotice(phase: .connecting("Local remote agent"), baseTheme: theme)
            RemoteAgentConnectionStatusNotice(phase: .failed("Local connection error display. No connection was attempted."), baseTheme: theme, retry: { selected = "Local Retry callback" })
            Text("An agent is running on your behalf").font(.headline)
            HostedRunNotice(sessionId: nil, callerName: "Local caller", agentName: "Local agent", isWorkspace: true, inspectionStep: stopped ? nil : "Writing…", inspectionStop: { stopped = true; selected = "Local Stop callback" })
            Text("Compacted conversation · expand for the summary").font(.headline)
            InspectorCompactionMarkerDisplay(expanded: $expandedSummary)
            Text("Conversation has unsaved changes").font(.headline)
            ChatPersistenceNotice(sessionId: Self.localID)
                .allowsHitTesting(false)
            Text("Conversation started by an agent, workspace or paired phone").font(.headline)
            HostedRunNotice(sessionId: nil, callerName: "Local caller", agentName: "Local agent", isWorkspace: false)
            HostedRunNotice(sessionId: nil, callerName: "Local teammate", agentName: "Local shared agent", isWorkspace: true)
            HostedRunNotice(sessionId: nil, callerName: nil, agentName: "Local agent", isWorkspace: false, isFromPairedPhone: true)
            Text("Charged reply with no visible text").font(.headline)
            InspectorEmptyReplyNotice().frame(height: NativeEmptyResponseNoticeView.inspectionHeight(theme))
            Text("Follow-up suggestions below the reply").font(.headline)
            FollowUpSuggestionsBar(suggestions: ["Review the next local sample", "A long local follow-up suggestion wraps in the existing row while keeping its original action and text layout."], animate: false) { selected = $0 }
            Text(verbatim: "Actual Chat notices. Retry, Stop and follow-up actions stay inside the preview; no connection, hosted run or model request is started.")
                .font(SettingsFont.caption)
        }
        .onAppear { ChatPersistenceStatus.shared.unsaved.insert(Self.localID) }
        .onDisappear { ChatPersistenceStatus.shared.unsaved.remove(Self.localID) }
    }
}

private struct InspectorEmptyReplyNotice: NSViewRepresentable {
    @Environment(\.theme) private var theme
    func makeNSView(context: Context) -> NativeEmptyResponseNoticeView { NativeEmptyResponseNoticeView() }
    func updateNSView(_ view: NativeEmptyResponseNoticeView, context: Context) {
        view.configure(turnId: UUID(uuidString: "ABC00000-0000-4000-8000-000000000040")!, outputTokens: 0, costMicro: "1200", theme: theme, onRetry: { _ in })
        view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection)
    }
}

/// Production native marker and nested native markdown, without a compaction run.
private struct InspectorCompactionMarkerDisplay: NSViewRepresentable {
    @Binding var expanded: Bool
    @Environment(\.theme) private var theme
    func makeNSView(context: Context) -> NativeCompactionMarkerView { NativeCompactionMarkerView() }
    func updateNSView(_ view: NativeCompactionMarkerView, context: Context) {
        defer { view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection) }; configure(view, width: max(300, view.bounds.width)) }
    private func configure(_ view: NativeCompactionMarkerView, width: CGFloat) {
        view.configure(savedTokens: 2400, modelName: "local display", summaryText: "## Local summary\n\nThis is **display-only** summary text with `inline code`.\n\n- Original conversation retained.\n- No compaction request was made.", width: width, isExpanded: expanded, theme: theme, blockId: "inspector-local-summary", onToggle: { expanded.toggle() }, onHeightChanged: {})
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeCompactionMarkerView, context: Context) -> CGSize? {
        let width = proposal.width ?? 760
        configure(nsView, width: width)
        return CGSize(width: width, height: nsView.measuredHeight())
    }
}
#endif
