import SwiftUI

extension Text {
    /// Localized label from the OsaurusCore string catalog (`bundle: .module`).
    init(localized key: LocalizedStringKey, comment: StaticString? = nil) {
        self.init(key, bundle: .module, comment: comment)
    }
}

extension Button where Label == Text {
    /// Localized text button from the OsaurusCore string catalog (`bundle: .module`).
    init(localized titleKey: LocalizedStringKey, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) {
            Text(localized: titleKey)
        }
    }
}

extension Label where Title == Text, Icon == Image {
    /// Localized label from the OsaurusCore string catalog (`bundle: .module`).
    init(localized titleKey: LocalizedStringKey, systemImage name: String) {
        self.init {
            Text(localized: titleKey)
        } icon: {
            Image(systemName: name)
        }
    }
}

extension View {
    /// Tooltip from the OsaurusCore string catalog (`bundle: .module`).
    func localizedHelp(_ key: LocalizedStringKey) -> some View {
        help(Text(localized: key))
    }
}
