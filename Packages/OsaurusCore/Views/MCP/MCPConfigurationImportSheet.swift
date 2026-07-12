//
//  MCPConfigurationImportSheet.swift
//  OsaurusCore
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MCPConfigurationImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeManager = ThemeManager.shared

    let onApply: (MCPImportedServerConfiguration) -> Void

    @State private var jsonText = ""
    @State private var servers: [MCPImportedServerConfiguration] = []
    @State private var selectedServerID: String?
    @State private var errorMessage: String?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sourceSection
                    if let errorMessage {
                        errorBanner(errorMessage)
                    }
                    if !servers.isEmpty {
                        previewSection
                    }
                }
                .padding(20)
            }
            footer
        }
        .frame(width: 560, height: 620)
        .background(theme.primaryBackground)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(theme.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import MCP Configuration", bundle: .module)
                    .font(.system(size: 16, weight: .semibold))
                Text("Review a server before adding it", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .localizedHelp("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(theme.secondaryBackground)
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MCP JSON", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: chooseFile) {
                    Label {
                        Text("Choose JSON", bundle: .module)
                    } icon: {
                        Image(systemName: "folder")
                    }
                }
                .buttonStyle(.borderless)
            }

            TextEditor(text: $jsonText)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 118, maxHeight: 150)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.tertiaryBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.primaryBorder, lineWidth: 1)
                        )
                )

            HStack {
                Spacer()
                Button("Preview", action: parseText)
                    .buttonStyle(.borderedProminent)
                    .disabled(jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if servers.count > 1 {
                Picker("Server", selection: selectedServerBinding) {
                    ForEach(servers) { server in
                        Text(server.name).tag(server.id)
                    }
                }
                .pickerStyle(.menu)
            }

            ForEach($servers) { $server in
                if server.id == selectedServerID {
                    serverPreview($server)
                }
            }
        }
    }

    private func serverPreview(
        _ server: Binding<MCPImportedServerConfiguration>
    ) -> some View {
        let value = server.wrappedValue
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text(value.transport == .stdio ? "Stdio" : (value.streamingEnabled ? "HTTP / SSE" : "HTTP"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                Button {
                    copyReporterSummary(value.reporterSafeSummary)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .localizedHelp("Copy import summary")
                if value.referencesHostPaths {
                    Label {
                        Text("Host paths", bundle: .module)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)
                }
            }

            if value.transport == .stdio {
                previewValue("Command", value: value.command)
                if !value.args.isEmpty {
                    previewValue("Arguments", value: ShellArgs.join(value.args))
                }
                if let workingDirectory = value.workingDirectory {
                    previewValue("Working Directory", value: workingDirectory)
                }
                fieldClassification(title: "Environment", fields: server.environment)
            } else {
                previewValue(
                    "URL",
                    value: MCPProviderProbeRedactor.safeHTTPURLForDiagnostics(value.url)
                )
                fieldClassification(title: "Headers", fields: server.headers)
            }

            ForEach(value.warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.primaryBorder, lineWidth: 1)
                )
        )
    }

    private func previewValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fieldClassification(
        title: String,
        fields: Binding<[MCPImportedConfigurationField]>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !fields.wrappedValue.isEmpty {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                ForEach(fields) { $field in
                    HStack {
                        Text(field.key)
                            .font(.system(size: 11, design: .monospaced))
                        Spacer()
                        Toggle("Secret", isOn: $field.isSecret)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10))
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundColor(theme.errorColor)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.errorColor.opacity(0.08))
    }

    private var footer: some View {
        HStack {
            Button(
                action: { dismiss() },
                label: { Text("Cancel", bundle: .module) }
            )
                .buttonStyle(.borderless)
            Spacer()
            Button {
                guard let server = selectedServer else { return }
                onApply(server)
                dismiss()
            } label: {
                Text("Use Configuration", bundle: .module)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedServer == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.secondaryBackground)
    }

    private var selectedServer: MCPImportedServerConfiguration? {
        servers.first { $0.id == selectedServerID }
    }

    private var selectedServerBinding: Binding<String> {
        Binding(
            get: { selectedServerID ?? servers.first?.id ?? "" },
            set: { selectedServerID = $0 }
        )
    }

    private func parseText() {
        parse(Data(jsonText.utf8))
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw MCPConfigurationImportFailure(
                    reason: .invalidField,
                    message: "Choose a regular JSON file."
                )
            }
            guard let fileSize = values.fileSize,
                fileSize <= MCPConfigurationImportService.maximumBytes
            else {
                throw MCPConfigurationImportFailure(
                    reason: .oversized,
                    message: "The MCP configuration is larger than 256 KB."
                )
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(
                upToCount: MCPConfigurationImportService.maximumBytes + 1
            ) ?? Data()
            jsonText = String(data: data, encoding: .utf8) ?? ""
            parse(data)
        } catch {
            servers = []
            selectedServerID = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "The file could not be read."
        }
    }

    private func parse(_ data: Data) {
        do {
            let parsed = try MCPConfigurationImportService.parse(data)
            servers = parsed
            selectedServerID = parsed.first?.id
            errorMessage = nil
        } catch {
            servers = []
            selectedServerID = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "The MCP configuration could not be imported."
        }
    }

    private func copyReporterSummary(_ summary: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
    }
}
