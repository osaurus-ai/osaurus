//
//  ClarificationCardView.swift
//  osaurus
//
//  UI for displaying clarification questions from the agent.
//  Allows users to select from options or provide custom responses.
//

import SwiftUI

struct ClarificationCardView: View {
    let request: ClarificationRequest
    let onSubmit: (String) -> Void

    @State private var selectedOption: String?
    @State private var customResponse: String = ""
    @State private var isHovered: Bool = false

    @Environment(\.theme) private var theme

    /// Whether options are provided
    private var hasOptions: Bool {
        request.options != nil && !(request.options?.isEmpty ?? true)
    }

    /// The response to submit (selected option or custom text)
    private var responseToSubmit: String {
        if let selected = selectedOption {
            return selected
        }
        return customResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether submit is enabled
    private var canSubmit: Bool {
        !responseToSubmit.isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left accent strip
            accentStrip

            // Main content
            VStack(alignment: .leading, spacing: 0) {
                header
                divider
                questionContent
                if hasOptions {
                    optionsContent
                } else {
                    textInputContent
                }
                submitButton
            }
        }
        .background(cardBackground)
        .overlay(cardBorder)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(theme.animationQuick(), value: isHovered)
        .animation(theme.animationQuick(), value: selectedOption)
        .onHover { isHovered = $0 }
    }

    // MARK: - Accent Strip

    private var accentStrip: some View {
        UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 10, bottomLeading: 10),
            style: .continuous
        )
        .fill(theme.accentColor)
        .frame(width: 4)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            // Question icon
            questionIcon

            // Title
            Text("Clarification Needed")
                .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                .foregroundColor(theme.secondaryText)

            Spacer()

            // Paused indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(theme.warningColor)
                    .frame(width: 6, height: 6)
                Text("Waiting")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(theme.warningColor.opacity(0.1))
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var questionIcon: some View {
        ZStack {
            Circle()
                .fill(theme.accentColor.opacity(0.15))
                .frame(width: 24, height: 24)

            Image(systemName: "questionmark")
                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .semibold))
                .foregroundColor(theme.accentColor)
        }
    }

    // MARK: - Divider

    private var divider: some View {
        Rectangle()
            .fill(theme.primaryBorder.opacity(0.15))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    // MARK: - Question Content

    private var questionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Question text
            Text(request.question)
                .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            // Context if provided
            if let context = request.context, !context.isEmpty {
                Text(context)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .regular))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, hasOptions ? 8 : 12)
    }

    // MARK: - Options Content

    private var optionsContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(request.options ?? [], id: \.self) { option in
                optionButton(option)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func optionButton(_ option: String) -> some View {
        let isSelected = selectedOption == option

        return Button {
            withAnimation(theme.animationQuick()) {
                if selectedOption == option {
                    selectedOption = nil
                } else {
                    selectedOption = option
                }
            }
        } label: {
            HStack(spacing: 10) {
                // Selection indicator
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? theme.accentColor : theme.tertiaryText.opacity(0.4),
                            lineWidth: 1.5
                        )
                        .frame(width: 18, height: 18)

                    if isSelected {
                        Circle()
                            .fill(theme.accentColor)
                            .frame(width: 10, height: 10)
                    }
                }

                // Option text
                Text(option)
                    .font(theme.font(size: CGFloat(theme.bodySize) - 1, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
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

    // MARK: - Text Input Content

    private var textInputContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            textInputField
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var textInputField: some View {
        TextField("", text: $customResponse, axis: .vertical)
            .font(theme.font(size: CGFloat(theme.bodySize) - 1, weight: .regular))
            .foregroundColor(theme.primaryText)
            .textFieldStyle(.plain)
            .lineLimit(1 ... 4)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(alignment: .topLeading) {
                if customResponse.isEmpty {
                    Text("Type your response...")
                        .font(theme.font(size: CGFloat(theme.bodySize) - 1, weight: .regular))
                        .foregroundColor(theme.placeholderText)
                        .padding(.leading, 12)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.tertiaryBackground.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.primaryBorder.opacity(0.2), lineWidth: 0.5)
            )
            .onSubmit {
                if canSubmit {
                    onSubmit(responseToSubmit)
                }
            }
    }

    // MARK: - Submit Button

    private var submitButton: some View {
        HStack {
            Spacer()

            Button {
                if canSubmit {
                    onSubmit(responseToSubmit)
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Continue")
                        .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))

                    Image(systemName: "arrow.right")
                        .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .semibold))
                }
                .foregroundColor(canSubmit ? .white : theme.tertiaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(canSubmit ? theme.accentColor : theme.tertiaryBackground)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    // MARK: - Background & Border

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(theme.secondaryBackground.opacity(isHovered ? 0.6 : 0.4))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                theme.primaryBorder.opacity(isHovered ? 0.3 : 0.2),
                lineWidth: 0.5
            )
    }
}

// MARK: - Preview

#if DEBUG
    struct ClarificationCardView_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 20) {
                // With options
                ClarificationCardView(
                    request: ClarificationRequest(
                        question: "Which database system should I use for this project?",
                        options: ["PostgreSQL", "MySQL", "SQLite"],
                        context: "The task mentions a database but doesn't specify which one."
                    ),
                    onSubmit: { response in
                        print("Selected: \(response)")
                    }
                )

                // Without options (free text)
                ClarificationCardView(
                    request: ClarificationRequest(
                        question: "What is the target directory for the generated files?",
                        options: nil,
                        context: "The task doesn't specify where to save the output."
                    ),
                    onSubmit: { response in
                        print("Response: \(response)")
                    }
                )
            }
            .frame(width: 500)
            .padding()
            .background(Color(hex: "0c0c0b"))
        }
    }
#endif
