//
//  WhatsNewView.swift
//  osaurus
//
//  Horizontal carousel modal announcing updates for the current version
//

import SwiftUI

public struct WhatsNewModal: View {
    @Environment(\.theme) private var theme

    let release: WhatsNewRelease
    let onClose: () -> Void
    /// Invoked when a page's CTA button is tapped. Closing the modal is up
    /// to the caller — most actions navigate elsewhere (Settings, browser),
    /// so the host typically calls `onClose` after handling the deep link.
    let onAction: ((WhatsNewAction) -> Void)?

    @State private var currentIndex: Int = 0

    public init(
        release: WhatsNewRelease,
        onClose: @escaping () -> Void,
        onAction: ((WhatsNewAction) -> Void)? = nil
    ) {
        self.release = release
        self.onClose = onClose
        self.onAction = onAction
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Sliding visual (image / sparkle background) — edge-to-edge,
            // with the header (title + close button) overlaid on top.
            // Identity is the *visual*, not the page — two consecutive
            // sparkle pages share an identity, so SwiftUI doesn't run the
            // slide transition between them.
            ZStack {
                ContentAreaView(page: release.pages[currentIndex])
                    .id(visualIdentity(for: release.pages[currentIndex]))
                    .transition(slideTransition)
            }
            .frame(height: 260)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 16,
                    topTrailingRadius: 16
                )
            )
            .overlay(alignment: .top) { headerOverlay }

            pageDots
                .padding(.top, 14)

            // Text block updates in place with a soft rise-and-fade on each
            // page change so the swap never feels abrupt.
            textBlock(for: release.pages[currentIndex])
                .id(release.pages[currentIndex].id)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 8)),
                        removal: .opacity.combined(with: .offset(y: -6))
                    )
                )
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)

            footer
        }
        .frame(width: 560, height: 440)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Header (overlaid on content)

    private var headerOverlay: some View {
        HStack {
            Text("What's New in v\(release.version)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 22, height: 22)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    // MARK: - Text block (title + description)

    private func textBlock(for page: WhatsNewPage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(page.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(page.description)
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            arrowButton(systemName: "chevron.left", action: goBack, disabled: currentIndex == 0)
            Spacer()
            // Optional per-page CTA between the chevrons.
            if let label = release.pages[currentIndex].actionLabel,
                let action = release.pages[currentIndex].action
            {
                Button {
                    onAction?(action)
                } label: {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(
                            Capsule().fill(theme.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                Spacer()
            }
            arrowButton(
                systemName: isLastPage ? "checkmark" : "chevron.right",
                action: goNext,
                disabled: false,
                prominent: true
            )
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    private func arrowButton(
        systemName: String,
        action: @escaping () -> Void,
        disabled: Bool,
        prominent: Bool = false
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    prominent
                        ? Color.white
                        : (disabled ? theme.tertiaryText : theme.primaryText)
                )
                .frame(width: 34, height: 34)
                .background(
                    Circle().fill(
                        prominent
                            ? theme.accentColor
                            : theme.secondaryBackground
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .keyboardShortcut(
            systemName == "chevron.left" ? .leftArrow : .rightArrow,
            modifiers: []
        )
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< release.pages.count, id: \.self) { i in
                Circle()
                    .fill(
                        i == currentIndex
                            ? theme.accentColor
                            : theme.secondaryText.opacity(0.3)
                    )
                    .frame(width: 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var slideTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private var isLastPage: Bool { currentIndex >= release.pages.count - 1 }

    private func goBack() {
        guard currentIndex > 0 else { return }
        navigate(to: currentIndex - 1)
    }

    private func goNext() {
        if isLastPage {
            onClose()
        } else {
            navigate(to: currentIndex + 1)
        }
    }

    private func navigate(to newIndex: Int) {
        withAnimation(.easeInOut(duration: 0.28)) {
            currentIndex = newIndex
        }
    }

    /// Used as the content view's `.id` so two consecutive sparkle pages
    /// keep the same identity and don't trigger the slide transition.
    private func visualIdentity(for page: WhatsNewPage) -> String {
        page.imageURL?.absoluteString ?? "__sparkle__"
    }
}

// MARK: - Content area (image or sparkle)

private struct ContentAreaView: View {
    let page: WhatsNewPage

    var body: some View {
        Group {
            if let url = page.imageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty:
                        ZStack {
                            SparklingStarsBackground()
                            ProgressView()
                        }
                    case .failure:
                        SparklingStarsBackground()
                    @unknown default:
                        SparklingStarsBackground()
                    }
                }
            } else {
                SparklingStarsBackground()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
