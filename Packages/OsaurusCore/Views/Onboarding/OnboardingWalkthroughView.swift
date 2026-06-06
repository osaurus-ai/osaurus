//
//  OnboardingWalkthroughView.swift
//  osaurus
//
//  Onboarding step 5 — a 3-page tour rendered as an internal carousel.
//
//  Unlike the rest of the flow (which is a navigation stack), the
//  walkthrough is a free-form carousel. Pages can be advanced with the
//  Next button, swiped via mouse drag, or jumped to by clicking a page
//  dot. The global Back button always exits the walkthrough — it never
//  drills internally between pages. The global step indicator is hidden
//  on this step so the carousel's own indicator is the only one shown.
//

import SwiftUI

// MARK: - Walkthrough Page

enum WalkthroughPage: Int, CaseIterable, Identifiable {
    case loop = 0
    case personal = 1
    case privacy = 2

    var id: Int { rawValue }

    var illustrationAsset: String {
        switch self {
        case .loop: return "osaurus-tool"
        case .personal: return "osaurus-built"
        case .privacy: return "osaurus-data"
        }
    }

    var headline: LocalizedStringKey {
        switch self {
        case .loop: return "It does the work, not just the talking"
        case .personal: return "Made to feel like yours"
        case .privacy: return "Your data stays yours"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .loop:
            return
                "Ask for something real. It uses the web, your files, and your apps to finish the job, then double-checks before answering."
        case .personal:
            return
                "Set up a dino for each kind of work. It remembers your context, so you stop re-explaining yourself."
        case .privacy:
            return
                "Chats, files, and keys stay on your device. No servers, no account, no one reading over your shoulder."
        }
    }
}

// MARK: - State

@MainActor
final class WalkthroughState: ObservableObject {
    @Published var currentPage: WalkthroughPage = .loop

    var pages: [WalkthroughPage] { WalkthroughPage.allCases }
    var pageIndex: Int { pages.firstIndex(of: currentPage) ?? 0 }
    var isLastPage: Bool { pageIndex == pages.count - 1 }

    /// Move forward (positive) or backward (negative). Bounded to the
    /// available pages — drag/click overflow at the edges is a no-op.
    /// Direction is implicit in the index delta — the carousel filmstrip
    /// reads off the index to compute its offset, so direction never
    /// needs to be stored.
    func advance(by step: Int) {
        let next = pageIndex + step
        guard next >= 0, next < pages.count else { return }
        currentPage = pages[next]
    }

    /// Jump directly to a page (used by the clickable page dots).
    func jump(to page: WalkthroughPage) {
        guard page != currentPage else { return }
        currentPage = page
    }

    /// Walkthrough is a carousel, not a navigation stack — Back always exits.
    func handleBack(parentBack: () -> Void) {
        parentBack()
    }
}

// MARK: - Body

struct WalkthroughBody: View {
    @ObservedObject var state: WalkthroughState

    @Environment(\.theme) private var theme

    /// Drag offset accumulated during an in-progress swipe. Resets to 0
    /// when the gesture ends (either committed by `advance(by:)` or
    /// snapped back by the spring animation).
    @State private var dragOffset: CGFloat = 0

    /// Minimum horizontal travel (in points) before a drag commits to a
    /// page change. Smaller drags spring back to the current page.
    private let dragCommitThreshold: CGFloat = 60

    var body: some View {
        VStack(spacing: 18) {
            carousel
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            paginationControls
                .padding(.bottom, 4)
        }
    }

    /// Chevron arrows flanking the page-dot row. Mirror the swipe + click
    /// affordances already on the carousel so users with trackpads or
    /// keyboards have a third path to advance pages.
    private var paginationControls: some View {
        HStack(spacing: 14) {
            arrowButton(
                systemImage: "chevron.left",
                disabled: state.pageIndex == 0,
                action: { state.advance(by: -1) }
            )
            pageDots
            arrowButton(
                systemImage: "chevron.right",
                disabled: state.isLastPage,
                action: { state.advance(by: 1) }
            )
        }
    }

    private func arrowButton(
        systemImage: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(disabled ? theme.tertiaryText.opacity(0.4) : theme.secondaryText)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(theme.tertiaryBackground.opacity(disabled ? 0.0 : 0.5))
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            theme.primaryBorder.opacity(disabled ? 0.0 : 0.4),
                            lineWidth: 1
                        )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
        .animation(.easeOut(duration: 0.15), value: disabled)
    }

    // MARK: - Carousel (filmstrip)

    /// Filmstrip carousel: all pages live in a horizontal HStack,
    /// each sized to the carousel's exact width. The strip offsets to show
    /// the current page (`-index * width`). Direction is naturally encoded
    /// in the index delta — no captured-state ambiguity (the prior
    /// `.transition(pageTransition)` setup baked `state.direction` into
    /// each view's transition value at construction time, which produced
    /// asymmetric animations when the user reversed direction). Drag is an
    /// additive offset on top of the index-driven offset.
    private var carousel: some View {
        GeometryReader { geo in
            let pageWidth = geo.size.width
            HStack(spacing: 0) {
                ForEach(state.pages) { page in
                    pageHero(page)
                        .frame(width: pageWidth, height: geo.size.height)
                }
            }
            .frame(width: pageWidth, height: geo.size.height, alignment: .leading)
            .offset(x: -CGFloat(state.pageIndex) * pageWidth + dragOffset)
            .animation(
                .spring(response: 0.55, dampingFraction: 0.88),
                value: state.pageIndex
            )
        }
        // Clip horizontally so adjacent filmstrip pages never peek past the
        // page edge, but extend the clip upward so the hero glow bleeds into
        // the header the same way the static hero steps do. A plain
        // `.clipped()` sheared the glow flat at the top, overriding the chrome
        // shell's `BodyClipShape` top-overflow and making the tour look
        // inconsistent with Welcome.
        .clipShape(CarouselClipShape(topOverflow: OnboardingMetrics.bodyGlowOverflow))
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Soft-clamp at the edges so dragging past the first/last
                    // page feels rubbery rather than free.
                    let raw = value.translation.width
                    if (state.pageIndex == 0 && raw > 0)
                        || (state.isLastPage && raw < 0)
                    {
                        dragOffset = raw / 3
                    } else {
                        dragOffset = raw
                    }
                }
                .onEnded { value in
                    let predicted = value.predictedEndTranslation.width
                    let committed = abs(predicted) > dragCommitThreshold
                    let direction = predicted < 0 ? 1 : -1
                    if committed {
                        state.advance(by: direction)
                    }
                    withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
        )
    }

    @ViewBuilder
    private func pageHero(_ page: WalkthroughPage) -> some View {
        OnboardingHeroBody(
            illustrationAsset: page.illustrationAsset,
            headline: page.headline,
            subtitle: page.subtitle
        )
    }

    // MARK: - Page dots (clickable)

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(state.pages) { page in
                pageDot(for: page)
            }
        }
    }

    private func pageDot(for page: WalkthroughPage) -> some View {
        let isCurrent = page == state.currentPage
        return Button {
            state.jump(to: page)
        } label: {
            Capsule()
                .fill(isCurrent ? theme.accentColor : theme.primaryBorder.opacity(0.45))
                .frame(width: isCurrent ? 24 : 8, height: 8)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isCurrent ? Color.clear : theme.primaryBorder.opacity(0.25),
                            lineWidth: 1
                        )
                )
                .contentShape(Capsule().inset(by: -6))
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.currentPage)
        }
        .buttonStyle(.plain)
        .help(Text(page.headline, bundle: .module))
    }
}

// MARK: - Carousel Clip Shape

/// Clips the filmstrip tight on the horizontal edges (so neighboring pages
/// stay hidden during slides) while extending the clip upward by
/// `topOverflow`, letting the hero glow bleed into the header instead of
/// being sheared flat. Mirrors the chrome shell's `BodyClipShape` so the
/// tour's hero treatment matches the static hero steps.
private struct CarouselClipShape: Shape {
    var topOverflow: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(
            CGRect(
                x: rect.minX,
                y: rect.minY - topOverflow,
                width: rect.width,
                height: rect.height + topOverflow
            )
        )
    }
}

// MARK: - CTA

struct WalkthroughCTA: View {
    @ObservedObject var state: WalkthroughState
    /// Advance past the walkthrough to the final consent step. The flow no
    /// longer finishes here — the consent screen now owns the last CTA.
    let onContinue: () -> Void

    var body: some View {
        OnboardingBrandButton(
            title: state.isLastPage ? "Continue" : "Next",
            action: {
                if state.isLastPage {
                    onContinue()
                } else {
                    state.advance(by: 1)
                }
            }
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingWalkthroughView_Previews: PreviewProvider {
        static var previews: some View {
            let state = WalkthroughState()
            return VStack {
                WalkthroughBody(state: state).frame(height: 460)
                WalkthroughCTA(state: state, onContinue: {})
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 620)
        }
    }
#endif
