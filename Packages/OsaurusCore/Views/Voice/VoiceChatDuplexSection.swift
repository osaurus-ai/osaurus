//
//  VoiceChatDuplexSection.swift
//  OsaurusCore
//
//  UI for the full-duplex speech-to-speech host. Pick a VoiceChat bundle,
//  give it audio, hear it answer — and see the measurements that say whether
//  what came back is speech rather than silence or noise.
//

import AppKit
import SwiftUI

struct VoiceChatDuplexSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var duplex = VoiceChatDuplexService.shared

    @State private var bundles: [URL] = []
    @State private var selectedBundle: URL?
    @State private var audioFile: URL?
    @State private var seconds: Double = 3.0

    var body: some View {
        SettingsSection(title: "Speech to Speech", icon: "waveform.badge.mic") {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "A duplex model listens and speaks on one clock instead of transcribing, thinking, then reading aloud.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

                bundlePicker
                audioPicker
                durationControl
                runControls
                statusArea
                if !duplex.history.isEmpty { historyArea }
            }
        }
        .onAppear(perform: refreshBundles)
    }

    // MARK: - Controls

    private var bundlePicker: some View {
        HStack(spacing: 8) {
            Text("Model", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 70, alignment: .leading)
            if bundles.isEmpty {
                Text("No speech-to-speech models found", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            } else {
                Picker("", selection: $selectedBundle) {
                    ForEach(bundles, id: \.self) { bundle in
                        Text(bundle.lastPathComponent).tag(Optional(bundle))
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("voicechat-bundle-picker")
            }
            Button(L("Rescan")) { refreshBundles() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("voicechat-rescan")
        }
    }

    private var audioPicker: some View {
        HStack(spacing: 8) {
            Text("Audio", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 70, alignment: .leading)
            Button(audioFile == nil ? L("Choose Audio…") : L("Change Audio…")) {
                chooseAudioFile()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("voicechat-choose-audio")
            if let audioFile {
                Text(audioFile.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var durationControl: some View {
        HStack(spacing: 8) {
            Text("Seconds", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 70, alignment: .leading)
            Slider(value: $seconds, in: 1 ... 10, step: 0.5)
                .frame(width: 180)
                .accessibilityIdentifier("voicechat-seconds")
            Text(String(format: "%.1f", seconds))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.secondaryText)
        }
    }

    private var runControls: some View {
        HStack(spacing: 8) {
            Button(L("Speak to Model")) { runTurn() }
                .buttonStyle(.borderedProminent)
                .disabled(selectedBundle == nil || audioFile == nil || duplex.isBusy)
                .accessibilityIdentifier("voicechat-run-turn")

            if duplex.loadedBundleName != nil {
                Button(L("Unload")) { duplex.unload() }
                    .buttonStyle(.bordered)
                    .disabled(duplex.isBusy)
                    .accessibilityIdentifier("voicechat-unload")
            }
        }
    }

    private var statusArea: some View {
        Group {
            switch duplex.state {
            case .idle:
                Text("Idle", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            case .loading(let name):
                Label(String(format: L("Loading %@…"), name), systemImage: "arrow.down.circle")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            case .running(let name):
                Label(String(format: L("%@ is listening…"), name), systemImage: "waveform")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            case .finished(let report):
                Text(report.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .accessibilityIdentifier("voicechat-result")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(theme.errorColor)
                    .accessibilityIdentifier("voicechat-error")
            }
        }
    }

    private var historyArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This session", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
            ForEach(Array(duplex.history.enumerated()), id: \.offset) { index, report in
                Text("\(index + 1). \(report.bundleName) — \(report.summary)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("voicechat-history-\(index)")
            }
        }
    }

    // MARK: - Actions

    private func refreshBundles() {
        let root = DirectoryPickerService.effectiveModelsDirectory()
        bundles = VoiceChatDuplexService.availableBundles(in: root)
        if selectedBundle == nil || !bundles.contains(selectedBundle!) {
            selectedBundle = bundles.first
        }
    }

    /// AppKit `NSOpenPanel` rather than SwiftUI `.fileImporter`, matching the
    /// rest of Settings — the SwiftUI importer misbehaves in this window's
    /// presentation context.
    private func chooseAudioFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url {
            audioFile = url
        }
    }

    private func runTurn() {
        guard let bundle = selectedBundle, let audioFile else { return }
        Task {
            await duplex.runTurn(bundle: bundle, audioFile: audioFile, seconds: seconds)
        }
    }
}
