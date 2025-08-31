//
//  DirectoryPickerView.swift
//  osaurus
//
//  Created by Kamil Andrusz on 8/22/25.
//

import SwiftUI

/// View for selecting and managing the models directory
struct DirectoryPickerView: View {
    @StateObject private var directoryPicker = DirectoryPickerService.shared
    @Environment(\.theme) private var theme
    @State private var showFilePicker = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Directory display field with theme styling
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(directoryDisplayText)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    if directoryPicker.hasValidDirectory {
                        Text("Custom directory selected")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                    } else {
                        Text("Using default location")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
                
                Spacer()
                
                // Action buttons with consistent styling
                HStack(spacing: 6) {
                    Button(action: {
                        showFilePicker = true
                    }) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 12))
                            .foregroundColor(theme.primaryText)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(theme.buttonBackground)
                                    .overlay(
                                        Circle()
                                            .stroke(theme.buttonBorder, lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Select custom directory")
                    
                    if directoryPicker.hasValidDirectory {
                        Button(action: {
                            directoryPicker.resetDirectory()
                        }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 12))
                                .foregroundColor(theme.primaryText)
                                .frame(width: 24, height: 24)
                                .background(
                                    Circle()
                                        .fill(theme.buttonBackground)
                                        .overlay(
                                            Circle()
                                                .stroke(theme.buttonBorder, lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Reset to default directory")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
            
            // Help text
            Text("Models will be organized in subfolders by repository name")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
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
           let selectedDirectory = directoryPicker.selectedDirectory {
            return selectedDirectory.path
        } else {
            // Show effective default (env override, old default if exists, else new default)
            let defaultURL = DirectoryPickerService.shared.effectiveModelsDirectory
            return defaultURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }
}

#Preview {
    DirectoryPickerView()
}
