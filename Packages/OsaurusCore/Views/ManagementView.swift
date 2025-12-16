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
    case providers
    case tools
    case themes
    case insights
    case server
    case settings

    var icon: String {
        switch self {
        case .models: return "cube.box.fill"
        case .providers: return "cloud.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .themes: return "paintpalette.fill"
        case .insights: return "chart.bar.doc.horizontal"
        case .server: return "server.rack"
        case .settings: return "gearshape.fill"
        }
    }

    var label: String {
        switch self {
        case .models: return "Models"
        case .providers: return "Providers"
        case .tools: return "Tools"
        case .themes: return "Themes"
        case .insights: return "Insights"
        case .server: return "Server"
        case .settings: return "Settings"
        }
    }
}

struct ManagementView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var repoService = PluginRepositoryService.shared
    @EnvironmentObject private var updater: UpdaterViewModel

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selectedTab: String
    @State private var hasAppeared = false
    @State private var searchText: String = ""

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

    @StateObject private var remoteProviderManager = RemoteProviderManager.shared

    private var sidebarItems: [SidebarItemData] {
        let connectedProviders = remoteProviderManager.providerStates.values.filter { $0.isConnected }.count
        let customThemeCount = themeManager.installedThemes.filter { !$0.isBuiltIn }.count

        return [
            SidebarItemData(
                id: ManagementTab.models.rawValue,
                icon: ManagementTab.models.icon,
                label: ManagementTab.models.label
            ),
            SidebarItemData(
                id: ManagementTab.providers.rawValue,
                icon: ManagementTab.providers.icon,
                label: ManagementTab.providers.label,
                badge: connectedProviders > 0 ? connectedProviders : nil
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
                id: ManagementTab.server.rawValue,
                icon: ManagementTab.server.icon,
                label: ManagementTab.server.label
            ),
            SidebarItemData(
                id: ManagementTab.themes.rawValue,
                icon: ManagementTab.themes.icon,
                label: ManagementTab.themes.label,
                badge: customThemeCount > 0 ? customThemeCount : nil
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
            searchText: $searchText,
            items: sidebarItems
        ) { selected in
            Group {
                switch selected {
                case ManagementTab.models.rawValue:
                    ModelDownloadView(
                        deeplinkModelId: deeplinkModelId,
                        deeplinkFile: deeplinkFile
                    )
                case ManagementTab.providers.rawValue:
                    RemoteProvidersView()
                case ManagementTab.tools.rawValue:
                    ToolsManagerView()
                case ManagementTab.themes.rawValue:
                    ThemesView()
                case ManagementTab.insights.rawValue:
                    InsightsView()
                case ManagementTab.server.rawValue:
                    ServerView()
                case ManagementTab.settings.rawValue:
                    ConfigurationView(searchText: $searchText)
                default:
                    Text("Unknown tab")
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        } footer: {
            SidebarUpdateButton(
                updateAvailable: updater.updateAvailable,
                availableVersion: updater.availableVersion
            ) {
                updater.checkForUpdates()
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .tint(theme.selectionColor)
        .onAppear {
            // Slight delay to prevent initial layout jank
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeOut(duration: 0.2)) {
                    hasAppeared = true
                }
            }
            // Check for updates in background when view appears
            updater.checkForUpdatesInBackground()
        }
        .onChange(of: selectedTab) { _, newTab in
            // Clear search when switching away from settings
            if newTab != ManagementTab.settings.rawValue && !searchText.isEmpty {
                searchText = ""
            }
        }
        .onChange(of: searchText) { _, newValue in
            // Navigate to Settings when user starts typing in search
            if !newValue.isEmpty && selectedTab != ManagementTab.settings.rawValue {
                withAnimation(.easeOut(duration: 0.2)) {
                    selectedTab = ManagementTab.settings.rawValue
                }
            }
        }
    }
}

#Preview {
    ManagementView()
}
