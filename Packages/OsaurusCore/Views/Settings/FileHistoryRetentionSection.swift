//
//  FileHistoryRetentionSection.swift
//  osaurus
//
//  Settings card for how long per-chat file change history (the snapshots
//  behind Revert / `file_undo`) is kept. Lives on Privacy → Storage.
//

import SwiftUI

struct FileHistoryRetentionSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var retention: FileHistoryRetention = ChatConfigurationStore.load().fileHistoryRetention
    @State private var storedBytes: Int64?

    static let ageChoices: [Int?] = [nil, 90, 30]
    /// Decimal gigabytes so the menu reads "20 GB", matching how the size
    /// formatter (and Finder) label bytes — `20 << 30` renders as "21.47 GB".
    static let gigabyte: Int64 = 1_000_000_000
    static let sizeChoices: [Int64?] = [nil, 20 * gigabyte, 5 * gigabyte, 1 * gigabyte]

    var body: some View {
        SettingsSection(title: "File History", icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "Every file an agent creates, edits, or deletes is snapshotted so it can be reverted from the chat's File Changes panel. Older history can be cleared automatically; history you remove can no longer be reverted.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                SettingsField(
                    label: "Keep File History",
                    hint: "Deleting a chat always deletes its file history.",
                    anchorId: "storage.fileHistory.retention"
                ) {
                    Picker("", selection: ageBinding) {
                        ForEach(Self.ageChoices, id: \.self) { days in
                            Text(Self.ageLabel(days)).tag(days)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                }

                SettingsField(
                    label: "File History Size Limit",
                    hint: usageHint,
                    anchorId: "storage.fileHistory.sizeLimit"
                ) {
                    Picker("", selection: sizeBinding) {
                        ForEach(Self.sizeChoices, id: \.self) { bytes in
                            Text(Self.sizeLabel(bytes)).tag(bytes)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                }
            }
        }
        .task { await refreshUsage() }
        .onReceive(NotificationCenter.default.publisher(for: .fileChangesDidChange)) { _ in
            Task { await refreshUsage() }
        }
    }

    private var usageHint: String {
        let base = L("Past the limit, the oldest changes are cleared first; the most recent change is always kept.")
        guard let storedBytes else { return base }
        let used = ByteCountFormatter.string(fromByteCount: storedBytes, countStyle: .file)
        return base + " " + L("Currently using \(used).")
    }

    private var ageBinding: Binding<Int?> {
        Binding(
            get: { retention.maxAgeDays },
            set: { retention.maxAgeDays = $0; save() }
        )
    }

    private var sizeBinding: Binding<Int64?> {
        Binding(
            get: { retention.maxBytes },
            set: { retention.maxBytes = $0; save() }
        )
    }

    private func save() {
        var config = ChatConfigurationStore.load()
        config.fileHistoryRetention = retention
        ChatConfigurationStore.save(config)
        let policy = retention
        Task {
            await FileChangeJournal.shared.performMaintenance(policy)
            await refreshUsage()
        }
    }

    private func refreshUsage() async {
        storedBytes = await FileChangeJournal.shared.storedBytes()
    }

    static func ageLabel(_ days: Int?) -> String {
        guard let days else { return L("Until the chat is deleted") }
        return L("For \(days) days")
    }

    static func sizeLabel(_ bytes: Int64?) -> String {
        guard let bytes else { return L("No limit") }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
