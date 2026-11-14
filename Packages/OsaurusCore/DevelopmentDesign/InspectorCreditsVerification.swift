#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// Mounts the wallet and account-detail renderers with local values.
/// The live pages' refresh, identity, billing and export actions are not mounted.
struct InspectorCreditsVerification: View {
    @Environment(\.theme) private var theme
    @State private var display = "Balances"
    @State private var state = "Active"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wallet & Credits · sample data")
            Picker("Credit display", selection: $display) {
                ForEach(["Balances", "Account details", "Recent activity"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu)
            if display != "Recent activity" {
                Picker("Local account state", selection: $state) {
                    ForEach(["Active", "Frozen", "Loading", "Error", "Disabled", "Missing identity"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
            }
            if display == "Balances" { CreditsView.inspectionBalances(state, theme: theme) }
            else if display == "Account details" { RouterAccountUsageCenterView.inspectionAccount(state, theme: theme) }
            else { CreditsView.inspectionActivityRows(theme: theme) }
        }
    }
}
#endif
