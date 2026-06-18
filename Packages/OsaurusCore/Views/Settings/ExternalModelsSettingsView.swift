//
//  ExternalModelsSettingsView.swift
//  osaurus
//
//  Settings controls for discovering and running models that already live
//  on this Mac via other tools — the Hugging Face Hub cache and LM Studio.
//  Toggling a source on/off triggers a background rescan; discovered models
//  appear in the catalog and run in place (never copied or modified).
//

import SwiftUI

struct ExternalModelsSettingsView: View {
    @Environment(\.theme) private var theme

    @AppStorage(ExternalModelLocator.importHFCacheDefaultsKey)
    private var importHFCache: Bool = true

    @AppStorage(ExternalModelLocator.importLMStudioDefaultsKey)
    private var importLMStudio: Bool = true

    @AppStorage(ExternalModelLocator.customHFCachePathDefaultsKey)
    private var customHFCachePath: String = ""

    @State private var hfCount: Int = 0
    @State private var lmStudioCount: Int = 0
    @State private var scanReport: ExternalModelLocator.ScanReport?
    @State private var isScanning: Bool = false
    @State private var showHFCachePicker: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Discover and run models already on this Mac from other tools. Osaurus references these files in place and never copies, modifies, or deletes them.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            SettingsToggle(
                title: L("Hugging Face cache"),
                description:
                    "Use MLX models from ~/.cache/huggingface (and HF_HOME / HF_HUB_CACHE).",
                badge: importHFCache && hfCount > 0 ? "\(hfCount)" : nil,
                isOn: $importHFCache
            )

            if importHFCache {
                hfCachePathControl
            }

            SettingsToggle(
                title: L("LM Studio"),
                description: "Use safetensors models from your LM Studio library.",
                badge: importLMStudio && lmStudioCount > 0 ? "\(lmStudioCount)" : nil,
                isOn: $importLMStudio
            )

            HStack(spacing: 8) {
                if isScanning {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text("Scanning…", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                } else {
                    Text("\(hfCount + lmStudioCount) external models found", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }

                Spacer()

                Button(
                    action: { rescan() },
                    label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Rescan", bundle: .module)
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                )
                .buttonStyle(PlainButtonStyle())
                .disabled(isScanning)
            }

            if let scanReport, !scanReport.skipped.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.warningColor)
                        Text("\(scanReport.skipped.count) external candidate(s) skipped", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                    }

                    ForEach(Array(scanReport.skipped.prefix(3).enumerated()), id: \.offset) { _, item in
                        Text(skippedSummary(item))
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
        }
        .onAppear { refreshCounts() }
        .onChange(of: importHFCache) { _, _ in rescan() }
        .onChange(of: importLMStudio) { _, _ in rescan() }
        .onChange(of: customHFCachePath) { _, _ in refreshCounts() }
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            refreshCounts()
        }
        .fileImporter(
            isPresented: $showHFCachePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                customHFCachePath = url.path
                rescan()
            }
        }
    }

    private var hfCachePathControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HF cache path", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)

            HStack(spacing: 8) {
                TextField(defaultHFCacheDisplayPath, text: $customHFCachePath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .onSubmit { rescan() }

                Button(
                    action: { showHFCachePicker = true },
                    label: {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                )
                .buttonStyle(.plain)
                .localizedHelp("Choose Hugging Face cache folder")

                if !customHFCachePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(
                        action: {
                            customHFCachePath = ""
                            rescan()
                        },
                        label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 22, height: 22)
                        }
                    )
                    .buttonStyle(.plain)
                    .localizedHelp("Use default Hugging Face cache locations")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )

            Text(
                "Empty scans HF_HUB_CACHE, HF_HOME/hub, and ~/.cache/huggingface/hub.",
                bundle: .module
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 8)
    }

    private func refreshCounts() {
        let models = ExternalModelLocator.models()
        scanReport = ExternalModelLocator.lastScanReport()
        hfCount =
            models.filter {
                $0.externalSource == ExternalModelLocator.Source.huggingFaceCache.rawValue
            }.count
        lmStudioCount =
            models.filter {
                $0.externalSource == ExternalModelLocator.Source.lmStudio.rawValue
            }.count
    }

    private func rescan() {
        guard !isScanning else { return }
        isScanning = true
        Task.detached(priority: .utility) {
            ExternalModelLocator.rescan()
            await MainActor.run {
                self.isScanning = false
                self.refreshCounts()
            }
        }
    }

    private func skippedSummary(_ item: ExternalModelLocator.Skipped) -> String {
        let name = item.repoId ?? URL(fileURLWithPath: item.path).lastPathComponent
        return "\(name): \(item.reason.title)"
    }

    private var defaultHFCacheDisplayPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
            .path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
