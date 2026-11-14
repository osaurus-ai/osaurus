#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

extension CatalogDesignStore {
    var scalarPrimitives: [String: [String: Any]] { document["scalarPrimitives"] as? [String: [String: Any]] ?? [:] }
    func updateScalarBinding(_ path: String, mode: String, value: Any) {
        let bindings = document["valueAliases"] as? [String: [String: String]] ?? [:]
        guard let name = bindings[path]?[mode] else { return }
        var values = scalarPrimitives; values[name]?[mode] = value; document["scalarPrimitives"] = values
    }
    func editScalar(_ name: String, mode: String, value: Any) {
        change { var values = scalarPrimitives; values[name]?[mode] = value; document["scalarPrimitives"] = values }
    }
    var primitives: [String: [String: String]] { document["primitives"] as? [String: [String: String]] ?? [:] }
    var colorAliases: [String: [String: String]] { document["colorAliases"] as? [String: [String: String]] ?? [:] }
    var primitiveNames: [String] { primitives.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    func primitiveHex(_ name: String, _ mode: String) -> String { primitives[name]?[mode] ?? "#00000000" }
    func assignPrimitive(_ path: String, mode: String, name: String) {
        change { var aliases = colorAliases; aliases[path]?[mode] = name; document["colorAliases"] = aliases }
    }
    func editPrimitive(_ name: String, mode: String, hex: String) {
        change { var values = primitives; values[name]?[mode] = hex; document["primitives"] = values }
    }
}

struct CatalogPrimitiveSwatch: View {
    let hex: String
    var body: some View {
        ZStack {
            Color.white
            Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 28,y: 0)); p.addLine(to: CGPoint(x: 0,y: 28)); p.closeSubpath() }.fill(Color.gray)
            Color(nsColor: CatalognsColor(hex))
        }.frame(width:28,height:28).clipShape(RoundedRectangle(cornerRadius:4))
            .overlay(RoundedRectangle(cornerRadius:4).stroke(.secondary,lineWidth:0.5)).accessibilityHidden(true)
    }
}
struct CatalogPrimitiveAssignment: View {
    @ObservedObject var store: CatalogDesignStore
    let path: String
    let mode: String
    var selected: String { store.colorAliases[path]?[mode] ?? "" }
    var resolvedHex: String { DesignWorkingStore.shared.document.colorValue(path, mode: mode)?.designString ?? store.primitiveHex(selected,mode) }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Picker("Primitive",selection:Binding(get:{selected},set:{store.assignPrimitive(path,mode:mode,name:$0)})) {
                if selected.hasPrefix("@") { Text("Semantic: " + String(selected.dropFirst())).tag(selected) }
                ForEach(store.primitiveNames,id: \.self) { name in Text(name).tag(name) }
            }.accessibilityLabel("\(path) \(mode) primitive")
            HStack(spacing:8) {
                CatalogPrimitiveSwatch(hex:resolvedHex)
                Text(resolvedHex).font(.system(.callout,design:.monospaced)).textSelection(.enabled)
                Text("Resolved").font(.caption).foregroundStyle(.secondary)
            }.accessibilityElement(children:.combine).accessibilityLabel("Resolved \(path) \(mode): \(resolvedHex)")
        }
    }
}
struct CatalogPrimitivesView: View {
    @ObservedObject var store: CatalogDesignStore
    @State private var query = ""
    @State private var selection: String? = "neutral/0"
    var filtered: [String] { (store.primitiveNames + store.scalarPrimitives.keys.sorted()).filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        HSplitView {
            VStack(alignment:.leading,spacing:12) {
                HStack { Text("Primitives").font(.title2.weight(.semibold)); Spacer(); Text("\(filtered.count) primitives").foregroundStyle(.secondary) }
                Text("Shared color, typography and geometry values. Light and Dark are independent.").font(.callout).foregroundStyle(.secondary)
                TextField("Search primitives",text:$query).textFieldStyle(.roundedBorder).accessibilityLabel("Search primitives")
                if filtered.isEmpty {
                    Text("No matching primitives").frame(maxWidth:.infinity,maxHeight:.infinity)
                    Button("Clear search") {query = ""}
                } else {
                    List(selection:$selection) {
                        ForEach(filtered,id: \.self) { name in
                            VStack(alignment:.leading,spacing:8) {
                                Text(name).font(.system(.body,design:.monospaced)).fixedSize(horizontal:false,vertical:true)
                                HStack(spacing:16) {
                                    ForEach(["light","dark"],id: \.self) { mode in
                                        HStack { if store.primitives[name] != nil { CatalogPrimitiveSwatch(hex:store.primitiveHex(name,mode)) }; VStack(alignment:.leading) {Text(mode.capitalized).font(.caption).foregroundStyle(.secondary);Text(store.primitives[name] != nil ? store.primitiveHex(name,mode) : String(describing: store.scalarPrimitives[name]?[mode] ?? "")).font(.system(.caption,design:.monospaced))} }.frame(maxWidth:.infinity,alignment:.leading)
                                    }
                                }
                            }.padding(.vertical,6).tag(name)
                        }
                    }.listStyle(.inset)
                }
            }.padding(20).frame(minWidth:360,idealWidth:470)
            if let name = selection, store.primitives[name] != nil {
                CatalogPrimitiveDetail(store:store,name:name).id(name).frame(minWidth:490,idealWidth:650)
            } else if let name = selection, store.scalarPrimitives[name] != nil {
                CatalogScalarPrimitiveDetail(store: store, name: name).id(name).frame(minWidth:490,idealWidth:650)
            } else { Text("Select a primitive to edit it.").frame(minWidth:490,maxHeight:.infinity) }
        }
    }
}
struct CatalogPrimitiveDetail: View {
    @ObservedObject var store: CatalogDesignStore
    let name: String
    var uses: [String] { store.colorAliases.keys.filter { store.colorAliases[$0]?.values.contains(name) == true }.sorted() }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                Text(name).font(.system(.title3,design:.monospaced).weight(.semibold)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                Text(name.hasPrefix("saved/") ? "Saved experiment preserved during migration. It remains editable and can be reassigned from Tokens." : "Imported from the live Osaurus Figma variables. This edits your local working design; it does not change Figma.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Text("Changes update every semantic token using this primitive in the edited appearance. Autosave is on; Undo is available.").font(.callout).fixedSize(horizontal:false,vertical:true)
                HStack(alignment:.top,spacing:20) {
                    ForEach(["light","dark"],id: \.self) { mode in
                        VStack(alignment:.leading,spacing:12) {
                            Text(mode.capitalized).font(.headline)
                            ColorPicker("Color",selection:Binding(get:{Color(nsColor:CatalognsColor(store.primitiveHex(name,mode)))},set:{store.editPrimitive(name,mode:mode,hex:CataloghexColor($0))}),supportsOpacity:true).accessibilityLabel("Primitive \(name) \(mode) color")
                            CatalogTokenTextField(value:store.primitiveHex(name,mode),label:"Primitive \(name) \(mode) hex",isHex:true) {store.editPrimitive(name,mode:mode,hex:$0)}
                            Text("Hex: #RRGGBB or #RRGGBBAA").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }
                }
                Text("Used by \(uses.count) semantic tokens").font(.headline)
                if uses.isEmpty {Text("No semantic tokens currently use this primitive.").foregroundStyle(.secondary)}
                ForEach(uses,id: \.self) { path in
                    VStack(alignment:.leading,spacing:4) {
                        Text(path).font(.system(.callout,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        Text(["light","dark"].filter{store.colorAliases[path]?[$0] == name}.map{$0.capitalized}.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(24)
        }.background(Color(nsColor:.controlBackgroundColor))
    }
}
struct CatalogScalarPrimitiveDetail: View {
    @ObservedObject var store: CatalogDesignStore
    let name: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(name).font(.title3.monospaced())
                Text("Edits update every bound token in this appearance and save automatically.").foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 20) {
                    ForEach(["light", "dark"], id: \.self) { mode in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(mode.capitalized).font(.headline)
                            if let n = store.scalarPrimitives[name]?[mode] as? NSNumber {
                                CatalogTokenNumberField(value: n.doubleValue, label: "Primitive \(name) \(mode)", allowNegative: name.hasSuffix("tracking") || name.hasSuffix("/x") || name.hasSuffix("/y")) { store.editScalar(name, mode: mode, value: $0) }
                            } else {
                                CatalogTokenTextField(value: store.scalarPrimitives[name]?[mode] as? String ?? "", label: "Primitive \(name) \(mode)") { store.editScalar(name, mode: mode, value: $0) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(24)
        }
    }
}
#endif
