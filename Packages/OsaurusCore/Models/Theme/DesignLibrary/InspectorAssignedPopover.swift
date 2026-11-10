#if OSAURUS_DESIGN_SYSTEM
import SwiftUI

/// Reuses the app's existing anchored presenter. The original content and
/// binding stay in charge; no native popover frame masks the assigned corners.
struct InspectorAssignedPopover<Card: View>: ViewModifier {
    @Binding var isPresented: Bool
    let width: CGFloat
    let accessibilityLabel: String
    let card: Card
    @State private var measuredHeight: CGFloat = 0
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.anchoredCard(
            isPresented: $isPresented,
            size: CGSize(width: width, height: measuredHeight),
            shadowPadding: 16,
            accessibilityLabel: accessibilityLabel
        ) {
            ScrollView(.vertical) {
                card
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if abs(measuredHeight - height) > 0.5 { measuredHeight = max(1, height) }
                    }
            }
            .scrollIndicators(.hidden)
            .clipShape(RoundedRectangle(cornerRadius: theme.assignedMetric("component.library.16.radius", fallback: theme.radius.xlarge), style: .continuous))
        }
    }
}
#endif
