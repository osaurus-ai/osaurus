//
//  MarkdownImageView.swift
//  osaurus
//
//  Renders images from URLs, file paths, or base64 data URIs with loading states
//

import AppKit
import SwiftUI

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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            imageContainer
                .onTapGesture {
                    if loadedImage != nil {
                        showFullScreen = true
                    }
                }

            // Alt text caption
            if !altText.isEmpty && loadedImage != nil {
                Text(altText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }
        }
        .sheet(isPresented: $showFullScreen) {
            ImageFullScreenView(image: loadedImage, altText: altText)
        }
        .onAppear {
            loadImage()
        }
    }

    @ViewBuilder
    private var imageContainer: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.secondaryBackground)

            if isLoading {
                loadingView
            } else if let error = loadError {
                errorView(error)
            } else if let image = loadedImage {
                imageView(image)
            }
        }
        .frame(maxWidth: maxImageWidth)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 0.5)
        )
        .shadow(
            color: theme.shadowColor.opacity(isHovered ? 0.15 : 0.08),
            radius: isHovered ? 12 : 6,
            x: 0,
            y: isHovered ? 6 : 3
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
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
        .frame(height: 160)
        .frame(maxWidth: .infinity)
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

            // Retry button
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
                .background(
                    Capsule()
                        .fill(theme.accentColor.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
        }
        .frame(height: 160)
        .frame(maxWidth: .infinity)
    }

    private func imageView(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: maxImageWidth)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
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
        // Check for base64 data URI
        if urlString.hasPrefix("data:image/") {
            return try loadBase64Image()
        }

        // Check for local file path
        if urlString.hasPrefix("file://") || urlString.hasPrefix("/") {
            return try loadLocalImage()
        }

        // Remote URL
        return try await loadRemoteImage()
    }

    private func loadBase64Image() throws -> NSImage {
        // Parse data URI: data:image/png;base64,iVBORw0...
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
        let path: String
        if urlString.hasPrefix("file://") {
            path = String(urlString.dropFirst(7))
        } else {
            path = urlString
        }

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

// MARK: - Image Load Error

private enum ImageLoadError: LocalizedError {
    case invalidURL
    case invalidDataURI
    case invalidBase64
    case fileNotFound
    case corruptedImage
    case networkError

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid image URL"
        case .invalidDataURI: return "Invalid data URI format"
        case .invalidBase64: return "Invalid base64 encoding"
        case .fileNotFound: return "File not found"
        case .corruptedImage: return "Corrupted image data"
        case .networkError: return "Network error"
        }
    }
}

// MARK: - Full Screen Image View

private struct ImageFullScreenView: View {
    let image: NSImage?
    let altText: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    var body: some View {
        ZStack {
            // Dark background
            Color.black.opacity(0.9)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1.0, min(value, 5.0))
                            }
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if scale > 1.0 {
                                    offset = value.translation
                                }
                            }
                            .onEnded { _ in
                                if scale <= 1.0 {
                                    withAnimation(.spring()) {
                                        offset = .zero
                                    }
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

            // Close button and caption
            VStack {
                HStack {
                    Spacer()
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

                if !altText.isEmpty {
                    Text(altText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.5))
                        )
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
