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

    private enum Metrics {
        static let width: CGFloat = 560
        static let height: CGFloat = 400
        static let heroHeight: CGFloat = 150
        static let cornerRadius: CGFloat = 16
    }

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
            // Compact hero: the page's glyph (or image) over an accent
            // gradient, with a version pill + close button overlaid. The
            // `visualIdentity` id drives the slide transition between pages.
            ZStack {
                ContentAreaView(page: release.pages[currentIndex])
                    .id(visualIdentity(for: release.pages[currentIndex]))
                    .transition(slideTransition)
            }
            .frame(height: Metrics.heroHeight)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
            .overlay(alignment: .top) { headerOverlay }

            // Content block — eyebrow + progress dots, then the title and
            // description, which now own most of the modal's height. The
            // text updates in place with a soft rise-and-fade on each page
            // change so the swap never feels abrupt.
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    Text(localized: "What's New")
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(theme.accentColor)
                    Spacer()
                    pageDots
                }

                textBlock(for: release.pages[currentIndex])
                    .id(release.pages[currentIndex].id)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity.combined(with: .offset(y: -6))
                        )
                    )
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 16)

            footer
        }
        .frame(width: Metrics.width, height: Metrics.height)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
    }

    // MARK: - Header (overlaid on content)

    private var headerOverlay: some View {
        HStack {
            Text(verbatim: "v\(release.version)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 22, height: 22)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .localizedHelp("Close")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    // MARK: - Text block (title + description)

    private func textBlock(for page: WhatsNewPage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Page copy is authored as English `String`s in `WhatsNewContent`.
            // Resolve them through the module catalog so translated releases
            // (e.g. 0.21.0) localize; keys missing from the catalog fall back
            // to the literal English string, so older notes are unaffected.
            Text(LocalizedStringKey(page.title), bundle: .module)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(LocalizedStringKey(page.description), bundle: .module)
                .font(.system(size: 14))
                .foregroundStyle(theme.secondaryText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            backButton
            Spacer(minLength: 12)
            actionCluster
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    /// Back lives on the far left as a subtle circular control and is
    /// disabled on the first page. The advance / CTA buttons cluster on
    /// the right so the primary action always sits in the same place.
    private var backButton: some View {
        Button(action: goBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(currentIndex == 0 ? theme.tertiaryText : theme.primaryText)
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.secondaryBackground))
        }
        .buttonStyle(.plain)
        .disabled(currentIndex == 0)
        .opacity(currentIndex == 0 ? 0.5 : 1)
        .keyboardShortcut(.leftArrow, modifiers: [])
    }

    @ViewBuilder
    private var actionCluster: some View {
        let page = release.pages[currentIndex]
        let advance = capsuleButton(
            label: Text(localized: isLastPage ? "Done" : "Next"),
            systemImage: isLastPage ? "checkmark" : "chevron.right",
            // The CTA, when present, is the action we want the user to
            // take, so it takes the prominent fill and advance falls back
            // to a secondary style.
            prominent: page.action == nil,
            action: goNext
        )
        .keyboardShortcut(.rightArrow, modifiers: [])

        if let label = page.actionLabel, let action = page.action {
            capsuleButton(
                label: Text(LocalizedStringKey(label), bundle: .module),
                systemImage: nil,
                prominent: true,
                action: {
                    onAction?(action)
                    // The CTA deep-links elsewhere (Settings, Credits, …).
                    // Keep the carousel open so the user can finish the
                    // remaining pages; only dismiss when this is the last one.
                    if isLastPage { onClose() }
                }
            )
            advance
        } else {
            advance
        }
    }

    private func capsuleButton(
        label: Text,
        systemImage: String?,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : theme.primaryText)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(capsuleBackground(prominent: prominent))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func capsuleBackground(prominent: Bool) -> some View {
        if prominent {
            Capsule().fill(theme.accentColor)
        } else {
            Capsule()
                .fill(theme.secondaryBackground)
                .overlay(Capsule().stroke(theme.primaryBorder.opacity(0.4), lineWidth: 1))
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< release.pages.count, id: \.self) { i in
                Capsule()
                    .fill(
                        i == currentIndex
                            ? theme.accentColor
                            : theme.secondaryText.opacity(0.25)
                    )
                    // The active page widens into a pill so progress reads at a
                    // glance even with several pages in the carousel.
                    .frame(width: i == currentIndex ? 16 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: currentIndex)
            }
        }
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

    /// Used as the content view's `.id` so the hero slides when the visual
    /// actually changes. Two consecutive pages that resolve to the same glyph
    /// (or image) keep the same identity and skip the slide transition.
    private func visualIdentity(for page: WhatsNewPage) -> String {
        page.imageURL?.absoluteString ?? "icon:\(page.systemImage ?? "sparkles")"
    }
}

// MARK: - Hero visual (image or glyph)

private struct ContentAreaView: View {
    let page: WhatsNewPage

    private var glyph: String { page.systemImage ?? "sparkles" }

    var body: some View {
        Group {
            if let url = page.imageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty:
                        ZStack {
                            WhatsNewHeroBackground(systemImage: glyph)
                            ProgressView()
                        }
                    default:
                        // `.failure` and any future phases fall back to the glyph.
                        WhatsNewHeroBackground(systemImage: glyph)
                    }
                }
            } else {
                WhatsNewHeroBackground(systemImage: glyph)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
