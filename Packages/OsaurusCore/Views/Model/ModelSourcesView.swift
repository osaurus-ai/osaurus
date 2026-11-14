//
//  ModelSourcesView.swift
//  osaurus
//
//  Models → Local Models → Sources: where Osaurus keeps the models it
//  downloads, and which other apps' models (Hugging Face cache, LM Studio)
//  it may run in place. Pushed from the Local Models header.
//

import SwiftUI

struct ModelSourcesView: View {
    /// Search landings that live on this page; Local Models opens it for them.
    static let anchorIds: Set<String> = ["storage.location", "storage.externalModels"]

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Model Sources",
                subtitle: "Where Osaurus keeps its models, and which other apps' models it can use"
            )
        } content: {
            SettingsSection(
                title: "Models Folder",
                subtitle: "Where Osaurus downloads and stores its own models.",
                anchorId: "storage.location"
            ) {
                DirectoryPickerView()
            }

            SettingsSection(
                title: "Use Models Already on This Mac",
                subtitle:
                    "Choose which other apps' models appear in your catalog. Files are referenced in place and never copied, modified, or deleted.",
                anchorId: "storage.externalModels"
            ) {
                ExternalModelsSettingsView()
            }
        }
    }
}
