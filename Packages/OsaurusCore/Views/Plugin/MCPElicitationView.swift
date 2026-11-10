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
                .padding([.top, .horizontal], theme.space.s24)

            if !request.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    Text(request.message)
                        .font(SettingsFont.body)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, theme.space.s8)
                .padding(.horizontal, theme.space.s24)
            }

            Group {
                switch request.mode {
                case .form(let form): formBody(form)
                case .url(let url, _): urlBody(url)
                }
            }
            .padding(.top, theme.space.s12)
            .padding(.horizontal, theme.space.s24)

            Rectangle()
                .fill(theme.border.subtle)
                .frame(height: 1)
                .padding(.top, theme.space.s16)

            buttons
                .padding(theme.space.s16)
                .padding(.horizontal, theme.space.s8)
        }
        .frame(width: 480)
        .fixedSize(horizontal: true, vertical: true)
        .settingsChrome(.card)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous)
                .strokeBorder(theme.border.default, lineWidth: theme.stroke.default)
        )
        .themeElevation(theme.elevation.overlay)
        .onAppear(perform: seedDefaults)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(theme.status.info.background)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: isURLMode ? "safari" : "list.bullet.rectangle")
                        .glyphSize(17, weight: .semibold)
                        .foregroundColor(theme.text.link)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    isURLMode
                        ? L("\(request.providerName) wants you to finish in your browser")
                        : L("\(request.providerName) needs more information")
                )
                .textStyle(.body, weight: 600)
                .foregroundColor(theme.text.primary)
                .fixedSize(horizontal: false, vertical: true)
                if case .form(let form) = request.mode, let title = form.title, !title.isEmpty {
                    Text(title)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)
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
                .padding(.vertical, theme.space.s2)
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
            .textStyle(.footnote)
            .foregroundColor(theme.text.secondary)
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: MCPElicitationField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .boolean = field.kind {
                Toggle(isOn: flagBinding(field.key)) {
                    fieldLabel(field)
                }
                .settingsSwitch(showsLabel: true)
            } else {
                fieldLabel(field)
                switch field.kind {
                case .choice(let choices):
                    SettingsMenuPicker(selection: textBinding(field.key)) {
                        Text("Choose…", bundle: .module).tag("")
                        ForEach(choices, id: \.value) { choice in
                            Text(choice.label).tag(choice.value)
                        }
                    }
                default:
                    SettingsTextField(placeholder: placeholder(for: field), text: textBinding(field.key))
                }
            }
            if let description = field.description, !description.isEmpty {
                Text(description)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = errors[field.key] {
                Text(error)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.status.error.foreground)
            }
        }
    }

    private func fieldLabel(_ field: MCPElicitationField) -> some View {
        HStack(spacing: 2) {
            Text(field.title)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
            if field.required {
                Text(verbatim: "*")
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.status.error.foreground)
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
                    .font(SettingsFont.cardTitle)
                    .foregroundColor(theme.text.primary)
                Text(url.absoluteString)
                    .textStyle(.footnote, family: .code)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(theme.space.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(.inset)

            Text(
                openedURL
                    ? L("Finish the steps in your browser. This closes on its own when \(request.providerName) confirms, or click Done.")
                    : L("Only continue if you trust this site. Osaurus opens it in your browser when you click Open.")
            )
            .textStyle(.footnote)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 10) {
            if openedURL {
                ElicitationButton(title: L("Done"), isPrimary: true, color: theme.action.primary.default.background) {
                    onAction(.done)
                }
            } else {
                ElicitationButton(title: L("Cancel"), isPrimary: false, color: theme.text.secondary) {
                    onAction(.respond(.cancel))
                }
                ElicitationButton(title: L("Decline"), isPrimary: false, color: theme.status.error.foreground) {
                    onAction(.respond(.decline))
                }
                switch request.mode {
                case .form(let form):
                    ElicitationButton(
                        title: L("Submit"),
                        isPrimary: true,
                        color: theme.action.primary.default.background
                    ) {
                        submit(form)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                case .url(let url, _):
                    ElicitationButton(
                        title: L("Open \(url.host ?? "")"),
                        isPrimary: true,
                        color: theme.action.primary.default.background
                    ) {
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
                .font(SettingsFont.sectionTitle)
                .foregroundColor(isPrimary ? .white : color)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, theme.space.s8)
                .background(
                    isPrimary
                        ? color.opacity(isHovering ? 0.9 : 1)
                        : (isHovering ? theme.surface.hover : theme.surface.subtle)
                )
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                        .stroke(isPrimary ? .clear : theme.border.default, lineWidth: theme.stroke.default)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
