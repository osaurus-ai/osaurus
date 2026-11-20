//
//  HelpImageAttachments.swift
//  osaurus
//
//  Images on Help reports: adding them (Add Image, drop, paste) to a new
//  report or a reply, the thumbnails while writing, the thumbnails on sent
//  messages, and the full-size viewer. Encoding goes through
//  `SupportImageEncoder` off the main thread, so a large photo never stalls
//  the page.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Intake

/// Where an image came from before it is encoded.
enum HelpImageSource: Sendable {
    case data(Data)
    case file(URL)
}

@MainActor
enum HelpImageIntake {
    /// Encode `sources` and append them to `images`, stopping at `limit`.
    /// Returns what to tell the user when something was left out.
    static func add(
        _ sources: [HelpImageSource],
        to images: Binding<[SupportImageAttachment]>,
        limit: Int
    ) async -> String? {
        let room = max(0, limit - images.wrappedValue.count)
        guard room > 0 else { return limitMessage(limit) }
        let accepted = Array(sources.prefix(room))
        let results = await Task.detached(priority: .userInitiated) {
            accepted.map { source -> Result<SupportImageAttachment, SupportImageEncoder.Failure> in
                do {
                    switch source {
                    case .data(let data): return .success(try SupportImageEncoder.encode(data: data))
                    case .file(let url): return .success(try SupportImageEncoder.encode(fileURL: url))
                    }
                } catch let failure as SupportImageEncoder.Failure {
                    return .failure(failure)
                } catch {
                    return .failure(.unreadable)
                }
            }
        }.value
        var message: String?
        for result in results {
            switch result {
            case .success(let image):
                guard images.wrappedValue.count < limit else { break }
                images.wrappedValue.append(image)
            case .failure(let failure):
                message = SupportImageEncoder.userMessage(for: failure)
            }
        }
        if sources.count > accepted.count { message = limitMessage(limit) }
        return message
    }

    static func limitMessage(_ limit: Int) -> String {
        String(format: L("You can attach up to %lld images here."), limit)
    }

    /// The open panel for Add Image.
    static func pickFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SupportImageEncoder.pickerTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L("Choose screenshots or photos to attach")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    /// Images in a drop, file URLs or raw image data.
    static func sources(from providers: [NSItemProvider]) async -> [HelpImageSource] {
        var sources: [HelpImageSource] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                let url = await loadFileURL(provider)
            {
                sources.append(.file(url))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                let data = await loadImageData(provider)
            {
                sources.append(.data(data))
            }
        }
        return sources
    }

    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    private static func loadImageData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

// MARK: - Editing

/// "Images" row for a report or reply being written: Add Image, the count,
/// and the thumbnails with remove buttons. Errors from drop and paste land
/// in `message` too, so they show in one place.
struct HelpImageAttachmentsRow: View {
    @Binding var images: [SupportImageAttachment]
    let limit: Int
    @Binding var message: String?
    var isDisabled = false

    @Environment(\.theme) private var theme
    @State private var isAdding = false
    @State private var preview: HelpImagePreview?

    private var description: String {
        if let message { return message }
        if limit == 0 { return L("This report has all the images it can hold.") }
        return String(
            format: L("Up to %lld screenshots or photos. You can also drop or paste them into the box above."), limit)
    }

    var body: some View {
        SettingsRow(title: "Images", description: description, verbatimDescription: true) {
            HStack(spacing: theme.space.s8) {
                if !images.isEmpty {
                    Text(verbatim: "\(images.count)/\(limit)")
                        .font(SettingsFont.caption.monospacedDigit())
                        .foregroundColor(theme.text.tertiary)
                }
                SettingsButton(.secondary, "Add Image", icon: "photo.badge.plus", isLoading: isAdding, size: .compact) {
                    add()
                }
                .disabled(isDisabled || isAdding || images.count >= limit)
            }
        }
        if !images.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: theme.space.s12) {
                    ForEach(images) { image in
                        HelpImageThumbnail(
                            id: image.id.uuidString,
                            data: image.data,
                            pixelWidth: image.width,
                            pixelHeight: image.height,
                            onTap: { preview = HelpImagePreview(id: image.id.uuidString, data: image.data) },
                            onRemove: isDisabled
                                ? nil
                                : {
                                    withAnimation(theme.motion.quick) {
                                        images.removeAll { $0.id == image.id }
                                        message = nil
                                    }
                                }
                        )
                    }
                }
                .padding(.vertical, theme.space.s6)
                .padding(.trailing, theme.space.s6)
            }
            .settingsRowChrome()
            .sheet(item: $preview) { preview in
                HelpImagePreviewSheet(preview: preview) { self.preview = nil }
            }
        }
    }

    private func add() {
        let urls = HelpImageIntake.pickFiles()
        guard !urls.isEmpty else { return }
        isAdding = true
        Task {
            message = await HelpImageIntake.add(urls.map(HelpImageSource.file), to: $images, limit: limit)
            isAdding = false
        }
    }
}

extension View {
    /// Accept dropped and pasted images into `images`. Paste is taken only
    /// while the text view inside this view has focus and the pasteboard
    /// holds an image, so ordinary text paste is untouched.
    func helpImageIntake(
        images: Binding<[SupportImageAttachment]>,
        limit: Int,
        message: Binding<String?>,
        isEnabled: Bool = true
    ) -> some View {
        modifier(HelpImageIntakeModifier(images: images, limit: limit, message: message, isEnabled: isEnabled))
    }
}

private struct HelpImageIntakeModifier: ViewModifier {
    @Binding var images: [SupportImageAttachment]
    let limit: Int
    @Binding var message: String?
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                guard isEnabled else { return false }
                Task {
                    let sources = await HelpImageIntake.sources(from: providers)
                    guard !sources.isEmpty else { return }
                    message = await HelpImageIntake.add(sources, to: $images, limit: limit)
                }
                return true
            }
            .background(
                HelpImagePasteMonitor(isEnabled: isEnabled) { datas in
                    Task {
                        message = await HelpImageIntake.add(datas.map(HelpImageSource.data), to: $images, limit: limit)
                    }
                }
            )
    }
}

/// Catches ⌘V for the text view it sits behind. A local key monitor sees
/// every window, so it only acts when the focused text view is inside this
/// view's frame in this view's window.
private struct HelpImagePasteMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onPaste: ([Data]) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.isEnabled = isEnabled
        view.onPaste = onPaste
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.isEnabled = isEnabled
        view.onPaste = onPaste
    }

    final class MonitorView: NSView {
        var isEnabled = true
        var onPaste: (([Data]) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, self.isEnabled, self.owns(event),
                        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                        event.charactersIgnoringModifiers == "v"
                    else { return event }
                    let datas = SupportImageEncoder.pasteboardImageData()
                    guard !datas.isEmpty else { return event }
                    self.onPaste?(datas)
                    return nil
                }
            }
        }

        override func removeFromSuperview() {
            removeMonitor()
            super.removeFromSuperview()
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func owns(_ event: NSEvent) -> Bool {
            guard let window, event.window === window,
                let textView = window.firstResponder as? NSTextView, textView.window === window
            else { return false }
            let mine = convert(bounds, to: nil)
            let theirs = textView.enclosingScrollView ?? textView
            let center = theirs.convert(NSPoint(x: theirs.bounds.midX, y: theirs.bounds.midY), to: nil)
            return mine.contains(center)
        }
    }
}

// MARK: - Sent

/// The images on a sent message. Each one is fetched when it scrolls in and
/// kept by `SupportService`, so reopening a report does not fetch again.
struct HelpMessageImages: View {
    let threadId: String
    let attachments: [OsaurusRouterSupportAttachment]

    @Environment(\.theme) private var theme
    @State private var preview: HelpImagePreview?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.space.s8) {
                ForEach(attachments) { attachment in
                    HelpRemoteImageThumbnail(threadId: threadId, attachment: attachment) { data in
                        preview = HelpImagePreview(id: attachment.id, data: data)
                    }
                }
            }
        }
        .sheet(item: $preview) { preview in
            HelpImagePreviewSheet(preview: preview) { self.preview = nil }
        }
    }
}

private struct HelpRemoteImageThumbnail: View {
    let threadId: String
    let attachment: OsaurusRouterSupportAttachment
    let onOpen: (Data) -> Void

    @Environment(\.theme) private var theme
    @State private var data: Data?
    @State private var failed = false

    var body: some View {
        Group {
            if let data {
                HelpImageThumbnail(
                    id: attachment.id,
                    data: data,
                    pixelWidth: attachment.width,
                    pixelHeight: attachment.height,
                    onTap: { onOpen(data) }
                )
            } else {
                let size = HelpImageThumbnail.displaySize(width: attachment.width, height: attachment.height)
                Group {
                    if failed {
                        SettingsIconButton("arrow.clockwise", help: "Try loading the image again", size: .small) {
                            failed = false
                            Task { await load() }
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: size.width, height: size.height)
                .settingsChrome(.inset)
            }
        }
        .task(id: attachment.id) { await load() }
    }

    private func load() async {
        guard data == nil else { return }
        do {
            data = try await SupportService.shared.attachmentData(threadId: threadId, attachmentId: attachment.id)
        } catch {
            failed = true
        }
    }
}

// MARK: - Thumbnail

/// One image at thumbnail height, its own aspect ratio (clamped so a
/// panorama or a tall screenshot stays a readable tile).
struct HelpImageThumbnail: View {
    let id: String
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
    var onTap: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var image: NSImage?

    static let height: CGFloat = 72

    static func displaySize(width: Int, height: Int) -> CGSize {
        guard width > 0, height > 0 else { return CGSize(width: Self.height, height: Self.height) }
        let ratio = min(2, max(0.5, Double(width) / Double(height)))
        return CGSize(width: (Self.height * ratio).rounded(), height: Self.height)
    }

    var body: some View {
        let size = Self.displaySize(width: pixelWidth, height: pixelHeight)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default)
        )
        .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
        .onTapGesture { onTap?() }
        .pointingHandCursor()
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                SettingsIconButton("xmark", help: "Remove image", size: .extraExtraSmall, role: .secondary, action: onRemove)
                    .offset(x: theme.space.s4, y: -theme.space.s4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Attached image", bundle: .module))
        .accessibilityAddTraits(.isButton)
        .task(id: id) {
            if let cached = ChatImageCache.shared.cachedImage(for: id) {
                image = cached
            } else {
                image = await ChatImageCache.shared.decode(data, id: id)
            }
        }
    }
}

// MARK: - Full Size

struct HelpImagePreview: Identifiable, Equatable {
    let id: String
    let data: Data
}

/// The chat's zoom / pan / save viewer, for one report image.
struct HelpImagePreviewSheet: View {
    let preview: HelpImagePreview
    let onDismiss: () -> Void

    @State private var image: NSImage?

    var body: some View {
        ImageFullScreenView(image: image, altText: "", onDismiss: onDismiss)
            .imageFullScreenSheetPresentation()
            .task(id: preview.id) {
                if let cached = ChatImageCache.shared.cachedImage(for: preview.id) {
                    image = cached
                } else {
                    image = await ChatImageCache.shared.decode(preview.data, id: preview.id)
                }
            }
    }
}
