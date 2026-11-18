#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

struct InspectorCodeBlockVerification: View {
    @Environment(\.inspectorVerificationWidth) private var width
    @State private var streaming = false
    @State private var height: CGFloat = 180
    @State private var longSample = false
    @State private var plainSample = false
    private var language: String { plainSample ? "inspector-plain-text" : "swift" }
    private let shortCode = "let design = \"Connected to Osaurus\"\n// Local sample; no code is executed.\nprint(design)"
    private var code: String {
        if plainSample { return (1...40).map { "Local plain fallback line \($0): " + String(repeating: "sample ", count: 10) }.joined(separator: "\n") }
        return longSample ? shortCode + "\n" + (1...30).map { "// Local line \($0): " + String(repeating: "long sample ", count: 12) }.joined(separator: "\n") : shortCode }
    var body: some View {
        SettingsSection(title: "Chat · code fences", layout: .plain, verbatimTitle: true) {
            Text("Native code block inside an agent reply. Copy and horizontal scrolling are the actual app controls.").font(SettingsFont.caption)
            Toggle("Code is streaming", isOn: $streaming)
            Toggle("Long code with horizontal overflow", isOn: $longSample)
            Toggle("Unsupported language · plain-text fallback", isOn: $plainSample)
            InspectorNativeCodeBlock(code: code, language: language, streaming: streaming, height: $height)
                .frame(width: width, height: height)
            Text(verbatim: "Plugin editor · SwiftUI code block").font(SettingsFont.rowTitle)
            CodeBlockView(code: code, language: language, baseWidth: width).frame(width: width)
            Text(verbatim: "The existing renderers and Copy actions. This sample is never executed.").font(SettingsFont.caption)
        }
    }
}
private struct InspectorNativeCodeBlock: NSViewRepresentable {
    @Environment(\.inspectorVerificationWidth) private var width
    @Environment(\.theme) private var theme
    let code: String
    let language: String
    let streaming: Bool
    @Binding var height: CGFloat
    func makeNSView(context: Context) -> NativeCodeBlockView { NativeCodeBlockView() }
    func updateNSView(_ view: NativeCodeBlockView, context: Context) {
        defer { view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection) }
        view.onHeightChanged = { [weak view] in
            guard let view else { return }
            let measured = view.measureHeightForOuterWidth(width)
            if abs(measured - height) > 0.5 { DispatchQueue.main.async { height = measured } }
        }
        view.configure(code: code, language: language, width: width, theme: theme, isStreaming: streaming)
    }
}
#endif
