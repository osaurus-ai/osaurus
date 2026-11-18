//
//  HelpAnnouncementCard.swift
//  osaurus
//
//  A live router announcement on the Help page: the same title, image,
//  body and buttons as its dialog, with no way to dismiss it. It stays
//  until the router stops serving it or it ends
//  (`AnnouncementsService.standingAnnouncements`).
//

import SwiftUI

struct HelpAnnouncementCard: View {
    let announcement: OsaurusRouterAnnouncement
    @Environment(\.theme) private var theme

    /// Primary first, as in the dialog.
    private var ctas: [OsaurusRouterAnnouncement.CTA] {
        let actionable = announcement.actionableCTAs
        return actionable.filter(\.isPrimary) + actionable.filter { !$0.isPrimary }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text(verbatim: announcement.title)
                .font(SettingsFont.cardTitle)
                .foregroundColor(theme.text.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            AnnouncementDialogContent(body: announcement.body, imageURL: announcement.resolvedImageURL)

            if !ctas.isEmpty {
                HStack(spacing: theme.settingsControlGap) {
                    ForEach(Array(ctas.enumerated()), id: \.offset) { _, cta in
                        SettingsButton(cta.isPrimary ? .primary : .secondary, cta.label, verbatim: true) {
                            AppDelegate.shared?.openAnnouncementCTA(cta)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsRowChrome()
    }
}
