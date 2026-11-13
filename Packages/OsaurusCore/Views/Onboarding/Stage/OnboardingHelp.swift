//
//  OnboardingHelp.swift
//  osaurus
//
//  The dino as a guide: a "Click me for help!" hint over its head, and a
//  click that has it talk through what the current step means, one comic
//  bubble at a time. The words live in `OnboardingHelp`, apart from the
//  views, so they can be read and tested without a window.
//

import SwiftUI

// MARK: - Explainers

enum OnboardingHelp {
    /// What the person is looking at when they ask.
    enum Topic: Equatable {
        case welcome
        /// The three ways Osaurus can run.
        case paths
        /// The recommended model on this Mac.
        case localModel
        /// Connecting an AI account or key.
        case ownAccount
    }

    /// The local model the step is offering, as the explainers describe it.
    struct Pick: Equatable {
        let name: String
        let downloadSize: String?
        let isDownloaded: Bool
        /// Why it was picked for this Mac; `nil` when the person picked it.
        let reason: String?
    }

    static func pages(_ topic: Topic, pick: Pick?) -> [String] {
        switch topic {
        case .welcome:
            return [
                L("Hi! Click me any time you want to know more. Osaurus gives you a team of AI helpers that chat, write, plan, and get things done on your Mac."),
                L("Your chats, files, and keys can stay right here on this Mac. There's no account to make."),
                L("The usage data switch is up to you. It sends anonymous counts, like which setup steps people finish. Never your chats, prompts, files, or keys."),
                L("Press Get started and I'll help you choose how Osaurus thinks."),
            ]
        case .paths:
            return [
                L("To think, Osaurus needs a model: the AI brain that reads your messages and writes the replies."),
                L("A model can run right here on your Mac, or on a computer in the cloud. You chat the same way either way."),
                localLine(pick),
                L("In the cloud you can start right away with nothing to download. Osaurus Cloud comes with free credit, or you can use an AI account you already pay for."),
                notSureLine(pick),
            ]
        case .localModel:
            var pages = [
                L("This model runs right here on your Mac, so nothing you type leaves it and it works offline.")
            ]
            if let pick {
                let reason = pick.reason ?? L("It stays on this Mac, so it works offline.")
                pages.append(L("I picked \(pick.name) for you. \(reason)"))
                pages.append(
                    pick.isDownloaded
                        ? L("It's ready now. Press Use this model to keep going.")
                        : L("Press Download and keep going. It finishes in the background."))
            }
            pages.append(L("Want a different one later? You can add more models any time in Settings."))
            return pages
        case .ownAccount:
            return [
                L("Already pay for an AI service like ChatGPT, Claude, Gemini, or Grok? Osaurus can use it instead of downloading a model."),
                L("Some let you sign in with your account. Others need an API key: a long secret code you copy from the provider's website."),
                L("Your key is stored in this Mac's Keychain, and your messages go to the provider you connect."),
            ]
        }
    }

    private static func localLine(_ pick: Pick?) -> String {
        guard let pick else { return L("On your Mac it's free, private, and works offline. You download it once.") }
        if pick.isDownloaded {
            return L("On your Mac it's free, private, and works offline. \(pick.name) is already downloaded.")
        }
        guard let size = pick.downloadSize else {
            return L("On your Mac it's free, private, and works offline. You download it once.")
        }
        return L("On your Mac it's free, private, and works offline. You download it once, about \(size).")
    }

    private static func notSureLine(_ pick: Pick?) -> String {
        guard let pick, let reason = pick.reason else {
            return L("Not sure? Pick the green one. You can switch any time in Settings.")
        }
        return L("Not sure? Pick the green one: \(pick.name). \(reason) You can switch any time in Settings.")
    }
}

// MARK: - Stage layer

/// The dino's help layer over the stage: the click target on the dino,
/// the hint above its head, and the explainer bubble.
struct OnboardingDinoHelp: View {
    @ObservedObject var stage: OnboardingStage
    /// The furthest right the explainer may reach before it would cover
    /// the chapter's own content.
    let maxRight: CGFloat
    /// Built on click, so the words match what is on screen right then.
    let pages: () -> [String]

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var feetY: CGFloat { OnboardingMetrics.windowHeight - OnboardingLayout.groundInset }
    /// Where the bubble's tail points: the center of the dino's head, which
    /// sits right of center while it faces right. The tail stops clear of
    /// the whole dino frame so neither bubble ever covers the dino.
    private var headX: CGFloat { stage.dinoX + stage.dinoSize * 0.16 }
    private var tailTipY: CGFloat { feetY - stage.dinoSize - theme.space.s8 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if stage.isHelping {
                explainer
                    .transition(bubbleTransition)
            } else if !stage.isWalking {
                hint
                    .transition(bubbleTransition)
            }

            clickTarget
        }
        .frame(width: OnboardingMetrics.windowWidth, height: OnboardingMetrics.windowHeight, alignment: .topLeading)
        .animation(OnboardingMotion.bouncy, value: stage.isHelping)
        .animation(theme.motion.standard, value: stage.isWalking)
    }

    private var bubbleTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity)
    }

    // MARK: Click target

    private var clickTarget: some View {
        let width = stage.dinoSize * 0.7
        let height = stage.dinoSize * 0.85
        return Color.clear
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onTapGesture { stage.toggleHelp(pages()) }
            .pointingHandCursor()
            .position(x: stage.dinoX, y: feetY - height / 2)
            .accessibilityElement()
            .accessibilityLabel(Text("Ask the dino for help", bundle: .module))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { stage.toggleHelp(pages()) }
    }

    // MARK: Hint

    private var hint: some View {
        Button {
            stage.toggleHelp(pages())
        } label: {
            HStack(spacing: theme.space.s6) {
                Image(systemName: "questionmark.circle.fill")
                    .glyphSize(.caption, weight: .bold)
                Text("Click me for help!", bundle: .module)
                    .font(OnboardingTypography.optionTitle)
            }
            .foregroundColor(OnboardingPalette.bubbleInk)
            .padding(.horizontal, theme.space.s12)
            .padding(.top, theme.space.s8)
            .padding(.bottom, theme.space.s8 + OnboardingLayout.bubbleTailHeight)
            .background {
                DinoBubbleShape(tailX: theme.space.s24, tailHeight: OnboardingLayout.bubbleTailHeight)
                    .fill(OnboardingPalette.bubbleFill)
                    .overlay(
                        DinoBubbleShape(tailX: theme.space.s24, tailHeight: OnboardingLayout.bubbleTailHeight)
                            .stroke(OnboardingPalette.bubbleInk, lineWidth: theme.stroke.default)
                    )
                    .themeElevation(theme.elevation.raised)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(OnboardingPressableButtonStyle())
        .pointingHandCursor()
        .offset(x: headX - theme.space.s24)
        .frame(width: OnboardingMetrics.windowWidth, height: tailTipY, alignment: .bottomLeading)
    }

    // MARK: Explainer

    /// Opens rightward from the dino's head, the tail a third of the way
    /// in, and slides left only as far as `maxRight` requires.
    private var bubbleLeft: CGFloat {
        let width = OnboardingLayout.helpBubbleWidth
        let preferred = headX - width / 3
        return max(OnboardingLayout.contentPadding, min(preferred, maxRight - width))
    }

    private var explainerTailX: CGFloat {
        let inset = theme.space.s24
        return min(max(headX - bubbleLeft, inset), OnboardingLayout.helpBubbleWidth - inset)
    }

    private var explainer: some View {
        let pages = stage.helpPages
        let page = min(stage.helpPage, max(pages.count - 1, 0))
        let isLast = page == pages.count - 1
        return VStack(alignment: .leading, spacing: theme.space.s12) {
            Text(pages.isEmpty ? "" : pages[page])
                .font(OnboardingTypography.subtitle)
                .foregroundColor(OnboardingPalette.bubbleInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, theme.space.s16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(page)
                .transition(.opacity)

            HStack(spacing: theme.space.s8) {
                Text("\(page + 1) of \(pages.count)", bundle: .module)
                    .font(OnboardingTypography.footnote)
                    .foregroundColor(OnboardingPalette.bubbleInk.opacity(0.55))
                Spacer(minLength: 0)
                if page > 0 {
                    DinoBubbleButton(title: "Back", prominent: false) { stage.previousHelpPage() }
                }
                DinoBubbleButton(title: isLast ? "Got it" : "Next", prominent: true) { stage.nextHelpPage() }
            }
        }
        .animation(theme.motion.quick, value: page)
        .padding(.horizontal, theme.space.s16)
        .padding(.top, theme.space.s16)
        .padding(.bottom, theme.space.s12 + OnboardingLayout.bubbleTailHeight)
        .frame(width: OnboardingLayout.helpBubbleWidth, alignment: .leading)
        .background {
            DinoBubbleShape(tailX: explainerTailX, tailHeight: OnboardingLayout.bubbleTailHeight)
                .fill(OnboardingPalette.bubbleFill)
                .overlay(
                    DinoBubbleShape(tailX: explainerTailX, tailHeight: OnboardingLayout.bubbleTailHeight)
                        .stroke(OnboardingPalette.bubbleInk, lineWidth: theme.stroke.default)
                )
                .themeElevation(theme.elevation.overlay)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                stage.closeHelp()
            } label: {
                Image(systemName: "xmark")
                    .glyphSize(.tiny, weight: .bold)
                    .foregroundColor(OnboardingPalette.bubbleInk.opacity(0.55))
                    .frame(width: theme.space.s24, height: theme.space.s24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(theme.space.s4)
            .accessibilityLabel(Text("Close", bundle: .module))
        }
        .offset(x: bubbleLeft)
        .frame(width: OnboardingMetrics.windowWidth, height: tailTipY, alignment: .bottomLeading)
        .accessibilityElement(children: .contain)
    }
}

/// A capsule button in the comic bubble's ink.
private struct DinoBubbleButton: View {
    @Environment(\.theme) private var theme
    let title: LocalizedStringKey
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title, bundle: .module)
                .font(OnboardingTypography.optionTitle)
                .foregroundColor(prominent ? OnboardingPalette.bubbleFill : OnboardingPalette.bubbleInk)
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s4)
                .background {
                    if prominent {
                        Capsule().fill(OnboardingPalette.bubbleInk)
                    } else {
                        Capsule().strokeBorder(OnboardingPalette.bubbleInk, lineWidth: theme.stroke.default)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(OnboardingPressableButtonStyle())
        .pointingHandCursor()
    }
}

// MARK: - Bubble shape

/// A comic speech bubble: a rounded body with a curled tail hanging off
/// its bottom edge, its point landing at `tailX`. One outline, so the
/// stroke never crosses where the tail meets the body.
struct DinoBubbleShape: Shape {
    var tailX: CGFloat
    var tailHeight: CGFloat
    var cornerRadius: CGFloat = OnboardingLayout.panelRadius

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tailHeight)
        let radius = min(cornerRadius, body.height / 2, body.width / 2)
        let halfRoot = tailHeight * 0.6
        let root = rect.minX + tailX + halfRoot * 0.6
        let x = min(max(root, body.minX + radius + halfRoot), body.maxX - radius - halfRoot)

        var path = Path()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.minY),
            tangent2End: CGPoint(x: body.maxX, y: body.minY + radius), radius: radius)
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.maxY),
            tangent2End: CGPoint(x: body.maxX - radius, y: body.maxY), radius: radius)
        // The tail bows down out of the bottom edge and curls to a point
        // just left of its root.
        path.addLine(to: CGPoint(x: x + halfRoot, y: body.maxY))
        path.addQuadCurve(
            to: CGPoint(x: x - halfRoot * 0.6, y: rect.maxY),
            control: CGPoint(x: x + halfRoot * 0.2, y: body.maxY + tailHeight * 0.7))
        path.addQuadCurve(
            to: CGPoint(x: x - halfRoot, y: body.maxY),
            control: CGPoint(x: x - halfRoot * 0.5, y: body.maxY + tailHeight * 0.45))
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.maxY),
            tangent2End: CGPoint(x: body.minX, y: body.maxY - radius), radius: radius)
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.minY),
            tangent2End: CGPoint(x: body.minX + radius, y: body.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}
