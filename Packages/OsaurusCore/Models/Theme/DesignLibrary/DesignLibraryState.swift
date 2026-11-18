import SwiftUI
struct DesignInspectorStateKey: EnvironmentKey { static let defaultValue: ThemeActionInteraction? = nil }
struct DesignInspectorFocusKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var designInspectorState: ThemeActionInteraction? {
        get { self[DesignInspectorStateKey.self] }
        set { self[DesignInspectorStateKey.self] = newValue }
    }
    var designInspectorFocus: Bool {
        get { self[DesignInspectorFocusKey.self] }
        set { self[DesignInspectorFocusKey.self] = newValue }
    }
}
