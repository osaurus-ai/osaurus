//
//  MarkdownImageView.swift
//  osaurus
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

let imageCornerRadius: CGFloat = 12

func isGenericCaption(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return trimmed.isEmpty || trimmed == "image" || trimmed == "generated image"
        || trimmed.hasPrefix("image|ts:")
}

let imageClipShape = RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous)

struct MarkdownImageView: View {
    let urlString: String
    let altText: String
    let baseWidth: CGFloat

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var showFullScreen = false
    @State private var loadedImage: NSImage?
    @State private var isLoading: Bool
    @State private var loadError: Error?

    init(urlString: String, altText: String, baseWidth: CGFloat) {
        self.urlString = urlString
        self.altText = altText
        self.baseWidth = baseWidth

        // Resolve from shared cache synchronously so the image appears
        // instantly when reloading a session instead of flashing a spinner.
        if let cached = ThreadCache.shared.image(for: urlString) {
            _loadedImage = State(initialValue: cached)
            _isLoading = State(initialValue: false)
        } else {
            _isLoading = State(initialValue: true)
        }
    }

    private var maxImageWidth: CGFloat {
        min(baseWidth - 32, 560)
    }

    private func displaySize(for image: NSImage) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            return CGSize(width: maxImageWidth, height: maxImageWidth * 0.75)
        }
        let width = min(size.width, maxImageWidth)
        return CGSize(width: width, height: width * size.height / size.width)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            imageContainer
                .onTapGesture {
                    if loadedImage != nil {
                        showFullScreen = true
                    }
                }

            if !isGenericCaption(altText), loadedImage != nil {
                Text(altText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }
        }
        .sheet(isPresented: $showFullScreen) {
            ImageFullScreenView(image: loadedImage, altText: altText)
                .imageFullScreenSheetPresentation()
        }
        .onAppear {
            if loadedImage == nil { loadImage() }
        }
    }

    @ViewBuilder
    private var imageContainer: some View {
        if isLoading {
            placeholderContainer { loadingView }
        } else if let error = loadError {
            placeholderContainer { errorView(error) }
        } else if let image = loadedImage {
            loadedImageView(image)
        }
    }

    private func placeholderContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            imageClipShape.fill(theme.secondaryBackground)
            content()
        }
        .frame(maxWidth: maxImageWidth)
        .frame(height: 160)
        .clipShape(imageClipShape)
        .overlay(imageClipShape.strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 0.5))
    }

    private func loadedImageView(_ image: NSImage) -> some View {
        let size = displaySize(for: image)
        return Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
            .clipShape(imageClipShape)
            .overlay(imageClipShape.strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    ImageHoverToolbar(image: image)
                        .transition(.opacity)
                }
            }
            .contextMenu { ImageContextMenuItems(image: image) { showFullScreen = true } }
            .shadow(
                color: theme.shadowColor.opacity(isHovered ? 0.15 : 0.08),
                radius: isHovered ? 12 : 6,
                x: 0,
                y: isHovered ? 6 : 3
            )
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isHovered)
            .onHover { isHovered = $0 }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
                .progressViewStyle(CircularProgressViewStyle(tint: theme.tertiaryText))
            Text("Loading image...", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
        }
    }

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(theme.tertiaryText)

            VStack(spacing: 4) {
                Text("Failed to load image", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                if !altText.isEmpty {
                    Text(altText)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
            }

            Button(action: loadImage) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                    Text("Retry", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.accentColor.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Image Loading

    private func loadImage() {
        isLoading = true
        loadError = nil

        let src = urlString
        Task.detached(priority: .userInitiated) {
            do {
                let image = try await ImageLoader.load(from: src)
                ThreadCache.shared.setImage(image, for: src)
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.loadedImage = image
                        self.isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.loadError = error
                        self.isLoading = false
                    }
                }
            }
        }
    }
}

// MARK: - Image Loader (non-actor-isolated)

enum ImageLoader {
    static func load(from urlString: String) async throws -> NSImage {
        if urlString.hasPrefix("data:image/") {
            return try loadBase64(urlString)
        }
        if urlString.hasPrefix("file://") || urlString.hasPrefix("/") {
            return try loadLocal(urlString)
        }
        return try await loadRemote(urlString)
    }

    private static func loadBase64(_ urlString: String) throws -> NSImage {
        guard let commaIndex = urlString.firstIndex(of: ",") else {
            throw ImageLoadError.invalidDataURI
        }
        let base64String = String(urlString[urlString.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else {
            throw ImageLoadError.invalidBase64
        }
        guard let image = NSImage(data: data) else {
            throw ImageLoadError.corruptedImage
        }
        return image
    }

    private static func loadLocal(_ urlString: String) throws -> NSImage {
        let path = urlString.hasPrefix("file://") ? String(urlString.dropFirst(7)) : urlString
        guard FileManager.default.fileExists(atPath: path) else {
            throw ImageLoadError.fileNotFound
        }
        guard let image = NSImage(contentsOfFile: path) else {
            throw ImageLoadError.corruptedImage
        }
        return image
    }

    private static func loadRemote(_ urlString: String) async throws -> NSImage {
        guard let url = URL(string: urlString) else {
            throw ImageLoadError.invalidURL
        }
        let (data, response) = try await makeRemoteImageSession().data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
            (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw ImageLoadError.networkError
        }
        guard let image = NSImage(data: data) else {
            throw ImageLoadError.corruptedImage
        }
        return image
    }

    static func makeRemoteImageSession() -> URLSession {
        GlobalProxySettings.sharedSession()
    }
}

// MARK: - Shared Image Interaction Helpers

struct ImageHoverToolbar: View {
    let image: NSImage

    var body: some View {
        HStack(spacing: 2) {
            imageToolbarButton("arrow.down.to.line", help: "Save Image") {
                ImageActions.saveImageToFile(image)
            }
            imageToolbarButton("doc.on.doc", help: "Copy Image") {
                ImageActions.copyImageToClipboard(image)
            }
        }
        .foregroundColor(.white)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .padding(8)
    }

    private func imageToolbarButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ImageContextMenuItems: View {
    let image: NSImage
    let onFullScreen: () -> Void

    var body: some View {
        Button {
            ImageActions.saveImageToFile(image)
        } label: {
            Label {
                Text("Save Image\u{2026}", bundle: .module)
            } icon: {
                Image(systemName: "arrow.down.to.line")
            }
        }
        Button {
            ImageActions.copyImageToClipboard(image)
        } label: {
            Label {
                Text("Copy Image", bundle: .module)
            } icon: {
                Image(systemName: "doc.on.doc")
            }
        }
        Divider()
        Button {
            onFullScreen()
        } label: {
            Label {
                Text("Open Full Screen", bundle: .module)
            } icon: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
        }
    }
}

// MARK: - Image Actions

@MainActor
enum ImageActions {
    static func saveImageToFile(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "image.png"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url,
                let tiffData = image.tiffRepresentation
            else { return }
            // Encode + write off the main thread so the disk I/O never blocks
            // the UI, then surface a "Reveal in Finder" toast on success.
            Task { @MainActor in
                let saved = await encodeAndWritePNG(tiff: tiffData, to: url)
                guard saved else {
                    NSSound.beep()
                    return
                }
                ToastManager.shared.action(
                    L("Image saved"),
                    message: url.lastPathComponent,
                    action: .revealInFinder(url),
                    buttonTitle: L("Reveal in Finder")
                )
            }
        }
    }

    static func copyImageToClipboard(_ image: NSImage) {
        // Pull the (cheap) Sendable TIFF on the main actor, then hand it to a
        // detached task so the pasteboard serialization never blocks the UI.
        let tiff = image.tiffRepresentation
        Task.detached(priority: .userInitiated) {
            await writeImageDataToPasteboard(tiff: tiff)
        }
    }

    /// Reads an image file off the main thread and copies its bytes to the
    /// clipboard. Avoids decoding the image into an `NSImage` and re-encoding
    /// it, so nothing heavy touches the main thread for a file-backed image.
    static func copyImageFileToClipboard(at url: URL) {
        Task.detached(priority: .userInitiated) {
            let data = try? Data(contentsOf: url)
            let type: NSPasteboard.PasteboardType =
                url.pathExtension.lowercased() == "png" ? .png : .tiff
            await MainActor.run {
                guard let data else {
                    NSSound.beep()
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(data, forType: type)
                ToastManager.shared.success(L("Image Copied to Clipboard"))
            }
        }
    }

    private static func writeImageDataToPasteboard(tiff: Data?) async {
        await MainActor.run {
            guard let tiff else {
                NSSound.beep()
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(tiff, forType: .tiff)
            ToastManager.shared.success(L("Image Copied to Clipboard"))
        }
    }

    /// Encodes TIFF data to PNG and writes it to `url` on a background queue.
    private static func encodeAndWritePNG(tiff: Data, to url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let bitmap = NSBitmapImageRep(data: tiff),
                let pngData = bitmap.representation(using: .png, properties: [:])
            else { return false }
            do {
                try pngData.write(to: url)
                return true
            } catch {
                return false
            }
        }.value
    }
}

// MARK: - Native Markdown Image Segment View

/// `NSImageView` used by the AppKit markdown renderer for inline / generated
/// images. Overlays a download button at the top-right of the *displayed*
/// image (revealed on hover) so a generated image can be saved without opening
/// it full screen. The owner positions the button via `setImageRightEdge(_:)`
/// since the view is full-width while the image is left-aligned and scaled.
final class MarkdownSegmentImageView: NSImageView {
    private let downloadButton = NSButton()
    private var trackingAreaRef: NSTrackingArea?
    private var rightEdgeConstraint: NSLayoutConstraint?

    private static let buttonSize: CGFloat = 26
    private static let inset: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureDownloadButton()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureDownloadButton() {
        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        downloadButton.isBordered = false
        downloadButton.bezelStyle = .regularSquare
        downloadButton.imagePosition = .imageOnly
        downloadButton.image = NSImage(
            systemSymbolName: "arrow.down.to.line",
            accessibilityDescription: "Save Image"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        downloadButton.contentTintColor = .white
        downloadButton.wantsLayer = true
        downloadButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        downloadButton.layer?.cornerRadius = 6
        downloadButton.target = self
        downloadButton.action = #selector(saveImageTapped)
        downloadButton.isHidden = true
        downloadButton.toolTip = L("Save Image")
        addSubview(downloadButton)

        let trailing = downloadButton.trailingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Self.buttonSize
        )
        rightEdgeConstraint = trailing
        NSLayoutConstraint.activate([
            downloadButton.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            trailing,
            downloadButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            downloadButton.heightAnchor.constraint(equalToConstant: Self.buttonSize),
        ])
    }

    /// Pin the button `inset` points inside the displayed image's right edge,
    /// `displayedWidth` measured from the view's left (where the image aligns).
    func setImageRightEdge(_ displayedWidth: CGFloat) {
        let target = max(Self.buttonSize + Self.inset, displayedWidth) - Self.inset
        if let c = rightEdgeConstraint, abs(c.constant - target) > 0.5 {
            c.constant = target
        }
    }

    @objc private func saveImageTapped() {
        guard let image else { return }
        ImageActions.saveImageToFile(image)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) {
        downloadButton.isHidden = (image == nil)
    }

    override func mouseExited(with event: NSEvent) {
        downloadButton.isHidden = true
    }
}

// MARK: - Image Load Error

enum ImageLoadError: LocalizedError {
    case invalidURL, invalidDataURI, invalidBase64, fileNotFound, corruptedImage, networkError

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid image URL"
        case .invalidDataURI: "Invalid data URI format"
        case .invalidBase64: "Invalid base64 encoding"
        case .fileNotFound: "File not found"
        case .corruptedImage: "Corrupted image data"
        case .networkError: "Network error"
        }
    }
}

// MARK: - Full Screen Image View

struct ImageFullScreenView: View {
    let image: NSImage?
    let altText: String
    /// when set (e.g. overlay presentation), avoids `Environment.dismiss` and prevents sheet-driven window sizing on macOS
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    private func close() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
                .ignoresSafeArea()
                .onTapGesture { close() }

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale = max(1.0, min($0, 5.0)) }
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { if scale > 1.0 { offset = $0.translation } }
                            .onEnded { _ in
                                if scale <= 1.0 {
                                    withAnimation(.spring()) { offset = .zero }
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring()) {
                            if scale > 1.0 {
                                scale = 1.0
                                offset = .zero
                            } else {
                                scale = 2.0
                            }
                        }
                    }
            }

            VStack {
                HStack {
                    Spacer()
                    if let image {
                        Button {
                            ImageActions.saveImageToFile(image)
                        } label: {
                            Image(systemName: "arrow.down.to.line.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white.opacity(0.8))
                                .shadow(radius: 4)
                        }
                        .buttonStyle(.plain)
                        .localizedHelp("Save Image")
                    }
                    Button(action: { close() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.8))
                            .shadow(radius: 4)
                    }
                    .buttonStyle(.plain)
                    .padding()
                }

                Spacer()

                if !isGenericCaption(altText) {
                    Text(altText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.5)))
                        .padding(.bottom, 40)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// macOS 15: default sheet sizing can resize the parent window when the sheet dismisses; `fitted` plus an explicit frame avoids that (see `PresentationSizing`).
    func imageFullScreenSheetPresentation() -> some View {
        frame(
            minWidth: 320,
            idealWidth: 960,
            maxWidth: .infinity,
            minHeight: 240,
            idealHeight: 720,
            maxHeight: .infinity
        )
        .presentationSizing(.fitted)
    }
}

// MARK: - Preview

#if DEBUG
    struct MarkdownImageView_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 20) {
                MarkdownImageView(
                    urlString: "https://placekitten.com/400/300",
                    altText: "A cute kitten",
                    baseWidth: 600
                )
                MarkdownImageView(
                    urlString: "invalid-url",
                    altText: "This will fail to load",
                    baseWidth: 600
                )
            }
            .padding()
            .frame(width: 700)
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
