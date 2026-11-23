#if OSAURUS_DESIGN_INSPECTOR
// Adapted from the preserved full component inspector; layout and catalog retained.
import SwiftUI
import AppKit

// Every fixture resolves the same explicit assignment contract, including state colors.
@MainActor struct CatalogLibraryTheme {
    let store:CatalogDesignStore;let spec:CatalogComponentSpec;let mode:String;let state:String;let scale:Double
    let revision: Int
    var element: String? = nil
    func scoped(_ element: String) -> Self { var copy = self; copy.element = element; return copy }
    func assignment(_ property:String)->String {
        let element = element ?? CatalogElementAssignments.defaultElement(property)
        let key = CatalogElementAssignments.key(spec.key, element, property)
        return store.mappings[key] == nil ? spec.key + "." + property : key
    }
    init(store: CatalogDesignStore, spec: CatalogComponentSpec, mode: String, state: String, scale: Double) {
        self.store = store; self.spec = spec; self.mode = mode; self.state = state; self.scale = scale; self.revision = store.revision
    }
    func role(_ property:String)->String {store.role(assignment(property))}
    func color(_ property:String)->Color {store.color(role(property),mode)}
    func number(_ property:String)->Double {store.number(role(property),mode)}
    var fill:Color {color(state == "disabled" ? "disabledBackground" : state == "hover" ? "hover" : state == "selected" ? "selected" : "background")}
    var ink:Color {color(state == "disabled" ? "disabledForeground" : "foreground")}
    func text(_ text:String,_ property:String="text",ink:Color?=nil,inkProperty:String?=nil)->some View {
        let owner = element == nil ? scoped(["heading":"heading","caption":"supportingText","label":"label","emphasis":"emphasis","code":"code"][property] ?? "body") : self
        return Text(LocalizedStringKey(text)).modifier(CatalogLibraryType(store:store,role:owner.role(property),mode:mode,scale:scale))
            .foregroundStyle(inkProperty.map { owner.color($0) } ?? ink ?? owner.ink).fixedSize(horizontal:false,vertical:true)
            .catalogPreviewTarget([owner.assignment(property)], "Text “" + text + "”")
            .catalogPreviewTarget([owner.assignment(inkProperty ?? (state == "disabled" ? "disabledForeground" : "foreground"))], "Text “" + text + "”")
    }
}
struct CatalogLibraryType:ViewModifier {
    @ObservedObject var store:CatalogDesignStore
    let role:String;let mode:String;var scale=1.0
    func body(content:Content)->some View {
        let r=store.value(role,mode) as? [String:Any] ?? [:]
        let size=max(1,r["size"] as? Double ?? 14)*scale
        let weight=CatalogdesignFontWeight(r["weight"] as? Double ?? 400)
        let family=r["family"] as? String ?? "system"
        let font:Font=family == "system" ? .system(size:size,weight:weight) : family == "systemMonospaced" ? .system(size:size,weight:weight,design:.monospaced) : .custom(family,size:size).weight(weight)
        content.font(font).tracking((r["tracking"] as? Double ?? 0)*scale).lineSpacing(max(0,(r["lineHeight"] as? Double ?? size*1.2)*scale-size*1.2))
    }
}
struct CatalogLibrarySurface:ViewModifier {
    @ObservedObject var store: CatalogDesignStore
    let theme:CatalogLibraryTheme
    init(theme: CatalogLibraryTheme) { self.theme = theme.element == nil ? theme.scoped("container") : theme; self.store = theme.store }
    func body(content:Content)->some View {
        content.padding(theme.number("padding")).frame(maxWidth:.infinity,alignment:.leading)
            .background(theme.fill,in:RoundedRectangle(cornerRadius:theme.number("radius")))
            .overlay(RoundedRectangle(cornerRadius:theme.number("radius")).stroke(theme.color(theme.state == "error" ? "error" : "border"),lineWidth:theme.number("borderWidth")))
            .catalogPreviewTarget(["padding","radius","borderWidth",theme.state == "error" ? "error" : "border",theme.state == "disabled" ? "disabledBackground" : theme.state == "hover" ? "hover" : theme.state == "selected" ? "selected" : "background"].map { theme.assignment($0) }, theme.element == "codeBlock" ? "Code block" : "Component container")
    }
}

struct CatalogLibraryWorkspace:View {
    @ObservedObject var store:CatalogDesignStore
    let spec:CatalogComponentSpec
    var openSection: (String) -> Void = { _ in }
    @State private var state="default"
    @State private var messageConfiguration = ""
    @State private var previewColumnWidth: CGFloat = 650
    private var isMessage: Bool { [28,29].contains(spec.id) }
    private var messageWidth: CGFloat { max(280, previewColumnWidth - 80) }
    @ObservedObject private var appThemes = ThemeManager.shared
    @EnvironmentObject private var inspection: CatalogPreviewInspection
    private var scale: Double { appThemes.currentTheme.fontScale }
    var body:some View {
        HSplitView {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    HStack { Text(spec.name).font(.title2.weight(.semibold)); Spacer(); if spec.isProduct { Button(spec.isMessaging ? ((33...36).contains(spec.id) ? "Open app example" : "Open Chat") : "Show in Osaurus") { CatalogAppNavigation.show(spec.id) }.help(spec.isMessaging ? ((33...36).contains(spec.id) ? "Open the app component gallery for these conditional views without starting an agent or tool." : "Open Chat with local example content. No model request is made.") : "Show this component in the app") } }
                    Text(spec.detail).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    HStack {
                        if [28,29].contains(spec.id) {
                            let configurations = spec.id == 28 ? InspectorMessageExamples.userConfigurations : InspectorMessageExamples.assistantConfigurations
                            Picker("App configuration", selection: Binding(get: { configurations.contains(messageConfiguration) ? messageConfiguration : configurations[0] }, set: { messageConfiguration = $0 })) {
                                ForEach(configurations, id: \.self) { Text($0).tag($0) }
                            }.frame(maxWidth: 360)
                        }
                        Picker("Text scale",selection:Binding(get:{scale},set:{appThemes.setDesignInspectionScale($0)})){Text("100%").tag(1.0);Text("150%").tag(1.5);Text("200%").tag(2.0)}.frame(maxWidth:200)
                            .help("Applies to catalog specimens and the connected development app. Does not change saved token values.")
                    }
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 20) { fixture("dark"); fixture("light") }
                    }
                }.padding(24)
            }.frame(minWidth:500)
                .background(GeometryReader { geometry in
                    Color.clear.onAppear { previewColumnWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in previewColumnWidth = width }
                })
            CatalogExpandedAssignments(store:store,spec:spec,openSection:openSection).frame(minWidth:400,idealWidth:440,maxWidth:500)
        }.onAppear{state=spec.Catalogstates.first!}
    }
    func fixture(_ mode:String)->some View {
        VStack(alignment:.leading,spacing:16) {
            Text(mode.capitalized).font(.headline)
            CatalogNativePreview(family: spec.id)
                .simultaneousGesture(TapGesture().onEnded { inspection.selected = nil })
                .environment(\.inspectorMessageConfiguration, isMessage ? $messageConfiguration : nil)
                .environment(\.inspectorVerificationWidth, spec.isMessaging ? messageWidth : spec.id == 54 ? min(740, messageWidth) : 740)
                .environment(\.theme, CustomizableTheme(config: mode == "dark" ? .darkDefault : .lightDefault, fontScale: scale))
                .environment(\.nativeCatalogPreview, true)
                .frame(width: spec.isMessaging ? messageWidth : nil, alignment: .leading)
                .frame(width: spec.isMessaging ? nil : max(280, min(740, previewColumnWidth - 80)), alignment: .leading)
                .id("native.\(spec.id).\(mode)")

        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(store.color("color.surface.canvas",mode),in:RoundedRectangle(cornerRadius:store.number("radius.large",mode))).foregroundStyle(store.color("color.text.primary",mode)).environment(\.colorScheme,mode == "dark" ? .dark : .light)
    }
}

struct CatalogExpandedAssignments:View {
    @ObservedObject var store:CatalogDesignStore
    let spec:CatalogComponentSpec
    var openSection: (String) -> Void = { _ in }
    @State private var mode="dark"
    
    @EnvironmentObject private var inspection: CatalogPreviewInspection
    var ownKeys:[String] {
        let existingFill = [29, 31, 32, 36, 37, 38, 39].contains(spec.assignmentFamily) ? [CatalogElementAssignments.routed(spec.key + ".background", mappings: store.mappings)] : []
        let rendered = Array(Set(existingFill + inspection.allTargets.keys.filter { $0.hasPrefix(spec.key + ".") } + AgentContentSurfaceAssignments.keys(spec.assignmentFamily)))
        let replaced = Set(rendered.compactMap { CatalogLayoutAssignments.byKey[$0] }.map {
            CatalogElementAssignments.routed($0.legacy, mappings: store.mappings)
        })
        return rendered.filter { !replaced.contains($0) || CatalogLayoutAssignments.byKey[$0] != nil }.sorted()
    }
    var keys:[String]{ownKeys}
    private var sharedParts: [(String, String)] {
        var result: [String: String] = [:]
        for key in inspection.allTargets.keys {
            if key.hasPrefix("component.input.") { result["Inputs"] = "Inputs" }
            if key.hasPrefix("component.button.") { result["Buttons"] = "Buttons" }
            let parts = key.split(separator: ".")
            if parts.count > 2, parts[1] == "library", let family = Int(parts[2]),
               family != spec.assignmentFamily,
               let child = CatalogcomponentCatalog.first(where: { $0.id == family }), child.isBase || child.isComposition {
                result[child.name] = child.section
            }
        }
        if [28,29].contains(spec.id) {
            result["Buttons"] = "Buttons"
            result["Message header and actions"] = "library.30"
            result["Rich-text message content"] = "library.31"
            if spec.id == 28 { result["Multiline text editor"] = "library.3"; result["Attachment chips and thumbnails"] = "library.24" }
            else { result["Avatars and identity marks"] = "library.11"; result["Code blocks"] = "library.32"; result["Thinking and generation status"] = "library.33"; result["Conversation notices and markers"] = "library.40" }
        }
        if spec.id == 5 { result["Context menus"] = "library.65" }
        if spec.id == 26 {
            result["Buttons"] = "Buttons"
            result["Chips"] = "library.56"
            result["Inputs"] = "Inputs"
        }
        if spec.id == 24 { result["Buttons · shared Remove action"] = "Buttons"; result.removeValue(forKey: "Buttons") }
        return result.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Live inspector").font(.headline)
            Picker("Value appearance",selection:$mode){Text("Light").tag("light");Text("Dark").tag("dark")}.pickerStyle(.segmented)
            if spec.id == 5 {
                Text("Closed dropdown styles are below. Popup styles are in Context menus.").font(.caption).foregroundStyle(.secondary)
            }
            if !sharedParts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shared components used here").font(.subheadline.weight(.semibold))
                    Text("Edit their styles once on these pages.").font(.caption).foregroundStyle(.secondary)
                    ForEach(sharedParts, id: \.0) { part in
                        Button(part.0) { openSection(part.1) }.buttonStyle(.link)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            CatalogAssignmentGroups(store:store,keys:keys,mode:mode,label:"\(spec.name) expanded assignments",prefix:spec.key + ".")
        }.padding(16).background(Color(nsColor:.controlBackgroundColor))
    }
}
func CatalogselectionAfterClosingTab(active:Int,closed:Int,remaining:Int)->Int {
    max(0,min(closed < active ? active-1 : active,remaining-1))
}
struct CatalogAssignmentGroups:View {
    @ObservedObject var store:CatalogDesignStore
    let keys:[String];let mode:String;let label:String
    var prefix = "component."
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                Text("Hover or select a property name to highlight what it changes.").font(.caption).foregroundStyle(.secondary)
                group("Colors",kind:"color")
                group("Typography",kind:"typography")
                group("Shape and size",kind:"dimension", excludingLayout: true)
                layoutGroups
                if keys.contains(where: { store.tokens[store.role($0)]?["type"] as? String == "effect" }) { group("Effects",kind:"effect") }
            }.padding(.vertical,12).padding(.trailing,8)
        }.accessibilityLabel(label)
    }
    private var layoutGroups: some View {
        let layoutKeys = keys.filter { $0.contains(".elements.layout.") || CatalogLayoutAssignments.byKey[$0] != nil }
        let groups = Dictionary(grouping: layoutKeys) { CatalogLayoutAssignments.byKey[$0]?.group ?? "Component layout" }
        return VStack(alignment: .leading, spacing: 20) {
            if !layoutKeys.isEmpty {
                Text("Layout and spacing").font(.headline)
                Text("Existing layout keeps the current spacing. Choose a token to change that boundary independently.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(groups.keys.sorted(), id: \.self) { name in
                VStack(alignment: .leading, spacing: 12) {
                    Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(groups[name] ?? [], id: \.self) { key in
                        CatalogAssignmentRow(store: store, key: key, title: name, kind: "dimension", mode: mode)
                    }
                }
            }
        }
    }
    @ViewBuilder func group(_ name:String,kind:String, excludingLayout:Bool = false, layoutOnly:Bool = false)->some View {
        let matching = keys.filter { store.tokens[store.role($0)]?["type"] as? String == kind && (!excludingLayout || (!$0.contains(".elements.layout.") && CatalogLayoutAssignments.byKey[$0] == nil)) && (!layoutOnly || $0.contains(".elements.layout.")) }
        if !matching.isEmpty {
            VStack(alignment:.leading,spacing:16) {
                Text(name).font(.headline)
                ForEach(matching,id:\.self){key in
                    CatalogAssignmentRow(store:store,key:key,title:key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key,kind:kind,mode:mode)
                }
            }.accessibilityElement(children:.contain).accessibilityLabel(name + " assignments")
        }
    }

}

struct CatalogAssignmentRow:View {
    @ObservedObject var store:CatalogDesignStore
    let key:String;let title:String;let kind:String;let mode:String
    @EnvironmentObject private var inspection: CatalogPreviewInspection
    var role:String{store.role(key)}
    var noneRole:String? {
        guard kind == "color" else { return nil }
        let property = key.split(separator:".").last.map(String.init) ?? ""
        if property.lowercased().contains("border") || key.contains(".border.") { return "color.border.none" }
        if property.lowercased().contains("background") || ["hover","selected"].contains(property) { return "color.surface.none" }
        return nil
    }
    var choices: [String] { store.assignmentChoices(key: key, kind: kind, mode: mode) }
    var body:some View {
        let available = choices
        let sections = Dictionary(grouping: available) { CatalogAssignmentMenu.group($0, kind:kind) }
        return VStack(alignment:.leading,spacing:8) {
            Button { inspection.selected = key } label: {
                Text(inspection.label(for:key, fallback:title)).font(.subheadline.weight(.medium)).fixedSize(horizontal:false,vertical:true)
            }.buttonStyle(.plain).accessibilityLabel("Highlight " + inspection.label(for:key, fallback:title))
                .help((inspection.allTargets[key] ?? []).sorted().joined(separator:"\n"))
                .onHover { hovering in
                    if hovering { inspection.selected = key }
                    else if inspection.selected == key { inspection.selected = nil }
                }
            Picker(title,selection:Binding(get:{store.usesAppDefault(key) ? "__app_default__" : role},set:{
                inspection.selected = nil
                store.map(key, $0 == "__app_default__" && key.hasSuffix(".borderWidth") && (key.hasPrefix("component.library.28.") || key.hasPrefix("component.library.29.")) ? "stroke.none" : $0)
            })){
                if store.offersAppDefault(key) { Text(CatalogLayoutAssignments.byKey[key] != nil ? "Existing layout" : (["28","29"].contains(String(key.split(separator: ".")[2])) && key.hasSuffix(".borderWidth")) ? "None (original app)" : "App default").tag("__app_default__") }
                if let noneRole { Text("None").tag(noneRole) }
                if !available.contains(role), role != noneRole {
                    Section("Current assignment") { Text(role).tag(role) }
                }
                ForEach(CatalogAssignmentMenu.groups.filter { sections[$0] != nil },id:\.self) { group in
                    Section(group) {
                        ForEach(sections[group] ?? [],id:\.self) { Text($0).tag($0) }
                    }
                }
            }.labelsHidden().accessibilityLabel(inspection.label(for: key, fallback: title) + " semantic assignment")

            if inspection.selected == key && inspection.allTargets[key] == nil {
                Text("Not visible in this preview state").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(6).background(inspection.selected == key ? Color.accentColor.opacity(0.10) : .clear, in:RoundedRectangle(cornerRadius:6))
            .id(key + "." + role + "." + mode)
    }
}

struct CatalogLibraryFixture:View {
    @ObservedObject var store:CatalogDesignStore
    let spec:CatalogComponentSpec;let mode:String;let state:String;let scale:Double
    @State private var text=""
    @State private var secondaryText=""
    @State private var enabled=true
    @State private var checked=false
    @State private var selected="Local"
    @State private var number=40.0
    @State private var date=Date()
    @State private var expanded=false
    @State private var sheet=false
    @State private var popover=false
    @State private var recording=false
    @State private var shortcut="⌘ K"
    @State private var feedback=""
    @State private var streamed=""
    @State private var hoveredRow=""
    @State private var attachments=["notes.md","reference.png"]
    @State private var entries=["Research direction","Review draft","Summarize changes"]
    @State private var active=0
    @State private var saved=""
    @State private var tab="Conversation"
    @FocusState private var focus:Bool
    var t:CatalogLibraryTheme{CatalogLibraryTheme(store:store,spec:spec,mode:mode,state:state,scale:scale)}
    var disabled:Bool{state == "disabled"}
    var body:some View {
        VStack(alignment:.leading,spacing:t.scoped("container").number("gap")) {
            content
            if !feedback.isEmpty {t.text(feedback,"caption",inkProperty:"secondary")}
        }.modifier(CatalogLibraryType(store:store,role:t.role("text"),mode:mode,scale:scale)).foregroundStyle(t.ink).tint(t.color("accent"))
            .frame(minHeight:t.scoped("container").number("height"),alignment:.leading).modifier(CatalogLibrarySurface(theme:t)).disabled(disabled)
            .catalogPreviewTarget(["gap","height"].map { t.scoped("container").assignment($0) }, "Component content layout")
            .onChange(of:state){_,s in
                if s == "selected" {checked=true}
                if s == "empty" {text=""}
                if [12,35,47,49].contains(spec.id) {if s == "waiting" {number=0};if s == "running" {number=40};if s == "complete" {number=100}}
                if s == "filled" && text.isEmpty {text="Please compare these approaches and suggest a starting point."}
            }
            .onAppear {
                switch spec.id {case 16,27:selected="Personal";case 26:selected="Osaurus local";case 36:selected="Use local files";case 41:entries=["Research assistant","Remote agent","Shared workspace","Project: Research","Conversation: Design tokens"];case 42:tab="Agents";case 50:selected="Time";case 54:selected="Square";default:break}
            }
            .task(id:state) {
                guard state == "streaming",[29,31,32].contains(spec.id) else{return}
                streamed=""
                let source=spec.id == 32 ? "struct Message { let content: String }\nlet message = Message(content: \"Hello, Osaurus\")" : "Start with the smallest reusable pieces, then combine them into a short conversation. This lets you test the design before arranging the full screen."
                for word in source.components(separatedBy:" ") {
                    if Task.isCancelled {return}
                    streamed += word + " "
                    try? await Task.sleep(nanoseconds:80_000_000)
                }
            }
            .sheet(isPresented:$sheet){sheetBody.padding(24).frame(minWidth:420,minHeight:220).environment(\.colorScheme,mode == "dark" ? .dark : .light)}
    }
    @ViewBuilder var content:some View {
        if spec.id <= 20 {baseContent} else if spec.id <= 32 {chatContent} else if spec.id <= 45 {activityContent} else {featureContent}
    }
    func button(_ label:String,_ variant:String="secondary",symbol:String?=nil,action:@escaping () -> Void)->some View {
        CatalogTokenButton(store:store,variant:variant,mode:mode,forced:disabled ? "disabled" : nil,label:label,scale:scale,symbol:symbol,familyKey:spec.key,action:action)
    }
    func title(_ text:String)->some View{t.text(text,"heading")}
    func caption(_ text:String)->some View{t.text(text,"caption",inkProperty:"secondary")}
    func divider()->some View {let t = self.t.scoped("divider"); return Rectangle().fill(t.color("border")).frame(height:max(0,t.number("borderWidth"))).catalogPreviewTarget([t.assignment("border"),t.assignment("borderWidth")], "Divider line")}
    func badge(_ label:String,_ color:String="accent",symbol:String?=nil)->some View {
        let t = self.t.scoped("badge")
        return 
        HStack(spacing:4){if let symbol {Image(systemName:symbol)};t.text(label,"caption",inkProperty:color)}.foregroundStyle(t.color(color)).padding(.horizontal,t.number("gap")).padding(.vertical,4).background(t.color("selected"),in:RoundedRectangle(cornerRadius:t.number("radius")))
            .catalogPreviewTarget(["selected","radius","gap"].map { t.assignment($0) }, "Badge “" + label + "”")
    }
    func identity(_ name:String,_ initials:String="O",status:String="Ready")->some View {
        let t = self.t.scoped("avatar")
        return 
        HStack(alignment:.center,spacing:t.number("gap")) {
            t.text(initials,"label").frame(width:max(24,t.number("avatarSize")),height:max(24,t.number("avatarSize"))).background(t.color("selected"),in:Circle()).catalogPreviewTarget([t.assignment("avatarSize"),t.assignment("selected")], "Avatar initials")
            VStack(alignment:.leading,spacing:4){self.t.scoped("label").text(name,"label");caption(status)}
        }
    }
    func input(_ title:String,text:Binding<String>,placeholder:String="Enter a value",secure:Bool=false)->some View {
        CatalogTokenInput(store:store,mode:mode,title:title,text:text,placeholder:placeholder,state:state == "error" ? "error" : disabled ? "disabled" : "default",message:state == "error" ? "Check this value and try again." : "",scale:scale,secure:secure,familyKey:spec.key)
    }
    func row(_ label:String,subtitle:String="",symbol:String="doc",selected:Bool=false,action:@escaping () -> Void)->some View {
        let t = self.t.scoped("row")
        return 
        Button(action:action) {
            HStack(spacing:t.number("gap")) {
                Image(systemName:symbol).foregroundStyle(t.color("accent")).catalogPreviewTarget([t.assignment("accent")], "Row icon “" + label + "”")
                VStack(alignment:.leading,spacing:4){t.text(label,"label");if !subtitle.isEmpty {t.text(subtitle,"caption",inkProperty:"secondary")}}
                Spacer(minLength:4)
                if selected {Image(systemName:"checkmark").foregroundStyle(t.color("accent")).catalogPreviewTarget([t.assignment("accent")], "Selected row checkmark")}
            }.padding(t.number("gap")).frame(minHeight:t.number("height"),alignment:.leading).background(selected ? t.color("selected") : hoveredRow == label ? t.color("hover") : t.color("background"),in:RoundedRectangle(cornerRadius:t.number("radius")))
        }.catalogPreviewTarget(["gap","height","radius",selected ? "selected" : hoveredRow == label ? "hover" : "background"].map { t.assignment($0) }, "Row “" + label + "”")
        .buttonStyle(.plain).onHover{hoveredRow=$0 ? label : ""}.accessibilityLabel(label).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    func editor(_ label:String)->some View {
        let t = self.t.scoped("editor")
        return 
        VStack(alignment:.leading,spacing:6) {
            t.text(label,"label")
            TextEditor(text:$text).modifier(CatalogLibraryType(store:store,role:t.role("text"),mode:mode,scale:scale)).scrollContentBackground(.hidden)
                .foregroundStyle(t.ink).padding(t.number("gap")).frame(height:min(300,max(96,Double(max(1,text.components(separatedBy:"\n").count) + text.count/55)*24*scale + t.number("padding")*2)))
                .background(t.color("background"),in:RoundedRectangle(cornerRadius:t.number("radius")))
                .overlay(RoundedRectangle(cornerRadius:t.number("radius")).stroke(focus ? t.color("accent") : t.color(state == "error" ? "error" : "border"),lineWidth:max(1,t.number("borderWidth"))))
                .focused($focus).accessibilityLabel(label)
                .catalogPreviewTarget(["text","foreground","background","radius","borderWidth","gap","padding",focus ? "accent" : state == "error" ? "error" : "border"].map { t.assignment($0) }, "Message editor")
            if text.isEmpty {caption("Type or paste a message. Enter adds a new line.")}
            if state == "error" {Label("Enter a message before sending.",systemImage:"exclamationmark.circle").foregroundStyle(t.color("error"))}
        }
    }
    func progress(_ value:Double)->some View {
        let t = self.t.scoped("progress")
        return 
        VStack(alignment:.leading,spacing:6) {
            GeometryReader{g in ZStack(alignment:.leading){Capsule().fill(t.color("selected"));Capsule().fill(t.color(state == "error" ? "error" : "accent")).frame(width:g.size.width*max(0,min(1,value)))}}.frame(height:8).catalogPreviewTarget([t.assignment("selected"),t.assignment(state == "error" ? "error" : "accent")], "Progress bar").accessibilityLabel("Progress").accessibilityValue("\(Int(value*100)) percent")
            caption("\(Int(value*100))%")
        }
    }
    @ViewBuilder var baseContent:some View {
        switch spec.id {
        case 3:
            editor("Multiline editor")
            HStack{button("Insert sample"){text="A longer note with multiple paragraphs.\n\nPlease compare these two approaches and explain the tradeoffs."};button("Clear","tertiary"){text=""}}
            caption("\(text.count) characters")
        case 4:
            VStack(alignment:.leading,spacing:t.number("gap")) {
                CatalogLibraryToggle(theme:t.scoped("switch"),title:"Enable notifications",isOn:$enabled)
                CatalogLibraryToggle(theme:t.scoped("checkbox"),title:"Include attachments",isOn:$checked,checkbox:true)
                caption("Notifications \(enabled ? "on" : "off") · attachments \(checked ? "included" : "excluded")")
            }.modifier(CatalogLibraryType(store:store,role:t.role("label"),mode:mode,scale:scale)).foregroundStyle(t.ink)
        case 5:
            Picker("Compute",selection:$selected){Text("Local").tag("Local");Text("Cloud").tag("Cloud");Text("Unavailable").tag("Unavailable").disabled(true)}
            Menu("Actions"){Button("Duplicate"){feedback="Duplicated locally"};Button("Rename"){feedback="Rename selected"};Divider();Button("Delete",role:.destructive){feedback="Removed in preview; Undo restores the row";entries.removeAll()}}
            ForEach(entries,id:\.self){name in row(name,symbol:"doc",selected:selected == name){selected=name}}
            button("Restore sample","tertiary"){entries=["Research direction","Review draft","Summarize changes"]}
        case 6:
            Picker("View",selection:$tab){Text("Conversation").tag("Conversation");Text("Activity").tag("Activity");Text("Files").tag("Files")}.pickerStyle(.segmented).catalogPreviewTarget([t.assignment("text"),spec.key + ".foreground"], "Conversation / Activity / Files segment labels")
            title(tab)
            caption("The selected segment changes the displayed sample content.")
        case 7:
            t.text("Temperature","label")
            CatalogLibrarySlider(theme:t.scoped("progress"),title:"Temperature",value:$number)
            Stepper("Value: \(Int(number))",value:$number,in:0...100).modifier(CatalogLibraryType(store:store,role:t.role("text"),mode:mode,scale:scale)).catalogPreviewTarget([t.assignment("text")], "Stepper value text")
            button("Restore default","tertiary"){number=40}
        case 8:
            DatePicker("Run at",selection:$date,displayedComponents:[.date,.hourAndMinute]).datePickerStyle(.field)
            caption(date.formatted(date:.abbreviated,time:.shortened))
        case 9:
            t.text("Open command menu","label")
            badge(recording ? "Press a key combination…" : shortcut,symbol:"keyboard")
            button(recording ? "Cancel recording" : "Record shortcut"){recording.toggle();focus=recording}
                .focusable().focused($focus).onKeyPress(phases:.down){press in
                    guard recording else{return .ignored}
                    if press.key == .escape {recording=false;return .handled}
                    shortcut="\(press.modifiers.contains(.command) ? "⌘ " : "")\(press.modifiers.contains(.shift) ? "⇧ " : "")\(press.characters.uppercased())";recording=false;feedback="Shortcut recorded for this preview";return .handled
                }
            caption("Tab to the recorder, then type a shortcut. Escape cancels.")
        case 10:
            VStack(alignment:.leading,spacing:t.number("gap")) {badge("Local");badge("3 active","success",symbol:"checkmark.circle");badge("Needs attention","warning",symbol:"exclamationmark.triangle");badge("Unavailable","error",symbol:"xmark.circle");badge("Research",symbol:"tag")}
        case 11:
            identity("Osaurus","O")
            identity("Research assistant","RA",status:"Running")
            HStack{Image(systemName:"person.crop.circle.fill").resizable().scaledToFit().frame(width:t.number("avatarSize"),height:t.number("avatarSize")).foregroundStyle(t.color("accent"));caption("Image fallback · system symbol")}
        case 12:
            title(state.capitalized)
            progress(state == "complete" ? 1 : number/100)
            if state == "running" || state == "waiting" {ProgressView().assignedProgressIndicator(tintOverride: t.color(state == "disabled" ? "disabledForeground" : "accent")).controlSize(.small).accessibilityLabel("Working")}
            badge(state == "error" ? "Failed" : state == "complete" ? "Complete" : "Working",state == "error" ? "error" : "success",symbol:state == "error" ? "xmark.circle" : "checkmark.circle")
            CatalogLibrarySlider(theme:t.scoped("progress"),title:"Demo progress",value:$number)
        case 13:
            title("Research workspace")
            t.text("A reusable surface with a title, description and optional actions.")
            divider()
            button("Open workspace","primary"){feedback="Workspace opened in preview"}
        case 14:
            title("Preferences")
            caption("Choose how this workspace behaves.")
            row("Workspace name",subtitle:"Personal",symbol:"folder"){feedback="Workspace row selected"}
            divider()
            row("Storage",subtitle:"Local on this Mac",symbol:"internaldrive"){feedback="Storage row selected"}
            caption("Changes apply to this workspace.")
        case 15:
            DisclosureGroup(isExpanded:$expanded){t.text("Details about this option, with enough text to wrap at smaller widths.");button("Apply","primary"){feedback="Option applied"}} label:{t.text("Advanced options","label")}
            badge(expanded ? "Expanded" : "Collapsed")
        case 16:
            button("Choose a workspace"){popover=true}.assignedPopover(isPresented:$popover, width:380, accessibilityLabel:"Popover specimen") {
                VStack(alignment:.leading,spacing:12){title("Choose a workspace");pickerSurface(["Personal","Research","Shared team"]);button("Done","primary"){popover=false}}.modifier(CatalogLibrarySurface(theme:t)).padding(12).frame(width:380).environment(\.colorScheme,mode == "dark" ? .dark : .light)
            }
            caption("A picker surface with search, selection rows, empty results and footer actions.")
            pickerSurface(["Personal","Research","Shared team"])
        case 17:
            title("Dialog and sheet")
            t.text("Confirm an action or complete a small form.")
            button("Open dialog","primary"){sheet=true}
            caption("The sample sheet uses the same inputs and buttons. Escape cancels.")
        case 18:
            if !checked {
                HStack(alignment:.top){Image(systemName:state == "error" ? "exclamationmark.circle" : "info.circle").foregroundStyle(t.color(state == "error" ? "error" : state == "warning" ? "warning" : "success"));VStack(alignment:.leading){t.text(state == "error" ? "Connection failed" : "Your changes are saved","label");caption(state == "error" ? "Try connecting again." : "This notice stays until dismissed.")}}
                HStack{button("Retry"){feedback="Retry complete in preview"};button("Dismiss","tertiary"){checked=true}}
            } else {button("Show notice"){checked=false}}
        case 19:
            Image(systemName:state == "error" ? "exclamationmark.triangle" : "bubble.left.and.bubble.right").font(.largeTitle).foregroundStyle(t.color(state == "error" ? "error" : "accent"))
            title(state == "error" ? "Couldn’t load conversations" : "No conversations yet")
            t.text(state == "error" ? "Try again to load the preview." : "Start with a question or choose a workspace.")
            button(state == "error" ? "Retry" : "Start conversation","primary"){feedback="Preview ready"}
        case 20:
            HStack{t.text("Name","label");Spacer();t.text("Status","label")};divider()
            ForEach(Array(entries.enumerated()),id:\.offset){i,name in row(name,subtitle:i == 0 ? "Running" : "Ready",symbol:"doc",selected:active == i){active=i;feedback="Selected \(name)"}}
            HStack{button("Add row"){entries.append("New item \(entries.count+1)")};button("Clear","tertiary"){entries=[]}}
            if entries.isEmpty {caption("No matching items.")}
        default:caption("Use the dedicated Buttons or Inputs study.")
        }
    }
    @ViewBuilder var chatContent:some View {
        switch spec.id {
        case 21:
            composer
        case 22:
            title("Composer actions")
            HStack{button("Send","primary",symbol:"arrow.up"){feedback="Message sent"};button("Stop","destructive",symbol:"stop.fill"){feedback="Generation stopped"}}
            HStack{button("Queue",symbol:"text.badge.plus"){feedback="Message queued"};button("Send now","primary",symbol:"arrow.up"){feedback="Queued message sent"}}
            HStack{button("Attach","tertiary",symbol:"paperclip"){attachments.append("document.pdf")};button("Commands","tertiary",symbol:"slash"){feedback="Command menu selected"};button("Voice","tertiary",symbol:"mic"){recording.toggle();feedback=recording ? "Listening" : "Voice stopped"}}
            caption("\(attachments.count) attachments")
        case 23:
            title("Context chips")
            ForEach(["Model: Osaurus local","Folder: Research","Skill: Summarize","Sandbox: \(enabled ? "On" : "Off")","Clipboard: \(checked ? "On" : "Off")","Context: 42%","Credits: 120","Workspace: Personal"],id:\.self){name in
                CatalogLibraryChip(theme:t.scoped("chip"),title:name,selected:selected == name) {
                    selected=name
                    if name.hasPrefix("Sandbox") {enabled.toggle()}
                    if name.hasPrefix("Clipboard") {checked.toggle()}
                    feedback="\(name) selected"
                }
            }
            progress(0.42)
        case 24:
            title("Attachments")
            attachmentTray
            button("Add sample attachment"){attachments.append("brief-\(attachments.count+1).pdf")}
            if attachments.isEmpty {caption("No attachments. Add a sample file.")}
        case 25:
            input("Search commands or files",text:$text,placeholder:"Type / or @")
            ForEach(["/summarize","/review","@README.md","@design.json"].filter{text.isEmpty || $0.localizedCaseInsensitiveContains(text)},id:\.self){name in row(name,symbol:name.hasPrefix("@") ? "doc" : "slash",selected:selected == name){selected=name;feedback="Inserted \(name)"}}
            if !text.isEmpty && !["/summarize","/review","@README.md","@design.json"].contains(where:{$0.localizedCaseInsensitiveContains(text)}) {caption("No matching commands or files.")}
        case 26:
            title("Choose a model")
            pickerSurface(["Osaurus local","Cloud model","Downloaded model"])
            badge(state == "error" ? "Unavailable" : "Available",state == "error" ? "error" : "success")
        case 27:
            title("Choose an agent or workspace")
            input("Search",text:$text,placeholder:"Search agents")
            ForEach(["Personal","Research assistant","Shared team"].filter{text.isEmpty || $0.localizedCaseInsensitiveContains(text)},id:\.self){name in row(name,subtitle:name == "Shared team" ? "Shared workspace" : "Local",symbol:"person.crop.circle",selected:selected == name){selected=name}}
            caption("Selected: \(selected)")
        case 28:
            HStack{Spacer();caption("You · just now")}
            if expanded {input("Edit message",text:$text,placeholder:"Write a message");HStack{button("Save","primary"){saved=text;expanded=false;feedback="Message updated"};button("Cancel","tertiary"){expanded=false}}}
            else {t.text(saved.isEmpty ? "Can you compare these two approaches and suggest a starting point?" : saved).textSelection(.enabled)}
            attachmentTray
            button("Edit message","tertiary",symbol:"pencil"){text=saved.isEmpty ? "Can you compare these two approaches?" : saved;expanded=true}
        case 29:
            identity("Osaurus","O",status:state == "error" ? "Interrupted" : "Assistant")
            if state == "error" {t.text("The response was interrupted.");button("Retry"){feedback="Retry started"}}
            else if state == "empty" {caption("No response was returned.");button("Retry"){feedback="Response restarted"}}
            else {t.text(state == "streaming" ? streamed : "Start with the smallest reusable pieces, then combine them into a short conversation. That lets you test the design before arranging the full screen.").textSelection(.enabled);assistantActions}
        case 30:
            identity("Research assistant","RA",status:"Completed · 12 seconds")
            assistantActions
            caption("420 tokens · local model")
        case 31:
            title("A sample answer")
            t.text("Emphasized message text", "emphasis")
            t.text(state == "streaming" ? streamed : "This paragraph includes **emphasis**, a [link](https://example.com), and `inline code`.")
            t.text("• First option\n• Second option\n\n1. Review the evidence\n2. Choose a direction")
            HStack{Rectangle().fill(t.color("accent")).frame(width:3);t.text("A quoted observation to compare with the answer.")}
            codeBlock("let message = \"Hello, Osaurus\"")
            HStack{t.text("Option","label");Spacer();t.text("Result","label")};divider();HStack{t.text("Local");Spacer();t.text("Ready")}
            Image(systemName:"photo").resizable().scaledToFit().frame(height:80).foregroundStyle(t.color("secondary")).accessibilityLabel("Sample image fallback")
            t.text("Formula specimen: E = mc²","code")
            caption("Rich-content fixtures use local text and image fallbacks; they make no remote requests.")
        case 32:
            codeBlock(state == "streaming" ? streamed : "struct Message {\n    let author: String\n    let content: String\n}\n\nlet message = Message(author: \"You\", content: \"Hello\")")
        default:EmptyView()
        }
    }
    @ViewBuilder var activityContent:some View {
        switch spec.id {
        case 33:
            badge(state.capitalized,state == "error" ? "error" : state == "complete" ? "success" : "accent",symbol:state == "complete" ? "checkmark.circle" : "sparkles")
            DisclosureGroup(isExpanded:$expanded){t.text("Compare the two approaches, identify the tradeoffs, and choose the smallest useful next step.")} label:{t.text("Thinking","label")}
            if state == "running" || state == "waiting" {ProgressView("Generating response…").controlSize(.small)}
            if state == "error" {button("Retry"){feedback="Generation restarted"}}
        case 34:
            title("Tool activity")
            ForEach(["Read README.md","Inspect design tokens","Build preview"],id:\.self){name in row(name,subtitle:state.capitalized,symbol:state == "error" ? "xmark.circle" : state == "complete" ? "checkmark.circle" : "clock"){expanded.toggle();selected=name}}
            caption("Select a step to inspect its output.")
            if expanded {codeBlock("{ \"path\": \"README.md\", \"result\": \"Read successfully\" }")}
            if state == "error" {button("Retry step"){feedback="Step retried"}}
        case 35:
            title("Agent progress")
            ForEach(Array(entries.enumerated()),id:\.offset){i,name in HStack{Image(systemName:i < Int(number/34) ? "checkmark.circle.fill" : "circle").foregroundStyle(t.color("success"));t.text(name);Spacer();caption(i == 2 ? "Research agent" : "Main agent")}}
            progress(number/100)
            button("Complete next step"){number=min(100,number+34);feedback=number >= 100 ? "All steps complete" : "Step completed"}
        case 36:
            title("Choose how to proceed")
            t.text("The assistant needs a choice before continuing.")
            ForEach(["Use local files","Use the selected workspace","Ask another question"],id:\.self){name in row(name,symbol:"circle",selected:selected == name){selected=name}}
            input("Optional details",text:$text)
            input("Secret value",text:$secondaryText,placeholder:"Stored only in this preview",secure:true)
            HStack{button("Continue","primary"){feedback="Selected: \(selected)"};button("Cancel","tertiary"){feedback="Request cancelled"}}
            caption("Approval and sensitive-input presentation use sample content only.")
        case 37:
            Image(systemName:"doc.richtext").font(.largeTitle).foregroundStyle(t.color("accent"))
            title("Research summary")
            caption("Document · updated just now")
            t.text("A short preview of the generated document, with content and actions kept together.")
            HStack{button("Open preview","primary"){sheet=true};button("Copy title","tertiary"){NSPasteboard.general.clearContents();NSPasteboard.general.setString("Research summary",forType:.string);feedback="Title copied"}}
        case 38:
            title("File changes")
            row("tokens.json",subtitle:"+4 −2",symbol:"doc.text",selected:expanded){expanded.toggle()}
            button(expanded ? "Hide diff" : "Show diff","tertiary"){expanded.toggle()}
            if expanded {codeBlock("− \"radius\": 6\n+ \"radius\": 8\n+ \"padding\": 12")}
            HStack{button("Accept sample","primary"){feedback="Sample changes accepted"};button("Discard","tertiary"){feedback="Sample changes discarded; restore with Reset preview"}}
            button("Reset preview","tertiary"){feedback="";expanded=false}
        case 39:
            title("Terminal output")
            codeBlock("$ build playground\nCompiling components…\n✓ Build succeeded\n✓ Assignments verified")
            title("Activity chart")
            HStack(alignment:.bottom,spacing:t.number("gap")){ForEach([25.0,60,45,90,70],id:\.self){v in Rectangle().fill(t.color("accent")).frame(maxWidth:.infinity).frame(height:v)}}.frame(height:100).accessibilityLabel("Sample activity chart, values 25, 60, 45, 90, 70")
            caption("Local sample data · five runs")
        case 40:
            badge(state == "warning" ? "Context compacted" : "Conversation saved",state == "error" ? "error" : "success",symbol:"info.circle")
            t.text(state == "error" ? "This response is empty. Retry to continue." : "Earlier messages were summarized to make room for this conversation.")
            divider()
            t.text("Suggested next steps","label")
            ForEach(["Compare the options","Show an example","Summarize the decision"],id:\.self){name in button(name,"tertiary"){feedback="Follow-up selected: \(name)"}}
        case 41:
            title("Conversations")
            ForEach(Array(entries.enumerated()),id:\.offset){i,name in row(name,subtitle:name.hasPrefix("Remote") ? "Online · remote" : name.hasPrefix("Shared") ? "3 members" : i == 0 ? "Running" : "Updated recently",symbol:name.hasPrefix("Conversation") ? "bubble.left" : name.hasPrefix("Project") ? "folder" : "person.crop.circle",selected:active == i){active=i}}
            input("Rename selected",text:$text,placeholder:entries.isEmpty ? "No selected item" : entries[min(active,entries.count-1)])
            HStack{button("Rename"){if !text.isEmpty && !entries.isEmpty {entries[min(active,entries.count-1)]=text;text=""}};button("New chat","primary"){entries.append("New conversation");active=entries.count-1}}
            caption("Agent, remote, shared and project row variants share this geometry and selection contract.")
        case 42:
            Picker("Sidebar lens",selection:$tab){Text("Agents").tag("Agents");Text("Projects").tag("Projects")}.pickerStyle(.segmented).catalogPreviewTarget([t.assignment("text"),spec.key + ".foreground"], "Agents / Projects segment labels")
            title(tab)
            row("Pinned",subtitle:"3 items",symbol:"pin"){expanded.toggle()}
            if expanded {row("Research",symbol:"folder"){feedback="Research selected"}}
            divider();row("Settings",symbol:"gearshape"){feedback="Settings selected"};caption("Panel chrome specimen; full navigation hierarchy remains a Figma decision.")
        case 43:
            ScrollView(.horizontal) {
                HStack(spacing:t.number("gap")) {
                    ForEach(Array(entries.enumerated()),id:\.offset){i,name in
                        HStack(spacing:0) {
                            CatalogLibraryChip(theme:t.scoped("chip"),title:name,selected:active == i){active=i}
                            CatalogTokenButton(store:store,variant:"tertiary",mode:mode,label:"Close \(name)",scale:scale,symbol:"xmark",iconOnly:true){entries.remove(at:i);active=CatalogselectionAfterClosingTab(active:active,closed:i,remaining:entries.count)}.accessibilityLabel("Close \(name), tab \(i+1), \(mode) preview")
                        }
                    }
                }.padding(.vertical,4)
            }
            caption(entries.isEmpty ? "No open tabs" : "Selected: \(entries[min(active,entries.count-1)])")
            HStack{button("New tab",symbol:"plus"){entries.append("New conversation");active=entries.count-1};button("Pin","tertiary",symbol:"pin"){feedback="Selected tab pinned"}}
        case 44:
            input("Find in conversation",text:$text,placeholder:"Search message text")
            let count = text.isEmpty ? 0 : ["Design tokens","Review tokens","Component library"].filter{$0.localizedCaseInsensitiveContains(text)}.count
            caption("\(count) matches · \(count == 0 ? 0 : active%count+1) selected")
            HStack{button("Previous",symbol:"chevron.up"){active=max(0,active-1)};button("Next",symbol:"chevron.down"){active+=1};button("Clear","tertiary"){text="";active=0}}
            progress(Double(min(3,active+1))/3)
        case 45:
            badge(recording ? "Listening" : state.capitalized,symbol:"mic")
            HStack(alignment:.center,spacing:4){ForEach(0..<15){i in Capsule().fill(t.color("accent")).frame(width:4,height:recording ? CGFloat(10+(i*13)%36) : 8)}}.frame(height:50).accessibilityLabel(recording ? "Sample listening waveform" : "Voice idle")
            t.text(text.isEmpty ? "Your transcript will appear here." : text)
            HStack{button(recording ? "Stop" : "Listen","primary",symbol:recording ? "stop" : "mic"){recording.toggle();if !recording {text="Please summarize the conversation."}};button("Cancel","tertiary"){recording=false;text=""}}
            caption("Voice simulation · microphone access is not requested.")
        default:EmptyView()
        }
    }
    @ViewBuilder var featureContent:some View {
        switch spec.id {
        case 46:
            title("Workspace preferences")
            input("Workspace name",text:$text,placeholder:"Personal")
            CatalogLibraryToggle(theme:t.scoped("switch"),title:"Save conversation history",isOn:$enabled)
            Picker("Default model",selection:$selected){Text("Local").tag("Local");Text("Cloud").tag("Cloud")}
            t.text("Response length","label");CatalogLibrarySlider(theme:t.scoped("progress"),title:"Response length",value:$number);divider()
            HStack{button("Save changes","primary"){saved=text;feedback="Preview preferences saved"};button("Cancel","tertiary"){text=saved;feedback="Restored last saved preview"}}
        case 47:
            title("Provider connection")
            input("Provider name",text:$text,placeholder:"Example provider")
            input("API key",text:$secondaryText,placeholder:"Sample key only",secure:true)
            badge(checked ? "Connected" : state == "error" ? "Connection failed" : "Disconnected",checked ? "success" : "error")
            button(checked ? "Disconnect" : "Test connection","primary"){checked.toggle();feedback="Connection simulated locally"}
            divider();t.text("Model download","label");progress(number/100)
            HStack{button("Download sample"){number=min(100,number+20)};button("Cancel download","tertiary"){number=0}}
        case 48:
            title("Catalog")
            ForEach(["Research agent","Summarize skill","File tools plugin"],id:\.self){name in row(name,subtitle:selected == name ? "Enabled" : "Available",symbol:name.contains("agent") ? "person.crop.circle" : "puzzlepiece.extension",selected:selected == name){selected=name}}
            button("Enable selected","primary"){feedback="\(selected) enabled in preview"}
            CatalogLibraryToggle(theme:t.scoped("checkbox"),title:"Allow this capability",isOn:$enabled,checkbox:true)
        case 49:
            title("Workspace provisioning")
            row("Personal workspace",subtitle:"Local · ready",symbol:"folder"){selected="Personal"}
            progress(number/100)
            ForEach(["Prepare workspace","Start environment","Run setup tasks"],id:\.self){name in HStack{Image(systemName:number >= 100 ? "checkmark.circle" : "circle").foregroundStyle(t.color("success"));t.text(name)}}
            button("Advance provisioning","primary"){number=min(100,number+25);feedback=number >= 100 ? "Environment ready" : "Provisioning advanced"}
            caption("CPU 12% · Memory 2.4 GB · Storage 8 GB")
        case 50:
            title("Scheduled task")
            input("Task name",text:$text,placeholder:"Weekly research summary")
            DatePicker("Next run",selection:$date,displayedComponents:[.date,.hourAndMinute])
            CatalogLibraryToggle(theme:t.scoped("switch"),title:"Enabled",isOn:$enabled)
            Picker("Trigger",selection:$selected){Text("Time").tag("Time");Text("File changed").tag("File changed");Text("Manual").tag("Manual")}
            caption("Next run: \(date.formatted(date:.abbreviated,time:.shortened))")
            button("Save schedule","primary"){feedback="Schedule saved in preview; no real task was scheduled"}
        case 51:
            title("Usage and credits")
            badge("120 credits available",symbol:"creditcard")
            progress(number/100);caption("\(Int(number))% of sample usage allowance")
            input("Redeem code",text:$text,placeholder:"Enter a sample code")
            HStack{button("Redeem","primary"){feedback=text.isEmpty ? "Enter a code to continue" : "Sample code accepted"};button("Top up"){sheet=true}}
            caption("No purchases, billing calls or transactions occur in this preview.")
        case 52:
            title("Privacy review")
            t.text("Email: [REDACTED]\nProject: Research workspace")
            CatalogLibraryToggle(theme:t.scoped("switch"),title:"Redact personal information",isOn:$enabled)
            DisclosureGroup("Review detected values",isExpanded:$expanded){t.text("Sample email address · redacted","code");caption("Synthetic review content only")}
            input("Custom rule",text:$text,placeholder:"Rule name")
            HStack{button("Approve","primary"){feedback="Privacy preview approved"};button("Edit rule","tertiary"){feedback="Rule editor selected"}}
            divider();badge("Identity recovery",symbol:"key");t.text("sample • sample • sample • sample","code")
            caption("No real secrets or recovery credentials are displayed.")
        case 53:
            title("Knowledge and memory")
            ForEach(["Design principles","Research notes","Project context"],id:\.self){name in row(name,subtitle:"Updated today",symbol:"doc.text",selected:selected == name){selected=name;expanded=true}}
            if expanded {t.text("\(selected): a reusable knowledge record with a title, summary, provenance and actions.");button("View history","tertiary"){feedback="History: created → revised → reviewed"}}
            divider();HStack{t.text("Key","label");Spacer();t.text("Value","label")};HStack{t.text("Preference");Spacer();t.text("Local")}
        case 54:
            title("Image generation")
            editor("Describe an image")
            Picker("Size",selection:$selected){Text("Square").tag("Square");Text("Landscape").tag("Landscape");Text("Portrait").tag("Portrait")}
            button("Generate sample","primary"){checked=true;feedback="Local placeholder result generated"}
            if checked {RoundedRectangle(cornerRadius:t.scoped("image").number("radius")).fill(t.scoped("image").color("selected")).frame(height:140).overlay(Image(systemName:"photo.artframe").font(.largeTitle).foregroundStyle(t.color("accent"))).catalogPreviewTarget(["radius","selected"].map { t.scoped("image").assignment($0) }, "Generated image").accessibilityLabel("Generated image placeholder");button("Preview result","tertiary"){sheet=true}}
            caption("No image-generation service is called.")
        default:EmptyView()
        }
    }
    @ViewBuilder var composer:some View {
        editor("Message")
        if !attachments.isEmpty {attachmentTray}
        HStack {
            button("Attach","tertiary",symbol:"paperclip"){attachments.append("notes-\(attachments.count+1).md")}
            Picker("Model",selection:$selected){Text("Local").tag("Local");Text("Cloud").tag("Cloud")}.labelsHidden().accessibilityLabel("Composer model")
        }
        HStack {
            if state == "sending" || recording {button("Stop","secondary",symbol:"stop.fill"){recording=false;feedback="Stopped in preview"}}
            else {button(state == "queued" ? "Queue message" : "Send","primary",symbol:"arrow.up"){
                if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {feedback="Enter a message before sending";focus=true}
                else {saved=text;feedback=state == "queued" ? "Message queued in preview" : "Message sent in preview";text=""}
            }}
            button("Voice","tertiary",symbol:"mic"){recording.toggle();feedback=recording ? "Listening simulation" : "Voice stopped"}
        }
        if !saved.isEmpty {caption("Last message: \(saved)")}
    }
    @ViewBuilder var attachmentTray:some View {
        let t = self.t.scoped("chip")
        ForEach(Array(attachments.enumerated()),id:\.offset){i,name in
            HStack(spacing:t.number("gap")) {
                Image(systemName:name.hasSuffix("png") ? "photo" : "doc.text").foregroundStyle(t.color("accent"))
                t.text(name,spec.id == 24 ? "text" : "caption").lineLimit(2)
                Spacer(minLength:0)
                CatalogTokenButton(store:store,variant:"tertiary",mode:mode,label:"Remove \(name)",scale:scale,symbol:"xmark",iconOnly:true){attachments.remove(at:i)}
            }.padding(t.number("gap")).background(t.color("selected"),in:RoundedRectangle(cornerRadius:t.number("radius"))).catalogPreviewTarget(["selected","radius","gap"].map { t.assignment($0) }, "Attachment chip")
            if name.hasSuffix("png") {
                Button{selected=name;sheet=true} label:{RoundedRectangle(cornerRadius:self.t.scoped("image").number("radius")).fill(self.t.scoped("image").color("selected")).frame(height:70).overlay(Image(systemName:"photo").font(.title).foregroundStyle(t.color("accent")))}.buttonStyle(.plain).catalogPreviewTarget(["radius","selected"].map { self.t.scoped("image").assignment($0) }, "Attachment thumbnail").accessibilityLabel("Preview \(name)")
            }
        }
    }
    func pickerSurface(_ options:[String])->some View {
        VStack(alignment:.leading,spacing:t.number("gap")) {
            input("Search options",text:$text,placeholder:"Search")
            ForEach(options.filter{text.isEmpty || $0.localizedCaseInsensitiveContains(text)},id:\.self){name in row(name,symbol:"folder",selected:selected == name){selected=name}}
            if !text.isEmpty && !options.contains(where:{$0.localizedCaseInsensitiveContains(text)}) {caption("No matching options.")}
            caption("Selected: \(selected)")
        }
    }
    func codeBlock(_ source:String)->some View {
        let t = self.t.scoped("codeBlock")
        return 
        VStack(alignment:.leading,spacing:t.number("gap")) {
            HStack{caption("Code");Spacer();button("Copy","tertiary",symbol:"doc.on.doc"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(source,forType:.string);feedback="Code copied"}}
            ScrollView(.horizontal){t.text(source,"code").textSelection(.enabled).fixedSize(horizontal:true,vertical:true)}
        }
    }
    @ViewBuilder var assistantActions:some View {
        VStack(alignment:.leading,spacing:t.number("gap")) {
            HStack{button("Copy","tertiary",symbol:"doc.on.doc"){NSPasteboard.general.clearContents();NSPasteboard.general.setString("Sample assistant response",forType:.string);feedback="Response copied"};button("Retry","tertiary",symbol:"arrow.clockwise"){feedback="Response restarted"}}
            HStack{button("Helpful","tertiary",symbol:"hand.thumbsup"){feedback="Feedback recorded: helpful"};button("Not helpful","tertiary",symbol:"hand.thumbsdown"){feedback="Feedback recorded: not helpful"}}
        }
    }
    @ViewBuilder var sheetBody:some View {
        VStack(alignment:.leading,spacing:16) {
            if [21,24,28].contains(spec.id) {
                title("Attachment preview")
                caption(selected)
                Image(systemName:"photo").resizable().scaledToFit().frame(height:160).foregroundStyle(t.color("accent")).accessibilityLabel("Sample image preview")
                button("Close","tertiary"){sheet=false}.keyboardShortcut(.cancelAction)
            } else {
                title(spec.id == 37 ? "Research summary" : spec.id == 51 ? "Sample credit top-up" : "Preview dialog")
                t.text(spec.id == 37 ? "A generated document preview with local sample content." : "Use the same input and action components in a contained surface.")
                input("Name",text:$secondaryText,placeholder:"Sample value")
                HStack{button("Cancel","tertiary"){sheet=false}.keyboardShortcut(.cancelAction);Spacer();button("Confirm","primary"){feedback="Dialog confirmed in preview";sheet=false}.keyboardShortcut(.defaultAction)}
            }
        }.modifier(CatalogLibrarySurface(theme:t))
    }

}

struct CatalogLibraryToggle:View {
    let theme:CatalogLibraryTheme;let title:String
    @Binding var isOn:Bool
    var checkbox=false
    @FocusState private var focused:Bool
    var body:some View {
        Button{isOn.toggle()} label:{
            HStack(spacing:theme.number("gap")) {
                if checkbox {
                    RoundedRectangle(cornerRadius:min(6,theme.number("radius"))).fill(theme.color(isOn ? "onBackground" : "offBackground"))
                        .frame(width:theme.number("indicatorSize"),height:theme.number("indicatorSize")).overlay(Image(systemName:isOn ? "checkmark" : "").foregroundStyle(theme.color("onForeground")))
                        .catalogPreviewTarget(["indicatorSize",isOn ? "onBackground" : "offBackground","onForeground","radius","border","borderWidth"].map { theme.assignment($0) }, "Checkbox indicator")
                        .overlay(RoundedRectangle(cornerRadius:min(6,theme.number("radius"))).stroke(theme.color("border"),lineWidth:theme.number("borderWidth")))
                } else {
                    Capsule().fill(theme.color(isOn ? "onBackground" : "offBackground")).frame(width:max(theme.number("switchWidth"),theme.number("switchHeight")*1.6),height:theme.number("switchHeight"))
                        .overlay(alignment:isOn ? .trailing : .leading){Circle().fill(theme.color("onForeground")).frame(width:theme.number("thumbSize"),height:theme.number("thumbSize")).catalogPreviewTarget([theme.assignment("thumbSize"),theme.assignment("onForeground")], "Switch thumb").padding(3)}
                        .catalogPreviewTarget(["switchWidth","switchHeight",isOn ? "onBackground" : "offBackground"].map { theme.assignment($0) }, "Switch track")
                }
                theme.text(title,"label")
            }.padding(3).overlay(RoundedRectangle(cornerRadius:theme.number("radius")).stroke(focused ? theme.color("accent") : .clear,lineWidth:2))
        }.buttonStyle(.plain).focusable(theme.state != "disabled").focusEffectDisabled().focused($focused)
            .onKeyPress(.space){guard theme.state != "disabled" else{return .ignored};isOn.toggle();return .handled}
            .accessibilityLabel(title).accessibilityValue(isOn ? "On" : "Off")
    }
}
struct CatalogLibrarySlider:View {
    let theme:CatalogLibraryTheme;let title:String
    @Binding var value:Double
    @FocusState private var focused:Bool
    var body:some View {
        GeometryReader{g in
            ZStack(alignment:.leading) {
                Capsule().fill(theme.color("selected")).frame(height:theme.number("trackHeight")).catalogPreviewTarget([theme.assignment("selected"),theme.assignment("trackHeight")], "Slider track")
                Capsule().fill(theme.color("accent")).frame(width:max(0,g.size.width*value/100),height:theme.number("trackHeight")).catalogPreviewTarget([theme.assignment("accent"),theme.assignment("trackHeight")], "Slider filled track")
                Circle().fill(theme.color("foreground")).frame(width:theme.number("thumbSize"),height:theme.number("thumbSize")).offset(x:max(0,(g.size.width-theme.number("thumbSize"))*value/100)).catalogPreviewTarget([theme.assignment("foreground"),theme.assignment("thumbSize")], "Slider thumb")
            }.frame(height:30).contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged{event in guard theme.state != "disabled" else{return};value=max(0,min(100,(event.location.x/g.size.width)*100)).rounded()})
        }.frame(height:30).overlay(RoundedRectangle(cornerRadius:4).stroke(focused ? theme.color("accent") : .clear,lineWidth:2))
            .focusable(theme.state != "disabled").focusEffectDisabled().focused($focused)
            .onKeyPress(.leftArrow){guard theme.state != "disabled" else{return .ignored};value=max(0,value-1);return .handled}.onKeyPress(.rightArrow){guard theme.state != "disabled" else{return .ignored};value=min(100,value+1);return .handled}
            .accessibilityElement().accessibilityLabel(title).accessibilityValue("\(Int(value))")
            .accessibilityAdjustableAction{direction in guard theme.state != "disabled" else{return};switch direction {case .increment:value=min(100,value+1);case .decrement:value=max(0,value-1);@unknown default:break}}
    }
}

struct CatalogLibraryChip:View {
    let theme:CatalogLibraryTheme;let title:String;let selected:Bool;let action:()->Void
    @State private var hovered=false
    @FocusState private var focused:Bool
    var body:some View {
        Button(action:action) {
            HStack(spacing:theme.number("gap")){Image(systemName:"slider.horizontal.3");theme.text(title,"label");if selected {Image(systemName:"checkmark")}}
                .padding(.horizontal,theme.number("padding")).padding(.vertical,theme.number("gap"))
                .frame(minHeight: theme.spec.id == 23 ? theme.number("height") : 0)
                .background(theme.color(selected ? "selected" : hovered ? "hover" : "background"),in:RoundedRectangle(cornerRadius: theme.spec.id == 23 ? theme.number("radius") : .infinity))
                .overlay(RoundedRectangle(cornerRadius: theme.spec.id == 23 ? theme.number("radius") : .infinity).stroke(theme.color(focused ? "accent" : "border"),lineWidth:focused ? 2 : theme.number("borderWidth")))
        }.catalogPreviewTarget(["padding","gap","height","radius","borderWidth",focused ? "accent" : "border",selected ? "selected" : hovered ? "hover" : "background"].map { theme.assignment($0) }, "Chip “" + title + "”").buttonStyle(.plain).onHover{hovered=$0}.focusable(theme.state != "disabled").focusEffectDisabled().focused($focused)
            .onKeyPress(.space){guard theme.state != "disabled" else{return .ignored};action();return .handled}.accessibilityLabel(title).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

#endif
