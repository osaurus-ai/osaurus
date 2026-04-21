//
//  ClarificationCardView.swift
//  osaurus
//
//  Floating overlay for clarification questions, styled after VoiceInputOverlay.
//  Appears anchored to the bottom of the chat area.
//

import SwiftUI

struct ClarificationCardView: View {
    let request: ClarificationRequest
    let onSubmit: (String) -> Void

    @State private var selectedOption: String?
    @State private var customResponse: String = ""

    @Environment(\.theme) private var theme

    private var hasOptions: Bool {
        request.options?.isEmpty == false
    }

    private var responseToSubmit: String {
        selectedOption ?? customResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !responseToSubmit.isEmpty
    }

    var body: some View {
        VStack(spacing: 12) {
            header

            questionArea

            if hasOptions {
                optionsContent
            }

            inputAndActions
        }
        .padding(16)
        .background(overlayBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(borderOverlay)
        .shadow(color: theme.shadowColor.opacity(0.12), radius: 16, x: 0, y: 6)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.accentColor)

                Text("Clarification Needed", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(theme.accentColor.opacity(theme.isDark ? 0.15 : 0.1))
            )

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(theme.warningColor)
                    .frame(width: 6, height: 6)
                Text("Waiting", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    // MARK: - Question Area

    private var questionArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.question)
                .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let context = request.context, !context.isEmpty {
                Text(context)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .regular))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.inputBorder, lineWidth: 1)
        )
    }

    // MARK: - Options

    private var optionsContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(request.options ?? [], id: \.self) { option in
                optionButton(option)
            }
        }
    }

    private func optionButton(_ option: String) -> some View {
        let isSelected = selectedOption == option

        return Button {
            withAnimation(theme.animationQuick()) {
                if selectedOption == option {
                    selectedOption = nil
                } else {
                    selectedOption = option
                    customResponse = ""
                }
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? theme.accentColor : theme.tertiaryText.opacity(0.4),
                            lineWidth: 1.5
                        )
                        .frame(width: 16, height: 16)

                    if isSelected {
                        Circle()
                            .fill(theme.accentColor)
                            .frame(width: 8, height: 8)
                    }
                }

                Text(option)
                    .font(theme.font(size: CGFloat(theme.bodySize) - 1, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? theme.accentColor.opacity(0.1) : theme.tertiaryBackground.opacity(0.3))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accentColor.opacity(0.3) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input & Actions

    private var inputAndActions: some View {
        HStack(spacing: 10) {
            TextField("", text: $customResponse, axis: .vertical)
                .font(theme.font(size: CGFloat(theme.bodySize) - 1, weight: .regular))
                .foregroundColor(theme.primaryText)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 3)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .overlay(alignment: .topLeading) {
                    if customResponse.isEmpty {
                        Text(hasOptions ? L("Or type a custom response...") : L("Type your response..."))
                            .font(theme.font(size: CGFloat(theme.bodySize) - 1, weight: .regular))
                            .foregroundColor(theme.placeholderText)
                            .padding(.leading, 12)
                            .padding(.top, 9)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.tertiaryBackground.opacity(0.4))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.primaryBorder.opacity(0.15), lineWidth: 1)
                )
                .onSubmit {
                    if canSubmit { onSubmit(responseToSubmit) }
                }
                .onChange(of: customResponse) { _, newValue in
                    if !newValue.isEmpty {
                        withAnimation(theme.animationQuick()) {
                            selectedOption = nil
                        }
                    }
                }

            Button {
                if canSubmit { onSubmit(responseToSubmit) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(canSubmit ? .white : theme.tertiaryText)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(canSubmit ? theme.accentColor : theme.tertiaryBackground)
                )
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
    }

    // MARK: - Background & Border

    private var overlayBackground: some View {
        ZStack {
            if theme.glassEnabled {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            }

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.cardBackground.opacity(theme.isDark ? 0.85 : 0.92))

            LinearGradient(
                colors: [theme.accentColor.opacity(theme.isDark ? 0.08 : 0.05), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(0.2),
                        theme.cardBorder,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }
}

// MARK: - Preview

#if DEBUG
    struct ClarificationCardView_Previews: PreviewProvider {
        static var previews: some View {
            ZStack(alignment: .bottom) {
                Color(hex: "0c0c0b").ignoresSafeArea()

                ClarificationCardView(
                    request: ClarificationRequest(
                        question:
                            "Which deployment target should I use for your personal website, and do you want me to deploy it there now?",
                        options: [
                            "GitHub Pages (needs GitHub repo access or you push it)",
                            "Netlify (needs site/account access or deploy token)",
                            "Vercel (needs account/project access or token)",
                            "Just build the site locally and give me the files",
                        ],
                        context:
                            "I can build the website immediately, but deployment requires a destination and access."
                    ),
                    onSubmit: { response in
                        print("Selected: \(response)")
                    }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(width: 560, height: 550)
        }
    }
#endif
