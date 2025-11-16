import SwiftUI

struct CircularIconButton: View {
    @Environment(\.theme) private var theme
    let systemName: String
    let help: String?
    let action: () -> Void

    init(systemName: String, help: String? = nil, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .foregroundColor(theme.primaryText)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(theme.buttonBackground)
                        .overlay(
                            Circle()
                                .stroke(theme.buttonBorder, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(PlainButtonStyle())
        .help(help ?? "")
    }
}
