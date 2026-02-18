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
    @State private var isLoading = true
    @State private var loadError: Error?

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
        }
        .onAppear { loadImage() }
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
            Text("Loading image...")
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
                Text("Failed to load image")
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
                    Text("Retry")
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

        Task {
            do {
                let image = try await loadImageFromSource()
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

    private func loadImageFromSource() async throws -> NSImage {
        if urlString.hasPrefix("data:image/") {
            return try loadBase64Image()
        }
        if urlString.hasPrefix("file://") || urlString.hasPrefix("/") {
            return try loadLocalImage()
        }
        return try await loadRemoteImage()
    }

    private func loadBase64Image() throws -> NSImage {
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

    private func loadLocalImage() throws -> NSImage {
        let path = urlString.hasPrefix("file://") ? String(urlString.dropFirst(7)) : urlString
        guard FileManager.default.fileExists(atPath: path) else {
            throw ImageLoadError.fileNotFound
        }
        guard let image = NSImage(contentsOfFile: path) else {
            throw ImageLoadError.corruptedImage
        }
        return image
    }

    private func loadRemoteImage() async throws -> NSImage {
        guard let url = URL(string: urlString) else {
            throw ImageLoadError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
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
            Label("Save Image\u{2026}", systemImage: "arrow.down.to.line")
        }
        Button {
            ImageActions.copyImageToClipboard(image)
        } label: {
            Label("Copy Image", systemImage: "doc.on.doc")
        }
        Divider()
        Button {
            onFullScreen()
        } label: {
            Label("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
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
                let tiffData = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiffData),
                let pngData = bitmap.representation(using: .png, properties: [:])
            else { return }
            try? pngData.write(to: url)
        }
    }

    static func copyImageToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
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

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

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
                        .help("Save Image")
                    }
                    Button(action: { dismiss() }) {
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
        .frame(minWidth: 600, minHeight: 400)
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
