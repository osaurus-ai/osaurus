//
//  SettingsKitGallery.swift
//  osaurus
//
//  Debug-only catalog of every settings-kit component in every state.
//  Reached from Developer Tools → Server (Debug builds) and `#Preview`.
//  Sample copy is English-only and never shipped.
//

#if DEBUG || OSAURUS_DESIGN_INSPECTOR

    import SwiftUI

    struct SettingsKitGallery: View {
        @Environment(\.theme) private var theme
        var inspectorFamily: Int? = nil
        var catalogPreview = false
        init(inspectorFamily: Int? = nil, catalogPreview: Bool = false) {
            self.inspectorFamily = inspectorFamily; self.catalogPreview = catalogPreview
        }

        @State private var isDisabled = false
        @State private var isNarrow = false
        private var verificationChromeTheme: any ThemeProtocol {
            #if OSAURUS_DESIGN_INSPECTOR
            if inspectorFamily != nil {
                // Keep verification controls usable while the original component
                // below uses the connected app's full text scale. This does not
                // change any production screen or the component under review.
                return CustomizableTheme(config: theme.isDark ? .darkDefault : .lightDefault, fontScale: 1)
            }
            #endif
            return theme
        }
        @State private var showsSearchGlow = false

        @State private var tab: GalleryTab = .overview
        @State private var search = ""
        @State private var toggleOn = true
        @State private var checkboxOn = false
        @State private var picker = "balanced"
        @State private var searchablePick: String?
        @State private var filter: GalleryFilter? = nil
        @State private var chipSelected = true
        @State private var text = ""
        @State private var filledText = "osaurus"
        @State private var secret = "sk-test-1234"
        @State private var notes = "Multi-line notes\nsecond line"
        @State private var sliderText = ""
        @State private var stepperText = "8"
        @State private var stepperValue = 15
        @State private var abilityOn = true
        @State private var librarySelected = 1
        @State private var dataTableSort: SettingsDataTableSort<String>? = nil
        @State private var dataTableSelection: String? = "Second"
        @State private var dataTableLoading = false
        @State private var statSelection: String? = "Errors"
        @State private var sliderValue = 0.6
        @State private var date = Date()
        #if OSAURUS_DESIGN_INSPECTOR
        private static let verificationMinimumDate = Date(timeIntervalSince1970: 1_792_411_200)
        @State private var boundedDate = Date(timeIntervalSince1970: 1_792_411_200)
        @State private var indicatorValue = 40
        @State private var indicatorPhase: IndicatorPhase = .running
        @State private var indicatorInvalidValue = false
        @State private var indicatorReducedMotion = false
        @State private var indicatorSearchText = ""
        @FocusState private var indicatorSearchFocused: Bool
        private enum IndicatorPhase: String, CaseIterable {
            case waiting, running, complete, error
            var title: String { rawValue.capitalized }
            var tone: StatusChip.Tone {
                switch self {
                case .waiting: .neutral
                case .running: .success
                case .complete: .success
                case .error: .error
                }
            }
            var isLoading: Bool { self == .waiting || self == .running }
        }
        #endif

        @ViewBuilder var body: some View {
            #if OSAURUS_DESIGN_INSPECTOR
            if catalogPreview {
                VStack(alignment: .leading, spacing: 20) { focusedComponent }
                    .environment(\.inspectorVerificationWidth, 740)
            } else { galleryPage }
            #else
            galleryPage
            #endif
        }
        private var galleryPage: some View {
            SettingsPage {
                SettingsPageHeader(
                    title: "Settings Kit",
                    subtitle: "Every component in every state",
                    count: 13,
                    utilities: {
                        controlSwitch("Disabled", $isDisabled)
                        controlSwitch("Narrow", $isNarrow)
                        controlSwitch("Search glow", $showsSearchGlow)
                    },
                    toolbar: {
                        SettingsTabsRow(selection: $tab, searchText: $search, searchPlaceholder: "Search the gallery")
                    }
                )
                .environment(\.theme, verificationChromeTheme)
            } content: {
                Group {
                    #if OSAURUS_DESIGN_INSPECTOR
                    if inspectorFamily != nil {
                        Text("Original component text: \(Int(theme.fontScale * 100))%. Verification toolbar: 100%.")
                            .textStyle(.caption)
                    }
                    #endif
                    if inspectorFamily == nil {
                        // The full gallery has hundreds of controls. Keep offscreen
                        // sections out of the eager layout pass used by SettingsPage.
                        LazyVStack(alignment: .leading, spacing: theme.settingsSectionGap) {
                            tokens
                            pageChrome
                            buttons
                            chips
                            rows
                            controls
                            fields
                            sections
                            noticesAndSheets
                            library
                            dataTable
                            indicators
                            statusAndFindings
                            emptyStates
                        }
                    } else {
                        focusedComponent
                    }
                }
                .disabled(isDisabled)
                #if OSAURUS_DESIGN_INSPECTOR
                .environment(\.inspectorVerificationWidth, isNarrow ? 472 : 800)
                #endif
            }
            .frame(maxWidth: isNarrow ? 520 : .infinity)
            .frame(maxWidth: .infinity)
            .background(theme.surface.canvas)
        }

        @ViewBuilder private var focusedComponent: some View {
            switch inspectorFamily {
            case 3: fields
            case 4: nativeToggleSamples
            case 5: nativeMenuSamples
            case 6:
                nativeTabs
                SettingsPickerRow(title: "Mode", selection: $picker, options: Self.pickerOptions)
            case 7: nativeNumberSamples
            case 8: nativeDateSamples
            case 9: nativeShortcut
            case 10: chips
            case 11: nativeAvatars
            case 12: indicators; statusAndFindings
            case 13: appCardExample; nativeFeatureCards
            case 14: rows
            case 15:
                Text("Expandable settings content. Used for advanced options; the child controls keep their own base styles.").foregroundStyle(.secondary)
                SettingsAdvancedDisclosure {
                    SettingsToggle(title: "Expand Thinking While Streaming", description: "Keep the model's reasoning open while it is thinking, then collapse it once the answer begins. Useful for watching long agent tasks.", verbatim: true, isOn: $checkboxOn)
                }
            case 16: nativePopover
            case 17: nativeSheet
            case 18: nativeBanners; nativeToasts; noticesAndSheets
            case 19: remainingEmptyStates
                emptyStates.environment(\.inspectorForceReducedMotion, sampleEmptyReducedMotion)
            case 20: remainingTableVariants; library; dataTable; nativeTable
            #if OSAURUS_DESIGN_INSPECTOR
            case 21: InspectorComposerVerification()
            case 22: InspectorComposerVerification(includeActionChecks: true)
            case 23: InspectorComposerVerification(includeChipChecks: true)
            case 24: InspectorComposerVerification(includeAttachmentChecks: true)
            case 25: InspectorSuggestionVerification()
            case 26: InspectorModelPickerVerification()
            case 27: InspectorAgentPickerVerification()
            case 28: InspectorUserMessageVerification()
            case 29: InspectorUserMessageVerification(isAssistant: true)
            case 30: InspectorMessageHeaderVerification()
            case 31: InspectorUserMessageVerification(isAssistant: true, richText: true)
            case 32: InspectorCodeBlockVerification()
            case 33: InspectorThinkingVerification()
            case 34: InspectorActivityVerification()
            case 35: InspectorAgentProgressVerification()
            case 36: InspectorPromptVerification()
            case 38: InspectorFileHistoryVerification()
            case 39: InspectorTerminalLiveVerification()
            case 40: InspectorNoticeVerification()
            case 41: InspectorSidebarRemainingVerification()
            case 42: InspectorSidebarChromeVerification()
            case 45: InspectorVoiceVerification()
            case 46: InspectorSettingsGeometryVerification(family: 46)
            case 47: InspectorProviderStatesVerification()
            case 48: InspectorCapabilityVerification()
            case 49: InspectorWorkspaceVerification()
            case 50: InspectorSettingsGeometryVerification(family: 50)
            case 51: InspectorCreditsVerification()
            case 52: InspectorPrivacyVerification()
            case 53: InspectorDataRemainingVerification()
            case 54: InspectorImagePanelVerification()
            #endif
            case 58: preservedStepTrackers
            case 59: preservedStatistics
            case 60: preservedStatusPanel
            case 61: preservedFindings
            case 62: preservedCallouts
            case 63: preservedDrillInRows
            case 64: preservedIconTiles
            #if OSAURUS_DESIGN_INSPECTOR
            case 500: InspectorContextMenuChecks()
            #endif
            default: EmptyView()
            }
        }

        // Existing compositions relocated from mixed control galleries.
        private var preservedStepTrackers: some View {
            VStack(alignment: .leading, spacing: 24) {
VStack(spacing: 16) {
                        SettingsStepTracker(steps: [
                            SettingsStep(id: "a", title: "Listing", state: .done),
                            SettingsStep(id: "b", title: "Signed and uploaded", state: .done),
                            SettingsStep(id: "c", title: "Review", detail: "Usually within 24 hours", state: .waiting),
                            SettingsStep(id: "d", title: "In the store", state: .upcoming),
                        ])
                        SettingsStepTracker(steps: [
                            SettingsStep(id: "a", title: "Listing", state: .done),
                            SettingsStep(id: "b", title: "Uploading", state: .working),
                            SettingsStep(id: "c", title: "Review", detail: "Changes requested", state: .attention),
                            SettingsStep(id: "d", title: "Failed", state: .failed),
                            SettingsStep(id: "e", title: "Skipped", state: .skipped),
                        ])
                    }
            }
        }
        private var preservedStatistics: some View {
            VStack(alignment: .leading, spacing: 24) {
SettingsSection(title: "Stat Strip", verbatimTitle: true) {
                    SettingsStatStrip(stats: [
                        SettingsStat(label: "Calls", value: "1,204"),
                        SettingsStat(label: "Latency", value: "212ms"),
                        SettingsStat(label: "Errors", value: "3"),
                    ])
                }
SettingsSection(title: "Stat Tiles", layout: .plain, verbatimTitle: true) {
                    SettingsStatStrip(
                        stats: [
                            SettingsStat(label: "Uptime", value: "3h 12m", icon: "clock"),
                            SettingsStat(label: "CPU", value: "12%", icon: "cpu"),
                            SettingsStat(label: "Memory", value: "1.2 GB", icon: "memorychip"),
                            SettingsStat(label: "Disk", value: "4.0 GB", icon: "internaldrive"),
                        ],
                        style: .tiles(columns: 3)
                    )
                    SettingsStatStrip(
                        stats: [
                            SettingsStat(label: "Errors", value: "3"),
                            SettingsStat(label: "Warnings", value: "12"),
                            SettingsStat(label: "Requests", value: "1,204"),
                        ],
                        style: .tiles(columns: 3),
                        selection: $statSelection
                    )
                }
            }
        }
        private var preservedStatusPanel: some View {
            VStack(alignment: .leading, spacing: 24) {
SettingsStatusHero(
                    title: "Status Hero",
                    icon: "antenna.radiowaves.left.and.right",
                    valueLabel: "Value",
                    value: "http://192.168.1.10:1337"
                ) {
                    #if OSAURUS_DESIGN_INSPECTOR
                    StatusChip(indicatorPhase.title, tone: indicatorPhase.tone, showsDot: true)
                    #else
                    StatusChip("Running", tone: .success, showsDot: true)
                    #endif
                } actions: {
                    SettingsButton(.secondary, "Action", size: .compact, verbatim: true) {}
                }
            }
        }
        private var preservedFindings: some View {
            VStack(alignment: .leading, spacing: 24) {
SettingsSection(title: "Finding Rows", layout: .plain, verbatimTitle: true) {
                    VStack(spacing: theme.space.s8) {
                        SettingsFindingRow(severity: .ok, title: "Healthy", value: "Granted", detail: "Quiet well.")
                        SettingsFindingRow(severity: .info, title: "Informational", detail: "No action needed.")
                        SettingsFindingRow(
                            severity: .warning,
                            title: "Needs setup",
                            code: "missing_root",
                            detail: "The folder does not exist yet.",
                            fix: "Create it and run again."
                        )
                        SettingsFindingRow(
                            severity: .blocked,
                            title: "Blocked",
                            code: "not_writable",
                            detail: "Osaurus cannot write here.",
                            fix: "chmod u+w ~/path"
                        )
                        SettingsFindingRow(severity: .inactive, title: "Inactive", value: "Off", detail: "Feature is off.")
                    }
                }
            }
        }
        private var preservedCallouts: some View {
            VStack(alignment: .leading, spacing: 24) {
SettingsCallout(
                    icon: "person.badge.key",
                    title: "Callout",
                    message: "A page-level state the user must act on first.",
                    tone: .info
                ) {
                    SettingsButton(.primary, "Set Up", size: .compact, verbatim: true) {}
                }
                SettingsCallout(
                    icon: "exclamationmark.bubble",
                    title: "Callout with a quote",
                    message: "Someone else's words, shown as they wrote them.",
                    tone: .warning,
                    quote: "Step names don't say what they do. Rename them and resubmit."
                ) {
                    SettingsButton(.primary, "Revise", size: .compact, verbatim: true) {}
                }
                SettingsCallout(
                    icon: "exclamationmark.triangle.fill",
                    title: "Unsaved changes",
                    message: "Save your changes before closing this window.",
                    tone: .urgentWarning
                )
            }
        }
        private var preservedDrillInRows: some View {
            VStack(alignment: .leading, spacing: 24) {
SettingsSection(title: "Drill-In Rows", verbatimTitle: true) {
                    SettingsDrillInRows(items: GalleryDrillIn.allCases, badges: [.second: 2]) { _ in }
                }
            }
        }
        private var preservedIconTiles: some View {
            VStack(alignment: .leading, spacing: 24) {
HStack(spacing: 8) {
                        SettingsIconTile(icon: "gearshape")
                        SettingsIconTile(icon: "bolt.fill", tint: theme.status.warning.foreground)
                        SettingsIconTile(icon: "sparkles", size: 36, gradient: [theme.status.info.foreground, theme.status.info.background])
                    }
            }
        }

        private var nativeToggleSamples: some View {
            VStack(alignment: .leading, spacing: 16) {
                SettingsToggle(title: "Enable feature", description: "Switch description", verbatim: true, isOn: $toggleOn)
                SettingsToggle(title: "Include selection", style: .checkbox, verbatim: true, isOn: $checkboxOn)
            }
        }
        private var nativeMenuSamples: some View {
            VStack(alignment: .leading, spacing: 16) {
                SettingsPickerRow(title: "Mode", style: .menu, selection: $picker, options: Self.pickerOptions)
                SettingsMenuButton(.secondary, "Actions", verbatim: true) {
                    Button("First action") { sampleMenuActions += 1 }
                    Button("Unavailable action") {}.disabled(true)
                    Divider()
                    Toggle("Pinned", isOn: $sampleMenuPinned)
                }
                SettingsOverflowMenu(help: "More actions") { Button("Duplicate") { sampleMenuActions += 1 } }
            }
        }
        private var nativeNumberSamples: some View {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSlider(title: "Amount", valueText: String(format: "%.2f", sliderValue), description: "Slider description", value: $sliderValue, range: 0...1, step: 0.05)
                SettingsStepperRow(label: "Count", help: "Stepper description", text: $stepperText, range: 1...64, step: 1, defaultValue: 8)
                SettingsStepper(value: $stepperValue, range: 0...1440, unit: "min")
            }
        }
        private var nativeDateSamples: some View {
            VStack(alignment: .leading, spacing: 16) {
                SettingsDatePicker(label: "Date and time", selection: $date, components: [.date, .hourAndMinute])
                #if OSAURUS_DESIGN_INSPECTOR
                SettingsDatePicker(label: "Minimum date", selection: $boundedDate, minimum: Self.verificationMinimumDate, components: [.date, .hourAndMinute])
                #endif
            }
        }
        @State private var sampleHotkey: Hotkey?
        @State private var sampleHostFilterVisible = true
        @State private var samplePatternFilterVisible = true
        @State private var samplePopover = false
        @State private var samplePopoverText = ""
        @State private var samplePopoverDisabled = false
        @State private var sampleTableOn = true
        @State private var sampleTableExpanded = true
        @State private var sampleTableReason: ToolAvailabilityReasonCode = .permissionBlocked
        @State private var sampleTableStatus = "Actionable warning"
        @State private var sampleTableVariantEnabled: Set<String> = ["status-tool"]
        @State private var sampleTableStatusActions = 0
        @State private var sampleEmptyPhase = "Empty"
        @State private var sampleEmptyActions = 0
        @State private var sampleEmptyReducedMotion = false
        @State private var sampleHeroAppeared = true
        @State private var sampleNotice = true
        @State private var sampleNoticeActions = 0
        @State private var sampleToastVariant = "Action"
        @State private var sampleToastVisible = true
        @State private var samplePersistentToast: UUID?
        private let sampleToastActionID = "inspector.local-toast-verification"
        @State private var sampleSheet = false
        @State private var sampleSheetVariant = "Standard"
        @State private var sampleSheetDisabled = false
        @State private var sampleSheetActions = 0
        @State private var sampleSheetText = ""
        @State private var sampleMenuActions = 0
        @State private var sampleMenuPinned = false
        @State private var sampleMenuOption = "available"
        @State private var sampleMenuSelections = 0
        @State private var sampleLongMenu = 1
        @State private var sampleCardOption = false
        @State private var sampleRowAction = "None"
        @State private var sampleRowActionCount = 0
        private func recordRowAction(_ name: String) {
            sampleRowAction = name
            sampleRowActionCount += 1
        }
        private var remainingRowVariants: some View {
            SettingsSection(title: "Remaining row variants", layout: .plain, verbatimTitle: true) {
                SettingsRow(title: "Rich description row", badge: "Local", verbatimTitle: true) {
                    SettingsIconTile(icon: "text.alignleft")
                } description: {
                    Text(verbatim: "First line of rich description\nSecond line of description")
                } trailing: {
                    SettingsButton(.secondary, "Row accessory action", size: .compact, verbatim: true) { recordRowAction("Accessory") }
                }
                SettingsValueRow(title: "Plain value", value: "No status dot or copy action", verbatimTitle: true)
                SettingsAbilityRow(title: "Paused accessory", description: "Main row is disabled; its explanation stays usable.",
                    icon: "pause.circle", isActive: false, isInteractive: false,
                    pausedNote: "Show local paused cause", onPausedNoteTap: { recordRowAction("Paused cause") }, verbatim: true) {
                        SettingsButton(.secondary, "Paused accessory action", size: .compact, verbatim: true) { recordRowAction("Paused accessory") }
                    }
                Text(verbatim: "Row action: \(sampleRowAction) · count: \(sampleRowActionCount)").font(SettingsFont.caption)
            }
        }
        private var remainingCardVariants: some View {
            SettingsSection(title: "Remaining card variants", layout: .plain, verbatimTitle: true) {
                LibraryCard(title: "Media and accessory card", subtitle: "Existing card slots", action: { librarySelected = 3 }) {
                    Image(systemName: "photo").resizable().scaledToFit().frame(height: 64)
                        .frame(maxWidth: .infinity).padding().background(theme.surface.subtle)
                } leading: {
                    LibraryIcon(symbol: "photo", tint: theme.text.secondary)
                } accessory: {
                    Toggle("Card accessory", isOn: $sampleCardOption).labelsHidden().settingsSwitch()
                        .accessibilityLabel("Card accessory")
                } content: {
                    LibraryCardPreview(text: "")
                } footer: {
                    LibraryCardFooter(facts: ["Local sample", "Footer fact"]) {
                        SettingsButton(.secondary, "Card footer action", size: .compact, verbatim: true) { sampleMenuActions += 1 }
                    }
                }
                LibraryCard(title: "Passive card", subtitle: nil) {
                    LibraryIcon(symbol: "doc", tint: theme.text.secondary)
                } content: {
                    LibraryCardPreview(text: "Body without an open action")
                } footer: {
                    LibraryStatRow(stats: [.init(icon: "clock", text: nil, help: "Icon-only fact")])
                }
                Text(verbatim: "Card selection: \(librarySelected) · card actions: \(sampleMenuActions) · accessory: \(sampleCardOption ? "on" : "off")")
                    .font(SettingsFont.caption)
            }
        }
        private var appCardExample: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tools & MCP → Add Service · LibraryCard").font(SettingsFont.sectionTitle)
                Text("The actual directory card. The click action is inactive in this preview.").font(SettingsFont.caption)
                MCPProviderDirectoryCard(icon: "slider.horizontal.3", title: "Custom Server",
                    tagline: "Connect to any other MCP-compatible server", action: {})
                    .frame(width: 260)
            }
        }
        private var nativeFeatureCards: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings → Orchestrator · SettingsFeatureCards").font(SettingsFont.sectionTitle)
                SettingsFeatureCards(features: [
                    .init(icon: "slider.horizontal.3", title: "Configures Osaurus", caption: "Changes settings, downloads models, and connects providers for you."),
                    .init(icon: "point.3.connected.trianglepath.dotted", title: "Delegates work", caption: "Hands real tasks to the agents listed under Subagents; each runs with its own tools."),
                    .init(icon: "folder", title: "Works in a folder", caption: "Reads its Working Folder to brief subagents; subagents write deliverables there.")
                ])
            }
        }
        @State private var previewExpiration: AccessKeyExpiration = .days30
        @State private var previewGenerating = false
        @State private var previewKeyError: String?
        private var nativeSheet: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Server → Access Keys → Generate Access Key").font(SettingsFont.sectionTitle)
                Text("Actual AccessKeyGeneratorSheet. This preview cannot generate or save a key. Fields and buttons use their shared base styles.").font(SettingsFont.caption)
                AccessKeyGeneratorSheet(theme: theme, label: $sampleSheetText,
                    expiration: $previewExpiration, isGenerating: $previewGenerating,
                    error: $previewKeyError, onGenerate: {}, onCancel: {})
                    .environment(\.inspectorSheetPreviewTheme, true)
            }
        }
        private var nativeShortcut: some View {
            SettingsSection(title: "Shortcut", verbatimTitle: true) {
                HotkeyRecorder(value: $sampleHotkey)
                PickerCardKeyHints()
            }
        }
        private var nativeAvatars: some View {
            SettingsSection(title: "Avatars", verbatimTitle: true) {
                HStack(spacing: 16) {
                    AgentAvatarView(mascotId: nil, name: "Research", tint: theme.border.focus, diameter: 32)
                    AgentAvatarView(mascotId: "blue", name: "Osaurus", tint: theme.border.focus, diameter: 32)
                }
            }
        }
        private var nativePopover: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Chat composer → Model, context and credits popovers").font(SettingsFont.sectionTitle)
                Text("Shared outer surface only. The content belongs to each picker; this is not an additional picker configuration.").font(SettingsFont.caption)
                Text("Popover surface")
                    .font(SettingsFont.caption)
                    .foregroundStyle(theme.text.secondary)
                    .frame(width: PickerCardMetrics.infoCardWidth, height: 120)
                    .pickerCardSurface()
                Text("Separate window: system shadow. In-window presentation: overlay elevation. No extra fields, buttons or footer are added by this container.").font(SettingsFont.caption)
            }
        }
        private var nativeBanners: some View {
            SettingsSection(title: "Banners", verbatimTitle: true) {
                if sampleNotice {
                    InlineBanner(kind: .error, title: "Connection failed", caption: "Try again.", onDismiss: { sampleNotice = false })
                    InlineBanner(kind: .success, title: "Changes saved")
                    InlineBanner(kind: .warning, title: "Review this setting")
                    InlineBanner(kind: .info, title: "Information notice", caption: "Local information only.")
                    InlineBanner(kind: .action, title: "Action notice", caption: "Local callbacks only.",
                        action: .init(title: "Local primary action", icon: "checkmark") { sampleNoticeActions += 1 },
                        secondaryAction: .init(title: "Local secondary action") { sampleNoticeActions += 1 })
                } else {
                    SettingsButton(.secondary, "Show notices", verbatim: true) { sampleNotice = true }
                }
            }
        }
        private var sampleToast: Toast {
            switch sampleToastVariant {
            case "Error": return Toast(type: .error, title: "Error toast", message: "Local status only", timeout: 0)
            case "Warning": return Toast(type: .warning, title: "Warning toast", message: "Local status only", timeout: 0)
            case "Success": return Toast(type: .success, title: "Success toast", message: "Local status only", timeout: 0)
            case "Loading": return Toast(type: .loading, title: "Loading toast", message: "Local progress only", timeout: 0, progress: 0.35)
            case "Title only": return Toast(type: .info, title: "Title-only information toast", timeout: 0)
            case "Avatar": return Toast(type: .success, title: "Avatar toast", message: "Existing optional image slot", timeout: 0,
                avatarImageData: NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?.tiffRepresentation)
            default: return Toast(type: .action, title: "Action toast", message: "Original notification renderer", timeout: 0, actionTitle: "Local toast action")
            }
        }
        private var sampleCompactTone: SimpleToastType {
            switch sampleToastVariant {
            case "Error": return .error
            case "Warning": return .warning
            case "Success", "Avatar": return .success
            default: return .info
            }
        }
        private var nativeToasts: some View {
            SettingsSection(title: "Toast variants", layout: .plain, verbatimTitle: true) {
                Text(verbatim: "Notice action count: \(sampleNoticeActions)").font(SettingsFont.caption)
                SettingsMenuPicker(selection: $sampleToastVariant) {
                    ForEach(["Action", "Loading", "Title only", "Avatar", "Error", "Warning", "Success"], id: \.self) { Text(verbatim: $0).tag($0) }
                }
                if sampleToastVisible {
                    ToastView(toast: sampleToast, onDismiss: { sampleToastVisible = false },
                        onAction: { sampleNoticeActions += 1 })
                } else {
                    SettingsButton(.secondary, "Restore toast", verbatim: true) { sampleToastVisible = true }
                }
                ThemedToastView("Existing compact notification", type: sampleCompactTone)
                HStack {
                    SettingsButton(.secondary, "Show persistent toast", verbatim: true) {
                        let manager = ToastManager.shared
                        if let samplePersistentToast { manager.dismiss(id: samplePersistentToast) }
                        manager.registerActionHandler(for: sampleToastActionID) { _ in sampleNoticeActions += 1 }
                        samplePersistentToast = manager.show(Toast(type: .action, title: "Persistent local toast",
                            message: "Timeout zero; no real app action", timeout: 0,
                            actionTitle: "Local persistent action", actionId: sampleToastActionID))
                    }
                    SettingsButton(.secondary, "Clear local toast", verbatim: true) {
                        if let samplePersistentToast { ToastManager.shared.dismiss(id: samplePersistentToast) }
                        samplePersistentToast = nil
                    }
                }
                Text(verbatim: "Persistent toast count: \(ToastManager.shared.toasts.filter { $0.id == samplePersistentToast }.count)")
                    .font(SettingsFont.caption)
                ToastContainerView().frame(height: 240)
            }
            .onChange(of: sampleToastVariant) { _, _ in sampleToastVisible = true }
            .onDisappear {
                ToastManager.shared.unregisterActionHandler(for: sampleToastActionID)
                if let samplePersistentToast { ToastManager.shared.dismiss(id: samplePersistentToast) }
            }
        }
        private var nativeTabs: some View {
            SettingsSection(title: "Tabs and counts", layout: .plain, verbatimTitle: true) {
                AnimatedTabSelector(selection: $tab, counts: [.overview: 3, .details: 7], badges: [.history: 2])
            }
        }
        private var remainingTableVariants: some View {
            SettingsSection(title: "Remaining table variants", layout: .plain, verbatimTitle: true) {
                Picker("Availability reason", selection: $sampleTableReason) {
                    ForEach(ToolAvailabilityReasonCode.allCases, id: \.self) { reason in
                        Text(verbatim: reason.rawValue).tag(reason)
                    }
                }
                Picker("Group status", selection: $sampleTableStatus) {
                    ForEach(["Actionable warning", "Passive status", "No status"], id: \.self) { value in
                        Text(verbatim: value).tag(value)
                    }
                }
                Text(verbatim: "Table status action count: \(sampleTableStatusActions)")
                    .font(SettingsFont.caption)
                CapabilitiesTableRepresentable(
                    rows: [.groupHeader(id: "status-fixture", name: "Status tools", icon: "wrench",
                        enabledCount: sampleTableVariantEnabled.count, totalCount: 2, isExpanded: true,
                        status: sampleTableStatus == "No status" ? nil : CapabilityGroupStatus(
                            text: sampleTableStatus == "Actionable warning" ? "Permission needed" : "Local status",
                            icon: "info.circle", isWarning: sampleTableStatus == "Actionable warning",
                            isActionable: sampleTableStatus == "Actionable warning", detail: "Local callback only")),
                        .tool(id: "status-tool", name: "Local status fixture",
                            description: "The existing two-line description remains independent of the status and token badges.",
                            enabled: sampleTableVariantEnabled.contains("status-tool"),
                            availability: ToolAvailability(toolName: "status-tool", runtime: nil, groupName: nil,
                                reasonCodes: [sampleTableReason], detail: "Local availability detail"),
                            groupToggleLabel: "App group", catalogTokens: 120, estimatedTokens: 240),
                        .tool(id: "status-tool-two", name: "Second local fixture", description: "Local toggle only.",
                            enabled: sampleTableVariantEnabled.contains("status-tool-two"),
                            availability: ToolAvailability(toolName: "status-tool-two", runtime: nil, groupName: nil,
                                reasonCodes: [.available], detail: "Local availability detail"),
                            groupToggleLabel: nil, catalogTokens: 0, estimatedTokens: 0)],
                    theme: theme, onEnableAllInGroup: { _ in sampleTableVariantEnabled = ["status-tool", "status-tool-two"] },
                    onDisableAllInGroup: { _ in sampleTableVariantEnabled = [] },
                    onGroupStatusTap: { _ in sampleTableStatusActions += 1 },
                    onToggleTool: { id, _ in
                        if sampleTableVariantEnabled.contains(id) { sampleTableVariantEnabled.remove(id) }
                        else { sampleTableVariantEnabled.insert(id) }
                    })
                    .frame(height: 460)
                TableView(headers: ["Local name", "Local status"], rows: [
                    ["A wrapped table cell<br>with a second line", "Ready"],
                    ["Inline **emphasis** and `code`", "Pending"],
                    ["Missing trailing cell"]], baseWidth: 760)
            }
        }
        private var nativeTable: some View {
            SettingsSection(title: "Table", layout: .plain, verbatimTitle: true) {
                CapabilitiesTableRepresentable(
                    rows: [.groupHeader(id: "sample", name: "Sample tools", icon: "wrench", enabledCount: sampleTableOn ? 1 : 0, totalCount: 1, isExpanded: sampleTableExpanded, status: nil)]
                        + (sampleTableExpanded ? [.tool(id: "sample-tool", name: "Read document", description: "Read a local document. No tool is executed by this example.", enabled: sampleTableOn,
                            availability: ToolAvailability(toolName: "sample-tool", runtime: nil, groupName: nil, reasonCodes: [.available], detail: "Available"), groupToggleLabel: nil, catalogTokens: 120, estimatedTokens: 120)] : []),
                    theme: theme, onToggleGroup: { _ in sampleTableExpanded.toggle() },
                    onEnableAllInGroup: { _ in sampleTableOn = true }, onDisableAllInGroup: { _ in sampleTableOn = false },
                    onToggleTool: { _, _ in sampleTableOn.toggle() })
                    .frame(height: 320)
            }
        }

        private func controlSwitch(_ title: String, _ isOn: Binding<Bool>) -> some View {
            Toggle(isOn: isOn) {
                Text(verbatim: title).font(SettingsFont.compactLabel)
            }
            .settingsSwitch(showsLabel: true)
        }

        // MARK: Tokens

        private var tokens: some View {
            SettingsSection(title: "Tokens", subtitle: "Type scale, radii, and chrome", verbatimTitle: true) {
                SettingsRow(title: "Type", verbatimTitle: true) {
                    EmptyView()
                } trailing: {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(ThemeTextStyleRole.allCases, id: \.self) { role in
                            Text(verbatim: "type.\(role.rawValue)").textStyle(role).foregroundColor(theme.text.primary)
                        }
                    }
                }
                SettingsRow(title: "Chrome", verbatimTitle: true) {
                    EmptyView()
                } trailing: {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                        ForEach(Self.chromes, id: \.0) { name, chrome in
                            Text(verbatim: name)
                                .font(SettingsFont.smallLabel)
                                .foregroundColor(theme.text.secondary)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .settingsChrome(chrome)
                        }
                    }
                    .frame(maxWidth: 380)
                }
                SettingsValueRow(
                    title: "Radii",
                    value: "inset 6 · control 8 · surface 10 · card 12",
                    monospaced: true,
                    verbatimTitle: true
                )
            }
        }

        // MARK: Page chrome

        private var pageChrome: some View {
            SettingsSection(title: "Page Chrome", layout: .plain, verbatimTitle: true) {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsDetailHeader(icon: "cpu", title: "Detail header", subtitle: "Pushed pages and wizards") {
                        StatusChip("Running", tone: .success, showsDot: true)
                        StatusChip("Local", tone: .neutral, icon: "laptopcomputer")
                    } actions: {
                        SettingsButton(.secondary, "Edit", icon: "pencil", verbatim: true) {}
                        SettingsOverflowMenu(help: "More") {
                            Button(action: {}) { Text(verbatim: "Duplicate") }
                            Button(role: .destructive, action: {}) { Text(verbatim: "Delete") }
                        }
                    }
                    .settingsChrome(.card)

                    SettingsPageHeader(
                        title: "Every header slot",
                        verbatimTitle: true,
                        subtitle: "Back line, leading, count, status, refresh, utilities, secondary, primary, overflow, toolbar",
                        verbatimSubtitle: true,
                        count: 3,
                        onRefresh: {},
                        leading: { SettingsIconTile(icon: "person.crop.circle", size: 32) },
                        status: { StatusChip("Saved", tone: .success, showsDot: true) },
                        utilities: { SettingsIconButton("list.bullet.indent", help: "Reorder") {} },
                        secondary: { SettingsButton(.secondary, "History", icon: "clock", verbatim: true) {} },
                        primary: { SettingsButton(.primary, "Add Item", icon: "plus", verbatim: true) {} },
                        overflow: { Button(action: {}) { Text(verbatim: "Export…") } },
                        toolbar: {
                            SettingsHeaderToolbar(searchText: .constant(""), searchPlaceholder: "Search") {
                                FilterChip("All", isSelected: true) {}
                            }
                        }
                    )
                    .settingsBackDestination("Parent", verbatim: true) {}
                    .settingsChrome(.card)
                    SettingsCodeBlock(code: "export OSAURUS_API_KEY=osk-…\ncodex --profile osaurus")
                    SettingsBackButton(title: "Back button", verbatim: true, action: {})
                }
            }
        }

        // MARK: Buttons

        private var buttons: some View {
            SettingsSection(title: "Buttons", verbatimTitle: true) {
                ForEach(Self.sizes, id: \.0) { sizeName, size in
                    SettingsRow(title: "Roles · \(sizeName)", verbatimTitle: true) {
                        EmptyView()
                    } trailing: {
                        HStack(spacing: 8) {
                            ForEach(Self.roles, id: \.0) { name, role in
                                SettingsButton(role, name, size: size, verbatim: true) {}
                            }
                        }
                    }
                }
                SettingsRow(title: "Every role · disabled", verbatimTitle: true) {
                    EmptyView()
                } trailing: {
                    HStack(spacing: 8) {
                        ForEach(Self.roles, id: \.0) { name, role in
                            SettingsButton(role, name, verbatim: true) {}.disabled(true)
                        }
                    }
                }
                SettingsRow(
                    title: "Keyboard focus",
                    description: "Tab into the row: the ring is border.focus at stroke.focus, offset by focus.offset.",
                    verbatimTitle: true,
                    verbatimDescription: true
                ) {
                    EmptyView()
                } trailing: {
                    HStack(spacing: 8) {
                        ForEach(Self.roles, id: \.0) { name, role in
                            Button(action: {}) { Text(verbatim: name) }
                                .assignedSettingsButtonStyle(role, forceKeyboardFocus: true)
                        }
                    }
                }
                SettingsRow(title: "Loading", verbatimTitle: true) {
                    EmptyView()
                } trailing: {
                    HStack(spacing: 8) {
                        SettingsButton(.primary, "Saving", isLoading: true, verbatim: true) {}
                        SettingsButton(.destructive, "Removing", isLoading: true, verbatim: true) {}
                        Button(action: {}) {
                            Label {
                                Text(verbatim: "Style")
                            } icon: {
                                Image(systemName: "star")
                            }
                        }
                        .assignedSettingsButtonStyle(.primary, size: .compact)
                    }
                }
                SettingsRow(title: "Icon buttons", verbatimTitle: true) {
                    EmptyView()
                } trailing: {
                    HStack(spacing: 8) {
                        SettingsIconButton("gearshape", help: "Default") {}
                        SettingsIconButton("lock.fill", help: "Active", isActive: true) {}
                        SettingsIconButton("trash", help: "Destructive", isDestructive: true) {}
                        SettingsIconButton("arrow.clockwise", isLoading: true, help: "Loading") {}
                        SettingsIconButton("xmark", help: "Compact", size: .compact) {}
                        SettingsIconButton("nosign", help: "Disabled") {}.disabled(true)
                        SettingsOverflowMenu(help: "Overflow") {
                            Button(action: {}) { Text(verbatim: "Action") }
                        }
                    }
                }
            }
        }

        // MARK: Chips

        private var chips: some View {
            SettingsSection(title: "StatusChip and CountBadge · Models, Agents and settings lists", verbatimTitle: true) {
                SettingsRow(title: "Status chips", verbatimTitle: true) {
                    EmptyView()
                } trailing: {
                    HStack(spacing: 6) {
                        StatusChip("Neutral")
                        StatusChip("Accent", tone: .accent)
                        StatusChip("Ready", tone: .success, showsDot: true)
                        StatusChip("Warning", tone: .warning, icon: "exclamationmark.triangle.fill")
                        StatusChip("Error", tone: .error)
                    }
                }
                SettingsRow(title: "Count badges", verbatimTitle: true) {
                    EmptyView()
                } trailing: {
                    HStack(spacing: 6) {
                        CountBadge(3)
                        CountBadge(128)
                        CountBadge(2, prominence: .attention)
                    }
                }

            }
        }

        // MARK: Rows

        private var rows: some View {
            SettingsSection(title: "Settings row variants · used throughout Settings", footer: "Rows are flat inside a settings group. Fields, switches, menus and buttons retain their own styles.", verbatimTitle: true) {
                SettingsToggle(
                    title: "Switch",
                    description: "Description under the title.",
                    badge: "Beta",
                    verbatim: true,
                    isOn: $toggleOn
                )
                SettingsToggle(
                    title: "Checkbox",
                    icon: "checkmark.square",
                    style: .checkbox,
                    verbatim: true,
                    isOn: $checkboxOn
                )
                SettingsPickerRow(
                    title: "Segmented picker",
                    selection: $picker,
                    options: Self.pickerOptions
                )
                SettingsPickerRow(title: "Menu picker", style: .menu, selection: $picker, options: Self.pickerOptions)
                SettingsValueRow(
                    title: "Value",
                    value: "127.0.0.1:1337",
                    monospaced: true,
                    dot: theme.status.success.foreground,
                    copyable: true,
                    verbatimTitle: true
                )
                SettingsLinkRow(title: "Link row", description: "Opens elsewhere.", action: { recordRowAction("Link") })
                SettingsNavigationRow(
                    icon: "folder",
                    title: "Navigation row",
                    subtitle: "Drills in",
                    badge: 3,
                    action: { recordRowAction("Navigation") }
                )
                SettingsNavigationRow(
                    icon: "bell",
                    title: "Highlighted badge",
                    badge: 1,
                    badgeHighlight: true,
                    action: { recordRowAction("Highlighted navigation") }
                )
                SettingsRow(
                    title: "Row with leading",
                    description: "Leading slot",
                    verbatimTitle: true,
                    verbatimDescription: true
                ) {
                    SettingsIconTile(icon: "sparkles")
                } trailing: {
                    SettingsButton(.secondary, "Action", size: .compact, verbatim: true) {}
                }
                SettingsAbilityRow(
                    title: "Ability (interactive)",
                    description: "Toggle with configure",
                    icon: "hammer",
                    isOn: $abilityOn,
                    configureLabel: "Configure",
                    onConfigure: { recordRowAction("Configure") },
                    verbatim: true
                )
                SettingsAbilityRow(
                    title: "Ability (read-only)",
                    description: "Paused with a note",
                    icon: "pause.circle",
                    isActive: false,
                    isInteractive: false,
                    pausedNote: "Paused by the workspace",
                    verbatim: true
                )
                SettingsSliderRow(
                    label: "Slider (inherits)",
                    help: "Empty text inherits the default.",
                    text: $sliderText,
                    range: 0 ... 2,
                    step: 0.1,
                    defaultValue: 0.7,
                    formatString: "%.1f"
                )
                SettingsStepperRow(
                    label: "Stepper",
                    help: "Integer with bounds.",
                    text: $stepperText,
                    range: 1 ... 64,
                    step: 1,
                    defaultValue: 8
                )
                SettingsRow(
                    title: "Stepper with unit",
                    description: "Bare SettingsStepper in a row.",
                    verbatimTitle: true,
                    verbatimDescription: true
                ) {
                    SettingsStepper(value: $stepperValue, range: 0 ... 1440, unit: "min")
                }
                SettingsRow(
                    title: "Pop-up (compact)",
                    description: "Opens a popover picker.",
                    verbatimTitle: true,
                    verbatimDescription: true
                ) {
                    SettingsPopUpButton(action: {}) { Text(verbatim: "Qwen3 8B") }
                }
                SettingsPopUpButton(style: .field, action: {}) { Text(verbatim: "Pop-up (field)") }
                    .padding(.vertical, theme.space.s12)
                SettingsSearchablePicker(
                    options: Self.searchableOptions,
                    selection: $searchablePick,
                    label: Self.searchableOptions.first { $0.id == searchablePick }?.title ?? "Default model",
                    icon: "cube",
                    noneTitle: "Default model",
                    searchPlaceholder: "Search models"
                )
                .padding(.vertical, theme.space.s12)
            }
        }

        private static let searchableOptions: [SettingsSearchablePicker.Option] = [
            .init(id: "qwen3-8b", title: "Qwen3 8B 4bit", group: "On this Mac"),
            .init(id: "gemma-4-26b", title: "Gemma 4 26B A4B", group: "On this Mac"),
            .init(id: "openai/gpt-4o", title: "gpt-4o", group: "OpenAI", keywords: "openai/gpt-4o"),
            .init(id: "openai/gpt-4o-mini", title: "gpt-4o-mini", group: "OpenAI", keywords: "openai/gpt-4o-mini"),
            .init(id: "groq/llama-3.3-70b", title: "llama-3.3-70b-versatile", group: "Groq"),
        ]

        // MARK: Controls

        private var controls: some View {
            SettingsSection(title: "Controls", verbatimTitle: true) {
                SettingsRow(
                    title: "Menu picker (bare)",
                    description: "For a row that already has a title.",
                    verbatimTitle: true,
                    verbatimDescription: true
                ) {
                    SettingsMenuPicker(selection: $picker, options: Self.pickerOptions)
                }
                SettingsRow(
                    title: "Menu button and overflow",
                    description: "Titled menu and icon-only overflow.",
                    verbatimTitle: true,
                    verbatimDescription: true
                ) {
                    HStack(spacing: theme.space.s8) {
                        SettingsMenuButton(.secondary, "Import", icon: "square.and.arrow.down", verbatim: true) {
                            Button { sampleMenuActions += 1 } label: { Text(verbatim: "From file…") }
                            Button { sampleMenuActions += 1 } label: { Text(verbatim: "From URL…") }
                            #if OSAURUS_DESIGN_INSPECTOR
                            Divider()
                            Button { sampleMenuActions += 100 } label: { Text(verbatim: "Unavailable action") }.disabled(true)
                            Toggle("Pinned", isOn: $sampleMenuPinned)
                            Menu("More options") {
                                Button { sampleMenuActions += 1 } label: { Text(verbatim: "Nested action") }
                            }
                            Section("Menu group") {
                                Button { sampleMenuActions += 1 } label: { Text(verbatim: "Grouped action") }
                                    .keyboardShortcut("g", modifiers: [.command, .shift])
                            }
                            #endif
                        }
                        SettingsOverflowMenu(help: "More") {
                            Button { sampleMenuActions += 1 } label: { Text(verbatim: "Duplicate") }
                        }
                    }
                }
                #if OSAURUS_DESIGN_INSPECTOR
                Text("Menu actions: \(sampleMenuActions) · pinned: \(sampleMenuPinned ? "on" : "off")").font(SettingsFont.caption)
                SettingsRow(title: "Menu options", description: "Original Picker options and separator", verbatimTitle: true, verbatimDescription: true) {
                    SettingsMenuPicker(selection: Binding(get: { sampleMenuOption }, set: { sampleMenuOption = $0; sampleMenuSelections += 1 }), disabledValues: ["unavailable"]) {
                        Text(verbatim: "Available").tag("available")
                        Text(verbatim: "Unavailable").tag("unavailable").disabled(true)
                        Divider()
                        Text(verbatim: "Other").tag("other")
                    }
                }
                Text("Menu selected: \(sampleMenuOption) · changes: \(sampleMenuSelections)").font(SettingsFont.caption)
                SettingsRow(title: "Long menu", description: "Original Picker with40 options", verbatimTitle: true, verbatimDescription: true) {
                    SettingsMenuPicker(selection: $sampleLongMenu) {
                        ForEach(1 ... 40, id: \.self) { option in Text("Option \(option)").tag(option) }
                    }
                }
                #endif
                SettingsSlider(
                    title: "Slider",
                    valueText: String(format: "%.2f", sliderValue),
                    description: "Always-in-effect value with a live readout.",
                    value: $sliderValue,
                    range: 0 ... 1,
                    step: 0.05
                )
                SettingsRow(
                    title: "Date picker",
                    description: "Compact date and time field.",
                    verbatimTitle: true,
                    verbatimDescription: true
                ) {
                    VStack(alignment: .trailing, spacing: theme.space.s4) {
                        SettingsDatePicker(label: "Date picker", selection: $date, components: [.date, .hourAndMinute])
                        Text(verbatim: "Selected: " + date.formatted(date: .numeric, time: .shortened))
                            .font(SettingsFont.rowDescription)
                            .foregroundStyle(theme.text.secondary)
                    }
                }
                #if OSAURUS_DESIGN_INSPECTOR
                SettingsRow(title: "Minimum-date variant", description: "The original DatePicker with its existing lower bound.", verbatimTitle: true, verbatimDescription: true) {
                    VStack(alignment: .trailing, spacing: theme.space.s4) {
                        SettingsDatePicker(label: "Bounded date", selection: $boundedDate,
                            minimum: Self.verificationMinimumDate, components: [.date, .hourAndMinute])
                        Text("Minimum: \(Self.verificationMinimumDate.formatted(date: .numeric, time: .shortened)) · Selected: \(boundedDate.formatted(date: .numeric, time: .shortened))")
                            .font(SettingsFont.rowDescription).foregroundStyle(theme.text.secondary)
                    }
                }
                #endif
                if !catalogPreview { SettingsPermissionRow(permission: .accessibility, description: "Live status from System Settings.") }
            }
        }

        // MARK: Fields

        private var fields: some View {
            SettingsSection(title: "Fields", verbatimTitle: true) {
                VStack(alignment: .leading, spacing: theme.space.s12) {
                    SettingsFieldRow(
                        label: "Empty",
                        hint: "Hint text under the field.",
                        verbatimHint: true,
                        verbatimLabel: true
                    ) {
                        SettingsTextField(placeholder: "Placeholder", text: $text)
                    }
                    SettingsFieldRow(label: "Icon, filled", verbatimLabel: true) {
                        SettingsTextField(placeholder: "Handle", text: $filledText, icon: "at")
                    }
                    SettingsFieldRow(label: "Secure, revealable, monospaced", verbatimLabel: true) {
                        SettingsTextField(
                            placeholder: "API key",
                            text: $secret,
                            monospaced: true,
                            isSecure: true,
                            revealable: true
                        )
                    }
                    SettingsFieldRow(
                        label: "Invalid",
                        hint: "Explains the problem.",
                        verbatimHint: true,
                        verbatimLabel: true
                    ) {
                        SettingsTextField(placeholder: "https://", text: .constant("not a url"), isInvalid: true)
                    }
                    SettingsFieldRow(label: "Disabled", verbatimLabel: true) {
                        SettingsTextField(placeholder: "Locked", text: .constant("read-only")).disabled(true)
                    }
                    SettingsFieldRow(label: "Editor", hint: "Multiline helper text", verbatimHint: true, verbatimLabel: true) {
                        SettingsTextEditor(text: $notes, placeholder: "Notes", minHeight: 64)
                    }
                    #if OSAURUS_DESIGN_INSPECTOR
                    SettingsFieldRow(label: "Empty editor", hint: "Type or paste multiple paragraphs.", verbatimHint: true, verbatimLabel: true) {
                        SettingsTextEditor(text: .constant(""), placeholder: "Editor placeholder", minHeight: 64)
                    }
                    SettingsFieldRow(label: "Invalid editor", hint: "Check this editor value.", verbatimHint: true, verbatimLabel: true) {
                        SettingsTextEditor(text: .constant("Invalid editor value"), minHeight: 64, isInvalid: true)
                    }
                    SettingsFieldRow(label: "Disabled editor", hint: "Read-only sample.", verbatimHint: true, verbatimLabel: true) {
                        SettingsTextEditor(text: .constant("Read-only editor value"), minHeight: 64).disabled(true)
                    }
                    #endif
                    SettingsFieldRow(label: "Search", verbatimLabel: true) {
                        SearchField(text: $search, placeholder: "Search", fillsAvailableWidth: true)
                    }
                }
                .settingsRowChrome()
                SettingsTextFieldRow(
                    label: "Text field row",
                    text: $filledText,
                    placeholder: "value",
                    help: "Label, help, and field in one row."
                )
            }
        }

        // MARK: Sections

        private var sections: some View {
            VStack(alignment: .leading, spacing: theme.settingsSectionGap) {
                SettingsSection(
                    title: "Grouped with Accessory",
                    caption: "Caption",
                    subtitle: "Subtitle under the title.",
                    verbatimTitle: true
                ) {
                    SettingsButton(.secondary, "Accessory", size: .compact, verbatim: true) {}
                } content: {
                    SettingsValueRow(title: "Row", value: "Value", verbatimTitle: true)
                        .settingsSearchHighlight(showsSearchGlow)
                }
                SettingsSection(title: "With Icon", verbatimTitle: true, icon: "calendar.badge.clock") {
                    SettingsValueRow(title: "Row", value: "Value", verbatimTitle: true)
                }
                SettingsSection(title: "Plain Layout", layout: .plain, verbatimTitle: true) {
                    Text(verbatim: "Plain sections hold cards and grids without a group surface.")
                        .font(SettingsFont.body)
                        .foregroundColor(theme.text.secondary)
                }
                SettingsAdvancedDisclosure {
                    SettingsToggle(title: "Hidden until expanded", verbatim: true, isOn: $checkboxOn)
                }
                SettingsDestructiveZone {
                    SettingsDestructiveRow(
                        title: "Reset",
                        description: "Warning severity.",
                        actionTitle: "Reset",
                        severity: .warning
                    ) {}
                    SettingsDestructiveRow(title: "Delete", description: "Destructive severity.", actionTitle: "Delete")
                    {}
                }
            }
        }

        // MARK: Notices and sheets

        private var noticesAndSheets: some View {
            VStack(alignment: .leading, spacing: theme.settingsSectionGap) {
                SettingsCallout(
                    icon: "person.badge.key",
                    title: "Callout",
                    message: "A page-level state the user must act on first.",
                    tone: .info
                ) {
                    SettingsButton(.primary, "Set Up", size: .compact, verbatim: true) {}
                }
                SettingsCallout(
                    icon: "exclamationmark.bubble",
                    title: "Callout with a quote",
                    message: "Someone else's words, shown as they wrote them.",
                    tone: .warning,
                    quote: "Step names don't say what they do. Rename them and resubmit."
                ) {
                    SettingsButton(.primary, "Revise", size: .compact, verbatim: true) {}
                }
                SettingsSection(title: "Sheet Chrome", layout: .plain, verbatimTitle: true) {
                    VStack(spacing: 0) {
                        SettingsSheetHeader(icon: "sparkles", title: "Sheet title", subtitle: "Subtitle", onClose: {})
                        Text(verbatim: "Body content")
                            .font(SettingsFont.body)
                            .foregroundColor(theme.text.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                        SettingsSheetFooter(
                            primary: .init(label: "Save") {},
                            secondary: .init(label: "Cancel") {},
                            destructive: .init(label: "Delete", isDestructive: true) {},
                            hint: "+ Enter to save"
                        )
                    }
                    .settingsChrome(.card)
                }
                SettingsSection(title: "Drill-In Rows", verbatimTitle: true) {
                    SettingsDrillInRows(items: GalleryDrillIn.allCases, badges: [.second: 2]) { _ in }
                }
            }
        }

        // MARK: Library

        private var library: some View {
            SettingsSection(title: "Library", layout: .plain, verbatimTitle: true) {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(0 ..< 3) { index in
                            LibraryCard(
                                title: ["Card", "Selected card", "Placeholder subtitle"][index],
                                subtitle: index == 2
                                    ? "No description" : "A short description that wraps onto two lines.",
                                subtitleIsPlaceholder: index == 2,
                                isSelected: librarySelected == index,
                                action: { librarySelected = index }
                            ) {
                                LibraryIcon(
                                    symbol: ["shippingbox", "star", "doc"][index],
                                    tint: theme.action.primary.default.background
                                )
                            } badges: {
                                if index == 1 { StatusChip("New", tone: .accent) }
                            } content: {
                                LibraryCardPreview(text: "Existing card body")
                            } footer: {
                                LibraryStatRow(stats: [
                                    LibraryStat(icon: "clock", text: "2d ago"),
                                    LibraryStat(
                                        icon: "exclamationmark.triangle",
                                        text: "1 issue",
                                        isWarning: index == 0
                                    ),
                                ])
                            } menu: {
                                #if OSAURUS_DESIGN_INSPECTOR
                                Button { sampleMenuActions += 1 } label: { Text(verbatim: "Duplicate") }
                                #else
                                Button(action: {}) { Text(verbatim: "Duplicate") }
                                #endif
                            }
                        }
                    }
                    SettingsGroup {
                        LibraryRow(title: "Library row", subtitle: "Subtitle", showsChevron: true, action: {}) {
                            LibraryIcon(symbol: "folder", tint: theme.action.primary.default.background, size: 28)
                        } badges: {
                            StatusChip("Synced", tone: .success)
                        }
                        LibraryRow(
                            title: "Selected row",
                            subtitle: "~/path/monospaced",
                            monospacedSubtitle: true,
                            isSelected: true,
                            action: {}
                        ) {
                            LibraryIcon(symbol: "terminal", tint: theme.status.warning.foreground, size: 28)
                        } trailing: {
                            CountBadge(4)
                        }
                    }
                }
            }
        }

        // MARK: Data Table

        private struct GalleryTableRow: Identifiable {
            let id: String
            let size: Double
            let status: String
        }

        private var dataTableRows: [GalleryTableRow] {
            let rows = [
                GalleryTableRow(id: "First", size: 4.3, status: "Ready"),
                GalleryTableRow(id: "Second", size: 37.6, status: "Too large"),
                GalleryTableRow(id: "Third", size: 0.6, status: "Downloading"),
            ]
            guard let sort = dataTableSort else { return rows }
            let sorted = sort.key == "size" ? rows.sorted { $0.size < $1.size } : rows.sorted { $0.id < $1.id }
            return sort.ascending ? sorted : sorted.reversed()
        }

        private var dataTable: some View {
            SettingsSection(title: "Data table", layout: .plain, verbatimTitle: true) {
                VStack(alignment: .leading, spacing: 12) {
                    controlSwitch("Loading", $dataTableLoading)
                    SettingsDataTable(
                        columns: [
                            SettingsDataTableColumn(id: "name", title: "Name", width: .flexible(min: 160), sortKey: "name"),
                            SettingsDataTableColumn(
                                id: "size", title: "Size", width: .fixed(80), alignment: .trailing,
                                sortKey: "size", hidePriority: 1),
                            SettingsDataTableColumn(id: "status", title: "Status", width: .fixed(110), alignment: .trailing),
                        ],
                        rows: dataTableLoading ? [] : dataTableRows,
                        sort: $dataTableSort,
                        selection: $dataTableSelection,
                        isLoading: dataTableLoading
                    ) { row, column in
                        switch column.id {
                        case "name":
                            Text(verbatim: row.id).font(SettingsFont.rowTitle).foregroundColor(theme.text.primary)
                        case "size":
                            Text(verbatim: "\(row.size) GB").font(SettingsFont.caption.monospacedDigit())
                                .foregroundColor(theme.text.secondary)
                        default:
                            StatusChip(row.status, tone: row.status == "Ready" ? .success : .neutral)
                        }
                    }
                }
            }
        }

        // MARK: Indicators

        #if OSAURUS_DESIGN_INSPECTOR
        private var liveIndicatorChecks: some View {
            SettingsSection(title: "Live indicator checks", verbatimTitle: true) {
                SettingsRow(title: "Raw progress value", description: "Local sample data; the progress bar handles values outside0–100%.", verbatimTitle: true, verbatimDescription: true) {
                    SettingsStepper(value: $indicatorValue, range: -50...150, step: 5, unit: "%")
                }
                SettingsRow(title: "Dynamic progress", verbatimTitle: true) {
                    Text(verbatim: indicatorInvalidValue ? "No valid progress value" : "Raw value: \(indicatorValue)%")
                        .font(SettingsFont.caption)
                } trailing: {
                    SettingsProgressBar(value: indicatorInvalidValue ? .nan : Double(indicatorValue) / 100)
                        .frame(width: 220).accessibilityLabel("Dynamic progress")
                }
                SettingsRow(title: "Loading state", description: "Local waiting, running, completion and failure states.", verbatimTitle: true, verbatimDescription: true) {
                    SettingsMenuPicker(selection: $indicatorPhase) {
                        ForEach(IndicatorPhase.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                    }
                }
                HStack {
                    Toggle("Invalid value", isOn: $indicatorInvalidValue).toggleStyle(.checkbox)
                    Toggle("Reduced motion check", isOn: $indicatorReducedMotion).toggleStyle(.checkbox)
                }
                if indicatorPhase.isLoading {
                    ProgressView("Standalone loading indicator").assignedProgressIndicator()
                }
                SidebarSearchField(text: $indicatorSearchText, placeholder: "Existing sidebar search indicator",
                    isFocused: $indicatorSearchFocused, isSearching: indicatorPhase.isLoading)
            }
            .environment(\.inspectorForceReducedMotion, indicatorReducedMotion)
            .onChange(of: indicatorPhase) { _, phase in
                if phase == .complete { indicatorValue = 100; indicatorInvalidValue = false }
                else if phase == .waiting { indicatorValue = 0; indicatorInvalidValue = false }
            }
        }
        #endif

        @ViewBuilder private var indicators: some View {
            #if OSAURUS_DESIGN_INSPECTOR
            liveIndicatorChecks
            #endif
            SettingsSection(title: "Indicators", verbatimTitle: true) {
                SettingsRow(title: "Progress", verbatimTitle: true) {
                    EmptyView()
                } trailing: {
                    VStack(spacing: 8) {
                        SettingsProgressBar(value: 0)
                        SettingsProgressBar(value: 0.4)
                        SettingsProgressBar(value: 1, tint: theme.status.success.foreground)
                    }
                    .frame(width: 220)
                }
                SettingsRow(title: "Skeleton", verbatimTitle: true) {
                    EmptyView()
                } trailing: {
                    HStack(spacing: 10) {
                        SettingsSkeletonBar(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsSkeletonBar(width: 140, height: 12)
                            SettingsSkeletonBar(width: 90, height: 9)
                        }
                    }
                    .settingsShimmer()
                }
                SettingsRow(title: "Step tracker", verbatimTitle: true) {
                    EmptyView()
                } trailing: {
                    VStack(spacing: 16) {
                        SettingsStepTracker(steps: [
                            SettingsStep(id: "a", title: "Listing", state: .done),
                            SettingsStep(id: "b", title: "Signed and uploaded", state: .done),
                            SettingsStep(id: "c", title: "Review", detail: "Usually within 24 hours", state: .waiting),
                            SettingsStep(id: "d", title: "In the store", state: .upcoming),
                        ])
                        SettingsStepTracker(steps: [
                            SettingsStep(id: "a", title: "Listing", state: .done),
                            SettingsStep(id: "b", title: "Uploading", state: .working),
                            SettingsStep(id: "c", title: "Review", detail: "Changes requested", state: .attention),
                            SettingsStep(id: "d", title: "Failed", state: .failed),
                            SettingsStep(id: "e", title: "Skipped", state: .skipped),
                        ])
                    }
                    .frame(width: 420)
                }
                SettingsRow(title: "Icon tiles", verbatimTitle: true) {
                    EmptyView()
                } trailing: {
                    HStack(spacing: 8) {
                        SettingsIconTile(icon: "gearshape")
                        SettingsIconTile(icon: "bolt.fill", tint: theme.status.warning.foreground)
                        SettingsIconTile(icon: "sparkles", size: 36, gradient: [theme.status.info.foreground, theme.status.info.background])
                    }
                }
            }
            #if OSAURUS_DESIGN_INSPECTOR
            .environment(\.inspectorForceReducedMotion, indicatorReducedMotion)
            #endif
        }

        // MARK: Status and findings

        private var statusAndFindings: some View {
            VStack(alignment: .leading, spacing: theme.settingsSectionGap) {
                SettingsFeatureCards(features: [
                    SettingsFeature(icon: "slider.horizontal.3", title: "Feature", caption: "What this page does."),
                    SettingsFeature(icon: "bolt", title: "Second", caption: "A caption long enough to wrap onto a second line."),
                    SettingsFeature(icon: "folder", title: "Third", caption: "Equal heights."),
                ])
                SettingsSection(title: "Stat Strip", verbatimTitle: true) {
                    SettingsStatStrip(stats: [
                        SettingsStat(label: "Calls", value: "1,204"),
                        SettingsStat(label: "Latency", value: "212ms"),
                        SettingsStat(label: "Errors", value: "3"),
                    ])
                }
                SettingsSection(title: "Stat Tiles", layout: .plain, verbatimTitle: true) {
                    SettingsStatStrip(
                        stats: [
                            SettingsStat(label: "Uptime", value: "3h 12m", icon: "clock"),
                            SettingsStat(label: "CPU", value: "12%", icon: "cpu"),
                            SettingsStat(label: "Memory", value: "1.2 GB", icon: "memorychip"),
                            SettingsStat(label: "Disk", value: "4.0 GB", icon: "internaldrive"),
                        ],
                        style: .tiles(columns: 3)
                    )
                }
                SettingsStatusHero(
                    title: "Status Hero",
                    icon: "antenna.radiowaves.left.and.right",
                    valueLabel: "Value",
                    value: "http://192.168.1.10:1337"
                ) {
                    #if OSAURUS_DESIGN_INSPECTOR
                    StatusChip(indicatorPhase.title, tone: indicatorPhase.tone, showsDot: true)
                    #else
                    StatusChip("Running", tone: .success, showsDot: true)
                    #endif
                } actions: {
                    SettingsButton(.secondary, "Action", size: .compact, verbatim: true) {}
                }
                SettingsSection(title: "Finding Rows", layout: .plain, verbatimTitle: true) {
                    VStack(spacing: theme.space.s8) {
                        SettingsFindingRow(severity: .ok, title: "Healthy", value: "Granted", detail: "Quiet well.")
                        SettingsFindingRow(severity: .info, title: "Informational", detail: "No action needed.")
                        SettingsFindingRow(
                            severity: .warning,
                            title: "Needs setup",
                            code: "missing_root",
                            detail: "The folder does not exist yet.",
                            fix: "Create it and run again."
                        )
                        SettingsFindingRow(
                            severity: .blocked,
                            title: "Blocked",
                            code: "not_writable",
                            detail: "Osaurus cannot write here.",
                            fix: "chmod u+w ~/path"
                        )
                        SettingsFindingRow(severity: .inactive, title: "Inactive", value: "Off", detail: "Feature is off.")
                    }
                }
            }
        }

        // MARK: Empty states

        private func changeEmptyPhase(_ phase: String) { sampleEmptyActions += 1; sampleEmptyPhase = phase }
        private var remainingEmptyStates: some View {
            SettingsSection(title: "Remaining empty-state variants", layout: .plain, verbatimTitle: true) {
                SettingsMenuPicker(selection: $sampleEmptyPhase) {
                    ForEach(["Empty", "Loading", "Unavailable", "Ready"], id: \.self) { Text(verbatim: $0).tag($0) }
                }
                SettingsToggle(title: "Reduced motion check", verbatim: true, isOn: $sampleEmptyReducedMotion)
                SettingsToggle(title: "Hero content appeared", verbatim: true, isOn: $sampleHeroAppeared)
                Text(verbatim: "Empty action count: \(sampleEmptyActions)").font(SettingsFont.caption)
                Group {
                    switch sampleEmptyPhase {
                    case "Loading": SettingsEmptyState(loading: "Loading local item")
                    case "Unavailable": SettingsEmptyState(inline: "wifi.slash", title: "Local content unavailable",
                        hint: "Local fixture; no network request is made.",
                        action: .init(title: "Retry local item", icon: "arrow.clockwise") { changeEmptyPhase("Loading") },
                        secondaryAction: .init(title: "Cancel local retry", icon: "") { changeEmptyPhase("Empty") })
                    case "Ready": Text(verbatim: "One local item is ready")
                        .assignedTypography("component.library.19.text", fallback: SettingsFont.body)
                        .frame(maxWidth: .infinity, minHeight: theme.assignedMetric("component.library.19.height", fallback: 100))
                    default: SettingsEmptyState(inline: "tray", title: "No local items", hint: "Exercise the existing loading and content states.",
                        action: .init(title: "Load local item", icon: "plus") { changeEmptyPhase("Loading") })
                    }
                }
                HStack {
                    SettingsButton(.secondary, "Complete local loading", verbatim: true) { changeEmptyPhase("Ready") }
                        .disabled(sampleEmptyPhase != "Loading")
                    SettingsButton(.secondary, "Reset local empty", verbatim: true) { changeEmptyPhase("Empty") }
                }
                SettingsEmptyState(icon: "tray", title: "Full hero empty", subtitle: "The existing full-size hero with a static status disc.",
                    primaryAction: .init(title: "Hero primary action", icon: "plus") { sampleEmptyActions += 1 },
                    secondaryAction: .init(title: "Hero secondary action", icon: "book") { sampleEmptyActions += 1 },
                    hasAppeared: sampleHeroAppeared, footnote: "Existing optional footnote")
                    .frame(minHeight: 420)
                SettingsEmptyState(icon: "sparkles", title: "Custom content empty", subtitle: "Existing compact custom-content slot.",
                    content: AnyView(Text(verbatim: "Custom local body")),
                    compact: true, footnote: "Custom-content footnote")
                    .frame(minHeight: 360)
            }
            .environment(\.inspectorForceReducedMotion, sampleEmptyReducedMotion)
        }
        private var emptyStates: some View {
            SettingsSection(title: "Empty States", layout: .plain, verbatimTitle: true) {
                VStack(spacing: 12) {
                    SettingsEmptyState(
                        inline: "tray",
                        title: "Inline empty",
                        hint: "Section, list, or filter with nothing in it.",
                        action: .init(title: "Add", icon: "plus", handler: {})
                    )
                    .settingsChrome(.card)
                    SettingsEmptyState(inline: "arrow.clockwise", title: "Inline loading", isLoading: true)
                        .settingsChrome(.card)
                    SettingsEmptyState(loading: "Loading…")
                        .settingsChrome(.card)
                    SettingsEmptyState(
                        icon: "sparkles",
                        title: "Hero empty",
                        subtitle: "First-run page with examples and actions.",
                        examples: [
                            .init(icon: "1.circle", title: "Example", description: "What you can do."),
                            .init(icon: "2.circle", title: "Another", description: "And this."),
                        ],
                        primaryAction: .init(title: "Get started", icon: "plus", handler: {}),
                        secondaryAction: .init(title: "Learn more", icon: "book", handler: {}),
                        compact: true
                    )
                    .frame(height: 420)
                    .settingsChrome(.card)
                }
            }
        }

        // MARK: Samples

        private enum GalleryDrillIn: String, SettingsDrillInItem, CaseIterable {
            case first, second
            var id: String { rawValue }
            var title: String { self == .first ? "Drill-in row" : "With badge" }
            var icon: String { self == .first ? "folder" : "bell" }
            var subtitle: String { "Opens a detail view" }
        }

        private static let chromes: [(String, SettingsChrome)] = [
            ("surface", .surface), ("card", .card), ("cardHover", .cardHover), ("overlay", .overlay), ("control", .control),
            ("subtle", .subtle), ("hover", .hover), ("inset", .inset),
            ("status", .status(.warning)), ("selected", .selected),
        ]

        private static let roles: [(String, SettingsButtonRole)] = [
            ("Primary", .primary), ("Secondary", .secondary), ("Tertiary", .tertiary), ("Destructive", .destructive),
        ]

        private static let sizes: [(String, SettingsButtonSize)] = [("regular", .regular), ("compact", .compact)]

        private static let pickerOptions: [SettingsPickerRow<String>.Option] = [
            .init("fast", "Fast", verbatim: true),
            .init("balanced", "Balanced", verbatim: true),
            .init("quality", "Quality", verbatim: true),
        ]
    }

    private enum GalleryTab: String, AnimatedTabItem {
        case overview, details, history
        var title: String { rawValue.capitalized }
    }

    private enum GalleryFilter: String, CaseIterable, Hashable {
        case local, remote
    }

    /// Developer Tools → Server entry for the gallery (Debug builds only).
    struct SettingsKitGallerySection: View {
        @Environment(\.theme) private var theme
        @State private var isPresented = false

        var body: some View {
            SettingsSection(title: "Settings Kit Gallery", verbatimTitle: true) {
                SettingsRow(
                    title: "Component gallery",
                    description: "Every settings component in every state. Debug builds only.",
                    verbatimTitle: true,
                    verbatimDescription: true
                ) {
                    SettingsButton(.secondary, "Open", icon: "square.grid.2x2", verbatim: true) { isPresented = true }
                }
            }
            .sheet(isPresented: $isPresented) {
                VStack(spacing: 0) {
                    SettingsKitGallery()
                    HStack {
                        Spacer()
                        SettingsButton(.primary, "Done", verbatim: true) { isPresented = false }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(theme.space.s16)
                }
                .frame(minWidth: 860, idealWidth: 960, minHeight: 680, idealHeight: 820)
            }
        }
    }

    #Preview("Settings Kit Gallery") {
        SettingsKitGallery()
            .frame(width: 960, height: 900)
    }

#endif
