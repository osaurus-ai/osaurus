//
//  DirectoryPickerView.swift
//  osaurus
//
//  Created by Kamil Andrusz on 8/22/25.
//

import SwiftUI

/// View for selecting and managing the models directory
struct DirectoryPickerView: View {
    @ObservedObject private var directoryPicker = DirectoryPickerService.shared
    @Environment(\.theme) private var theme
    @State private var showFilePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            // Directory display field with theme styling
            HStack(spacing: theme.space.s12) {
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    Text(directoryDisplayText)
                        .font(SettingsFont.mono)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if directoryPicker.hasValidDirectory {
                        Text("Custom directory selected", bundle: .module)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.secondary)
                    } else {
                        Text("Using default location", bundle: .module)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                    }
                }

                Spacer()

                HStack(spacing: theme.space.s6) {
                    SettingsIconButton(
                        "folder.badge.gearshape",
                        help: "Select custom directory",
                        size: .compact
                    ) {
                        showFilePicker = true
                    }

                    if directoryPicker.hasValidDirectory {
                        SettingsIconButton(
                            "arrow.counterclockwise",
                            help: "Reset to default directory",
                            size: .compact
                        ) {
                            directoryPicker.resetDirectory()
                        }
                    }
                }
            }
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s8)
            .settingsChrome(.control)

            // Help text
            Text("Models will be organized in subfolders by repository name", bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    directoryPicker.saveDirectoryFromFilePicker(url)
                }
            case .failure(let error):
                print("Directory selection failed: \(error)")
            }
        }
    }

    private var directoryDisplayText: String {
        if directoryPicker.hasValidDirectory,
            let selectedDirectory = directoryPicker.selectedDirectory
        {
            return selectedDirectory.path
        } else {
            // Show effective default (env override, old default if exists, else new default)
            let defaultURL = DirectoryPickerService.shared.effectiveModelsDirectory
            return defaultURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        DirectoryPickerView()
    }
#endif
