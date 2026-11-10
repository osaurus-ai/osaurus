//
//  AnnouncementDialogContent.swift
//  osaurus
//
//  Body of a router-served announcement dialog (see `AnnouncementsService`
//  and `AppDelegate.presentAnnouncementIfEligible`): an optional hosted
//  header image followed by the operator-authored Markdown body rendered
//  with the chat engine (`MarkdownDocument`). Slots into a
//  `ThemedAlertRequest.accessory` so the title header, button row and
//  dismissal chrome stay the standard alert ones.
//

import SwiftUI

struct AnnouncementDialogContent: View {
    let body_: String
    let imageURL: URL?

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled, authoritative: true) }

    init(body: String, imageURL: URL?) {
        self.body_ = body
        self.imageURL = imageURL
    }

    var body: some View {
        Group {

        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.announcementDialogContent.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", 14, theme))) {
            if let imageURL {
                // Loaded asynchronously; the dialog shows without it on
                // failure (the contract says never block on the image).
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
                    case .empty:
                        RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                            .fill(theme.surface.hover)
                            .frame(height: 120)
                            .overlay(ProgressView().controlSize(.small))
                    default:
                        EmptyView()
                    }
                }
            }

            // Operators keep bodies to a few short paragraphs; cap the
            // height anyway so a long one scrolls instead of growing the
            // dialog past the screen.
            ScrollView(.vertical, showsIndicators: true) {
                MarkdownDocument(text: body_)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }.catalogLayoutTarget("component.library.55.elements.layout.announcementDialogContent.body.verticalGap")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    
        }.environment(\.theme, theme)
}
}
