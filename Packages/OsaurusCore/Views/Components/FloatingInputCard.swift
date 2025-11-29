//
//  FloatingInputCard.swift
//  osaurus
//
//  Premium floating input card with model chip and smooth animations
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct FloatingInputCard: View {
    @Binding var text: String
    @Binding var selectedModel: String?
    @Binding var pendingImages: [Data]
    let modelOptions: [String]
    let isStreaming: Bool
    let supportsImages: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.theme) private var theme
    @State private var isDragOver = false

    private let maxHeight: CGFloat = 200
    private let maxImageSize: Int = 10 * 1024 * 1024  // 10MB limit

    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImages = !pendingImages.isEmpty
        return (hasText || hasImages) && !isStreaming
    }

    var body: some View {
        VStack(spacing: 12) {
            // Model selector chip (when multiple models available)
            if modelOptions.count > 1 {
                modelSelector
            }

            // Pending images preview
            if !pendingImages.isEmpty {
                pendingImagesPreview
            }

            // Main input card
            inputCard
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .onDrop(of: [UTType.image], isTargeted: $isDragOver) { providers in
            handleImageDrop(providers)
        }
    }

    // MARK: - Pending Images Preview

    private var pendingImagesPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(pendingImages.enumerated()), id: \.offset) { index, imageData in
                    imagePreviewThumbnail(imageData: imageData, index: index)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 72)
    }

    private func imagePreviewThumbnail(imageData: Data, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 1)
                    )
            }

            // Remove button
            Button(action: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    _ = pendingImages.remove(at: index)
                }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.6))
                            .frame(width: 18, height: 18)
                    )
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
    }

    // MARK: - Model Selector

    private var modelSelector: some View {
        HStack {
            Menu {
                ForEach(modelOptions, id: \.self) { model in
                    Button(action: { selectedModel = model }) {
                        HStack {
                            Text(displayModelName(model))
                            if selectedModel == model {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)

                    Text(displayModelName(selectedModel))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(theme.secondaryBackground.opacity(0.8))
                        .overlay(
                            Capsule()
                                .strokeBorder(theme.primaryBorder.opacity(0.5), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)

            Spacer()

            // Keyboard hint
            keyboardHint
        }
    }

    private var keyboardHint: some View {
        HStack(spacing: 4) {
            Text("⏎")
                .font(.system(size: 10, weight: .medium, design: .rounded))
            Text("to send")
                .font(.system(size: 11))
        }
        .foregroundColor(theme.tertiaryText.opacity(0.7))
    }

    private func displayModelName(_ raw: String?) -> String {
        guard let raw else { return "Model" }
        if raw.lowercased() == "foundation" { return "Foundation" }
        if let last = raw.split(separator: "/").last { return String(last) }
        return raw
    }

    // MARK: - Input Card

    private var inputCard: some View {
        HStack(alignment: .bottom, spacing: 12) {
            // Image attachment button (only for VLM models)
            if supportsImages {
                imageAttachButton
            }

            // Text input area
            textInputArea

            // Action button (send/stop)
            actionButton
        }
        .padding(12)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(effectiveBorderStyle, lineWidth: isDragOver ? 2 : (isFocused ? 1.5 : 0.5))
        )
        .shadow(
            color: shadowColor,
            radius: isFocused ? 24 : 12,
            x: 0,
            y: isFocused ? 8 : 4
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFocused)
        .animation(.easeInOut(duration: 0.2), value: isDragOver)
    }

    // MARK: - Image Attachment Button

    private var imageAttachButton: some View {
        Button(action: pickImage) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(theme.secondaryBackground.opacity(0.8))
                )
        }
        .buttonStyle(.plain)
        .help("Attach image (or paste/drag)")
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select images to attach"

        if panel.runModal() == .OK {
            for url in panel.urls {
                if let data = try? Data(contentsOf: url), data.count <= maxImageSize {
                    // Convert to PNG for consistency
                    if let nsImage = NSImage(data: data),
                        let pngData = nsImage.pngData()
                    {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            pendingImages.append(pngData)
                        }
                    }
                }
            }
        }
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard supportsImages else { return false }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    guard let data = data, error == nil, data.count <= maxImageSize else { return }
                    DispatchQueue.main.async {
                        if let nsImage = NSImage(data: data),
                            let pngData = nsImage.pngData()
                        {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                pendingImages.append(pngData)
                            }
                        }
                    }
                }
            }
        }
        return true
    }

    private var textInputArea: some View {
        TextEditor(text: $text)
            .font(.system(size: 15))
            .foregroundColor(theme.primaryText)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .focused($isFocused)
            .frame(minHeight: 44, maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
            .overlay(alignment: .topLeading) {
                // Placeholder
                if text.isEmpty && pendingImages.isEmpty {
                    Text(supportsImages ? "Message or paste image..." : "Message...")
                        .font(.system(size: 15))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.leading, 6)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
            }
            .onPasteCommand(of: [UTType.image]) { providers in
                handleImagePaste(providers)
            }
    }

    private func handleImagePaste(_ providers: [NSItemProvider]) {
        guard supportsImages else { return }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    guard let data = data, error == nil, data.count <= maxImageSize else { return }
                    DispatchQueue.main.async {
                        if let nsImage = NSImage(data: data),
                            let pngData = nsImage.pngData()
                        {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                pendingImages.append(pngData)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Action Button

    private var actionButton: some View {
        Button(action: isStreaming ? onStop : onSend) {
            ZStack {
                // Send icon
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .opacity(isStreaming ? 0 : 1)
                    .scaleEffect(isStreaming ? 0.5 : 1)

                // Stop icon
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .opacity(isStreaming ? 1 : 0)
                    .scaleEffect(isStreaming ? 1 : 0.5)
            }
            .frame(width: 32, height: 32)
            .background(buttonBackground)
            .clipShape(Circle())
            .shadow(
                color: buttonShadowColor,
                radius: 8,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !isStreaming)
        .opacity(!canSend && !isStreaming ? 0.5 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isStreaming)
        .animation(.easeInOut(duration: 0.15), value: canSend)
    }

    private var buttonBackground: some ShapeStyle {
        if isStreaming {
            return AnyShapeStyle(Color.red)
        } else {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private var buttonShadowColor: Color {
        isStreaming ? Color.red.opacity(0.4) : Color.accentColor.opacity(0.4)
    }

    // MARK: - Card Styling

    private var cardBackground: some View {
        ZStack {
            // Base blur
            if #available(macOS 13.0, *) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(theme.primaryBackground.opacity(0.95))
            }

            // Subtle tint
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(theme.primaryBackground.opacity(0.6))
        }
    }

    private var effectiveBorderStyle: AnyShapeStyle {
        if isDragOver {
            return AnyShapeStyle(Color.accentColor)
        }
        return borderGradient
    }

    private var borderGradient: AnyShapeStyle {
        if isFocused {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.6), Color.accentColor.opacity(0.2)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [theme.glassEdgeLight, theme.glassEdgeLight.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var shadowColor: Color {
        isFocused ? Color.accentColor.opacity(0.15) : Color.black.opacity(0.15)
    }
}

// MARK: - NSImage PNG Conversion

extension NSImage {
    /// Convert NSImage to PNG data
    func pngData() -> Data? {
        guard let tiffData = self.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - Preview

#if DEBUG
    struct FloatingInputCard_Previews: PreviewProvider {
        struct PreviewWrapper: View {
            @State private var text = ""
            @State private var model: String? = "foundation"
            @State private var images: [Data] = []

            var body: some View {
                VStack {
                    Spacer()
                    FloatingInputCard(
                        text: $text,
                        selectedModel: $model,
                        pendingImages: $images,
                        modelOptions: ["foundation", "mlx-community/Llama-3.2-3B-Instruct"],
                        isStreaming: false,
                        supportsImages: true,
                        onSend: {},
                        onStop: {}
                    )
                }
                .frame(width: 700, height: 400)
                .background(Color(hex: "0f0f10"))
            }
        }

        static var previews: some View {
            PreviewWrapper()
        }
    }
#endif
