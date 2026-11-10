//
//  OnboardingStageViews.swift
//  osaurus
//
//  The onboarding window's stage layers: the landscape and the dino that
//  stands on it.
//

import SwiftUI

/// The landscape, redrawn on pointer moves without touching the chapters.
struct OnboardingBackdropHost: View {
    @ObservedObject var stage: OnboardingStage
    @ObservedObject var pointer: OnboardingPointer

    var body: some View {
        OnboardingBackdrop(scene: stage.scene, focus: stage.focus, pointer: pointer.location)
    }
}

/// The dino on the ground line.
struct OnboardingStageDino: View {
    @ObservedObject var stage: OnboardingStage

    private var feetY: CGFloat { OnboardingMetrics.windowHeight - OnboardingLayout.groundInset }

    var body: some View {
        DinoView(director: stage.dino, size: stage.dinoSize)
            .frame(width: stage.dinoSize, height: stage.dinoSize)
            .position(x: stage.dinoX, y: feetY - stage.dinoSize / 2)
            .frame(
                width: OnboardingMetrics.windowWidth, height: OnboardingMetrics.windowHeight, alignment: .topLeading
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
