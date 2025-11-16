//
//  ManagementView.swift
//  osaurus
//
//  Combines Models and Tools management into a single tabbed UI.
//

import AppKit
import Foundation
import SwiftUI

enum ManagementTab: Hashable {
    case models
    case tools
}

struct ManagementView: View {
    @State private var selectedTab: ManagementTab
    var deeplinkModelId: String?
    var deeplinkFile: String?

    init(
        initialTab: ManagementTab = .models,
        deeplinkModelId: String? = nil,
        deeplinkFile: String? = nil
    ) {
        _selectedTab = State(initialValue: initialTab)
        self.deeplinkModelId = deeplinkModelId
        self.deeplinkFile = deeplinkFile
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ModelDownloadView(
                deeplinkModelId: deeplinkModelId,
                deeplinkFile: deeplinkFile
            )
            .tabItem { Label("Models", systemImage: "cube.box") }
            .tag(ManagementTab.models)

            ToolsManagerView()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .tag(ManagementTab.tools)
        }
    }
}

#Preview {
    ManagementView()
}
