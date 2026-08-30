//
//  OnboardingMotion.swift
//  osaurus
//
//  Motion vocabulary for the redesigned onboarding flow: named springs,
//  the staggered-entrance modifier every step uses to cascade its content
//  in, the parallax step/substate push, and the shared pressable button
//  style. Deliberately restrained — entrances, exits, and modal
//  transitions only, no ambient/looping motion. Every effect degrades to
//  a plain crossfade (or nothing) under Reduce Motion.
//

import SwiftUI

// MARK: - Motion tokens

enum OnboardingMotion {
    /// Crisp micro-interaction spring (hover, press, checkbox) — settles
    /// fast with no visible wobble.
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.9)
    /// Playful spring with a single soft overshoot (avatar swap, selection
    /// pops, speech bubble, modals). Restrained on purpose: one bounce
    /// reads as character, two reads as cartoon.
    static let bouncy = Animation.spring(response: 0.35, dampingFraction: 0.72)
    /// Critically damped glide for step slides and entrances — decelerates
    /// smoothly into place and stops dead, no terminal wobble.
    static let gentle = Animation.spring(response: 0.45, dampingFraction: 1.0)
    /// Non-overshooting spring for scrims, layout reflows, and modal
    /// presentation — anything where overshoot would read as a pulse or
    /// jank rather than character.
    static let smooth = Animation.spring(response: 0.4, dampingFraction: 1.0)

    /// Delay between consecutive staggered-entrance indices. Tight enough
    /// that the cascade reads as one gesture, not items queueing up.
    static let stagger: Double = 0.04
    /// Vertical rise distance an entrance travels while fading in.
    static let entranceRise: CGFloat = 6
    /// Default delay before the first entrance index reveals — just enough
    /// for the step slide to get underway.
    static let entranceBaseDelay: Double = 0.05

    /// Horizontal travel of an incoming view during a push-fade.
    static let pushTravelIn: CGFloat = 64
    /// Horizontal travel of an outgoing view during a push-fade.
    static let pushTravelOut: CGFloat = 44

    /// Direction-aware push-fade for step and substate navigation, in the
    /// Setup Assistant idiom: the crossfade carries the story while a short
    /// directional drift (~64pt in, ~44pt out) supplies continuity — nothing
    /// races across the window. Each side carries its own timing: the
    /// outgoing view gets out of the way quickly while the incoming one
    /// glides to rest, so mid-transition there's a clean handoff instead of
    /// a double-exposure mush. Under Reduce Motion both sides simply
    /// crossfade.
    ///
    /// The removal side is a custom modifier transition rather than
    /// `.offset + .opacity` because the outgoing view now stays overlapped
    /// with the incoming one (it used to exit through the window edge) and
    /// SwiftUI still hit-tests views at opacity 0 — an invisible outgoing
    /// step was eating the first clicks after every navigation. The modifier
    /// disables hit testing the instant the removal begins.
    static func pushFade(
        direction: OnboardingDirection,
        reduceMotion: Bool
    ) -> AnyTransition {
        let inX = direction == .forward ? pushTravelIn : -pushTravelIn
        let outX = direction == .forward ? -pushTravelOut : pushTravelOut
        let insertion: AnyTransition =
            reduceMotion
            ? .opacity
            : .offset(x: inX).combined(with: .opacity).animation(gentle)
        return .asymmetric(
            insertion: insertion,
            removal: .modifier(
                active: PushOutModifier(progress: 0, travel: reduceMotion ? 0 : outX),
                identity: PushOutModifier(progress: 1, travel: reduceMotion ? 0 : outX)
            )
            .animation(.easeIn(duration: 0.2))
        )
    }

    /// Crossfade for window-root modal hosts (chooser, connect dialog) whose
    /// scrim covers the whole window. A plain `.opacity` transition left the
    /// invisible outgoing scrim hit-testable for the length of the dismissal
    /// spring — every click in that window was swallowed. The removal phase
    /// here cuts hit testing the instant dismissal starts; timing rides the
    /// presenting driver.
    static var modalFade: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .modifier(
                active: PushOutModifier(progress: 0, travel: 0),
                identity: PushOutModifier(progress: 1, travel: 0)
            )
        )
    }

}

/// Removal phase of `pushFade`: drifts `travel` points while fading out as
/// `progress` animates 1 → 0, with hit testing cut the moment the view is
/// no longer at identity so a departing (or lingering, invisible) step can
/// never swallow clicks meant for the one below it.
private struct PushOutModifier: ViewModifier {
    var progress: CGFloat
    let travel: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .offset(x: travel * (1 - progress))
            .opacity(Double(progress))
            .allowsHitTesting(progress >= 1)
    }
}

// MARK: - Staggered entrance

/// Whether staggered entrances are live in this subtree. The onboarding
/// root enables them only for the window's very first screen: content
/// materializing element-by-element makes sense while the window itself is
/// arriving, but on later step navigation the content must ride in with
/// the slide as one composed surface — fading into already-reserved gaps
/// reads as a glitch, not a flourish.
private struct OnboardingEntranceEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var onboardingEntranceEnabled: Bool {
        get { self[OnboardingEntranceEnabledKey.self] }
        set { self[OnboardingEntranceEnabledKey.self] = newValue }
    }
}

/// Reveals the view after `baseDelay + index × stagger`: a fade with a
/// small upward drift (and an optional settle from `scaleFrom`). Two
/// properties, nothing else — no blur, no theatrics — so the cascade reads
/// as content arriving, not performing. Renders the content untouched when
/// entrances are disabled for the subtree. Under Reduce Motion the drift
/// and scale are dropped and only the fade remains.
private struct OnboardingEntranceModifier: ViewModifier {
    let index: Int
    let baseDelay: Double
    let scaleFrom: CGFloat

    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingEntranceEnabled) private var enabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed || reduceMotion ? 0 : OnboardingMotion.entranceRise)
                .scaleEffect(revealed || reduceMotion ? 1 : scaleFrom)
                .onAppearAfter(baseDelay + Double(index) * OnboardingMotion.stagger) {
                    // Ease-out, not a spring: opacity has no mass to settle,
                    // and a spring only stretches the fade's tail.
                    withAnimation(.easeOut(duration: reduceMotion ? 0.3 : 0.35)) {
                        revealed = true
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    /// Staggered content entrance: element `index` fades in with an upward
    /// rise, `stagger` seconds after element `index - 1`. `scaleFrom` lets
    /// panels settle from slightly-larger (e.g. 1.03 → 1).
    func onboardingEntrance(
        _ index: Int,
        baseDelay: Double = OnboardingMotion.entranceBaseDelay,
        scaleFrom: CGFloat = 1
    ) -> some View {
        modifier(
            OnboardingEntranceModifier(index: index, baseDelay: baseDelay, scaleFrom: scaleFrom)
        )
    }
}

// MARK: - Pressable button style

/// Drop-in replacement for `.plain` on onboarding buttons that adds a
/// press-down scale with a snappy spring release. Components keep their own
/// hover states; this only owns the press feedback.
struct OnboardingPressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.965

    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration, pressedScale: pressedScale)
    }

    /// Inner view so the style can read the Reduce Motion environment.
    private struct PressableBody: View {
        let configuration: Configuration
        let pressedScale: CGFloat

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
                .animation(OnboardingMotion.snappy, value: configuration.isPressed)
        }
    }
}
