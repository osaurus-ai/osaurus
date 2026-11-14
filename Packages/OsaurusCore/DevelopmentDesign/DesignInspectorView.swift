#if OSAURUS_DESIGN_INSPECTOR
import AppKit
import SwiftUI

struct DevelopmentDesignInspectorView: View {
    @ObservedObject var store = DesignWorkingStore.shared
    @ObservedObject var themeManager = ThemeManager.shared
    @State private var page = "Buttons"
    @State private var mode = "dark"
    @State private var variant = "primary"
    @State private var interaction = "default"
    @State private var query = ""
    @State private var token = "type.label"
    @State private var label = "Continue"
    @State private var snapshotName = "Design exploration"
    @State private var focusPreview = false
    @State private var reviewingExport = false
    @State private var feedback = "Interactive examples use the app’s SettingsButton implementation."
    @State private var sampleName = "Research workspace"
    private var current: any ThemeProtocol { themeManager.currentTheme }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                VStack(alignment:.leading,spacing:3) {
                    Text("Osaurus · Live design inspector").font(.headline)
                    Text("Development copy · source 00ba05e · provisional values").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Undo") { store.undo() }.disabled(!store.canUndo)
                Button("Redo") { store.redo() }.disabled(!store.canRedo)
                Menu("Snapshots") {
                    Button("Save snapshot") { store.snapshot(snapshotName) }
                    ForEach(store.snapshots,id:\.self) { url in Button(url.deletingPathExtension().lastPathComponent) { store.loadSnapshot(url) } }
                }
                Button("Reset to handoff") { store.reset() }
                Button("Review changes for export") { reviewingExport = true }
            }.padding(16)
            Divider()
            HSplitView {
                VStack(alignment:.leading,spacing:14) {
                    Picker("View",selection:$page) { Text("Buttons").tag("Buttons"); Text("All tokens").tag("Tokens") }.pickerStyle(.segmented)
                    if page == "Tokens" { tokenBrowser } else { gallery }
                }.padding(20).frame(minWidth:540)
                VStack(alignment:.leading,spacing:12) {
                    Text("Live inspector").font(.headline)
                    Picker("Value appearance",selection:$mode) { Text("Light").tag("light");Text("Dark").tag("dark") }.pickerStyle(.segmented)
                    if page == "Buttons" {
                        Picker("Variant",selection:$variant) {ForEach(["primary","secondary","tertiary"],id:\.self){Text($0.capitalized).tag($0)}}
                        Picker("State",selection:$interaction) {ForEach(ThemeActionInteraction.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0.rawValue)}}
                    }
                    Text("Assignments update real shared buttons. Colors edit this appearance; typography and geometry stay shared. Value edits are live; layout and behavior changes require code and a rebuild.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    ScrollView {
                        VStack(alignment:.leading,spacing:24) {
                            if page == "Tokens" {
                                if let item = store.document.tokens[token] {
                                    Text(token).font(.system(.headline,design:.monospaced)).textSelection(.enabled)
                                    Text(item.use).font(.caption).fixedSize(horizontal:false,vertical:true)
                                    DesignValueEditor(store:store,role:token,mode:mode)
                                }
                            } else {
                                assignmentGroup("Colors", keys:["background","foreground","border"].map{"component.button.\(variant).\(interaction).\($0)"} + ["component.button.\(variant).focus.color"])
                                assignmentGroup("Typography",keys:["component.button.label","component.button.compactLabel"])
                                assignmentGroup("Geometry",keys:["component.button.radius","component.button.paddingX","component.button.paddingY","component.button.minimumHeight","component.button.compactPaddingX","component.button.compactPaddingY","component.button.compactHeight","component.button.focus.width","component.button.focus.offset"])
                            }
                        }.padding(.vertical,12)
                    }.accessibilityLabel("Expanded design assignments")
                }.padding(16).frame(minWidth:400,idealWidth:440,maxWidth:500).background(current.surface.raised)
            }
            Divider()
            Text(store.status).font(.caption).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(10)
        }.background(current.surface.canvas).foregroundStyle(current.text.primary)
        .environment(\.theme,current)
        .preferredColorScheme(current.isDark ? .dark : .light)
        .frame(minWidth:1100,minHeight:720)
        .sheet(isPresented:$reviewingExport) { DesignExportReview(store:store) }
    }
    private var tokenBrowser: some View {
        VStack(alignment:.leading,spacing:12) {
            TextField("Search 130 semantic roles",text:$query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:12) {
                    ForEach(store.document.tokens.keys.filter{query.isEmpty || $0.localizedCaseInsensitiveContains(query)}.sorted{$0.localizedStandardCompare($1) == .orderedAscending},id:\.self) { name in
                        Button { token=name } label: {
                            VStack(alignment:.leading,spacing:5) {
                                Text(name).font(.system(.body,design:.monospaced))
                                Text(store.document.tokens[name]?.use ?? "").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                HStack { Text("Light: " + summary(store.value(name,mode:"light"))); Text("Dark: " + summary(store.value(name,mode:"dark"))) }.font(.caption)
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(10).background(name == token ? current.surface.selected : current.surface.raised,in:RoundedRectangle(cornerRadius:8))
                        }.buttonStyle(.plain).accessibilityLabel("Inspect \(name)")
                    }
                }
            }
        }
    }
    private var gallery: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack {
                    Picker("App appearance",selection:Binding(get:{themeManager.currentTheme.isDark ? "dark" : "light"},set:{themeManager.setAppearanceMode($0 == "dark" ? .dark : .light,persist:false)})) {Text("Light").tag("light");Text("Dark").tag("dark")}.pickerStyle(.segmented).frame(width:240)
                    Picker("Text scale",selection:Binding(get:{ThemeManager.fontScale},set:{themeManager.setDesignInspectionScale($0)})) {Text("100%").tag(1.0);Text("150%").tag(1.5);Text("200%").tag(2.0)}.frame(width:190)
                }
                HStack { Text("Preview label");TextField("Button text",text:$label).textFieldStyle(.roundedBorder) }
                Toggle("Show focus-ring samples",isOn:$focusPreview)
                ViewThatFits(in:.horizontal) {
                    HStack(alignment:.top,spacing:20) { appearance("light").frame(minWidth:280);appearance("dark").frame(minWidth:280) }
                    VStack(alignment:.leading,spacing:20) { appearance("light");appearance("dark") }
                }
                Text("In the actual app").font(.headline)
                Text("Open Settings or a conversation, then edit this inspector. They resolve the same working themes; no account, models or installed-app data are used.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open app Settings") { AppDelegate.shared?.showManagementWindow(initialTab:.chat) }
                    Button("Open app conversation") { _ = ChatWindowManager.shared.createWindow() }
                }
                SettingsSection(title:"Workspace preferences",verbatimTitle:true) {
                    VStack(alignment:.leading,spacing:12) {
                        SettingsTextField(placeholder:"Workspace name",text:$sampleName)
                        HStack {SettingsButton(.primary,"Save changes",verbatim:true){feedback="Saved in this local component example."};SettingsButton(.secondary,"Cancel",verbatim:true){sampleName="Research workspace"};SettingsButton(.tertiary,"Reset",verbatim:true){sampleName=""}}
                    }.padding(16)
                }
                Text(feedback).font(.caption).foregroundStyle(.secondary)
                TextField("Snapshot name",text:$snapshotName).textFieldStyle(.roundedBorder)
            }
        }
    }
    private func appearance(_ mode:String) -> some View {
        let theme = CustomizableTheme(config: mode == "dark" ? CustomTheme.darkDefault : CustomTheme.lightDefault)
        return VStack(alignment:.leading,spacing:18) {
            Text(mode.capitalized).font(.headline)
            ForEach(["primary","secondary","tertiary"],id:\.self) { variant in
                VStack(alignment:.leading,spacing:10) {
                    Text(variant.capitalized).font(.subheadline.bold())
                    ForEach(ThemeActionInteraction.allCases,id:\.self) { state in
                        HStack(alignment:.firstTextBaseline) {
                            Text(state.rawValue.capitalized).font(.caption).frame(width:64,alignment:.leading)
                            SettingsButton(buttonRole(variant),label,verbatim:true){feedback="\(mode.capitalized) \(variant) activated"}
                                .environment(\.designInspectorState,state)
                                .environment(\.designInspectorFocus,focusPreview)
                                .disabled(state == .disabled)
                                .accessibilityLabel("\(mode) \(variant) \(state.rawValue) specimen")
                        }
                    }
                }
            }
            Text("Interactive controls").font(.subheadline.bold())
            SettingsButton(.primary,"Try keyboard and pointer",verbatim:true){feedback="Interactive primary activated in \(mode)."}
            SettingsButton(.primary,"Saving…",isLoading:true,verbatim:true){feedback="ERROR: loading control activated"}
        }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
        .background(theme.surface.raised,in:RoundedRectangle(cornerRadius:theme.radius.large))
        .foregroundStyle(theme.text.primary).environment(\.theme,theme)
        .environment(\.colorScheme,mode == "dark" ? .dark : .light)
    }
    private func assignmentGroup(_ title:String,keys:[String]) -> some View {
        VStack(alignment:.leading,spacing:18) {
            Text(title).font(.headline)
            ForEach(keys,id:\.self) { key in
                VStack(alignment:.leading,spacing:8) {
                    Text(key.replacingOccurrences(of:"component.button.",with:"")).font(.subheadline.weight(.medium)).fixedSize(horizontal:false,vertical:true)
                    let role=store.role(key), kind=store.document.tokens[role]?.type ?? ""
                    Picker("Semantic role",selection:Binding(get:{store.role(key)},set:{store.assign(key,to:$0)})) {
                        ForEach(store.choices(kind:kind),id:\.self){Text($0).tag($0)}
                    }.labelsHidden().accessibilityLabel("\(key) semantic assignment")
                    Text(role).font(.system(.caption,design:.monospaced)).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                    DesignValueEditor(store:store,role:role,mode:mode)
                    Text("Shared by \(store.document.mappings.values.filter{$0 == role}.count) assignments").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.accessibilityElement(children:.contain).accessibilityLabel(title + " assignments")
    }
    private func buttonRole(_ name:String)->SettingsButtonRole { name == "primary" ? .primary : name == "secondary" ? .secondary : .tertiary }
    private func summary(_ value:JSONValue)->String {
        switch value {case .string(let s):return s;case .number(let n):return n.formatted();case .object:return "Recipe";default:return "See inspector"}
    }
}

struct DesignExportReview: View {
    @ObservedObject var store: DesignWorkingStore
    @Environment(\.dismiss) private var dismiss
    @State private var error = ""
    private var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(store.changesForReview()), encoding: .utf8)) ?? "Unable to encode review"
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Review working changes").font(.title2.bold())
            Text("Compare the old and new values and assignments below. Export saves a separate file; the engineering handoff stays unchanged.").font(.body)
            ScrollView([.horizontal,.vertical]) { Text(json).font(.system(.caption,design:.monospaced)).textSelection(.enabled).padding(12) }.background(.background)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Export reviewed changes") {
                    do { _ = try store.exportChanges(); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:780,height:650)
    }
}

struct DesignValueEditor: View {
    @ObservedObject var store:DesignWorkingStore
    let role:String
    let mode:String
    var body:some View {
        let item=store.document.tokens[role]
        let value=store.value(role,mode:mode)
        VStack(alignment:.leading,spacing:10) {
            if item?.type == "color", let hex=value.designString {
                HStack {
                    ColorPicker(mode.capitalized,selection:Binding(get:{Color(themeHex:hex)},set:{store.edit(role,mode:mode,value:.string(Self.hex($0)))}),supportsOpacity:true).accessibilityLabel("\(role) \(mode) color")
                    DesignStringEntry(value:hex,label:"\(role) \(mode) hex",isHex:true){store.edit(role,mode:mode,value:.string($0))}
                }
            } else if item?.type == "typography",let recipe=value.designObject {
                Picker("Family",selection:Binding(get:{recipe["family"]?.designString ?? "system"},set:{store.edit(role,mode:mode,value:.string($0),field:"family")})) {
                    Text("System").tag("system");Text("System monospaced").tag("systemMonospaced")
                    ForEach(NSFontManager.shared.availableFontFamilies.sorted(),id:\.self){Text($0).tag($0)}
                }.accessibilityLabel("\(role) family")
                ForEach(["size","weight","lineHeight","tracking"],id:\.self) { field in
                    HStack {
                        Text(["size":"Size","weight":"Weight","lineHeight":"Line height","tracking":"Tracking"][field]!).frame(width:90,alignment:.leading)
                        DesignNumberEntry(value:recipe[field]?.designNumber ?? 0,label:"\(role) \(field)",allowNegative:field == "tracking") {store.edit(role,mode:mode,value:.number($0),field:field)}
                    }
                }
            } else if let number=value.designNumber {
                HStack {Text("Points / value");DesignNumberEntry(value:number,label:"\(role) \(mode) value"){store.edit(role,mode:mode,value:.number($0))}}
            } else if role.hasPrefix("font.family."),let family=value.designString {
                DesignStringEntry(value:family,label:role){store.edit(role,mode:mode,value:.string($0))}
            } else {
                Text("Structured or platform-resolved token. See the handoff for its formula or enum; this first inspector exposes scalar colors, full typography recipes and numeric geometry.").font(.caption).foregroundStyle(.secondary)
                Text(String(describing:value)).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
            }
        }.id(role + mode)
    }
    static func hex(_ color:Color)->String {
        let c=NSColor(color).usingColorSpace(.sRGB) ?? .clear
        return String(format:"#%02X%02X%02X%02X",Int((c.redComponent*255).rounded()),Int((c.greenComponent*255).rounded()),Int((c.blueComponent*255).rounded()),Int((c.alphaComponent*255).rounded()))
    }
}
struct DesignNumberEntry: View {
    let value:Double;let label:String;var allowNegative=false;let update:(Double)->Void
    @State private var draft=""
    var body:some View {
        TextField(label,text:$draft).textFieldStyle(.roundedBorder).labelsHidden().accessibilityLabel(label)
            .onAppear{sync()}.onChange(of:value){_,_ in sync()}.onChange(of:draft){_,text in
                if let n=Double(text),n.isFinite,(allowNegative || n >= 0),n != value {update(n)}
            }
    }
    private func sync(){if Double(draft) != value {draft=value.formatted(.number.grouping(.never).precision(.fractionLength(0...4)))}}
}
struct DesignStringEntry: View {
    let value:String;let label:String;var isHex=false;let update:(String)->Void
    @State private var draft=""
    var body:some View {
        TextField(label,text:$draft).textFieldStyle(.roundedBorder).accessibilityLabel(label)
            .onAppear{draft=value}.onChange(of:value){_,v in if draft != v {draft=v}}
            .onChange(of:draft){_,v in
                let valid=isHex ? v.range(of:"^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$",options:.regularExpression) != nil : !v.trimmingCharacters(in:.whitespaces).isEmpty
                if valid,v != value {update(v)}
            }
    }
}
#endif
