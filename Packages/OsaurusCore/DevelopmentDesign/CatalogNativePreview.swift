#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI
import AppKit

/// Uses the existing app implementations and existing safe sample hosts. There
/// is no parallel drawing of these components in the design inspector.
struct CatalogNativePreview: View {
    let family: Int
    @EnvironmentObject private var inspection: CatalogPreviewInspection
    var body: some View {
        content.environment(\.nativeCatalogInspection, inspection)
            .environment(\.nativeCatalogSelection, inspection.selected)
    }
    @ViewBuilder private var content: some View {
        switch family {
        case 4...12: CatalogBaseControlPreview(family: family)
        case 65: CatalogSharedContextMenuPreview()
        case 56: CatalogSharedChipsPreview()
        case 57: CatalogSharedSectionsPreview()
        case 3: CatalogNativeEditorPreview()
        case 24: InspectorAttachmentConfigurations()
        case 26: InspectorModelPickerVerification(catalogPreview: true)
        case 28: InspectorMessageConfigurations(isAssistant: false)
        case 29: InspectorMessageConfigurations(isAssistant: true)
        case 30: InspectorMessageHeaderVerification()
        case 31: InspectorRichTextConfigurations()
        case 32: InspectorCodeBlockVerification()
        case 33: InspectorThinkingVerification()
        case 34: InspectorActivityVerification()
        case 35: InspectorAgentProgressVerification()
        case 36: InspectorPromptVerification()
        case 37: InspectorArtifactConfigurations()
        case 38: InspectorFileHistoryVerification()
        case 39: InspectorTerminalChartConfigurations()
        case 40: InspectorNoticeVerification()
        case 44: CatalogNativeFindPreview()
        case 54: InspectorImagePanelVerification()
        default: SettingsKitGallery(inspectorFamily: family, catalogPreview: true)
        }
    }
}
private struct CatalogSharedSectionsPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(title: "Section title", caption: "Optional summary",
                subtitle: "Supporting text explains the group.", footer: "Optional footer below the group.", verbatimTitle: true) {
                SettingsValueRow(title: "Setting", value: "Value", verbatimTitle: true)
                SettingsValueRow(title: "Another setting", value: "Value", verbatimTitle: true)
            }
            SettingsSection(title: "Plain section", layout: .plain, verbatimTitle: true) {
                Text("Used above cards and custom content, without a group surface.")
            }
        }
    }
}
private struct CatalogSharedChipsPreview: View {
    @State private var selectedSelectors: Set<String> = []
    @State private var selectedFilters: Set<String> = []
    private func toggle(_ size: SharedChipSize, in values: inout Set<String>) {
        if values.contains(size.rawValue) { values.remove(size.rawValue) }
        else { values.insert(size.rawValue) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(SharedChipSize.allCases, id: \.self) { size in
                VStack(alignment: .leading, spacing: 12) {
                    Text(size.rawValue.capitalized).font(.headline)
                    HStack(spacing: 12) {
                        Button { toggle(size, in: &selectedSelectors) } label: {
                            SharedChipContent(spacing: 6) {
                                Text("Selector")
                                Image(systemName: "chevron.down")
                            }
                                .composerChipTextStyle(.label).composerChipInk("foreground", fallback: .primary)
                                .composerChipSurface(selected: selectedSelectors.contains(size.rawValue))
                        }.composerChipButtonStyle().composerChipFocus()
                        FilterChip("Filter", isSelected: selectedFilters.contains(size.rawValue)) { toggle(size, in: &selectedFilters) }
                        FilterTokenChip("Applied filter") {}
                    }.environment(\.sharedChipSize, size)
                }
            }
        }
    }
}
private struct CatalogNativeFindPreview: View {
    @State private var query = "sample"
    @State private var index = 0
    var body: some View {
        ChatFindBar(query: $query, matchIndex: index, matchCount: query.isEmpty ? 0 : 3,
            onPrevious: { index = (index + 2) % 3 }, onNext: { index = (index + 1) % 3 }, onClose: { query = "" })
    }
}
struct CatalogNativeArtifactPreview: NSViewRepresentable {
    let artifact: SharedArtifact
    @Environment(\.theme) private var theme
    func makeNSView(context: Context) -> NativeArtifactCardView { NativeArtifactCardView() }
    func updateNSView(_ view: NativeArtifactCardView, context: Context) {
        defer { view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection) }
        view.catalogAssignmentTarget(["background", "radius", "border", "borderWidth", "padding", "gap", "height"].map { "component.library.37." + $0 }, name: "Artifact card", theme: theme)
        view.configure(artifact: artifact, theme: theme)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeArtifactCardView, context: Context) -> CGSize? {
        let width = proposal.width ?? 500
        return CGSize(width: width, height: nsView.measuredCardHeight(width: width))
    }
}
#endif

#if OSAURUS_DESIGN_INSPECTOR
/// Standalone uses of the real shared menu, with the app's actual action names.
private struct CatalogSharedContextMenuPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Add to chat · composer + menu").font(.headline)
            ChatContextMenu {
                action("Add folder", icon: "folder")
                action("Attach files", icon: "paperclip")
                action("Add Workflow", icon: "point.forward.to.point.capsulepath")
                action("Slash commands", icon: "slash.forward")
            }
            Text("Chat row · right-click and ellipsis").font(.headline)
            ChatContextMenu {
                action("Open in New Window", icon: "macwindow.badge.plus")
                ChatContextMenuDivider()
                action("Rename")
                action("Pin")
                ChatContextMenuDivider()
                action("Export…")
                ChatContextMenuDivider()
                action("Archive")
                action("Delete")
            }
            Text("Row states · same menu action control").font(.headline)
            ChatContextMenu {
                action("Default")
                action("Keyboard highlight", selected: true)
                action("Disabled", disabled: true)
            }
        }
    }
    private func action(_ title: String, icon: String? = nil, selected: Bool = false, disabled: Bool = false) -> some View {
        Button {} label: {
            ChatContextMenuLabel(title: Text(verbatim: title), icon: Group {
                if icon == "slash.forward" { Text("/") }
                else if let icon { Image(systemName: icon) } else { Color.clear }
            })
        }.buttonStyle(ChatContextMenuRowStyle(selected: selected)).disabled(disabled)
    }
}
#endif
