//
//  MCPElicitationView.swift
//  osaurus
//
//  Card for an MCP server's `elicitation/create` request: a small form built
//  from the server's flat schema, or a "finish in your browser" step that only
//  opens the link when the user clicks.
//

import AppKit
import SwiftUI

struct MCPElicitationView: View {
    let request: MCPElicitationRequest
    let onAction: (MCPElicitationAction) -> Void

    @Environment(\.theme) private var theme
    @State private var inputs: [String: MCPElicitationInput] = [:]
    @State private var errors: [String: String] = [:]
    @State private var openedURL = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.top, .horizontal], 24)

            if !request.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    Text(request.message)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.horizontal, 24)
            }

            Group {
                switch request.mode {
                case .form(let form): formBody(form)
                case .url(let url, _): urlBody(url)
                }
            }
            .padding(.top, 14)
            .padding(.horizontal, 24)

            Rectangle()
                .fill(theme.primaryBorder.opacity(0.3))
                .frame(height: 1)
                .padding(.top, 16)

            buttons
                .padding(16)
                .padding(.horizontal, 8)
        }
        .frame(width: 480)
        .fixedSize(horizontal: true, vertical: true)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.cardBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.glassEdgeLight.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: theme.shadowColor.opacity(theme.shadowOpacity * 2), radius: 12, x: 0, y: 6)
        .onAppear(perform: seedDefaults)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(theme.accentColor.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: isURLMode ? "safari" : "list.bullet.rectangle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    isURLMode
                        ? L("\(request.providerName) wants you to finish in your browser")
                        : L("\(request.providerName) needs more information")
                )
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                if case .form(let form) = request.mode, let title = form.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }
            }
        }
    }

    private var isURLMode: Bool {
        if case .url = request.mode { return true }
        return false
    }

    // MARK: Form mode

    private func formBody(_ form: MCPElicitationForm) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(form.fields) { field in
                        fieldRow(field)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)

            Label {
                Text(
                    L(
                        "Never enter passwords, API keys or card numbers here. Your answers are sent to \(request.providerName)."
                    )
                )
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.trianglebadge.exclamationmark")
            }
            .font(.system(size: 11))
            .foregroundColor(theme.secondaryText)
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: MCPElicitationField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .boolean = field.kind {
                Toggle(isOn: flagBinding(field.key)) {
                    fieldLabel(field)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            } else {
                fieldLabel(field)
                switch field.kind {
                case .choice(let choices):
                    Picker("", selection: textBinding(field.key)) {
                        Text("Choose…", bundle: .module).tag("")
                        ForEach(choices, id: \.value) { choice in
                            Text(choice.label).tag(choice.value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                default:
                    TextField(placeholder(for: field), text: textBinding(field.key))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                }
            }
            if let description = field.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = errors[field.key] {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.errorColor)
            }
        }
    }

    private func fieldLabel(_ field: MCPElicitationField) -> some View {
        HStack(spacing: 2) {
            Text(field.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
            if field.required {
                Text(verbatim: "*")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.errorColor)
                    .accessibilityLabel(L("Required"))
            }
        }
    }

    private func placeholder(for field: MCPElicitationField) -> String {
        switch field.kind {
        case .text(.email?, _, _): return "name@example.com"
        case .text(.uri?, _, _): return "https://"
        case .text(.date?, _, _): return "YYYY-MM-DD"
        case .text(.dateTime?, _, _): return "YYYY-MM-DDTHH:MM:SSZ"
        case .number(true, _, _): return "0"
        case .number(false, _, _): return "0.0"
        default: return ""
        }
    }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(
            get: {
                if case .text(let value)? = inputs[key] { return value }
                return ""
            },
            set: {
                inputs[key] = .text($0)
                errors[key] = nil
            }
        )
    }

    private func flagBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: {
                if case .flag(let value)? = inputs[key] { return value }
                return false
            },
            set: {
                inputs[key] = .flag($0)
                errors[key] = nil
            }
        )
    }

    private func seedDefaults() {
        guard case .form(let form) = request.mode else { return }
        for field in form.fields where inputs[field.key] == nil {
            if let value = field.defaultValue {
                inputs[field.key] = value
            } else if case .boolean = field.kind {
                inputs[field.key] = .flag(false)
            }
        }
    }

    private func submit(_ form: MCPElicitationForm) {
        switch form.content(from: inputs) {
        case .success(let content): onAction(.respond(.accept(content)))
        case .failure(let failure): errors = failure.messages
        }
    }

    // MARK: URL mode

    private func urlBody(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(url.host ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(url.absoluteString)
                    .font(theme.monoFont(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.codeBlockBackground))

            Text(
                openedURL
                    ? L("Finish the steps in your browser. This closes on its own when \(request.providerName) confirms, or click Done.")
                    : L("Only continue if you trust this site. Osaurus opens it in your browser when you click Open.")
            )
            .font(.system(size: 11))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 10) {
            if openedURL {
                ElicitationButton(title: L("Done"), isPrimary: true, color: theme.accentColor) {
                    onAction(.done)
                }
            } else {
                ElicitationButton(title: L("Cancel"), isPrimary: false, color: theme.secondaryText) {
                    onAction(.respond(.cancel))
                }
                ElicitationButton(title: L("Decline"), isPrimary: false, color: theme.errorColor) {
                    onAction(.respond(.decline))
                }
                switch request.mode {
                case .form(let form):
                    ElicitationButton(title: L("Submit"), isPrimary: true, color: theme.accentColor) {
                        submit(form)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                case .url(let url, _):
                    ElicitationButton(title: L("Open \(url.host ?? "")"), isPrimary: true, color: theme.accentColor) {
                        NSWorkspace.shared.open(url)
                        openedURL = true
                        onAction(.openedURL)
                    }
                }
            }
        }
    }
}

private struct ElicitationButton: View {
    let title: String
    let isPrimary: Bool
    let color: Color
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isPrimary ? .white : color)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    isPrimary
                        ? color.opacity(isHovering ? 0.9 : 1)
                        : theme.tertiaryBackground.opacity(isHovering ? 0.8 : 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isPrimary ? .clear : theme.cardBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
