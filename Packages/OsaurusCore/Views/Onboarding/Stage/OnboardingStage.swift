//
//  OnboardingStage.swift
//  osaurus
//
//  The onboarding window's stage: where the dino stands, which way it
//  faces, and how much attention the landscape takes. The views read
//  this; only this moves things.
//

import AppKit
import SwiftUI

@MainActor
final class OnboardingStage: ObservableObject {
    let dino = DinoDirector(costume: DinoCostume(), facingLeft: false)
    let scene: OnboardingScene
    let greetingLines: [String]

    @Published private(set) var focus: OnboardingBackdropFocus = .clear
    /// The dino's box center along the ground, in content points.
    @Published private(set) var dinoX: CGFloat = OnboardingStage.helloX
    @Published private(set) var dinoSize: CGFloat = OnboardingLayout.helloDinoSize
    @Published private(set) var isWalking = false
    /// The explainer the dino is talking through, one bubble per page;
    /// empty when it is not explaining.
    @Published private(set) var helpPages: [String] = []
    @Published private(set) var helpPage = 0

    private var walkTask: Task<Void, Never>?
    private var hasGreeted = false

    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var motion: ThemeMotion { ThemeManager.shared.currentTheme.motion }

    static let helloX: CGFloat = 230
    static let brainX: CGFloat = 170

    init(scene: OnboardingScene = .current()) {
        self.scene = scene
        greetingLines = [scene.greeting, L("Meet Osaurus.")]
    }

    var greetingText: String { greetingLines.joined(separator: " ") }

    /// One wave when the window opens.
    func greet() {
        guard !hasGreeted else { return }
        hasGreeted = true
        dino.play(.wave)
    }

    // MARK: Chapters

    /// The landscape pulls focus and the dino walks aside for the setup.
    func enterBrain() {
        withAnimation(motion.timed(.easeInOut, duration: OnboardingChoreography.time(0.8)) ?? motion.standard) {
            focus = .pulled
        }
        walk(to: Self.brainX, size: OnboardingLayout.brainDinoSize)
    }

    func returnToHello() {
        withAnimation(motion.timed(.easeInOut, duration: OnboardingChoreography.time(0.8)) ?? motion.standard) {
            focus = .clear
        }
        walk(to: Self.helloX, size: OnboardingLayout.helloDinoSize)
    }

    private func walk(to x: CGFloat, size: CGFloat) {
        closeHelp()
        let duration = OnboardingChoreography.time(0.8)
        dino.face(left: x < dinoX)
        dino.play(.walkingHappy)
        isWalking = true
        withAnimation(motion.timed(.easeInOut, duration: duration) ?? motion.standard) {
            dinoX = x
            dinoSize = size
        }
        walkTask?.cancel()
        walkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            self.walkTask = nil
            self.isWalking = false
            self.dino.face(left: false)
            self.dino.rest()
        }
    }

    // MARK: Help

    var isHelping: Bool { !helpPages.isEmpty }

    /// A click on the dino: it starts explaining `pages`, or stops if it
    /// already is.
    func toggleHelp(_ pages: [String]) {
        guard !isHelping else {
            closeHelp()
            return
        }
        guard !pages.isEmpty, !isWalking else { return }
        helpPages = pages
        helpPage = 0
        dino.face(left: false)
        dino.speak(pages[0])
    }

    func nextHelpPage() {
        guard helpPage + 1 < helpPages.count else {
            closeHelp()
            return
        }
        helpPage += 1
        dino.speak(helpPages[helpPage])
    }

    func previousHelpPage() {
        guard helpPage > 0 else { return }
        helpPage -= 1
        dino.speak(helpPages[helpPage])
    }

    func closeHelp() {
        guard isHelping else { return }
        helpPages = []
        helpPage = 0
        dino.rest()
    }

    // MARK: Pointer

    /// Faces the pointer while standing. Holds still while explaining, so
    /// it never turns its back on the bubble.
    func pointerMoved(to point: CGPoint?) {
        guard let point, walkTask == nil, !isHelping else { return }
        dino.look(toward: point.x, from: dinoX)
    }
}
