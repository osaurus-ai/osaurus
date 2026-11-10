//
//  WorkflowShareCardView.swift
//  osaurus
//
//  The image a person posts when their workflow goes live: 1200×630 in
//  the registry's own look (the same dark card its pages use for link
//  previews), with the name, the summary, one line of facts, the author's
//  handle, a QR code of the page, and the page address. Rendered once at
//  2× so the preview in the sheet and the saved file are the same pixels.
//

import AppKit
import SwiftUI

struct WorkflowShareCardContent: Equatable {
    let name: String
    let summary: String
    /// "5 steps · Runs on this Mac"
    let facts: String
    /// "@tpae" or a short address.
    let handle: String
    let url: URL

    /// The address without scheme, for the footer.
    var displayURL: String {
        var s = url.absoluteString
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// The card at its natural size, 1200×630.
struct WorkflowShareCardView: View {
    @Environment(\.theme) private var theme
    static let size = CGSize(width: 1200, height: 630)

    let content: WorkflowShareCardContent

    private let ink = Color(red: 0x11 / 255, green: 0x10 / 255, blue: 0x0F / 255)
    private let paper = Color(red: 0xFD / 255, green: 0xFC / 255, blue: 0xFA / 255)
    private let muted = Color(red: 0xE0 / 255, green: 0xE0 / 255, blue: 0xD6 / 255)
    private let lime = Color(red: 0xC0 / 255, green: 0xEC / 255, blue: 0x51 / 255)

    var body: some View {
        ZStack(alignment: .topLeading) {
            ink
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "Osaurus Workflow")
                    .font(SettingsFont.pageTitle)
                    .foregroundColor(ink)
                    .padding(.horizontal, theme.space.s16)
                    .padding(.vertical, theme.space.s6)
                    .background(Capsule().fill(lime))

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 22) {
                    Text(verbatim: content.name)
                        .font(.system(size: content.name.count > 36 ? 60 : 76, weight: .bold))
                        .tracking(-2)
                        .foregroundColor(paper)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .fixedSize(horizontal: false, vertical: true)
                    if !content.summary.isEmpty {
                        Text(verbatim: content.summary)
                            .font(SettingsFont.pageTitle)
                            .foregroundColor(muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !content.facts.isEmpty {
                        Text(verbatim: content.facts)
                            .font(SettingsFont.pageTitle)
                            .foregroundColor(muted.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)

                Spacer(minLength: 0)

                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    Text(verbatim: content.handle)
                        .font(SettingsFont.pageTitle)
                        .foregroundColor(lime)
                    Spacer()
                    Text(verbatim: content.displayURL)
                        .font(SettingsFont.mono)
                        .foregroundColor(muted.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 560, alignment: .trailing)
                }
            }
            .padding(EdgeInsets(top: 72, leading: 80, bottom: 72, trailing: 80))

            if let qr = ShareQRCardView.render(content.url.absoluteString) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(theme.space.s12)
                    .frame(width: 184, height: 184)
                    .background(RoundedRectangle(cornerRadius: theme.radius.xlarge).fill(.white))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, theme.space.s64)
                    .padding(.trailing, theme.space.s64)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.none))
        .accessibilityLabel(Text(verbatim: L("Share card for \(content.name)")))
    }
}

@MainActor
enum WorkflowShareCard {
    /// Renders the card at `scale`× (2× by default: 2400×1260).
    static func render(_ content: WorkflowShareCardContent, scale: CGFloat = 2) -> NSImage? {
        let renderer = ImageRenderer(content: WorkflowShareCardView(content: content))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(WorkflowShareCardView.size)
        guard let cgImage = renderer.cgImage else { return nil }
        // The renderer's pixel size follows the host's backing scale on
        // headless machines; drawing into a fixed bitmap keeps the PNG at
        // exactly `scale`× everywhere.
        let size = WorkflowShareCardView.size
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        context.imageInterpolation = .high
        context.cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func copy(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let png = png(image) {
            pasteboard.setData(png, forType: .png)
        } else {
            pasteboard.writeObjects([image])
        }
    }

    /// Asks where to save the PNG; nil when the user cancels.
    static func save(_ image: NSImage, suggestedName: String) -> URL? {
        guard let png = png(image) else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            _ = ToastManager.shared.error(L("Save Image"), message: error.localizedDescription)
            return nil
        }
    }
}

/// Presents the system share sheet (Messages, Mail, AirDrop, Notes, …)
/// anchored to the view it decorates, the moment `isPresented` turns on.
struct SharingServicePresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let items: [Any]

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        guard isPresented, !items.isEmpty else { return }
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: items)
            picker.delegate = context.coordinator
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            isPresented = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate {}
}

/// Copy Image · Save Image… · Share…, under a card preview.
struct ShareCardActions: View {
    @Environment(\.theme) private var theme
    let image: NSImage?
    let pageURL: URL
    let suggestedName: String
    /// Save Image… is for the live moment; the dashboard keeps to copy and share.
    var includesSave = true

    @State private var copied = false
    @State private var presentingShare = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                guard let image else { return }
                WorkflowShareCard.copy(image)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Label {
                    Text(copied ? L("Copied") : L("Copy Image"))
                } icon: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
            }
            .assignedSettingsButtonStyle(.secondary, size: .compact)
            .disabled(image == nil)
            .settingsLandingAnchor("workflows.shareCard")
            if includesSave {
                Button {
                    guard let image else { return }
                    if let url = WorkflowShareCard.save(image, suggestedName: suggestedName) {
                        ToastManager.shared.action(
                            L("Saved the share card"), message: nil, action: .revealInFinder(url),
                            buttonTitle: L("Show in Finder"))
                    }
                } label: {
                    Label { Text("Save Image…", bundle: .module) } icon: { Image(systemName: "square.and.arrow.down") }
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
                .disabled(image == nil)
            }
            Button {
                presentingShare = true
            } label: {
                Label { Text("Share…", bundle: .module) } icon: { Image(systemName: "square.and.arrow.up") }
            }
            .assignedSettingsButtonStyle(.secondary, size: .compact)
            .background(
                SharingServicePresenter(isPresented: $presentingShare, items: [pageURL] + (image.map { [$0] } ?? []))
            )
        }
    }
}
