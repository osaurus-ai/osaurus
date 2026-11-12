import SwiftUI

struct ChatPersistenceNotice: View {
    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(40) }
    @ObservedObject private var status = ChatPersistenceStatus.shared
    let sessionId: UUID?

    var body: some View {
        if let sessionId, status.unsaved.contains(sessionId) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.40.elements.layout.chatPersistenceNotice.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(40, "gap", theme.space.s8, theme))) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                Text("History isn't saved yet. Retrying automatically; keep Osaurus open.", bundle: .module)
                    .componentInspectionText(40, role: .body, fallback: .micro, theme: theme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: { ChatSessionStore.retryUnsaved() }) { Text("Retry", bundle: .module) }
                    .assignedSettingsButtonStyle(.secondary, size: .compact)
            }.catalogLayoutTarget("component.library.40.elements.layout.chatPersistenceNotice.body.horizontalGap")
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.40.elements.layout.chatPersistenceNotice.body.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(40, "padding", theme.space.s10, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.40.elements.layout.chatPersistenceNotice.body.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(40, "padding", theme.space.s10, theme))).catalogLayoutTarget("component.library.40.elements.layout.chatPersistenceNotice.body.padding.horizontal").catalogLayoutTarget("component.library.40.elements.layout.chatPersistenceNotice.body.padding.vertical")
            .foregroundStyle(theme.text.primary)
            .frame(minHeight: NativeComponentInspectionStyle.metric(40, "height", 0, theme))
            .assignedBaseChrome(40, fallback: theme.isDark ? nil : .status(.urgentWarning))
            .environment(\.theme, theme)
            .accessibilityElement(children: .contain)
        }
    }
}
