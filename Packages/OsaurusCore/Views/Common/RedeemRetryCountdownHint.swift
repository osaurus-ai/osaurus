import SwiftUI

/// Live countdown shown under a redeem-code field while a 429 backoff blocks
/// resubmission. Explains why the Redeem button stays disabled even after the
/// user edits the code and the error text clears.
struct RedeemRetryCountdownHint: View {
    let deadline: Date

    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let remaining = Int(deadline.timeIntervalSince(timeline.date).rounded(.up))
            if remaining > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 9, weight: .semibold))
                    Text("You can try again in \(remaining)s.", bundle: .module)
                        .font(theme.font(size: 11))
                        .monospacedDigit()
                }
                .foregroundColor(theme.tertiaryText)
            }
        }
    }
}
