#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

struct InspectorThinkingVerification: View {
    @Environment(\.inspectorVerificationWidth) private var width
    @State private var expanded = false
    @State private var streaming = false
    @State private var finishing = false
    @State private var height: CGFloat = 70
    @Environment(\.theme) private var theme
    var body: some View {
        SettingsSection(title: "Chat · reasoning and generation", layout: .plain, verbatimTitle: true) {
            Text("Reasoning appears above the reply. Expand or collapse its actual disclosure below.").font(SettingsFont.caption)
            Toggle("Reasoning is streaming", isOn: $streaming)
            InspectorNativeThinking(expanded: $expanded, streaming: streaming, height: $height)
                .frame(width: width, height: height)
            Toggle("Generation is finishing", isOn: $finishing)
            InspectorNativeGeneration(finishing: finishing)
                .frame(width: width, height: ThinkingInspectionStyle.statusHeight(theme))
            Text(verbatim: "Generation appears while waiting for the agent and during finalization. Preview state only; no model request is made.").font(SettingsFont.caption)
        }
    }
}
private struct InspectorNativeThinking: NSViewRepresentable {
    @Environment(\.inspectorVerificationWidth) private var width
    @Environment(\.theme) private var theme
    @Binding var expanded: Bool
    let streaming: Bool
    @Binding var height: CGFloat
    func makeNSView(context: Context) -> NativeThinkingView { NativeThinkingView() }
    func updateNSView(_ view: NativeThinkingView, context: Context) {
        defer { view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection) }
        view.configure(thinking: "Compare the available options and **choose a small next step**.\n\n- Review the evidence\n- Check the tradeoffs", thinkingLength: nil, width: width, isStreaming: streaming, isExpanded: expanded, duration: streaming ? nil : 12, theme: theme, blockId: "inspector-native-thinking-33", onToggle: { expanded.toggle() }, onHeightChanged: { [weak view] in
            guard let view else { return }
            let measured = view.measuredHeight()
            if abs(measured - height) > 0.5 { DispatchQueue.main.async { height = measured } }
        })
    }
}
private struct InspectorNativeGeneration: NSViewRepresentable {
    @Environment(\.inspectorVerificationWidth) private var width
    @Environment(\.theme) private var theme
    let finishing: Bool
    func makeNSView(context: Context) -> NativeTypingIndicatorView { NativeTypingIndicatorView() }
    func updateNSView(_ view: NativeTypingIndicatorView, context: Context) {
        defer { view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection) }
        view.configure(theme: theme, phase: finishing ? .finishing : .generating)
    }
}
#endif
