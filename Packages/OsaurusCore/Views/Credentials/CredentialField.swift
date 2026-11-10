//
//  CredentialField.swift
//  osaurus
//
//  The value field every consumer editor (plugins, channels) uses for a
//  key saved in Keys. The saved value is never loaded into the field:
//  blank keeps it, and revealing it goes through the Keys page.
//

import SwiftUI

struct CredentialField: View {
    @Environment(\.theme) private var theme

    /// The Keys entry the value is saved under.
    let key: String
    let isSet: Bool
    @Binding var value: String
    var placeholder: String = ""
    var isInvalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsTextField(
                placeholder: isSet ? L("Unchanged") : placeholder,
                text: $value,
                monospaced: true,
                isSecure: true,
                revealable: true,
                isInvalid: isInvalid
            )
            Text(Self.hint(key: key, isSet: isSet))
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func hint(key: String, isSet: Bool) -> String {
        isSet
            ? L("Managed in Vault → \(key). Leave blank to keep it.")
            : L("Not set yet. Saved in Vault as \(key).")
    }
}
