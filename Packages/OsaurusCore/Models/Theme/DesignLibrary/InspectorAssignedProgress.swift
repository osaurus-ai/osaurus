#if OSAURUS_DESIGN_SYSTEM
import SwiftUI
import AppKit
import QuartzCore

/// Local verification override; never changes the Mac's accessibility settings
/// or the saved design. The real accessibility value remains authoritative.
private struct InspectorReducedMotionKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var inspectorForceReducedMotion: Bool {
        get { self[InspectorReducedMotionKey.self] }
        set { self[InspectorReducedMotionKey.self] = newValue }
    }
}

/// Reuses the app's loading glyph and the already-connected determinate bar.
/// Explicit parent-owned loading glyphs (buttons and empty states) stay on
/// their existing assignments; this styles shared standalone indicators.
struct InspectorAssignedProgressStyle: ProgressViewStyle {
    var tintOverride: Color? = nil
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.inspectorForceReducedMotion) private var forceReducedMotion

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        Group {
            if let fraction = configuration.fractionCompleted {
                VStack(alignment: .leading, spacing: 0) {
                    label(configuration)
                        .padding(.bottom, theme.catalogLayoutMetric("component.library.12.elements.layout.progressLabelGap", inheriting: theme.assignedMetric("component.library.12.gap", fallback: 8)))
                        .catalogLayoutTarget("component.library.12.elements.layout.progressLabelGap")
                    SettingsProgressBar(value: fraction)
                    caption(configuration)
                        .padding(.top, theme.catalogLayoutMetric("component.library.12.elements.layout.progressCaptionGap", inheriting: theme.assignedMetric("component.library.12.gap", fallback: 8)))
                        .catalogLayoutTarget("component.library.12.elements.layout.progressCaptionGap")
                }
            } else {
                HStack(spacing: theme.catalogLayoutMetric("component.library.12.elements.layout.spinnerContentGap", inheriting: theme.assignedMetric("component.library.12.gap", fallback: 8))) {
                    spinner
                    label(configuration)
                    caption(configuration)
                }.catalogLayoutTarget("component.library.12.elements.layout.spinnerContentGap")
            }
        }
        .accessibilityRepresentation {
            // Match the existing empty-state loading glyph: animation remains
            // visual, while accessibility sees a stable native progress view.
            ProgressView(value: configuration.fractionCompleted.map { $0.isNaN ? 0 : min(max($0, 0), 1) }, total: 1) {
                label(configuration)
            } currentValueLabel: {
                caption(configuration)
            }
            .progressViewStyle(CircularProgressViewStyle())
        }
    }

    private var side: CGFloat {
        switch controlSize {
        case .mini: 12
        case .small, .regular: 16
        case .large: 32
        case .extraLarge: 48
        @unknown default: 16
        }
    }
    @ViewBuilder private var spinner: some View {
        let color = tintOverride ?? theme.assignedColor("component.library.12." + (enabled ? "accent" : "disabledForeground"), fallback: theme.text.secondary)
        if reduceMotion || forceReducedMotion {
            ToastSpinnerShape(progress: 0)
                .stroke(color, style: StrokeStyle(lineWidth: theme.stroke.focus, lineCap: .round))
                .frame(width: side, height: side)
        } else {
            InspectorLayerSpinner(color: color, lineWidth: theme.stroke.focus)
                .frame(width: side, height: side)
        }
    }
    @ViewBuilder private func label(_ configuration: Configuration) -> some View {
        if let label = configuration.label {
            label.assignedTypography("component.library.12.text", fallback: SettingsFont.body)
                .foregroundStyle(theme.assignedColor("component.library.12." + (enabled ? "foreground" : "disabledForeground"), fallback: theme.text.primary))
        }
    }
    @ViewBuilder private func caption(_ configuration: Configuration) -> some View {
        if let label = configuration.currentValueLabel {
            label.assignedTypography("component.library.12.caption", fallback: SettingsFont.caption)
                .foregroundStyle(theme.assignedColor("component.library.12." + (enabled ? "secondary" : "disabledForeground"), fallback: theme.text.secondary))
        }
    }
}

/// The same 290-degree arc and 1.5 rotations/second as ToastSpinnerIcon.
/// Animate the layer instead of invalidating SwiftUI layout every frame: the
/// inspector measures multiple Light/Dark specimens inside ViewThatFits.
private struct InspectorLayerSpinner: NSViewRepresentable {
    let color: Color
    let lineWidth: CGFloat

    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }
    func updateNSView(_ view: SpinnerView, context: Context) {
        view.arc.strokeColor = NSColor(color).cgColor
        view.arc.lineWidth = lineWidth
        view.needsLayout = true
    }

    final class SpinnerView: NSView {
        let arc = CAShapeLayer()
        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            arc.fillColor = nil
            arc.lineCap = .round
            layer?.addSublayer(arc)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arc.frame = bounds
            let path = CGMutablePath()
            path.addArc(
                center: CGPoint(x: bounds.midX, y: bounds.midY),
                radius: min(bounds.width, bounds.height) / 2,
                startAngle: -.pi / 2,
                endAngle: .pi * 200 / 180,
                clockwise: false
            )
            arc.path = path
            CATransaction.commit()
            if arc.animation(forKey: "spin") == nil, window != nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = Double.pi * 2
                spin.duration = 2.0 / 3.0
                spin.repeatCount = .infinity
                arc.add(spin, forKey: "spin")
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { arc.removeAnimation(forKey: "spin") }
            else { needsLayout = true }
        }
    }
}
#endif
