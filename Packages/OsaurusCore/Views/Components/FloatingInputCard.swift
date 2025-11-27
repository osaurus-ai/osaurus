//
//  FloatingInputCard.swift
//  osaurus
//
//  Premium floating input card with model chip and smooth animations
//

import SwiftUI

struct FloatingInputCard: View {
    @Binding var text: String
    @Binding var selectedModel: String?
    let modelOptions: [String]
    let isStreaming: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.theme) private var theme

    private let maxHeight: CGFloat = 200

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
    }

    var body: some View {
        VStack(spacing: 12) {
            // Model selector chip (when multiple models available)
            if modelOptions.count > 1 {
                modelSelector
            }

            // Main input card
            inputCard
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
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
                .strokeBorder(borderGradient, lineWidth: isFocused ? 1.5 : 0.5)
        )
        .shadow(
            color: shadowColor,
            radius: isFocused ? 24 : 12,
            x: 0,
            y: isFocused ? 8 : 4
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFocused)
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
                if text.isEmpty {
                    Text("Message...")
                        .font(.system(size: 15))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.leading, 6)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
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

    private var borderGradient: some ShapeStyle {
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

// MARK: - Preview

#if DEBUG
    struct FloatingInputCard_Previews: PreviewProvider {
        struct PreviewWrapper: View {
            @State private var text = ""
            @State private var model: String? = "foundation"

            var body: some View {
                VStack {
                    Spacer()
                    FloatingInputCard(
                        text: $text,
                        selectedModel: $model,
                        modelOptions: ["foundation", "mlx-community/Llama-3.2-3B-Instruct"],
                        isStreaming: false,
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
