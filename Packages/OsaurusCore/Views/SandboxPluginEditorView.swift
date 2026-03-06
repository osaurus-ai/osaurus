//
//  SandboxPluginEditorView.swift
//  osaurus
//
//  JSON editor for creating and editing sandbox plugin recipes.
//  Supports paste JSON, import from clipboard, and validation.
//

import SwiftUI

struct SandboxPluginEditorView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let agentId: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var jsonText: String = samplePluginJSON
    @State private var validationError: String?
    @State private var isInstalling = false
    @State private var installSuccess = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            editorArea
            Divider()
            footer
        }
        .frame(width: 600, height: 500)
        .background(theme.primaryBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Sandbox Plugin")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Define a JSON recipe for a plugin that runs inside the agent's VM")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundColor(theme.secondaryText)
        }
        .padding(16)
    }

    // MARK: - Editor

    private var editorArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $jsonText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.secondaryBackground)
                )
                .onChange(of: jsonText) {
                    validateJSON()
                }

            if let error = validationError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text(error)
                        .font(.system(size: 11))
                }
                .foregroundColor(.red)
                .padding(.horizontal, 4)
            }

            if installSuccess {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                    Text("Plugin installed successfully")
                        .font(.system(size: 11))
                }
                .foregroundColor(.green)
                .padding(.horizontal, 4)
            }
        }
        .padding(16)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                if let clipboard = NSPasteboard.general.string(forType: .string) {
                    jsonText = clipboard
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 10))
                    Text("Paste from Clipboard")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accentColor)

            Spacer()

            Button {
                Task { await installPlugin() }
            } label: {
                HStack(spacing: 4) {
                    if isInstalling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 10))
                    }
                    Text("Install")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(validationError == nil ? theme.accentColor : Color.gray)
                )
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .disabled(validationError != nil || isInstalling)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func validateJSON() {
        validationError = nil
        installSuccess = false

        guard let data = jsonText.data(using: .utf8) else {
            validationError = "Invalid UTF-8 text"
            return
        }

        do {
            let plugin = try JSONDecoder().decode(SandboxPlugin.self, from: data)
            if plugin.name.isEmpty {
                validationError = "Plugin name is required"
            } else if plugin.description.isEmpty {
                validationError = "Plugin description is required"
            }
        } catch {
            validationError = "JSON parse error: \(error.localizedDescription)"
        }
    }

    private func installPlugin() async {
        guard let data = jsonText.data(using: .utf8) else { return }
        isInstalling = true
        defer { isInstalling = false }

        do {
            try await SandboxPluginManager.shared.install(jsonData: data, for: agentId)
            installSuccess = true
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}

// MARK: - Sample JSON

private let samplePluginJSON = """
{
  "name": "My Plugin",
  "description": "Description of what this plugin does",
  "version": "1.0.0",

  "dependencies": [],

  "setup": "",

  "tools": [
    {
      "id": "my_tool",
      "description": "What this tool does",
      "parameters": {
        "input": { "type": "string", "description": "Input parameter" }
      },
      "run": "echo \\"Hello $PARAM_INPUT\\""
    }
  ]
}
"""
