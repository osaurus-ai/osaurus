import SwiftUI

/// Shared original connection status presentation. State and retry remain owned
/// by ChatView; local inspector displays can use the same view without connecting.
struct RemoteAgentConnectionStatusNotice: View {
    enum Phase { case connecting(String), failed(String) }
    let phase: Phase
    let baseTheme: any ThemeProtocol
    var retry: () -> Void = {}
    var body: some View {
        switch phase {
        case .connecting(let name):
            RemoteAgentNoticeRow(tone: baseTheme.status.info, baseTheme: baseTheme) {
                ProgressView().controlSize(.small)
                Text(String(format: L("Connecting to %@…"), name))
                    .textStyle(.caption, weight: 500)
                    .foregroundColor(baseTheme.assignedColor(NativeComponentInspectionStyle.key(40, "foreground"), fallback: baseTheme.text.primary))
            }
        case .failed(let message):
            RemoteAgentNoticeRow(tone: baseTheme.status.warning, baseTheme: baseTheme) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .glyphSize(12, weight: .semibold)
                    .foregroundColor(baseTheme.status.warning.foreground)
                Text(message)
                    .textStyle(.caption, weight: 500)
                    .foregroundColor(baseTheme.assignedColor(NativeComponentInspectionStyle.key(40, "foreground"), fallback: baseTheme.text.primary))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Button(action: retry) {
                    Text(L("Retry")).textStyle(.caption, weight: 600).foregroundColor(baseTheme.text.link)
                }.buttonStyle(.plain)
            }
        }
    }
}

struct RemoteAgentNoticeRow<Content: View>: View {
    let tone: ThemeStatusSet<Color>
    let baseTheme: any ThemeProtocol
    private let content: Content
    init(tone: ThemeStatusSet<Color>, baseTheme: any ThemeProtocol, @ViewBuilder content: () -> Content) {
        self.tone = tone; self.baseTheme = baseTheme; self.content = content()
    }
    var body: some View {
        let noticeTheme = baseTheme.catalogFamily(40, authoritative: true)
        HStack(spacing: noticeTheme.catalogLayoutMetric("component.library.40.elements.layout.remoteAgentNoticeRow.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(40, "gap", baseTheme.space.s8, noticeTheme))) { content }.catalogLayoutTarget("component.library.40.elements.layout.remoteAgentNoticeRow.body.horizontalGap")
            .padding(.horizontal, noticeTheme.catalogLayoutMetric("component.library.40.elements.layout.remoteAgentNoticeRow.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(40, "padding", baseTheme.space.s12, noticeTheme))).catalogLayoutTarget("component.library.40.elements.layout.remoteAgentNoticeRow.body.paddingX")
            .padding(.vertical, noticeTheme.catalogLayoutMetric("component.library.40.elements.layout.remoteAgentNoticeRow.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(40, "padding", baseTheme.space.s6, noticeTheme))).catalogLayoutTarget("component.library.40.elements.layout.remoteAgentNoticeRow.body.paddingY")
            .frame(minHeight: NativeComponentInspectionStyle.metric(40, "height", 0, noticeTheme))
            .componentInspectionSurface(40, background: tone.background, border: tone.border, radius: baseTheme.radius.large, width: baseTheme.stroke.default)
            .environment(\.theme, noticeTheme)
            .padding(.bottom, baseTheme.space.s8)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}
