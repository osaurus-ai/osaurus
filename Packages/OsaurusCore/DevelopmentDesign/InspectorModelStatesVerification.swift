#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

struct InspectorModelStatesVerification: View {
    @State private var callbacks = 0
    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            LocalModelStatusCell(
                item: sample(
                    "downloading",
                    status: .inProgress(progress: 0.42, detail: "42 MB / 100 MB", isPaused: false)
                ),
                perform: { _ in callbacks += 1 }
            )
            LocalModelStatusCell(item: sample("installed", status: .installed, isDefault: true), perform: { _ in })
            LocalModelStatusCell(
                item: sample("failed", status: .failed("Local display error; no download attempted.")),
                perform: { _ in }
            )
        }
    }

    private func sample(
        _ id: String,
        status: LocalModelCatalogItem.Status,
        isDefault: Bool = false
    ) -> LocalModelCatalogItem {
        var item = LocalModelCatalogItem(
            id: id, name: "Local \(id) model", subtitle: "Local display only", icon: "cube.box",
            isDefault: isDefault, status: status)
        item.onCancel = { callbacks += 1 }
        return item
    }
}
#endif
