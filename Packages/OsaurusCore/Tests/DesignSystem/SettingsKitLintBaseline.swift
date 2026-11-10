//
//  SettingsKitLintBaseline.swift
//  osaurusTests
//
//  Ratchet for `SettingsKitLintTests`. Every count is zero: Management views
//  use the kit. `allowlist` exempts specific files from specific rules for
//  surfaces that are not settings rows (chat-shared views, the sidebar,
//  tables, artwork). It must only shrink; do not add a file to silence a
//  new violation.
//

enum SettingsKitLintBaseline {
    static let allowlist: [String: Set<String>] = [
        // Chat-shared components (chat header, code blocks, markdown, global dialogs).
        "Views/Common/AnimatedProgressComponents.swift": ["rawTextFont"],
        "Views/Common/AnnouncementDialogContent.swift": ["handChrome", "familyThemeWrapper", "inspectionSpacing"],
        "Views/Common/InspectorSubTabBar.swift": ["capsuleFill", "adHocButton"],
        "Views/Common/SharedHeaderComponents.swift": ["capsuleFill", "uppercaseTitle", "rawTextFont", "adHocButton", "fakePopUp", "familyThemeWrapper", "inspectionSpacing"],
        "Views/Common/ThemedAlertDialog.swift": ["rawTextFont", "inspectionSpacing"],

        // Rendered in the chat window or its inspector; they follow the chat design.
        "Views/Model/ChatModelPickerCard.swift": ["rawTextInput"],  // chat model picker card
        "Views/Model/ModelPickerView.swift": ["handChrome", "capsuleFill", "uppercaseTitle", "rawTextFont", "adHocButton", "familyThemeWrapper", "inspectionSpacing"],  // chat model picker popover
        "Views/Workflow/Architect/WorkflowNodeEditor.swift": ["rawTextFont", "fakePopUp"],  // chat inspector editor
        // Floating overlays and HUDs.
        "Views/Voice/TranscriptionOverlayView.swift": ["capsuleFill", "familyThemeWrapper", "inspectionSpacing"],  // floating HUD
        "Views/Voice/VoiceInputOverlay.swift": ["familyThemeWrapper", "inspectionSpacing"],  // floating HUD
        "Views/Voice/VoiceComponents.swift": ["handChrome", "capsuleFill", "familyThemeWrapper", "inspectionSpacing"],  // waveform and HUD visuals

        // The sidebar follows the macOS source-list look.
        "Views/Management/SharedSidebarComponents.swift": ["rawTextInput", "handChrome", "capsuleFill", "rawTextFont", "adHocButton", "familyThemeWrapper", "inspectionSpacing"],  // sidebar (macOS source list)
        "Views/Management/SidebarNavigation.swift": ["rawTextInput", "handChrome", "capsuleFill", "uppercaseTitle"],  // sidebar (macOS source list)
        "Views/Settings/ServerSettings/ServerSettingsSidebarNav.swift": ["rawTextFont"],  // sidebar
        "Views/Workflow/Library/WorkflowsPaneView.swift": ["borderlessMenu"],  // sidebar list (hover ⋯ on source-list rows)
        "Views/Workflow/WorkflowRunHistoryList.swift": ["borderlessMenu"],  // sidebar list (hover ⋯ on source-list rows)

        // Tables and data grids: dense cells, not settings rows.
        "Views/Agent/CapabilitiesTableRepresentable.swift": ["capsuleFill", "adHocButton", "familyThemeWrapper", "inspectionSpacing"],  // NSTableView cells
        "Views/Agent/Database/DatabaseSavedViewsView.swift": ["rawTextFont"],  // data grid source list
        "Views/Agent/Database/DatabaseTablesView.swift": ["uppercaseTitle", "rawTextFont"],  // data grid
        "Views/Insights/InsightsDetailPane.swift": ["capsuleFill", "rawTextFont", "adHocButton"],  // log inspector
        "Views/Insights/InsightsView.swift": ["handChrome", "capsuleFill", "uppercaseTitle", "rawTextFont", "adHocButton"],  // log table
        "Views/Settings/ChannelsOverviewTable.swift": ["uppercaseTitle", "rawTextFont"],  // table header and cells

        // Illustrations, rendered artwork, and theme previews.
        "Views/Agent/AgentAvatarView.swift": ["rawTextFont"],  // avatar glyph
        "Views/Agent/Templates/AgentTemplatesIntroCard.swift": ["handChrome", "capsuleFill", "rawTextFont"],  // illustration
        "Views/Model/SystemStatusBar.swift": ["handChrome"],  // meters
        "Views/Sandbox/ProvisioningJourneyView.swift": ["rawTextFont"],  // animated journey
        "Views/Template/WorkflowShareCardView.swift": ["capsuleFill", "uppercaseTitle", "rawTextFont", "rawSystemFont", "namedColor"],  // rendered share image: fixed ink-on-paper artwork
        "Views/Workspaces/WorkspacesIntroExplainer.swift": ["handChrome", "capsuleFill", "rawTextFont"],  // illustration

        // Shared components the kit builds on.
        "Views/Common/InlineBanner.swift": ["rawTextFont"],  // shared component
        "Views/Common/SimpleComponents.swift": ["handChrome", "capsuleFill", "adHocButton"],  // shared component
        "Views/Model/ModelFavoriteButtonStyle.swift": ["handChrome"],  // ButtonStyle

        // Composite controls with no kit equivalent.
        "Views/Event/EventFormComponents.swift": ["rawTextInput", "adHocButton"],  // composite time and day entry controls

        // Documented exceptions to the design-token rules.
        "Views/Common/CategoryPalettes.swift": ["namedColor"],  // brand, category, mascot, model-family and chart-series palettes
        "Views/Onboarding/DesignSystem/OnboardingDesign.swift": ["namedColor", "rawSystemFont"],  // onboarding brand constants (dino green, comic bubble, glass highlights) and display type ramp
        "Views/DesignSystem/SettingsSearchHighlight.swift": ["themeOpacityTone", "handShadow"],  // animated focus glow on the search landing target
    ]

    static let counts: [String: [String: Int]] = [
        "handChrome": [
            "Views/Event/EventFormComponents.swift": 1,
            "Views/Voice/TranscriptionOverlayView.swift": 2,
        ],
        "rawDatePicker": [
            "Views/Event/EventFormComponents.swift": 1,
        ],
        "systemButtonStyle": [
            "Views/Agent/Database/DatabaseTablesView.swift": 1,
        ],
        "rawSheetClose": [
            "Views/Common/ThemedAlertDialog.swift": 1,
            "Views/Voice/VoiceComponents.swift": 1,
        ],
        "rawPadding": [
            "Views/Agent/CapabilitiesTableRepresentable.swift": 1,
            "Views/Common/AnnouncementDialogContent.swift": 1,
            "Views/Common/InspectorSubTabBar.swift": 1,
            "Views/Common/ThemedAlertDialog.swift": 5,
            "Views/Management/SharedSidebarComponents.swift": 4,
            "Views/Management/SidebarNavigation.swift": 16,
            "Views/Model/ChatModelPickerCard.swift": 5,
            "Views/Model/ModelPickerView.swift": 10,
            "Views/Settings/ProvidersView.swift": 1,
            "Views/Voice/HotkeyRecorder.swift": 2,
            "Views/Voice/TranscriptionOverlayView.swift": 2,
            "Views/Voice/VoiceComponents.swift": 1,
            "Views/Voice/VoiceInputOverlay.swift": 2,
            "Views/Workflow/Architect/WorkflowNodeEditor.swift": 8,
            "Views/Workspaces/WorkspacesIntroExplainer.swift": 2,
        ],
        "rawFixedWidth": [
            "PrivacyFilter/Views/PIIModelDownloadPromptView.swift": 1,
            "PrivacyFilter/Views/PrivacyCustomRuleEditor.swift": 2,
            "PrivacyFilter/Views/PrivacyPresetRulesSection.swift": 3,
            "PrivacyFilter/Views/RedactionReviewSheet.swift": 2,
            "Views/Agent/AgentAbilitiesOverviewView.swift": 2,
            "Views/Agent/AgentCapabilityManagerView.swift": 1,
            "Views/Agent/AgentDetailChrome.swift": 1,
            "Views/Agent/AgentsView.swift": 15,
            "Views/Agent/BuiltInAgentAvatarPicker.swift": 1,
            "Views/Agent/CapabilitiesTableRepresentable.swift": 5,
            "Views/Agent/Database/DatabaseOverviewView.swift": 1,
            "Views/Agent/Database/DatabaseSavedViewsView.swift": 1,
            "Views/Agent/Database/DatabaseSharedUI.swift": 1,
            "Views/Agent/Database/DatabaseTablesView.swift": 3,
            "Views/Agent/NextRunPanelView.swift": 1,
            "Views/Agent/RemoteAgentViews.swift": 1,
            "Views/Agent/Setup/AgentSetupWizardView.swift": 2,
            "Views/Agent/ShareAgentSheet.swift": 1,
            "Views/Agent/SpawnConfigurationEditor.swift": 4,
            "Views/Agent/Templates/AgentTemplateSheets.swift": 2,
            "Views/Agent/Templates/AgentTemplatesIntroCard.swift": 4,
            "Views/Common/AnimatedProgressComponents.swift": 2,
            "Views/Common/InlineBanner.swift": 1,
            "Views/Common/InspectorSubTabBar.swift": 2,
            "Views/Common/PickerCardStyle.swift": 1,
            "Views/Common/SimpleComponents.swift": 3,
            "Views/Common/ThemedAlertDialog.swift": 4,
            "Views/Credits/CreditsView.swift": 1,
            "Views/Event/AutomationHistoryView.swift": 1,
            "Views/Event/ChannelRoutingSection.swift": 8,
            "Views/Event/EventDetailView.swift": 5,
            "Views/Event/EventEditorSheet.swift": 1,
            "Views/Event/EventFormComponents.swift": 11,
            "Views/Identity/AgentKeyManagement.swift": 2,
            "Views/Identity/IdentityView.swift": 2,
            "Views/Identity/LoginConsentView.swift": 2,
            "Views/Identity/MasterMnemonicCard.swift": 1,
            "Views/Identity/RecoverFromMnemonicSheet.swift": 1,
            "Views/Identity/SignInWithOsaurusSection.swift": 1,
            "Views/Insights/InsightsDetailPane.swift": 4,
            "Views/Insights/InsightsView.swift": 10,
            "Views/Knowledge/KnowledgeView.swift": 3,
            "Views/Management/SharedSidebarComponents.swift": 2,
            "Views/Management/SidebarNavigation.swift": 6,
            "Views/Memory/MemoryComponents.swift": 5,
            "Views/Memory/MemoryDiagnosticsViews.swift": 3,
            "Views/Memory/MemoryManagementConsoleView.swift": 6,
            "Views/Memory/MemoryView.swift": 1,
            "Views/Model/ChatModelPickerCard.swift": 1,
            "Views/Model/ChatModelPickerPreviews.swift": 1,
            "Views/Model/CloudModelBrowserDialog.swift": 2,
            "Views/Model/HuggingFaceTokenViews.swift": 2,
            "Views/Model/ModelCacheInspectorView.swift": 2,
            "Views/Model/ModelDetailView.swift": 3,
            "Views/Model/ModelPickerView.swift": 8,
            "Views/Plugin/ClaudeMarketplaceDetailView.swift": 3,
            "Views/Plugin/ClaudePluginDetailView.swift": 4,
            "Views/Plugin/GitHubImportSheet.swift": 14,
            "Views/Plugin/GitHubTokenViews.swift": 2,
            "Views/Plugin/MCPElicitationView.swift": 2,
            "Views/Plugin/PluginsView.swift": 2,
            "Views/Plugin/ToolPermissionView.swift": 1,
            "Views/Provider/ProviderCredentialPromptSheet.swift": 4,
            "Views/Router/RouterAccountUsageCenterView.swift": 4,
            "Views/Sandbox/ProvisioningJourneyView.swift": 2,
            "Views/Sandbox/SandboxView.swift": 6,
            "Views/Settings/AgentChannelAuditRows.swift": 2,
            "Views/Settings/AgentChannelConnectionCenterView.swift": 1,
            "Views/Settings/AgentChannelCustomConnectionSheet.swift": 1,
            "Views/Settings/AgentChannelDestinationViews.swift": 5,
            "Views/Settings/AgentChannelSettingsComponents.swift": 6,
            "Views/Settings/AgentChannelTransportHealthView.swift": 3,
            "Views/Settings/BrowserSettingsView.swift": 3,
            "Views/Settings/ChannelsOverviewTable.swift": 3,
            "Views/Settings/ClaudeCodeSetupStep.swift": 2,
            "Views/Settings/ComputerUseSettingsView.swift": 3,
            "Views/Settings/ConfigurationView.swift": 2,
            "Views/Settings/ExternalModelsSettingsView.swift": 1,
            "Views/Settings/IMessageSettingsView.swift": 2,
            "Views/Settings/N8nSettingsView.swift": 1,
            "Views/Settings/OrchestratorSupportSections.swift": 1,
            "Views/Settings/ProviderDiagnosticsRowsView.swift": 2,
            "Views/Settings/ProvidersView.swift": 8,
            "Views/Settings/RemoteProviderEditSheet.swift": 15,
            "Views/Settings/RemoteProviderReorderSheet.swift": 1,
            "Views/Settings/RemoteProvidersView.swift": 1,
            "Views/Settings/SearchView.swift": 3,
            "Views/Settings/ServerSettings/GlobalProxySection.swift": 1,
            "Views/Settings/ServerSettings/ServerSettingsActionBar.swift": 1,
            "Views/Settings/ServerSettings/ServerSettingsHelpers.swift": 1,
            "Views/Settings/ServerSettings/ServerSettingsSidebarNav.swift": 1,
            "Views/Settings/ServerSettingsTabContent.swift": 1,
            "Views/Settings/ServerView.swift": 6,
            "Views/Settings/SlackSettingsView.swift": 3,
            "Views/Settings/StatusPanelView.swift": 5,
            "Views/Settings/StorageSettingsView.swift": 2,
            "Views/Settings/TelegramSettingsView.swift": 2,
            "Views/Settings/WhatsAppSettingsView.swift": 3,
            "Views/Shared/ShareLinkComponents.swift": 1,
            "Views/Skill/SkillEditorSheet.swift": 2,
            "Views/Template/PublishedWorkflowDashboard.swift": 5,
            "Views/Template/SetupWizardParts.swift": 2,
            "Views/Template/ShareOptionRow.swift": 1,
            "Views/Template/ShareWorkflowSheet.swift": 1,
            "Views/Template/TemplateImportReviewView.swift": 2,
            "Views/Template/TemplateVersionHistorySheet.swift": 2,
            "Views/Template/WorkflowShareCardView.swift": 1,
            "Views/Tool/ToolAdvancedDiagnosticsSection.swift": 1,
            "Views/Tool/ToolCatalogRows.swift": 2,
            "Views/Tool/ToolPermissionBanner.swift": 1,
            "Views/Voice/TTSModeSettingsTab.swift": 1,
            "Views/Voice/TranscriptionOverlayView.swift": 4,
            "Views/Voice/TranscriptionSettingsTab.swift": 1,
            "Views/Voice/VADModeSettingsTab.swift": 3,
            "Views/Voice/VoiceComponents.swift": 16,
            "Views/Voice/VoiceInputOverlay.swift": 4,
            "Views/Voice/VoiceSetupTab.swift": 8,
            "Views/Workflow/Architect/ArchitectSidebarPanel.swift": 6,
            "Views/Workflow/Architect/WorkflowRequirementsPanel.swift": 1,
            "Views/Workflow/Library/WorkflowBundleSetupView.swift": 1,
            "Views/Workflow/Library/WorkflowCards.swift": 1,
            "Views/Workflow/Library/WorkflowDetailPage.swift": 1,
            "Views/Workflow/Library/WorkflowSetupWizardView.swift": 1,
            "Views/Workflow/Library/WorkflowsPaneView.swift": 1,
            "Views/Workflow/WorkflowMediaGallery.swift": 1,
            "Views/Workflow/WorkflowRunFilesView.swift": 1,
            "Views/Workflow/WorkflowRunHistoryList.swift": 1,
            "Views/Workspaces/WorkspaceAuditView.swift": 1,
            "Views/Workspaces/WorkspaceDetailView.swift": 4,
            "Views/Workspaces/WorkspacePoolActivityView.swift": 2,
            "Views/Workspaces/WorkspaceSheets.swift": 1,
            "Views/Workspaces/WorkspacesIntroExplainer.swift": 8,
            "Views/Workspaces/WorkspacesView.swift": 1,
        ],
        "handRolledRow": [
            "Views/Agent/AgentGenerationSettingsEditor.swift": 2,
            "Views/Agent/AgentReorderSheet.swift": 1,
            "Views/Agent/AgentsView.swift": 6,
            "Views/Agent/NextRunPanelView.swift": 1,
            "Views/Agent/Setup/AgentSetupWizardView.swift": 1,
            "Views/Agent/Templates/AgentTemplateSheets.swift": 1,
            "Views/Identity/SignInWithOsaurusSection.swift": 1,
            "Views/Insights/InsightsView.swift": 1,
            "Views/Knowledge/KnowledgeWritePreviewView.swift": 1,
            "Views/Memory/MemoryDiagnosticsViews.swift": 1,
            "Views/Model/ModelDetailView.swift": 1,
            "Views/Plugin/ClaudePluginDetailView.swift": 1,
            "Views/Plugin/GitHubImportSheet.swift": 1,
            "Views/Settings/ChannelAccountViews.swift": 1,
            "Views/Settings/ConfigHistorySection.swift": 1,
            "Views/Settings/N8nSettingsView.swift": 1,
            "Views/Settings/ServerSettings/AuthenticationSection.swift": 1,
            "Views/Settings/ServerView.swift": 1,
            "Views/Template/PublishedWorkflowDashboard.swift": 2,
            "Views/Template/ShareWorkflowSheet.swift": 1,
            "Views/Voice/VADModeSettingsTab.swift": 1,
            "Views/Voice/VoiceSharedComponents.swift": 1,
            "Views/Workflow/Library/WorkflowDetailPage.swift": 3,
        ],
    ]
    // END COUNTS
}
