import Foundation

/// Localized string helper for OsaurusCore SwiftPM package.
/// Looks up strings in the package's own bundle (Resources/Localizable.xcstrings)
/// instead of the main app bundle. This is required because OsaurusCore ships
/// its Localizable.xcstrings as a SwiftPM resource via `.process("Resources")`.
public func L(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String {
    String(localized: key, bundle: .module, comment: comment)
}
