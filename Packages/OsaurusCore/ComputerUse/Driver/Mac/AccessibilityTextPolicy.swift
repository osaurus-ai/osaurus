import Foundation

/// Shared privacy boundary for reading text through macOS Accessibility.
/// Computer Use and user-initiated selection capture must make the same
/// decision so a role cannot be readable through one path but denied in the
/// other.
enum AccessibilityTextPolicy {
    static let readableSelectionRoles: Set<String> = [
        "textfield",
        "textarea",
        "searchfield",
        "combobox",
        "statictext",
        "staticrtext",
        "webarea",
    ]

    static func normalizeRole(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("ax") {
            return String(lower.dropFirst(2))
        }
        return lower
    }

    static func isSecure(
        role: String?,
        subrole: String?,
        roleDescription: String? = nil
    ) -> Bool {
        [role, subrole, roleDescription]
            .compactMap { $0?.lowercased() }
            .contains { value in
                value.contains("secure") || value.contains("password")
            }
    }

    static func canReadSelection(
        role: String?,
        subrole: String?,
        roleDescription: String? = nil
    ) -> Bool {
        guard !isSecure(role: role, subrole: subrole, roleDescription: roleDescription),
            let role
        else { return false }
        return readableSelectionRoles.contains(normalizeRole(role))
    }
}
