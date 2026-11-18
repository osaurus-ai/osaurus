#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

private struct InspectorVerificationWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 800
}

extension EnvironmentValues {
    /// Width supplied to the original native renderers by the verification gallery.
    var inspectorVerificationWidth: CGFloat {
        get { self[InspectorVerificationWidthKey.self] }
        set { self[InspectorVerificationWidthKey.self] = newValue }
    }
}
#endif
