//
//  ManagementView.swift
//  osaurus
//
//  Combines Models and Tools management into a modern sidebar-based UI.
//

import AppKit
import Foundation
import OsaurusRepository
import SwiftUI

enum ManagementTab: String, CaseIterable {
    case models
    case tools
    case insights
    case settings

    var icon: String {
        switch self {
        case .models: return "cube.box.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .insights: return "chart.bar.doc.horizontal"
        case .settings: return "gearshape.fill"
        }
    }

    var label: String {
        switch self {
        case .models: return "Models"
        case .tools: return "Tools"
        case .insights: return "Insights"
        case .settings: return "Settings"
        }
    }
}

struct ManagementView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var repoService = PluginRepositoryService.shared
    @Environment(\.theme) private var theme

    @State private var selectedTab: String
    @State private var hasAppeared = false

    var deeplinkModelId: String?
    var deeplinkFile: String?

    init(
        initialTab: ManagementTab = .models,
        deeplinkModelId: String? = nil,
        deeplinkFile: String? = nil
    ) {
        _selectedTab = State(initialValue: initialTab.rawValue)
        self.deeplinkModelId = deeplinkModelId
        self.deeplinkFile = deeplinkFile
    }

    private var sidebarItems: [SidebarItemData] {
        [
            SidebarItemData(
                id: ManagementTab.models.rawValue,
                icon: ManagementTab.models.icon,
                label: ManagementTab.models.label
            ),
            SidebarItemData(
                id: ManagementTab.tools.rawValue,
                icon: ManagementTab.tools.icon,
                label: ManagementTab.tools.label,
                badge: repoService.updatesAvailableCount > 0 ? repoService.updatesAvailableCount : nil
            ),
            SidebarItemData(
                id: ManagementTab.insights.rawValue,
                icon: ManagementTab.insights.icon,
                label: ManagementTab.insights.label
            ),
            SidebarItemData(
                id: ManagementTab.settings.rawValue,
                icon: ManagementTab.settings.icon,
                label: ManagementTab.settings.label
            ),
        ]
    }

    var body: some View {
        SidebarNavigation(
            selection: $selectedTab,
            items: sidebarItems
        ) { selected in
            Group {
                switch selected {
                case ManagementTab.models.rawValue:
                    ModelDownloadView(
                        deeplinkModelId: deeplinkModelId,
                        deeplinkFile: deeplinkFile
                    )
                case ManagementTab.tools.rawValue:
                    ToolsManagerView()
                case ManagementTab.insights.rawValue:
                    InsightsView()
                case ManagementTab.settings.rawValue:
                    ConfigurationView()
                default:
                    Text("Unknown tab")
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(minWidth: 900, minHeight: 640)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            // Slight delay to prevent initial layout jank
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeOut(duration: 0.2)) {
                    hasAppeared = true
                }
            }
        }
    }
}

#Preview {
    ManagementView()
}
