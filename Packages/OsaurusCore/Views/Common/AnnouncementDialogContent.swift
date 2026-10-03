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

    @Environment(\.theme) private var theme

    init(body: String, imageURL: URL?) {
        self.body_ = body
        self.imageURL = imageURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    case .empty:
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.tertiaryBackground.opacity(0.4))
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}
