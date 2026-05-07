//
//  AccessKeyGeneratorSheet.swift
//  osaurus
//
//  Modal sheet for generating a new osk-v1 access key. Hosted from
//  ServerView.AccessKeysSection (global, master-scoped) and from
//  IdentityView's per-agent expansion (agent-scoped).
//
//  Visibility: internal (`struct AccessKeyGeneratorSheet`) so both files in
//  the same target can present it without re-implementing the form.
//

import SwiftUI

struct AccessKeyGeneratorSheet: View {
    let theme: ThemeProtocol
    let title: LocalizedStringKey
    let scopeCaption: LocalizedStringKey?
    @Binding var label: String
    @Binding var expiration: AccessKeyExpiration
    @Binding var isGenerating: Bool
    @Binding var error: String?
    let onGenerate: () -> Void
    let onCancel: () -> Void

    init(
        theme: ThemeProtocol,
        title: LocalizedStringKey = "Generate Access Key",
        scopeCaption: LocalizedStringKey? = nil,
        label: Binding<String>,
        expiration: Binding<AccessKeyExpiration>,
        isGenerating: Binding<Bool>,
        error: Binding<String?>,
        onGenerate: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.theme = theme
        self.title = title
        self.scopeCaption = scopeCaption
        self._label = label
        self._expiration = expiration
        self._isGenerating = isGenerating
        self._error = error
        self.onGenerate = onGenerate
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(title, bundle: .module)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
            }

            if let scopeCaption {
                HStack(spacing: 6) {
                    Image(systemName: "scope")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)
                    Text(scopeCaption, bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor.opacity(0.06))
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Label", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                TextField(text: $label, prompt: Text("e.g. Cursor, CLI, my-app", bundle: .module)) {
                    Text("e.g. Cursor, CLI, my-app", bundle: .module)
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Expiration", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                HStack(spacing: 8) {
                    ForEach(AccessKeyExpiration.allCases, id: \.rawValue) { option in
                        Button(action: { expiration = option }) {
                            Text(option.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(expiration == option ? .white : theme.primaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(expiration == option ? theme.accentColor : theme.tertiaryBackground)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }

            if let error {
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.errorColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.errorColor.opacity(0.1))
                    )
            }

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.tertiaryBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: onGenerate) {
                    HStack(spacing: 6) {
                        if isGenerating {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "key.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text("Generate", bundle: .module)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? theme.accentColor.opacity(0.4)
                                    : theme.accentColor
                            )
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(width: 420)
        .background(theme.primaryBackground)
    }
}
