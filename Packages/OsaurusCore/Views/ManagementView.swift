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
    case skills
    case personas
    case schedules
    case voice
    case themes
    case insights
    case server
    case permissions
    case settings

    var icon: String {
        switch self {
        case .models: return "cube.box.fill"
        case .providers: return "cloud.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .skills: return "sparkles"
        case .personas: return "person.2.fill"
        case .schedules: return "calendar.badge.clock"
        case .voice: return "waveform"
        case .themes: return "paintpalette.fill"
        case .insights: return "chart.bar.doc.horizontal"
        case .server: return "server.rack"
        case .permissions: return "lock.shield.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var label: String {
        switch self {
        case .models: return "Models"
        case .providers: return "Providers"
        case .tools: return "Tools"
        case .skills: return "Skills"
        case .personas: return "Personas"
        case .schedules: return "Schedules"
        case .voice: return "Voice"
        case .themes: return "Themes"
        case .insights: return "Insights"
        case .server: return "Server"
        case .permissions: return "Permissions"
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

    @StateObject private var personaManager = PersonaManager.shared

    @StateObject private var skillManager = SkillManager.shared

    private var sidebarItems: [SidebarItemData] {
        let connectedProviders = remoteProviderManager.providerStates.values.filter { $0.isConnected }.count
        let customThemeCount = themeManager.installedThemes.filter { !$0.isBuiltIn }.count
        let customPersonaCount = personaManager.personas.filter { !$0.isBuiltIn }.count
        let enabledSkillCount = skillManager.enabledCount

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
                id: ManagementTab.skills.rawValue,
                icon: ManagementTab.skills.icon,
                label: ManagementTab.skills.label,
                badge: enabledSkillCount > 0 ? enabledSkillCount : nil
            ),
            SidebarItemData(
                id: ManagementTab.personas.rawValue,
                icon: ManagementTab.personas.icon,
                label: ManagementTab.personas.label,
                badge: customPersonaCount > 0 ? customPersonaCount : nil
            ),
            SidebarItemData(
                id: ManagementTab.schedules.rawValue,
                icon: ManagementTab.schedules.icon,
                label: ManagementTab.schedules.label,
                badge: ScheduleManager.shared.schedules.isEmpty ? nil : ScheduleManager.shared.schedules.count
            ),
            SidebarItemData(
                id: ManagementTab.voice.rawValue,
                icon: ManagementTab.voice.icon,
                label: ManagementTab.voice.label
            ),
            SidebarItemData(
                id: ManagementTab.themes.rawValue,
                icon: ManagementTab.themes.icon,
                label: ManagementTab.themes.label,
                badge: customThemeCount > 0 ? customThemeCount : nil
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
                id: ManagementTab.permissions.rawValue,
                icon: ManagementTab.permissions.icon,
                label: ManagementTab.permissions.label
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
                case ManagementTab.skills.rawValue:
                    SkillsView()
                case ManagementTab.personas.rawValue:
                    PersonasView()
                case ManagementTab.schedules.rawValue:
                    SchedulesView()
                case ManagementTab.voice.rawValue:
                    VoiceView()
                case ManagementTab.themes.rawValue:
                    ThemesView()
                case ManagementTab.insights.rawValue:
                    InsightsView()
                case ManagementTab.server.rawValue:
                    ServerView()
                case ManagementTab.permissions.rawValue:
                    PermissionsView()
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
        .tint(theme.accentColor)
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
