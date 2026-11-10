#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI
struct CatalogEffectEditor: View {
    @ObservedObject var store: CatalogDesignStore
    let token: String
    let mode: String
    var recipe: [String: Any] { store.value(token, mode) as? [String: Any] ?? [:] }
    var layers: [[String: Any]] { recipe["layers"] as? [[String: Any]] ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if recipe["available"] as? Bool != true {
                Text("No Figma style for this appearance.").foregroundStyle(.secondary)
            } else {
                ForEach(layers.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Layer \(index + 1) · \(layers[index]["type"] as? String ?? "")").font(.headline)
                        CatalogPrimitiveAssignment(store: store, path: "\(token).layers.\(index).color", mode: mode)
                        ForEach(["x", "y", "blur", "spread"], id: \.self) { field in
                            HStack {
                                Text(field.capitalized)
                                CatalogTokenNumberField(value: layers[index][field] as? Double ?? 0, label: "\(token) \(mode) layer \(index + 1) \(field)", allowNegative: field != "blur") { number in
                                    var updated = layers; updated[index][field] = number
                                    store.setTokenProperty(token, mode: mode, value: updated, field: "layers")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif
