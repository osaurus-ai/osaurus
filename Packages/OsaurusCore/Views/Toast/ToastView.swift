//
//  ToastView.swift
//  osaurus
//
//  Individual toast notification view with themed styling, icons,
//  avatar support, and smooth animations.
//

import SwiftUI

// MARK: - Toast View

/// A single toast notification card
struct ToastView: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(18, enabled: componentEnabled) }

    let toast: Toast
    let onDismiss: () -> Void
    let onAction: (() -> Void)?

    @State private var isHovering = false

    init(toast: Toast, onDismiss: @escaping () -> Void, onAction: (() -> Void)? = nil) {
        self.toast = toast
        self.onDismiss = onDismiss
        self.onAction = onAction
    }

    var body: some View {
        HStack(alignment: verticalAlignment, spacing: theme.catalogLayoutMetric("component.library.18.elements.layout.toastView.body.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: 12))) {
            leadingContent

            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.18.elements.layout.toastView.body.verticalGap", inheriting: theme.catalogMetric("gap", fallback: 8))) {
                HStack(alignment: .top, spacing: theme.catalogLayoutMetric("component.library.18.elements.layout.toastView.body.horizontalGap2", inheriting: theme.catalogMetric("gap", fallback: 8))) {
                    textContent
                    Spacer(minLength: 4)
                    dismissButton
                }.catalogLayoutTarget("component.library.18.elements.layout.toastView.body.horizontalGap2")

                if let actionTitle = toast.effectiveActionTitle, hasAction {
                    actionButton(title: actionTitle)
                }
            }.catalogLayoutTarget("component.library.18.elements.layout.toastView.body.verticalGap")
        }.catalogLayoutTarget("component.library.18.elements.layout.toastView.body.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.18.elements.layout.toastView.body.paddingX", inheriting: theme.catalogMetric("padding", fallback: 14))).catalogLayoutTarget("component.library.18.elements.layout.toastView.body.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.18.elements.layout.toastView.body.paddingY", inheriting: theme.catalogMetric("padding", fallback: 12))).catalogLayoutTarget("component.library.18.elements.layout.toastView.body.paddingY")
        #if OSAURUS_DESIGN_SYSTEM
        .frame(minHeight: theme.catalogMetric("height", fallback: 0))
        .assignedBaseChrome(18)
        #else
        .background(ToastBackground())
        .clipShape(RoundedRectangle(cornerRadius: ToastStyle.cornerRadius, style: .continuous))
        .overlay(ToastBorder(tone: tone, isHovering: isHovering))
        #endif
        .toastShadow(theme: theme, isHovering: isHovering)
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovering = hovering
            }
        }
        .frame(maxWidth: 400, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A title-only toast is a single short row, so center it against the icon.
    /// Toasts that add a message line or an action button grow taller, where
    /// top alignment keeps the icon beside the title row.
    private var verticalAlignment: VerticalAlignment {
        let hasMessage = toast.message?.isEmpty == false
        let hasActionButton = hasAction && toast.effectiveActionTitle != nil
        return (hasMessage || hasActionButton) ? .top : .center
    }

    // MARK: - Leading Content

    @ViewBuilder
    private var leadingContent: some View {
        if let avatarImage = toast.avatarImage {
            Image(nsImage: avatarImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .overlay(Circle().stroke(tone.border, lineWidth: theme.stroke.focus))
        } else {
            iconView
        }
    }

    @ViewBuilder
    private var iconView: some View {
        ZStack {
            Circle()
                .fill(tone.background)
                .frame(width: 28, height: 28)

            if toast.type == .loading {
                // A TimelineView-driven arc, not ProgressView: a scaled
                // CircularProgressViewStyle can render as a static circle in
                // the toast overlay panel (no spin), reading as a bare dot.
                #if OSAURUS_DESIGN_SYSTEM
                ProgressView().controlSize(.regular).assignedProgressIndicator(tintOverride: tone.foreground)
                #else
                ToastSpinnerIcon(color: tone.foreground, size: 16)
                #endif
            } else {
                Image(systemName: toast.type.iconName)
                    .glyphSize(14, weight: .semibold)
                    .foregroundColor(tone.foreground)
            }
        }
    }

    // MARK: - Text Content

    private var textContent: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.18.elements.layout.toastView.textContent.verticalGap", inheriting: theme.catalogMetric("gap", fallback: 3))) {
            Text(toast.title)
                #if OSAURUS_DESIGN_SYSTEM
                .assignedTypography("component.library.18.label", fallback: SettingsFont.rowTitle)
                #else
                .textStyle(.label, weight: 600)
                #endif
                .foregroundColor(theme.text.primary)
                .lineLimit(2)

            if let message = toast.message {
                Text(message)
                    #if OSAURUS_DESIGN_SYSTEM
                    .assignedTypography("component.library.18.caption", fallback: SettingsFont.rowDescription)
                    #else
                    .textStyle(.caption)
                    #endif
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(3)
            }

            if toast.type == .loading, let progress = toast.progress {
                #if OSAURUS_DESIGN_SYSTEM
                SettingsProgressBar(value: progress)
                    .accessibilityLabel(Text("Loading progress", bundle: .module))
                    .padding(.top, theme.catalogLayoutMetric("component.library.18.elements.layout.toastView.textContent.paddingY", inheriting: theme.catalogMetric("gap", fallback: 4))).catalogLayoutTarget("component.library.18.elements.layout.toastView.textContent.paddingY")
                #else
                ProgressView(value: progress)
                    .progressViewStyle(ToastProgressStyle(color: tone.foreground))
                    .frame(height: 4)
                    .padding(.top, 4)
                #endif
            }
        }.catalogLayoutTarget("component.library.18.elements.layout.toastView.textContent.verticalGap")
    }

    // MARK: - Buttons

    @ViewBuilder
    private func actionButton(title: String) -> some View {
        ToastActionButton(title: title) { onAction?() }
    }

    @ViewBuilder
    private var dismissButton: some View {
        if isHovering || toast.type != .loading {
            ToastDismissButton(isHovering: isHovering, action: onDismiss)
                .transition(.opacity)
        }
    }

    // MARK: - Helpers

    private var hasAction: Bool {
        toast.type == .action || toast.action != nil || toast.actionId != nil
    }

    private var tone: ThemeStatusSet<Color> {
        switch toast.type {
        case .success: return theme.status.success
        case .info: return theme.status.info
        case .warning: return theme.status.warning
        case .error: return theme.status.error
        case .action, .loading: return theme.status.info
        }
    }
}

// MARK: - Toast Spinner Icon

/// Loading indicator for `.loading` toasts: a smoothly spinning arc driven by
/// `TimelineView`, same approach as `AnimatedProgressComponents`' spinner.
struct ToastSpinnerIcon: View {
    @Environment(\.theme) private var theme
    let color: Color
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let progress = spinProgress(for: timeline.date)
            ToastSpinnerShape(progress: progress)
                .stroke(color, style: StrokeStyle(lineWidth: theme.stroke.focus, lineCap: .round))
                .frame(width: size, height: size)
        }
    }

    private func spinProgress(for date: Date) -> Double {
        let seconds = date.timeIntervalSinceReferenceDate
        return (seconds * 1.5).truncatingRemainder(dividingBy: 1.0)
    }
}

struct ToastSpinnerShape: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let startAngle = Angle(degrees: progress * 360 - 90)
        let endAngle = Angle(degrees: progress * 360 + 200)

        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        return path
    }
}

// MARK: - Toast Progress Style

private struct ToastProgressStyle: ProgressViewStyle {
    @Environment(\.theme) private var theme
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: theme.radius.small)
                    .fill(color.opacity(0.2))
                    .frame(height: 4)

                RoundedRectangle(cornerRadius: theme.radius.small)
                    .fill(color)
                    .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0), height: 4)
                    .animation(theme.motion.standard, value: configuration.fractionCompleted)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Preview

#if DEBUG
    struct ToastView_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 16) {
                ToastView(
                    toast: Toast(
                        type: .success,
                        title: "Task completed",
                        message: "Your file has been processed successfully"
                    ),
                    onDismiss: {}
                )

                ToastView(
                    toast: Toast(type: .error, title: "Connection failed", message: "Unable to connect to the server"),
                    onDismiss: {}
                )

                ToastView(
                    toast: Toast(type: .loading, title: "Processing...", message: "Please wait", progress: 0.6),
                    onDismiss: {}
                )

                ToastView(
                    toast: Toast(
                        type: .action,
                        title: "Update available",
                        message: "A new version is ready to install",
                        actionTitle: "Install",
                        actionId: "install"
                    ),
                    onDismiss: {},
                    onAction: {}
                )
            }
            .padding()
            .frame(width: 420)
            .background(CustomizableTheme.dark().surface.canvas)
        }
    }
#endif
