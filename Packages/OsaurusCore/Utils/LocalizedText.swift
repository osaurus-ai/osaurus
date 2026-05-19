import SwiftUI

extension Text {
    /// Localized label from the OsaurusCore string catalog (`bundle: .module`).
    init(localized key: LocalizedStringKey, comment: StaticString? = nil) {
        self.init(key, bundle: .module, comment: comment)
    }
}

extension View {
    /// Tooltip from the OsaurusCore string catalog (`bundle: .module`).
    func localizedHelp(_ key: LocalizedStringKey) -> some View {
        help(Text(localized: key))
    }
}
