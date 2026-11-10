#if OSAURUS_DESIGN_INSPECTOR
// Adapted from the preserved full component inspector; layout and catalog retained.
import SwiftUI
import AppKit

@MainActor final class CatalogDesignStore: ObservableObject {
    @Published var document: [String: Any] = [:] {
        didSet { refreshLookups() }
    }
    // Bridging the entire JSON dictionary on every property lookup is linear
    // in the catalog size. Convert once when the document actually changes.
    private var tokenLookup: [String: [String: Any]] = [:]
    private var mappingLookup: [String: String] = [:]
    private var assignmentChoiceCache: [String: [String]] = [:]
    private func refreshLookups() {
        assignmentChoiceCache.removeAll(keepingCapacity: true)
        tokenLookup = (document["tokens"] as? [String: Any])?["semanticTokens"] as? [String: [String: Any]] ?? [:]
        mappingLookup = (document["components"] as? [String: Any])?["mappings"] as? [String: String] ?? [:]
    }
    @Published var status = "All changes saved"
    @Published var revision = 0
    @Published var snapshots: [URL] = []
    let root: URL
    var undoStack: [Data] = []
    var redoStack: [Data] = []
    var file: URL { root.appendingPathComponent("Design/design.json") }
    nonisolated static let inputDefaults = DesignLibraryDefaults.inputDefaults
    func completeInputMappings() -> Bool {
        var c = document["components"] as? [String:Any] ?? [:]
        var m = c["mappings"] as? [String:String] ?? [:]
        var added = false
        for (key,role) in Self.inputDefaults.merging(DesignButtonBindings.libraryDefaults, uniquingKeysWith: { old, _ in old }) where m[key] == nil {m[key]=role;added=true}
        for spec in CatalogcomponentCatalog where spec.id > 2 {
            for (key,role) in spec.defaults where m[key] == nil {m[key]=role;added=true}
        }
        c["mappings"]=m;document["components"]=c
        return added
    }
    init() {
        root = DesignWorkingStore.shared.root
        document = DesignWorkingStore.shared.catalogDocument()
        refreshLookups()
        status = DesignWorkingStore.shared.status
        listSnapshots()
    }
    static func read(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        return object
    }
    var tokens: [String: [String: Any]] { tokenLookup }
    var mappings: [String: String] { mappingLookup }
    func value(_ role: String, _ mode: String) -> Any { tokens[role]?[mode] ?? "" }
    func role(_ key: String) -> String { mappings[key] ?? key }
    func number(_ role: String, _ mode: String) -> Double { value(role, mode) as? Double ?? 0 }
    func metric(_ key: String, _ mode: String) -> Double { number(role(key), mode) }
    func color(_ role: String, _ mode: String) -> Color { Color(nsColor: CatalognsColor(value(role,mode) as? String ?? "#00000000")) }
    func data() -> Data { (try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])) ?? Data() }
    func change(_ edit: () -> Void) { undoStack.append(data()); redoStack.removeAll(); edit(); save() }
    func setValue(_ role: String, _ mode: String, _ value: Any) {
        change { var t = document["tokens"] as? [String: Any] ?? [:]; var all = tokens; all[role]?[mode] = value; t["semanticTokens"] = all; document["tokens"] = t }
    }
    // Geometry is shared across appearances; one edit is one undo transaction.
    func setSharedDimension(_ role: String, _ value: Double) {
        change {
            var t = document["tokens"] as? [String: Any] ?? [:]; var all = tokens
            for mode in ["light", "dark"] { all[role]?[mode] = value; updateScalarBinding(role, mode: mode, value: value) }
            t["semanticTokens"] = all; document["tokens"] = t
        }
    }
    // Update only the edited property, retaining other appearance-specific edits.
    func setTypographyField(_ role: String, _ field: String, _ value: Any, mode: String) {
        setTokenProperty(role, mode: mode, value: value, field: field)
    }
    func assignmentChoices(key: String, kind: String, mode: String) -> [String] {
        let cacheKey = kind + "|" + mode + "|" + key
        if let cached = assignmentChoiceCache[cacheKey] { return cached }
        let result = tokens.keys.filter{ !["color.surface.none","color.border.none"].contains($0) && tokens[$0]?["type"] as? String == kind && (kind != "dimension" || value($0,mode) is Double) && CatalogAssignmentMenu.allows($0, for:key, kind:kind)}.sorted {
            if kind == "typography" {
                let a = value($0,mode) as? [String:Any] ?? [:], b = value($1,mode) as? [String:Any] ?? [:]
                let sa = a["size"] as? Double ?? 0, sb = b["size"] as? Double ?? 0
                if sa != sb { return sa < sb }
                let wa = a["weight"] as? Double ?? 0, wb = b["weight"] as? Double ?? 0
                if wa != wb { return wa < wb }
            }
            if kind == "dimension" {let a=number($0,mode),b=number($1,mode);return a == b ? $0.localizedStandardCompare($1) == .orderedAscending : a < b}
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
        assignmentChoiceCache[cacheKey] = result
        return result
    }
    func dimensionRoles(_ prefix: String, _ mode: String) -> [String] {
        tokens.keys.filter { $0.hasPrefix(prefix) && tokens[$0]?["type"] as? String == "dimension" }.sorted {
            // Spacing scale names retain their numeric order even after value edits.
            if prefix == "space." { return $0.localizedStandardCompare($1) == .orderedAscending }
            let a = number($0, mode), b = number($1, mode)
            return a == b ? $0.localizedStandardCompare($1) == .orderedAscending : a < b
        }
    }
    func setTokenProperty(_ token:String, mode:String, value:Any, field:String? = nil, linked:Bool = false) {
        change {
            var t = document["tokens"] as? [String:Any] ?? [:]; var all = tokens
            for target in (linked || tokens[token]?["type"] as? String == "dimension") ? ["light","dark"] : [mode] {
                updateScalarBinding(token + (field.map { "." + $0 } ?? ""), mode: target, value: value)
                if let field { var recipe = all[token]?[target] as? [String:Any] ?? [:]; recipe[field] = value; all[token]?[target] = recipe }
                else { all[token]?[target] = value }
            }
            t["semanticTokens"] = all; document["tokens"] = t
        }
    }
    func offersAppDefault(_ key: String) -> Bool {
        if CatalogLayoutAssignments.byKey[key] != nil { return true }
        let parts = key.split(separator: ".")
        guard parts.count > 2, parts[0] == "component", parts[1] == "library", let family = Int(parts[2]) else { return false }
        if [28,29].contains(family), key.hasSuffix(".borderWidth") { return true }
        return [10, 13, 14, 15, 16, 17, 57].contains(family)
    }
    func usesAppDefault(_ key: String) -> Bool {
        guard offersAppDefault(key) else { return false }
        if CatalogLayoutAssignments.byKey[key] != nil {
            return !(document["explicitAssignments"] as? [String] ?? []).contains(key)
        }
        if key.hasSuffix(".borderWidth"), let family = Int(key.split(separator: ".")[2]), [28,29].contains(family) {
            return !MessageBubbleInspectionStyle.hasBorderOverride(family, snapshot: DesignThemeOverlay.shared.current())
        }
        let explicit = Set(document["explicitAssignments"] as? [String] ?? [])
        return !explicit.contains(key) && mappings[key] == DesignWorkingStore.shared.baseline.mappings[key]
    }
    func map(_ key: String, _ role: String) {
        change {
            var c = document["components"] as? [String: Any] ?? [:]; var m = mappings
            var explicit = Set(document["explicitAssignments"] as? [String] ?? [])
            if role == "__app_default__" {
                m[key] = DesignWorkingStore.shared.baseline.mappings[key]
                explicit.remove(key)
            } else { m[key] = role; explicit.insert(key) }
            c["mappings"] = m; document["components"] = c
            document["explicitAssignments"] = explicit.sorted()
        }
    }
    func save() {
        DesignWorkingStore.shared.replaceFromCatalog(document)
        document = DesignWorkingStore.shared.catalogDocument()
        status = DesignWorkingStore.shared.status
        revision += 1
    }
    func undo() { guard let previous = undoStack.popLast() else { return }; redoStack.append(data()); restore(previous) }
    func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(data()); restore(next) }
    func restore(_ data: Data) {
        do {
            guard let restored = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            document = restored; _ = completeInputMappings(); save()
        } catch { status = error.localizedDescription }
    }
    func reset() {
        change { document = DesignWorkingStore.shared.catalogDocument(baseline: true) }
    }
    func snapshot(_ name: String) {
        DesignWorkingStore.shared.snapshot(name)
        status = DesignWorkingStore.shared.status
        listSnapshots()
    }
    func listSnapshots() { snapshots = DesignWorkingStore.shared.snapshots }
    func loadSnapshot(_ url: URL) {
        undoStack.append(data()); redoStack.removeAll()
        DesignWorkingStore.shared.loadSnapshot(url)
        document = DesignWorkingStore.shared.catalogDocument()
        status = DesignWorkingStore.shared.status
        revision += 1
    }

}
func CatalognsColor(_ hex: String) -> NSColor {
    let s = hex.replacingOccurrences(of: "#", with: ""); guard let n = UInt64(s, radix: 16), [6,8].contains(s.count) else { return .clear }
    let v = s.count == 6 ? n << 8 | 255 : n
    return NSColor(srgbRed: Double((v >> 24) & 255)/255, green: Double((v >> 16) & 255)/255, blue: Double((v >> 8) & 255)/255, alpha: Double(v & 255)/255)
}
func CataloghexColor(_ color: Color) -> String {
    let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
    return String(format: "#%02X%02X%02X%02X", Int((c.redComponent*255).rounded()), Int((c.greenComponent*255).rounded()), Int((c.blueComponent*255).rounded()), Int((c.alphaComponent*255).rounded()))
}
func CatalogdesignFontWeight(_ w: Double) -> Font.Weight { switch w { case ..<150:return .ultraLight; case ..<250:return .thin; case ..<350: return .light; case ..<450:return .regular; case ..<550:return .medium; case ..<650:return .semibold; case ..<750:return .bold; case ..<850:return .heavy; default:return .black } }
let Catalogvariants = ["brand", "primary", "secondary", "tertiary", "destructive"]
let Catalogstates = ["default", "hover", "pressed", "disabled"]

struct CatalogTokenButton: View {
    @ObservedObject var store: CatalogDesignStore
    var variant: String
    var mode: String
    var forced: String? = nil
    var showFocus = false
    var label = "Continue"
    var scale = 1.0
    var symbol:String? = nil
    var iconOnly=false
    var loading=false
    var buttonSize: SettingsButtonSize? = nil
    var familyKey: String? = nil
    var action: () -> Void = {}
    @State private var hover = false
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) { HStack(spacing: buttonSize.map { store.metric($0.assignment("gap"), mode) } ?? 6) {if let symbol {Image(systemName:symbol)};if !iconOnly {Text(label)}} }
            .buttonStyle(CatalogTokenButtonStyle(store: store, variant: variant, mode: mode, forced: forced, hover: hover, focus: showFocus || (focused && DesignKeyboardFocus.shared.isVisible), scale: scale, buttonSize: buttonSize, iconOnly: iconOnly, familyKey: familyKey))
            .disabled(forced == "disabled" || loading)
            .focusable(forced != "disabled" && !loading)
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.space) { guard forced != "disabled",!loading else { return .ignored }; action(); return .handled }
            .onKeyPress(.return) { guard forced != "disabled",!loading else { return .ignored }; action(); return .handled }
            .onHover { hover = $0 }
            .accessibilityLabel("\(variant.capitalized): \(label)\(forced.map { ", \($0) preview" } ?? "")")
    }
}
struct CatalogTokenButtonStyle: ButtonStyle {
    @ObservedObject var store: CatalogDesignStore
    var variant: String; var mode: String; var forced: String?; var hover: Bool; var focus: Bool; var scale: Double
    var buttonSize: SettingsButtonSize? = nil
    var iconOnly = false
    var familyKey: String? = nil
    func scoped(_ original: String) -> String { CatalogElementAssignments.childKey(original, family: familyKey) }
    func key(_ field: String, legacy: String) -> String { scoped(buttonSize?.assignment(field) ?? "component.button." + legacy) }
    func makeBody(configuration: Configuration) -> some View {
        let state = forced ?? (configuration.isPressed ? "pressed" : hover ? "hover" : "default")
        let prefix = scoped("component.button.\(variant).\(state).")
        let recipe = store.value(store.role(key("label", legacy: "label")), mode) as? [String: Any] ?? [:]
        let size = (recipe["size"] as? Double ?? 13) * scale
        let family = recipe["family"] as? String ?? "system"
        let weight = CatalogdesignFontWeight(recipe["weight"] as? Double ?? 500)
        let font: Font = family == "system" ? .system(size: size, weight: weight) : family == "systemMonospaced" ? .system(size: size, weight: weight, design: .monospaced) : .custom(family, size: size).weight(weight)
        let height = store.metric(key("height", legacy: "minimumHeight"), mode)
        let radius = iconOnly && buttonSize != nil ? height / 2 : store.metric(key("radius", legacy: "radius"), mode)
        let gap = store.metric(scoped("component.focus.offset"), mode)
        let variantFocus = store.role(scoped("component.button.\(variant).focus.color"))
        let focusRole = variantFocus == "color.border.focus" ? store.role(scoped("component.focus.color")) : variantFocus
        return configuration.label.font(font)
            .catalogPreviewTarget([key("label", legacy:"label"), prefix + "foreground"], "Button label and icon")
            .tracking((recipe["tracking"] as? Double ?? 0) * scale)
            .lineSpacing(max(0, (recipe["lineHeight"] as? Double ?? 18) * scale - size * 1.2))
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: max(size * 1.2, (recipe["lineHeight"] as? Double ?? 18) * scale))
            .frame(minWidth: !iconOnly && buttonSize != nil ? store.metric(buttonSize!.assignment("minimumLabelWidth"), mode) : nil)
            .padding(.horizontal, iconOnly && buttonSize != nil ? 0 : store.metric(key("paddingX", legacy: "paddingX"), mode))
            .padding(.vertical, buttonSize != nil ? 0 : store.metric(scoped("component.button.paddingY"), mode))
            .frame(width: iconOnly && buttonSize != nil ? height : nil)
            .frame(minHeight: height)
            .foregroundStyle(store.color(store.role(prefix + "foreground"), mode))
            .background(store.color(store.role(prefix + "background"), mode), in: RoundedRectangle(cornerRadius: radius))
            .designEffect(DesignWorkingStore.shared.document.tokens[store.role(prefix + "effect")]?[mode],radius:radius)
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(store.color(store.role(prefix + "border"), mode), lineWidth: buttonSize.map { store.metric($0.assignment("borderWidth"), mode) } ?? store.number("stroke.default",mode)))
            .assignedFocusOutline(focus, radius: radius, color: store.color(focusRole, mode), width: store.metric(scoped("component.focus.width"), mode), offset: gap)
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .catalogPreviewTarget([prefix + "background",prefix + "border",prefix + "effect",key("radius",legacy:"radius"),key("paddingX",legacy:"paddingX"),key("height",legacy:"minimumHeight"),key("gap",legacy:"gap"),key("minimumLabelWidth",legacy:"minimumLabelWidth"),key("borderWidth",legacy:"borderWidth")] + (buttonSize == nil ? [scoped("component.button.paddingY")] : []) + (focus ? [scoped("component.focus.color"),scoped("component.focus.width"),scoped("component.focus.offset")] : []), "\(variant.capitalized) button · \(state)")
    }
}
struct CatalogBaseMaterial: NSViewRepresentable {
    var disabled: Bool
    func makeNSView(context: Context) -> NSVisualEffectView { let v = NSVisualEffectView(); v.material = .underWindowBackground; v.blendingMode = .behindWindow; v.state = .active; return v }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.isHidden = disabled }
}
struct CatalogContentView: View {
    @StateObject private var previewInspection = CatalogPreviewInspection()
    @ObservedObject var store: CatalogDesignStore
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @State var section = "Tokens"
    @State var variant = "primary"
    @State var buttonSize: SettingsButtonSize = .standard
    @State var buttonIconOnly = false
    @State var state = "default"
    @State var mode = "dark"
    @State var focus = false
    @State var opaque = false
    @State var scale = 1.0
    @State var label = "Continue"
    @State var snapshotName = ""
    @State var feedback = "Try a live button to see its response."
    @State var snapshotSheet = false
    @AppStorage("designInspector.previewCreditsData") private var previewCreditsData = true
    @State private var reviewingExport = false
    @State private var showingAppControls = false
    @State private var appControlFamily: Int?
    @ObservedObject private var appThemes = ThemeManager.shared
    @State private var baseExpanded=true
    @State private var fixedBaseExpanded=true
    @State private var compositionsExpanded=true
    @State private var messagingExpanded=true
    @State private var productExpanded=true
    private let fixedBaseFamilies: Set<Int> = [3,4,5,6,7,8,9,10,11,12,56,65]
    // Keep saved assignments for the retired chat tabs and the live onboarding flow.
    private let visibleComponents = CatalogcomponentCatalog.filter { $0.id != 43 && $0.id != 55 }
    var body: some View {
        ZStack {
            CatalogBaseMaterial(disabled: reduceTransparency || opaque)
            store.color(reduceTransparency || opaque ? "material.window.fallback" : "material.window.tint", mode).opacity(reduceTransparency || opaque ? 1 : store.number("material.window.tintOpacity",mode))
            VStack(spacing: 0) {
                header.padding(20)
                Divider()
                HStack(spacing:0) {
                    navigationSidebar
                    Divider()
                if section == "Primitives" {
                    CatalogPrimitivesView(store: store)
                } else if section == "Tokens" {
                    CatalogTokensView(store: store)
                } else if section == "Inputs" || section == "Settings" {
                    CatalogInputWorkspace(store:store,settings:section == "Settings")
                } else if let spec=visibleComponents.first(where:{$0.section == section}) {
                    CatalogLibraryWorkspace(store:store,spec:spec,openSection: { section = $0 }).id(spec.id)
                } else {
                HSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            HStack { Text("Button study").font(.title2.weight(.semibold)); Spacer(); Text("Working design · provisional").foregroundStyle(.secondary) }
                            HStack(alignment: .top, spacing: 20) { gallery("light"); gallery("dark") }
                            HStack { Text("Preview text"); TextField("Button label", text: $label).textFieldStyle(.roundedBorder); Picker("Text scale", selection: $scale) { Text("100%").tag(1.0); Text("150%").tag(1.5); Text("200%").tag(2.0) }.frame(width: 165) }
                            Text("Changes update the development app immediately. The engineering handoff stays preserved.").font(.callout).foregroundStyle(.secondary)
                        }.padding(24)
                    }.frame(minWidth: 600)
                    inspector.frame(minWidth:400,idealWidth:440,maxWidth:500)
                }
                }
                }
                Divider()
                HStack { Image(systemName: store.status.contains("failed") ? "exclamationmark.triangle" : "checkmark.circle"); Text(store.status); Spacer(); if store.status.contains("failed") { Button("Retry saving") { store.save() } }; Text("Connected development app · Component verification tracked separately").foregroundStyle(.secondary) }.font(.caption).padding(.horizontal,20).padding(.vertical,10)
            }
        }.environmentObject(previewInspection)
        .environment(\.nativeCatalogSelection, previewInspection.selected)
        .onPreferenceChange(CatalogPreviewTargets.self) { if previewInspection.targets != $0 { previewInspection.targets = $0 } }
        .onChange(of:section) { _,_ in previewInspection.selected = nil }
        .onExitCommand { previewInspection.selected = nil }
        .preferredColorScheme(mode == "dark" ? .dark : .light)
        .onReceive(NotificationCenter.default.publisher(for: .designInspectorBaseComponent)) { notification in
            appControlFamily = notification.object as? Int
            showingAppControls = true
        }
        .sheet(isPresented: $showingAppControls) {
            VStack(spacing: 0) {
                SettingsKitGallery(inspectorFamily: appControlFamily)
                Button("Done") { showingAppControls = false }.padding(12)
            }
            .environment(\.theme, appThemes.currentTheme)
            .preferredColorScheme(appThemes.currentTheme.isDark ? .dark : .light)
            .frame(width: 960, height: 760)
        }
        .sheet(isPresented: $reviewingExport) { DesignExportReview(store: DesignWorkingStore.shared) }
        .sheet(isPresented: $snapshotSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Save a snapshot").font(.headline)
                TextField("Snapshot name", text: $snapshotName).textFieldStyle(.roundedBorder)
                HStack { Button("Cancel") { snapshotSheet = false }.keyboardShortcut(.cancelAction); Spacer(); Button("Save snapshot") { store.snapshot(snapshotName); snapshotSheet = false; snapshotName = "" }.disabled(snapshotName.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 350)
        }
    }
    var navigationSidebar: some View {
        List(selection:$section) {
            Section("Foundations") { Label("Primitives",systemImage:"paintpalette").tag("Primitives"); Label("Tokens",systemImage:"square.grid.2x2").tag("Tokens") }
            DisclosureGroup("Fixed base components",isExpanded:$fixedBaseExpanded) {
                Label("Buttons",systemImage:"rectangle.and.hand.point.up.left").tag("Buttons")
                Label("Inputs",systemImage:"character.cursor.ibeam").tag("Inputs")
                ForEach(CatalogcomponentCatalog.filter{fixedBaseFamilies.contains($0.id)}){spec in Text(spec.name).font(.callout).lineLimit(2).fixedSize(horizontal:false,vertical:true).help(spec.name).tag(spec.section)}
            }
            let remainingBase = CatalogcomponentCatalog.filter { $0.id > 2 && $0.isBase && !$0.isComposition && !fixedBaseFamilies.contains($0.id) }
            if !remainingBase.isEmpty {
                DisclosureGroup("Base components",isExpanded:$baseExpanded) {
                    ForEach(remainingBase){spec in Text(spec.name).font(.callout).lineLimit(2).fixedSize(horizontal:false,vertical:true).help(spec.name).tag(spec.section)}
                }
            }
            DisclosureGroup("Composed components",isExpanded:$compositionsExpanded) {
                ForEach(CatalogcomponentCatalog.filter{$0.isComposition}){spec in Text(spec.name).font(.callout).lineLimit(2).fixedSize(horizontal:false,vertical:true).help(spec.name).tag(spec.section)}
            }
            DisclosureGroup("Messaging components",isExpanded:$messagingExpanded) {
                ForEach(CatalogcomponentCatalog.filter{$0.isMessaging}){spec in Text(spec.name).font(.callout).lineLimit(2).fixedSize(horizontal:false,vertical:true).help(spec.name).tag(spec.section)}
            }
            DisclosureGroup("Product components",isExpanded:$productExpanded) {
                ForEach(visibleComponents.filter{$0.isProduct && !$0.isMessaging}){spec in Text(spec.name).font(.callout).lineLimit(2).fixedSize(horizontal:false,vertical:true).help(spec.name).tag(spec.section)}
            }
        }.listStyle(.sidebar).scrollContentBackground(.hidden).frame(width:220)
            .background(store.color("color.surface.sidebar",mode))
            .accessibilityLabel("Playground navigation")
    }
    var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up").font(.title2)
            VStack(alignment: .leading,spacing:3) { Text("Osaurus").font(.headline); Text("Integration inspector · beta 40 · source 4dc20d68").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Undo") { store.undo() }.disabled(store.undoStack.isEmpty).keyboardShortcut("z")
            Button("Redo") { store.redo() }.disabled(store.redoStack.isEmpty).keyboardShortcut("z", modifiers: [.command,.shift])
            Menu("Snapshots") { Button("Save snapshot…") { snapshotSheet = true }; if store.snapshots.isEmpty { Text("No snapshots yet") }; ForEach(store.snapshots, id: \.self) { url in Button(url.deletingPathExtension().lastPathComponent) { store.loadSnapshot(url) } } }
            Menu("App") {
                Button("Open Settings") { AppDelegate.shared?.showManagementWindow(initialTab: .chat) }
                Button("Open existing app control gallery") {
                    CatalogAppNavigation.showGallery(CatalogcomponentCatalog.first(where: { $0.section == section }).flatMap { ((21...36).contains($0.id) || [38,39,40,42,46,47,48,49,50,51,52,53,54].contains($0.id)) ? $0.id : nil })
                }
                Toggle("Sample credits data", isOn: $previewCreditsData)
                Button("Open conversation") { _ = ChatWindowManager.shared.createWindow() }
                Button("Open sample conversation") { CatalogAppNavigation.sampleConversation() }
                Button("Compact verification chat") { CatalogAppNavigation.arrangeVerificationChat(compact: true) }
                Button("Wide verification chat") { CatalogAppNavigation.arrangeVerificationChat(compact: false) }
                Button("Open remaining menu checks") { CatalogAppNavigation.showGallery(500) }
                Button("Light appearance") { appThemes.setAppearanceMode(.light, persist: false) }
                Button("Dark appearance") { appThemes.setAppearanceMode(.dark, persist: false) }
            }
            Button("Review export") { reviewingExport = true }
            Button("Reset design") { store.reset() }.help("Restore the imported Figma token and style defaults. Undo is available.")
        }.buttonStyle(.bordered)
    }
    func gallery(_ appearance: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(appearance.capitalized).font(.headline)
            ForEach(Catalogvariants, id: \.self) { v in
                VStack(alignment: .leading, spacing: 12) {
                    Text(v.capitalized).font(.subheadline.weight(.semibold))
                    ForEach(Catalogstates, id: \.self) { s in
                        HStack(alignment: .center) {
                            Text(s.capitalized).font(.caption).foregroundStyle(store.color("color.text.secondary",appearance)).frame(width: 60, alignment: .leading)
                            CatalogTokenButton(store: store, variant: v, mode: appearance, forced: s, showFocus: focus && v == variant && s == state, label: label.isEmpty ? "Continue" : label, scale: scale, symbol: buttonIconOnly ? "plus" : nil, iconOnly: buttonIconOnly, buttonSize: buttonSize) { variant = v; state = s }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }.padding(20).frame(maxWidth: .infinity,alignment: .leading)
            .foregroundStyle(store.color("color.text.primary",appearance))
            .background(store.color("color.surface.raised",appearance),in: RoundedRectangle(cornerRadius: store.number("radius.large",appearance)))
            .environment(\.colorScheme,appearance == "dark" ? .dark : .light)
    }
    var contextExample: some View {
        VStack(alignment: .leading,spacing:16) {
            Text("In context").font(.headline)
            Text("Start a conversation").font(.title3.weight(.semibold))
            Text("Explore an idea with Osaurus. These controls respond to hover, press and keyboard focus.").foregroundStyle(store.color("color.text.secondary",mode))
            ViewThatFits(in: .horizontal) {
                HStack(spacing:12) { liveButtons }
                VStack(alignment:.leading,spacing:12) { liveButtons }
            }
            HStack {
                CatalogTokenButton(store:store,variant:"primary",mode:mode,label:"Send",scale:scale,symbol:"arrow.up"){feedback="Icon action selected"}
                CatalogTokenButton(store:store,variant:"tertiary",mode:mode,label:"Attach",scale:scale,symbol:"paperclip"){feedback="Attachment action selected"}
                CatalogTokenButton(store:store,variant:"secondary",mode:mode,label:"More actions",scale:scale,symbol:"ellipsis",iconOnly:true){feedback="Icon-only action selected"}
                CatalogTokenButton(store:store,variant:"primary",mode:mode,label:"Saving…",scale:scale,loading:true)
                ProgressView("Working").controlSize(.small)
            }
            Text(feedback).font(.callout).foregroundStyle(store.color("color.text.secondary",mode))
        }.padding(24).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(store.color("color.text.primary",mode)).background(store.color("color.surface.raised",mode),in:RoundedRectangle(cornerRadius:store.number("radius.large",mode)))
    }
    @ViewBuilder var liveButtons: some View {
        CatalogTokenButton(store:store,variant:"primary",mode:mode,label:"Start conversation",scale:scale) { feedback = "Conversation started · preview only" }
        CatalogTokenButton(store:store,variant:"secondary",mode:mode,label:"Choose model",scale:scale) { feedback = "Model picker selected · preview only" }
        CatalogTokenButton(store:store,variant:"tertiary",mode:mode,label:"Cancel",scale:scale) { feedback = "Preview cancelled" }
    }
    var inspector: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Live inspector").font(.headline)
            Picker("Size", selection: $buttonSize) {
                Text("Default · 32").tag(SettingsButtonSize.standard)
                Text("Small · 28").tag(SettingsButtonSize.small)
                Text("X-Small · 24").tag(SettingsButtonSize.extraSmall)
                Text("XX-Small · 16").tag(SettingsButtonSize.extraExtraSmall)
            }
            Toggle("Icon button", isOn: $buttonIconOnly)
            Picker("Variant",selection:$variant) { ForEach(Catalogvariants,id:\.self) { Text($0.capitalized).tag($0) } }
            Picker("State",selection:$state) { ForEach(Catalogstates,id:\.self) { Text($0.capitalized).tag($0) } }
            Picker("Value appearance",selection:$mode) {Text("Light").tag("light");Text("Dark").tag("dark")}.pickerStyle(.segmented)
            Toggle("Show keyboard focus",isOn:$focus)
            CatalogAssignmentGroups(store:store,keys:["background","foreground","border","effect"].map{"component.button.\(variant).\(state).\($0)"} + ["label","radius","paddingX","height","gap","minimumLabelWidth","borderWidth"].map { buttonSize.assignment($0) } + ["component.focus.color","component.focus.width","component.focus.offset"],mode:mode,label:"Buttons expanded assignments")
            Toggle("Use opaque fallback",isOn:$opaque)
        }.padding(16).background(Color(nsColor:.controlBackgroundColor))
    }
    func assignment(_ key: String, roles: [String]) -> some View {
        Picker("Semantic role",selection:Binding(get:{store.role(key)},set:{store.map(key,$0)})) { ForEach(roles,id:\.self) { Text($0).tag($0) } }.labelsHidden().help("Changes this component mapping only").accessibilityLabel("Semantic assignment for \(key)")
    }
    func colorEditor(_ title: String, property: String) -> some View {
        let key = "component.button.\(variant).\(state).\(property)"
        let role = store.role(key)
        return VStack(alignment:.leading,spacing:6) {
            Text(title).font(.subheadline.weight(.medium))
            assignment(key,roles:store.tokens.keys.filter { store.tokens[$0]?["type"] as? String == "color" }.sorted())
            CatalogPrimitiveAssignment(store:store,path:role,mode:mode)
            Text(store.value(role,mode) as? String ?? "").font(.system(.caption,design:.monospaced)).textSelection(.enabled)
            Text("Used by \(store.mappings.values.filter{$0 == role}.count) \(store.mappings.values.filter{$0 == role}.count == 1 ? "mapping" : "mappings")").font(.caption).foregroundStyle(.secondary)
        }
    }
    var typography: some View {
        let key = buttonSize.assignment("label")
        let role = store.role(key)
        let recipe = store.value(role,mode) as? [String:Any] ?? [:]
        return VStack(alignment:.leading,spacing:12) {
            Text("Typography").font(.headline)
            assignment(key,roles:store.tokens.keys.filter{$0.hasPrefix("type.")}.sorted())
            Text("Edits the shared \(role) recipe in both light and dark.").font(.caption).foregroundStyle(.secondary)
            Picker("Family",selection:Binding(get:{recipe["family"] as? String ?? "system"},set:{store.setTypographyField(role,"family",$0,mode:mode)})) {
                Text("System").tag("system"); Text("System monospaced").tag("systemMonospaced")
                ForEach(NSFontManager.shared.availableFontFamilies.sorted(),id:\.self) { Text($0).tag($0) }
            }
            ForEach(["size","weight","lineHeight","tracking"],id:\.self) { field in
                let names = ["size":"Size","weight":"Weight","lineHeight":"Line height","tracking":"Tracking"]
                let range: ClosedRange<Double> = field == "weight" ? 300...900 : field == "tracking" ? -2...8 : field == "size" ? 10...40 : 12...64
                numberControl(names[field]!,value:Binding(get:{recipe[field] as? Double ?? 0},set:{store.setTypographyField(role,field,$0,mode:mode)}),range:range,step:field == "weight" ? 100 : field == "tracking" ? 0.25 : 1)
            }
        }
    }
    func metricEditor(_ title:String,key:String,range:ClosedRange<Double>,prefix:String) -> some View {
        VStack(alignment:.leading,spacing:6) {
            assignment(key,roles:store.dimensionRoles(prefix,mode))
            numberControl(title,value:Binding(get:{store.metric(key,mode)},set:{store.setSharedDimension(store.role(key),$0)}),range:range)
        }
    }
    func numberControl(_ title:String,value:Binding<Double>,range:ClosedRange<Double>,step:Double = 1) -> some View {
        VStack(alignment:.leading,spacing:4) {
            HStack { Text(title); Spacer(); Text(value.wrappedValue.formatted(.number.precision(.fractionLength(0...2)))).monospacedDigit() }
            Slider(value:value,in:range,step:step).accessibilityLabel(title)
        }.font(.callout)
    }
}



struct CatalogSemanticType:ViewModifier {
    @ObservedObject var store:CatalogDesignStore
    var role:String;var mode:String;var scale:Double = 1
    func body(content:Content) -> some View {
        let recipe = store.value(role,mode) as? [String:Any] ?? [:]
        let size = max(1,(recipe["size"] as? Double ?? 13) * scale)
        let family = recipe["family"] as? String ?? "system"
        let weight = CatalogdesignFontWeight(recipe["weight"] as? Double ?? 400)
        let font:Font = family == "system" ? .system(size:size,weight:weight) : family == "systemMonospaced" ? .system(size:size,weight:weight,design:.monospaced) : .custom(family,size:size).weight(weight)
        content.font(font).tracking((recipe["tracking"] as? Double ?? 0) * scale).lineSpacing(max(0,(recipe["lineHeight"] as? Double ?? size / scale * 1.2) * scale - size * 1.2)).fixedSize(horizontal:false,vertical:true)
    }
}
struct CatalogTokenInput: View {
    @ObservedObject var store: CatalogDesignStore
    var mode: String
    var title: String
    @Binding var text: String
    var placeholder = "Enter a value"
    var state = "default"
    var message = ""
    var scale = 1.0
    var focusRequest = 0
    var secure = false
    var familyKey: String? = nil
    var showsLabel = false
    var exampleHeading = true
    @FocusState private var focused: Bool
    private var sampleLabel: String { exampleHeading ? (title == "Search" ? "Search conversations" : secure ? "Password" : "Workspace name") : title }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if exampleHeading { Text(title).font(.caption).foregroundStyle(store.color("color.text.secondary", mode)) }
            SettingsFieldRow(label: showsLabel ? sampleLabel : "", hint: message.isEmpty ? nil : message,
                verbatimHint: true, verbatimLabel: true) {
                field
            }
        }
        .environment(\.theme, CustomizableTheme(config: mode == "dark" ? .darkDefault : .lightDefault, fontScale: scale))
        .environment(\.nativeCatalogPreview, true)
        .environment(\.inspectorInputPreviewState, state)
        .onChange(of: focusRequest) { _, _ in focused = true }
    }
    @ViewBuilder private var field: some View {
        if title == "Search" {
            SearchField(text: $text, placeholder: LocalizedStringKey(placeholder), fillsAvailableWidth: true)
                .disabled(state == "disabled")
                .accessibilityLabel(mode.capitalized + " Search")
                .nativeCatalogTarget(["component.input.paddingX", "component.input.paddingY", "component.input.radius", "component.input.background", "component.input.border", "component.input.text", "component.input.placeholder"], "Search field")
        } else {
            SettingsTextField(placeholder: placeholder, text: $text, isSecure: secure, revealable: secure,
                isInvalid: state == "error", focus: $focused)
                .disabled(state == "disabled")
                .settingsFieldAccessibility(exampleHeading ? sampleLabel : title, help: message.isEmpty ? nil : message)
        }
    }
}
struct CatalogInputWorkspace:View {
    @ObservedObject var store:CatalogDesignStore
    var settings:Bool
    @State private var scale = 1.0
    @State private var showsLabels = false
        var body:some View {
        HSplitView {
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    Text(settings ? "Settings composition" : "Input study").font(.title2.weight(.semibold))
                    Text(settings ? "Shared inputs and buttons assembled in a settings group. Edit their appearance on their base component pages." : "Empty, filled, hover, focus, error and disabled states. Input assignments are connected to the development app.").foregroundStyle(.secondary)
                    Picker("Text scale",selection:$scale) {Text("100%").tag(1.0);Text("150%").tag(1.5);Text("200%").tag(2.0)}.pickerStyle(.segmented).frame(maxWidth:300)
                    if !settings { Toggle("Show field labels", isOn: $showsLabels).toggleStyle(.checkbox) }
                    // Stack appearances when side-by-side columns cannot fit comfortably.
                    ViewThatFits(in:.horizontal) {
                        HStack(alignment:.top,spacing:20) { specimens("light").frame(minWidth:270);specimens("dark").frame(minWidth:270) }
                        VStack(alignment:.leading,spacing:20) {specimens("light");specimens("dark")}
                    }
                }.padding(24)
            }.frame(minWidth:500)
            CatalogComponentRoleInspector(store:store).padding(16).frame(minWidth:400,idealWidth:440,maxWidth:500).background(Color(nsColor:.controlBackgroundColor))
        }
    }
    @ViewBuilder func specimens(_ mode:String) -> some View {
        if settings { CatalogSettingsSpecimen(store:store,mode:mode,scale:scale) }
        else { CatalogInputSpecimens(store:store,mode:mode,scale:scale,showsLabels:showsLabels) }
    }
}
struct CatalogInputSpecimens:View {
    @ObservedObject var store:CatalogDesignStore
    var mode:String;var scale:Double
    var showsLabels = false
    @State private var empty = ""
    @State private var filled = "Personal workspace"
    @State private var hover = "Personal workspace"
    @State private var focus = "Personal workspace"
    @State private var error = ""
    @State private var disabled = "Managed workspace"
    @State private var reveal=false
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            Text(mode.capitalized).font(.headline)
            CatalogTokenInput(store:store,mode:mode,title:"Empty",text:$empty,placeholder:"Workspace name",scale:scale,showsLabel:showsLabels)
            CatalogTokenInput(store:store,mode:mode,title:"Filled",text:$filled,scale:scale,showsLabel:showsLabels)
            CatalogTokenInput(store:store,mode:mode,title:"Hover",text:$hover,state:"hover",scale:scale,showsLabel:showsLabels)
            CatalogTokenInput(store:store,mode:mode,title:"Focus",text:$focus,state:"focus",scale:scale,showsLabel:showsLabels)
            CatalogTokenInput(store:store,mode:mode,title:"Error",text:$error,placeholder:"Workspace name",state:"error",message:"Enter a workspace name.",scale:scale,showsLabel:showsLabels)
            CatalogTokenInput(store:store,mode:mode,title:"Disabled",text:$disabled,state:"disabled",message:"Managed by your organization.",scale:scale,showsLabel:showsLabels)
            CatalogTokenInput(store:store,mode:mode,title:"Search",text:$empty,placeholder:"Search conversations",scale:scale,showsLabel:showsLabels)
            CatalogTokenInput(store:store,mode:mode,title:"Secure",text:$filled,placeholder:"Enter a sample secret",scale:scale,secure:!reveal,showsLabel:showsLabels)
            CatalogTokenButton(store:store,variant:"tertiary",mode:mode,label:reveal ? "Hide value" : "Show value",scale:scale,symbol:reveal ? "eye.slash" : "eye"){reveal.toggle()}
            CatalogTokenButton(store:store,variant:"tertiary",mode:mode,label:"Clear search",scale:scale,symbol:"xmark"){empty=""}
        }.padding(20).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(store.color("color.text.primary",mode)).background(store.color("color.surface.canvas",mode),in:RoundedRectangle(cornerRadius:store.number("radius.large",mode))).environment(\.colorScheme,mode == "dark" ? .dark : .light)
    }
}
struct CatalogSettingsSpecimen:View {
    @Environment(\.displayScale) private var displayScale
    @ObservedObject var store:CatalogDesignStore
    var mode:String;var scale:Double
    @State private var name = "Personal"
    @State private var replyName = "Neesh"
    @State private var savedName = "Personal"
    @State private var savedReplyName = "Neesh"
    @State private var attempted = false
    @State private var feedback = "Preview only · no app preferences are changed."
    @State private var focusName = 0
    var invalid:Bool { attempted && name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text(mode.capitalized).font(.headline)
            VStack(alignment:.leading,spacing:store.metric("component.settings.gap",mode)) {
                Text("Workspace preferences").modifier(CatalogSemanticType(store:store,role:store.role("component.settings.heading"),mode:mode,scale:scale)).catalogPreviewTarget(["component.settings.heading","component.settings.foreground"], "Workspace preferences title")
                Text("Choose how this workspace is identified.").modifier(CatalogSemanticType(store:store,role:store.role("component.settings.text"),mode:mode,scale:scale)).foregroundStyle(store.color(store.role("component.settings.secondary"),mode)).catalogPreviewTarget(["component.settings.text","component.settings.secondary"], "Workspace description below title")
                CatalogTokenInput(store:store,mode:mode,title:"Workspace name",text:$name,placeholder:"e.g. Personal",state:invalid ? "error" : "default",message:invalid ? "Enter a workspace name before saving." : "",scale:scale,focusRequest:focusName,showsLabel:true,exampleHeading:false)
                CatalogTokenInput(store:store,mode:mode,title:"Your name",text:$replyName,placeholder:"How should Osaurus address you?",scale:scale,showsLabel:true,exampleHeading:false)
                Rectangle().fill(store.color(store.role("component.settings.divider.color"),mode)).frame(height:1 / max(1,displayScale)).catalogPreviewTarget(["component.settings.divider.color"], "Divider above settings actions")
                ViewThatFits(in:.horizontal) {
                    HStack(spacing:store.metric("component.settings.actionGap",mode)) { actions }
                    VStack(alignment:.leading,spacing:store.metric("component.settings.actionGap",mode)) { actions }
                }.catalogPreviewTarget(["component.settings.actionGap"], "Spacing between Save, Cancel and Reset")
                Text(feedback).modifier(CatalogSemanticType(store:store,role:store.role("component.settings.caption"),mode:mode,scale:scale)).foregroundStyle(store.color(store.role("component.settings.secondary"),mode)).fixedSize(horizontal:false,vertical:true).catalogPreviewTarget(["component.settings.caption","component.settings.secondary"], "Save / validation feedback below actions")
            }.padding(.horizontal,store.metric("component.settings.row.insetX",mode)).padding(.vertical,store.metric("component.settings.row.insetY",mode))
                .background(store.color(store.role("component.settings.group.background"),mode),in:RoundedRectangle(cornerRadius:store.metric("component.settings.group.radius",mode)))
                .overlay(RoundedRectangle(cornerRadius:store.metric("component.settings.group.radius",mode)).stroke(store.color(store.role("component.settings.group.border"),mode),lineWidth:store.metric("component.settings.borderWidth",mode)))
                .catalogPreviewTarget(["component.settings.group.background","component.settings.group.border","component.settings.group.radius","component.settings.borderWidth","component.settings.row.insetX","component.settings.row.insetY","component.settings.gap"], "Settings group container")
        }.padding(20).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(store.color(store.role("component.settings.foreground"),mode)).background(store.color("color.surface.canvas",mode),in:RoundedRectangle(cornerRadius:store.number("radius.large",mode))).environment(\.colorScheme,mode == "dark" ? .dark : .light)
    }
    @ViewBuilder var actions:some View {
        CatalogTokenButton(store:store,variant:"primary",mode:mode,label:"Save changes",scale:scale) {
            attempted = true
            if !invalid { savedName=name;savedReplyName=replyName;feedback="Saved in this preview." }
            else {feedback="Check the workspace name above.";focusName += 1}
        }
        CatalogTokenButton(store:store,variant:"secondary",mode:mode,label:"Cancel",scale:scale) {name=savedName;replyName=savedReplyName;attempted=false;feedback="Restored the last saved preview."}
        CatalogTokenButton(store:store,variant:"tertiary",mode:mode,label:"Reset",scale:scale) {name="Personal";replyName="Neesh";attempted=false;feedback="Defaults restored in the preview. Save to keep them here."}
    }
}
struct CatalogComponentRoleInspector:View {
    @ObservedObject var store:CatalogDesignStore
    @State private var component = "Input"
    @State private var property = "component.input.background"
    var prefix:String {
        switch component {case "Primary button":return "component.button.primary.";case "Secondary button":return "component.button.secondary.";case "Tertiary button":return "component.button.tertiary.";case "Settings group":return "component.settings.";default:return "component.input."}
    }
    var properties:[String] {
        var keys = store.mappings.keys.filter{$0.hasPrefix(prefix)}
        if component.contains("button") {keys += ["component.button.label","component.button.radius","component.button.paddingX","component.button.paddingY","component.button.minimumHeight"]}
        if component == "Input" {
            keys.removeAll { $0 == "component.input.contentGap" }
            keys += ["component.control.heightDefault","component.focus.color","component.focus.width","component.focus.offset"]
        }
        return keys.sorted{$0.localizedStandardCompare($1) == .orderedAscending}
    }
    @State private var mode = "dark"
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Live inspector").font(.headline)
            Picker("Value appearance",selection:$mode) {Text("Light").tag("light");Text("Dark").tag("dark")}.pickerStyle(.segmented)
            CatalogAssignmentGroups(store:store,keys:properties,mode:mode,label:"\(component) expanded assignments")
        }
    }
}

struct CatalogTokensView: View {
    @ObservedObject var store: CatalogDesignStore
    @State private var query = ""
    @State private var group = "All"
    @State private var selection: String? = "type.label"
    var groups: [String] { Array(Set(store.tokens.keys.map { String($0.split(separator: ".")[0]) })).sorted() }
    var filtered: [String] {
        store.tokens.keys.filter { key in
            (group == "All" || key.hasPrefix(group + ".")) && (query.isEmpty || (key + " " + (store.tokens[key]?["use"] as? String ?? "")).localizedCaseInsensitiveContains(query))
        }.sorted { a, b in
            if a.hasPrefix("type."), b.hasPrefix("type.") {
                let av = store.value(a,"light") as? [String:Any] ?? [:]
                let bv = store.value(b,"light") as? [String:Any] ?? [:]
                let sa = av["size"] as? Double ?? 0, sb = bv["size"] as? Double ?? 0
                if sa != sb { return sa < sb }
                let wa = av["weight"] as? Double ?? 0, wb = bv["weight"] as? Double ?? 0
                if wa != wb { return wa < wb }
            }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing:12) {
                HStack { Text("Semantic tokens").font(.title2.weight(.semibold)); Spacer(); Text("\(filtered.count) of \(store.tokens.count)").foregroundStyle(.secondary).monospacedDigit() }
                TextField("Search names or usage",text:$query).textFieldStyle(.roundedBorder).accessibilityLabel("Search semantic tokens")
                Picker("Category",selection:$group) { Text("All categories").tag("All"); ForEach(groups,id:\.self) { Text($0.capitalized).tag($0) } }
                if filtered.isEmpty {
                    VStack(spacing:12) { Text("No matching tokens").font(.headline); Text("Try another name or clear the filters.").foregroundStyle(.secondary); Button("Clear filters") { query = ""; group = "All" } }.frame(maxWidth:.infinity,maxHeight:.infinity)
                } else {
                    List(selection:$selection) {
                        ForEach(filtered,id:\.self) { key in
                            VStack(alignment:.leading,spacing:7) {
                                Text(key).font(.system(.body,design:.monospaced)).lineLimit(2)
                                Text(store.tokens[key]?["use"] as? String ?? "").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                HStack(alignment:.top,spacing:16) {
                                    valueSummary(key,"light"); valueSummary(key,"dark")
                                }
                            }.padding(.vertical,8).tag(key)
                        }
                    }.listStyle(.inset)
                }
            }.padding(20).frame(minWidth:360,idealWidth:470)
            if let key = selection, store.tokens[key] != nil {
                CatalogTokenDetail(store:store,token:key).id(key).frame(minWidth:490,idealWidth:650)
            } else { Text("Select a token to inspect and edit it.").frame(minWidth:490,maxHeight:.infinity) }
        }
    }
    func valueSummary(_ key:String,_ mode:String) -> some View {
        HStack(alignment:.top,spacing:6) {
            if store.tokens[key]?["type"] as? String == "color" {
                RoundedRectangle(cornerRadius:3).fill(store.color(key,mode)).frame(width:18,height:18).overlay(RoundedRectangle(cornerRadius:3).stroke(.secondary,lineWidth:0.5)).background(Color.gray.opacity(0.2))
            }
            VStack(alignment:.leading,spacing:2) { Text(mode.capitalized).font(.caption).foregroundStyle(.secondary); Text(summary(store.value(key,mode))).font(.system(.caption,design:.monospaced)).fixedSize(horizontal:false,vertical:true) }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    func summary(_ value:Any) -> String {
        if let d = value as? [String:Any] {
            if let size = d["size"],let weight = d["weight"] { return "\(d["family"] ?? "system") · \(size) pt · \(weight)\nLine \(d["lineHeight"] ?? "") · Track \(d["tracking"] ?? "")" }
            return d.keys.sorted().map { "\($0): \(d[$0]!)" }.joined(separator:" · ")
        }
        return String(describing:value)
    }
}
struct CatalogTokenDetail: View {
    @ObservedObject var store:CatalogDesignStore
    var token:String
    @State private var linkModes = false
    var kind:String { store.tokens[token]?["type"] as? String ?? "" }
    var uses:[String] { store.mappings.filter{$0.value == token}.keys.sorted() }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                VStack(alignment:.leading,spacing:8) {
                    Text(token).font(.system(.title3,design:.monospaced).weight(.semibold)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                    Text(kind).font(.caption).foregroundStyle(.secondary)
                    if DesignTypographyTokens.roles.contains(token) {
                        Text("Choose this typography style from the text assignments on component pages.").font(.callout).foregroundStyle(.secondary)
                    } else if kind == "typography" {
                        Text("This editor stores complete typography recipes, including custom font families. App coverage is recorded in the integration verification checklist.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(store.tokens[token]?["use"] as? String ?? "").fixedSize(horizontal:false,vertical:true)
                }
                if kind == "dimension" {
                    Text("Geometry edits update both appearances. Typography and other values can be edited independently.").font(.callout).foregroundStyle(.secondary)
                } else if ["color.surface.none","color.border.none"].contains(token) {
                    Text("None · no fill or border in either appearance").font(.callout)
                } else if kind == "color" {
                    Text("Choose a primitive independently for Light and Dark. Edit the shared color itself in Primitives. Changes autosave.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Toggle("Edit both appearances together",isOn:$linkModes)
                    Text(linkModes ? "Each edit updates that property in light and dark. Other properties stay as saved." : "Each column edits its own appearance. Changes autosave immediately.").font(.callout).foregroundStyle(.secondary)
                }
                HStack(alignment:.top,spacing:18) {
                    modeEditor("light"); modeEditor("dark")
                }
                VStack(alignment:.leading,spacing:10) {
                    Text("Where used").font(.headline)
                    if uses.isEmpty { Text("No component mappings reference this role yet.").foregroundStyle(.secondary) }
                    ForEach(uses,id:\.self) { Text($0).font(.system(.callout,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
                    Text("The component library uses these shared roles live. Assignments list catalog references. Edits update connected app views. See the progress list for controls that have not yet been verified.").font(.callout).foregroundStyle(.secondary)
                }
            }.padding(24)
        }.background(Color(nsColor:.controlBackgroundColor))
    }
    func update(_ mode:String,_ value:Any,field:String? = nil) {
        store.setTokenProperty(token,mode:mode,value:value,field:field,linked:linkModes)
    }

    func modeEditor(_ mode:String) -> some View {
        VStack(alignment:.leading,spacing:16) {
            Text(mode.capitalized).font(.headline)
            preview(mode)
            if ["color.surface.none","color.border.none"].contains(token) { Text("Transparent · fixed").font(.caption).foregroundStyle(.secondary) }
            else if kind == "effect" { CatalogEffectEditor(store:store,token:token,mode:mode) }
            else if let dict = store.value(token,mode) as? [String:Any] {
                ForEach(orderedFields(dict),id:\.self) { field in
                    editor(field,value:dict[field]!,mode:mode,field:field)
                }
            } else { editor("Value",value:store.value(token,mode),mode:mode) }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    func orderedFields(_ d:[String:Any]) -> [String] {
        let preferred = ["family","weight","size","lineHeight","tracking","x","y","blur","opacity","color","response","dampingFraction","formula","unit"]
        return preferred.filter{d[$0] != nil} + d.keys.filter{!preferred.contains($0)}.sorted()
    }
    @ViewBuilder func editor(_ name:String,value:Any,mode:String,field:String? = nil) -> some View {
        let title = ["lineHeight":"Line height","tracking":"Tracking","family":"Family","weight":"Weight","size":"Size","dampingFraction":"Damping","response":"Response" ][name] ?? name.capitalized
        VStack(alignment:.leading,spacing:5) {
            Text(title).font(.callout.weight(.medium))
            if name == "unit" {
                Text(String(describing:value)).foregroundStyle(.secondary).help("Native dimensions are measured in points.")
            } else if let n = value as? NSNumber {
                CatalogTokenNumberField(value:n.doubleValue,label:"\(token) \(mode) \(title)",allowNegative:field == "tracking" || field == "x" || field == "y",maximum:field == "opacity" || token == "material.window.tintOpacity" ? 1 : nil) { update(mode,$0,field:field) }
            } else if let text = value as? String, text.hasPrefix("#") {
                CatalogPrimitiveAssignment(store:store,path:field == "color" ? token + ".color" : token,mode:mode)
            } else if name == "family" || kind == "fontFamily" {
                Picker("\(mode.capitalized) font family",selection:Binding(get:{value as? String ?? "system"},set:{update(mode,$0,field:field)})) {
                    Text("System").tag("system");Text("System monospaced").tag("systemMonospaced")
                    ForEach(NSFontManager.shared.availableFontFamilies.sorted(),id:\.self) { Text($0).tag($0) }
                }.labelsHidden()
            } else {
                CatalogTokenTextField(value:String(describing:value),label:"\(token) \(mode) \(title)") { update(mode,$0,field:field) }
            }
        }
    }
    @ViewBuilder func preview(_ mode:String) -> some View {
        let background = store.color("color.surface.raised",mode)
        let foreground = store.color("color.text.primary",mode)
        if kind == "typography", let r = store.value(token,mode) as? [String:Any] {
            let size = max(1,r["size"] as? Double ?? 13)
            let family = r["family"] as? String ?? "system"
            let weight = CatalogdesignFontWeight(r["weight"] as? Double ?? 400)
            let font:Font = family == "system" ? .system(size:size,weight:weight) : family == "systemMonospaced" ? .system(size:size,weight:weight,design:.monospaced) : .custom(family,size:size).weight(weight)
            Text("The quick brown fox\n0123456789").font(font).tracking(r["tracking"] as? Double ?? 0).lineSpacing(max(0,(r["lineHeight"] as? Double ?? size * 1.2) - size * 1.2)).fixedSize(horizontal:false,vertical:true).padding(14).frame(maxWidth:.infinity,minHeight:100,alignment:.leading).foregroundStyle(foreground).background(background,in:RoundedRectangle(cornerRadius:8))
        } else if kind == "color" {
            RoundedRectangle(cornerRadius:8).fill(store.color(token,mode)).frame(height:80).overlay(RoundedRectangle(cornerRadius:8).stroke(.secondary,lineWidth:0.5)).background(background,in:RoundedRectangle(cornerRadius:8))
        } else if kind == "dimension" {
            VStack(alignment:.leading,spacing:6) { Text("\(store.number(token,mode).formatted()) pt").monospacedDigit(); Capsule().fill(foreground).frame(width:max(1,min(180,store.number(token,mode))),height:8) }.padding(14).frame(maxWidth:.infinity,minHeight:80,alignment:.leading).foregroundStyle(foreground).background(background,in:RoundedRectangle(cornerRadius:8))
        } else if kind == "effect" {
            let raw = try? JSONSerialization.data(withJSONObject: store.value(token,mode))
            let value = raw.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            RoundedRectangle(cornerRadius:8).fill(background).frame(height:90).designEffect(value,radius:8).padding(20)
        } else { Text("Shared \(kind) definition").font(.callout).foregroundStyle(.secondary) }
    }
}
struct CatalogTokenNumberField:View {
    var value:Double; var label:String; var allowNegative = false; var maximum:Double? = nil; var onChange:(Double)->Void
    @State private var draft = ""
    @State private var error = false
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            TextField(label,text:$draft).textFieldStyle(.roundedBorder).labelsHidden().accessibilityLabel(label).onAppear{sync()}.onChange(of:value){_,_ in sync()}.onChange(of:draft){_,text in
                guard let n = Double(text),n.isFinite,(allowNegative || n >= 0),(maximum == nil || n <= maximum!) else { error = true;return }
                error = false;if n != value { onChange(n) }
            }
            if error { Text(maximum == 1 ? "Enter a number from 0 to 1." : allowNegative ? "Enter a number." : "Enter a number of 0 or more.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    func sync() { let n = Double(draft);if n != value { draft = value.formatted(.number.grouping(.never).precision(.fractionLength(0...4))) } }
}
struct CatalogTokenTextField:View {
    var value:String;var label:String;var isHex = false;var onChange:(String)->Void
    @State private var draft = ""
    @State private var error = false
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            TextField(label,text:$draft).textFieldStyle(.roundedBorder).accessibilityLabel(label).onAppear{draft=value}.onChange(of:value){_,v in if v != draft {draft=v}}.onChange(of:draft){_,v in
                let valid = isHex ? v.range(of:"^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$",options:.regularExpression) != nil : !v.trimmingCharacters(in:.whitespaces).isEmpty
                error = !valid;if valid && v != value {onChange(v)}
            }
            if error {Text(isHex ? "Use #RRGGBB or #RRGGBBAA." : "Enter a value.").font(.caption).foregroundStyle(.secondary)}
        }
    }
}


#endif
