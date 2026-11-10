import SwiftUI

struct ChatPersistenceNotice: View {
    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(40, authoritative: true) }
    @ObservedObject private var status = ChatPersistenceStatus.shared
    let sessionId: UUID?

    var body: some View {
        if let sessionId, status.unsaved.contains(sessionId) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.40.elements.layout.chatPersistenceNotice.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(40, "gap", 8, theme))) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                Text("History isn't saved yet. Retrying automatically; keep Osaurus open.", bundle: .module)
                    .componentInspectionText(40, role: .body, fallback: .micro, theme: theme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: { ChatSessionStore.retryUnsaved() }) { Text("Retry", bundle: .module) }
                    .assignedSettingsButtonStyle(.secondary, size: .compact)
            }.catalogLayoutTarget("component.library.40.elements.layout.chatPersistenceNotice.body.horizontalGap")
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.40.elements.layout.chatPersistenceNotice.body.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(40, "padding", 10, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.40.elements.layout.chatPersistenceNotice.body.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(40, "padding", 10, theme))).catalogLayoutTarget("component.library.40.elements.layout.chatPersistenceNotice.body.padding.horizontal").catalogLayoutTarget("component.library.40.elements.layout.chatPersistenceNotice.body.padding.vertical")
            .foregroundStyle(theme.text.primary)
            .frame(minHeight: NativeComponentInspectionStyle.metric(40, "height", 0, theme))
            #if OSAURUS_DESIGN_SYSTEM
            .assignedBaseChrome(40, fallback: theme.isDark ? nil : .status(.urgentWarning))
            #else
            .componentInspectionSurface(40, background: theme.status[.urgentWarning].background, radius: theme.radius.medium)
            #endif
            .environment(\.theme, theme)
            .accessibilityElement(children: .contain)
        }
    }
}
