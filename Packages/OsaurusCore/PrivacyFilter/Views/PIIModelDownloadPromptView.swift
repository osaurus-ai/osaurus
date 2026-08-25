//
//  PIIModelDownloadPromptView.swift
//  osaurus
//
//  Modal card presented when an agent tool (`detect_pii` / `redact_file`)
//  needs a PII model and none is installed. Recommends the ~37MB Rampart
//  bundle, drives `RampartModelManager` with its aggregated progress, and
//  resolves the suspended tool call on completion or decline. Presented
//  through `ToolPermissionPromptService.requestPIIModelDownload()`.
//

import SwiftUI

struct PIIModelDownloadPromptView: View {
    @ObservedObject private var manager = RampartModelManager.shared

    let onInstalled: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 22, weight: .medium))
                Text("Install PII detection model?")
                    .font(.headline)
            }

            Text(
                "This task detects personal information (names, addresses) with an on-device model. Installing the recommended model (37 MB) takes a few seconds and runs fully offline. Without it, only pattern-based detection (emails, phone numbers) is available."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            switch manager.state {
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                    Text("Downloading, \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text("Download failed: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .ready:
                EmptyView()
            }

            HStack {
                Spacer()
                Button("Not Now") { onDecline() }
                    .keyboardShortcut(.cancelAction)
                switch manager.state {
                case .downloading:
                    Button("Install") {}
                        .disabled(true)
                case .failed:
                    Button("Retry") { manager.startDownload() }
                        .keyboardShortcut(.defaultAction)
                default:
                    Button("Install") { manager.startDownload() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: manager.state) { _, newState in
            if newState == .ready { onInstalled() }
        }
        .onAppear {
            // Belt and braces: if the bundle appeared between the tool's
            // availability check and presentation, resolve immediately.
            if manager.state == .ready { onInstalled() }
        }
    }
}
