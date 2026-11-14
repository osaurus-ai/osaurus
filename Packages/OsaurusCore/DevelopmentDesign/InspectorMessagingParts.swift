#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI
import AppKit

/// The same attachment controls used by the composer and sent-message cells.
struct InspectorAttachmentConfigurations: View {
    @State private var variant = "Composer · document"
    private let variants = ["Composer · document", "Composer · pasted text", "Composer · image", "Composer · audio", "Composer · video", "Sent message · document", "Sent message · image", "Sent message · attachments only"]
    private static let samples = InspectorAttachmentSamples.items
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Used in", selection: $variant) { ForEach(variants, id: \.self) { Text($0).tag($0) } }
            if variant.hasPrefix("Sent message") {
                InspectorMessageConfigurations(isAssistant: false)
                    .environment(\.inspectorMessageConfiguration, .constant(variant.hasSuffix("document") ? "With a file" : variant.hasSuffix("image") ? "With an image" : "Attachments without text"))
            } else if variant.hasSuffix("image"), let data = Self.samples.first(where: \.isImage)?.imageData {
                CachedImageThumbnail(imageData: data, size: 96, onRemove: {}, onTap: {})
                    .catalogPreviewTarget(["elements.image.radius", "elements.image.border", "elements.image.borderWidth", "elements.image.height", "elements.image.padding", "elements.image.background"].map { CatalogElementAssignments.routed("component.library.24." + $0, mappings: DesignThemeOverlay.shared.current()?.document.mappings ?? [:]) }, "Composer image attachment")
            } else {
                let attachment: Attachment = variant.hasSuffix("pasted text") ? .pastedContent("Meeting notes\nReview the proposal\nConfirm the next step") : variant.hasSuffix("audio") ? .audio(Data(repeating: 0, count: 4096), format: "wav", filename: "Recording.wav") : variant.hasSuffix("video") ? .video(Data(repeating: 0, count: 8192), filename: "Recording.mp4") : Self.samples.first(where: \.isDocument)!
                DocumentChip(attachment: attachment, onRemove: {}, onTap: {}, onEdit: variant.hasSuffix("pasted text") ? {} : nil, onInline: variant.hasSuffix("pasted text") ? {} : nil)
                    .catalogPreviewTarget(["background", "border", "borderWidth", "radius", "padding", "gap", "height", "hover", "foreground", "secondary", "accent"].map { CatalogElementAssignments.routed("component.library.24." + $0, mappings: DesignThemeOverlay.shared.current()?.document.mappings ?? [:]) }, "Composer document attachment")
            }
            Text("Composer attachments have Remove; pasted text also has Edit and Insert. Sent messages use the native attachment layout above the message. Preview file actions stay local.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct InspectorArtifactConfigurations: View {
    @State private var variant = "Text document"
    static let variants = ["Text document", "Image", "PDF", "Audio", "Web page", "Folder", "Video · unavailable preview", "Unavailable image", "No local file", "Without description"]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Artifact format", selection: $variant) { ForEach(Self.variants, id: \.self) { Text($0).tag($0) } }
            CatalogNativeArtifactPreview(artifact: Self.artifact(variant)).id(variant)
            Text("Chat · a file shared by the agent. The app chooses the preview and Finder/Browser actions from its file type and available local path; these are the actual card views.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private static let folder: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Osaurus-Inspector-Messaging")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let data = InspectorAttachmentSamples.items.first(where: \.isImage)?.imageData,
           let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url.appendingPathComponent("Reference.png"))
        }
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let label = NSTextField(labelWithString: "Project summary"); label.frame = NSRect(x: 24, y: 140, width: 250, height: 24); page.addSubview(label)
        try? page.dataWithPDF(inside: page.bounds).write(to: url.appendingPathComponent("Summary.pdf"))
        try? Data("<html><body><h1>Project summary</h1></body></html>".utf8).write(to: url.appendingPathComponent("Summary.html"))
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("Project"), withIntermediateDirectories: true)
        // A short silent WAV supplies actual audio metadata without playback.
        var audio = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ value: T) { var n = value.littleEndian; withUnsafeBytes(of: &n) { audio.append(contentsOf: $0) } }
        number(UInt32(8036)); audio.append(Data("WAVEfmt ".utf8)); number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(8000)); number(UInt32(16000)); number(UInt16(2)); number(UInt16(16)); audio.append(Data("data".utf8)); number(UInt32(8000)); audio.append(Data(repeating: 0, count: 8000))
        try? audio.write(to: url.appendingPathComponent("Recording.wav"))
        return url
    }()
    static func artifact(_ variant: String) -> SharedArtifact {
        let names = ["Image": "Reference.png", "PDF": "Summary.pdf", "Audio": "Recording.wav", "Web page": "Summary.html", "Folder": "Project", "Video · unavailable preview": "Unavailable.mp4", "Unavailable image": "Unavailable.png"]
        let name = names[variant] ?? "Summary.txt"
        let mime = variant == "Folder" ? "inode/directory" : SharedArtifact.mimeType(from: name)
        return SharedArtifact(id: "inspector-messaging-" + variant, contextId: "inspector", contextType: .chat, filename: name, mimeType: mime, fileSize: 2048,
            hostPath: variant == "No local file" ? "" : folder.appendingPathComponent(name).path,
            isDirectory: variant == "Folder", content: mime.hasPrefix("text/plain") ? "Project summary\nThe proposal is ready for review.\nNext step: confirm the plan." : nil,
            description: variant == "Without description" ? nil : "Project reference shared by the agent")
    }
}

struct InspectorTerminalChartConfigurations: View {
    @State private var variant = "Terminal output"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Used in Chat", selection: $variant) { Text("Terminal output").tag("Terminal output"); Text("Chart in an agent reply").tag("Chart in an agent reply") }
            if variant == "Terminal output" { InspectorTerminalLiveVerification() }
            else { InspectorNativeChartPreview() }
        }
    }
}
private struct InspectorNativeChartPreview: NSViewRepresentable {
    @Environment(\.theme) private var theme
    func makeNSView(context: Context) -> NativeChartView { NativeChartView() }
    func updateNSView(_ view: NativeChartView, context: Context) {
        view.configure(spec: ChartSpec(chartType: "column", title: "Comparison", categories: ["One", "Two", "Three"], series: [ChartSeries(name: "First", data: [2,4,3]), ChartSeries(name: "Second", data: [3,2,5])], dataLabelsEnabled: true, note: "Agent reply · chart block. The chart's own type picker offers the formats supported by the app."), theme: theme, animateInitialDraw: false)
        view.catalogAssignmentTarget(["background", "foreground", "secondary", "border", "borderWidth", "radius", "padding", "gap", "height"].map { "component.library.39." + $0 }, name: "Chart card", theme: theme)
        view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeChartView, context: Context) -> CGSize? { CGSize(width: proposal.width ?? 600, height: nsView.measuredCardHeight()) }
}

struct InspectorRichTextConfigurations: View {
    @State private var renderer = "Chat · agent reply"
    @State private var streaming = false
    private let sample = "## Recommendation\nA paragraph with **emphasis**, *italic*, a [link](https://example.com), and `inline code`.\n\n> A quoted observation.\n\n- First result\n- Second result\n\n| Option | Result |\n| --- | --- |\n| Shared controls | Consistent styles |\n\nInline math: $x^2 + y^2 = r^2$."
    @Environment(\.inspectorVerificationWidth) private var width
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Used in", selection: $renderer) { Text("Chat · agent reply").tag("Chat · agent reply"); Text("Plugin details · description").tag("Plugin details · description") }
            if renderer == "Chat · agent reply" {
                Toggle("Reply is streaming", isOn: $streaming)
                InspectorNativeRichText(text: sample, streaming: streaming)
            } else { MarkdownMessageView(text: sample, baseWidth: width).frame(width: width) }
            Text("Actual Markdown renderers: headings, emphasis, links, lists, quotes, tables, inline code and math. Fenced code and charts have their own messaging pages.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
private struct InspectorNativeRichText: NSViewRepresentable {
    let text: String
    let streaming: Bool
    @Environment(\.theme) private var theme
    @Environment(\.inspectorVerificationWidth) private var width
    func makeNSView(context: Context) -> NativeMarkdownView { NativeMarkdownView() }
    func updateNSView(_ view: NativeMarkdownView, context: Context) {
        view.configure(text: text, width: width, theme: theme, cacheKey: "inspector-rich-content", isStreaming: streaming)
        view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeMarkdownView, context: Context) -> CGSize? { CGSize(width: width, height: nsView.measuredHeight(for: width)) }
}
#endif
