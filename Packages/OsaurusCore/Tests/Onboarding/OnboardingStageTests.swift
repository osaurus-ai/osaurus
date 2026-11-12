//
//  OnboardingStageTests.swift
//  osaurusTests
//
//  The pure parts of the welcome window: the compact chat frame it
//  becomes, the time-of-day scene, the greeting, the dino's mouth shapes,
//  and the teammate casting.
//

import CoreGraphics
import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct OnboardingStageTests {

    // MARK: Compact chat frame

    @Test func compactFrameIsCenteredAtItsSize() {
        let visible = CGRect(x: 0, y: 25, width: 1512, height: 920)
        let frame = OnboardingHandoff.compactChatFrame(in: visible)
        #expect(frame.size == OnboardingHandoff.compactChatSize)
        #expect(abs(frame.midX - visible.midX) <= 0.5)
        #expect(abs(frame.midY - visible.midY) <= 0.5)
        #expect(visible.contains(frame))
    }

    @Test func compactFrameShrinksToSmallScreens() {
        let visible = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frame = OnboardingHandoff.compactChatFrame(in: visible)
        #expect(frame.width == 800)
        #expect(frame.height == 600)
        #expect(frame.origin == .zero)
    }

    @Test func compactFrameHonorsTheChatMinimum() {
        let visible = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let frame = OnboardingHandoff.compactChatFrame(in: visible, minimum: CGSize(width: 1100, height: 800))
        #expect(frame.size == CGSize(width: 1100, height: 800))
    }

    @Test func compactFrameFollowsSecondaryScreens() {
        let visible = CGRect(x: -1920, y: 200, width: 1920, height: 1055)
        let frame = OnboardingHandoff.compactChatFrame(in: visible)
        #expect(visible.contains(frame))
        #expect(frame.origin.x == frame.origin.x.rounded())
        #expect(frame.origin.y == frame.origin.y.rounded())
    }

    // MARK: Scene and greeting

    @Test func sceneFollowsTheHour() {
        let expected: [(Int, OnboardingScene)] = [
            (0, .night), (4, .night), (5, .morning), (10, .morning), (11, .day),
            (16, .day), (17, .evening), (20, .evening), (21, .night), (23, .night),
        ]
        for (hour, scene) in expected {
            #expect(OnboardingScene.forHour(hour) == scene, "hour \(hour)")
        }
    }

    @Test func everySceneShipsItsPlate() {
        for scene in OnboardingScene.allCases {
            #expect(OnboardingBackdropPlates.url(for: scene) != nil, "\(scene)")
            #expect(OnboardingBackdropPlates.sharp(scene) != nil, "\(scene)")
        }
    }

    @Test func greetingNeverNamesThePerson() {
        #expect(OnboardingScene.morning.greeting == "Good morning.")
        #expect(OnboardingScene.day.greeting == "Good afternoon.")
        #expect(OnboardingScene.night.greeting == "Good evening.")
    }

    // MARK: Dino help

    private static let pick = OnboardingHelp.Pick(
        name: "Raptor 0.7 4B", downloadSize: "3.68 GB", isDownloaded: false,
        reason: "It runs smoothly with your Mac's 32 GB of memory and leaves room for your other apps.")

    @Test func everyStepHasSeveralPagesOfHelp() {
        for topic: OnboardingHelp.Topic in [.welcome, .paths, .localModel, .ownAccount] {
            let pages = OnboardingHelp.pages(topic, pick: Self.pick)
            #expect(pages.count >= 3, "\(topic)")
            #expect(pages.allSatisfy { !$0.isEmpty }, "\(topic)")
        }
    }

    /// The model step explains what a model is before anything else, and
    /// ends on the pick and why.
    @Test func theModelHelpStartsWithWhatAModelIs_andEndsWithWhy() {
        let pages = OnboardingHelp.pages(.paths, pick: Self.pick)
        #expect(pages.first?.contains("model") == true)
        #expect(pages.contains { $0.contains("3.68 GB") })
        #expect(pages.last?.contains("Raptor 0.7 4B") == true)
        #expect(pages.last?.contains("32 GB") == true)
    }

    @Test func theLocalHelpNamesThePick_andNeverOffersAChooser() {
        let pick = OnboardingHelp.Pick(name: "Raptor 0.7 4B", downloadSize: "3.68 GB", isDownloaded: false, reason: nil)
        let pages = OnboardingHelp.pages(.localModel, pick: pick)
        #expect(pages.contains { $0 == "I picked Raptor 0.7 4B for you. It stays on this Mac, so it works offline." })
        #expect(!pages.contains { $0.contains("Change model") })
        #expect(pages.last?.contains("Settings") == true)
    }

    @Test func clickingTheDinoTalksThroughThePages_andClickingAgainStops() {
        let stage = OnboardingStage(scene: .day)
        stage.toggleHelp(["one", "two"])
        #expect(stage.isHelping && stage.helpPage == 0)
        stage.nextHelpPage()
        #expect(stage.helpPage == 1)
        stage.previousHelpPage()
        #expect(stage.helpPage == 0)
        stage.toggleHelp(["one", "two"])
        #expect(!stage.isHelping)

        stage.toggleHelp(["only"])
        stage.nextHelpPage()
        #expect(!stage.isHelping)
    }

    // MARK: Mouth shapes

    @Test func visemesCollapseRepeatsAndEndClosed() {
        #expect(DinoViseme.sequence(for: "") == [.closed])
        #expect(DinoViseme.sequence(for: "Moo") == [.closed, .round, .closed])
        #expect(DinoViseme.sequence(for: "aaa") == [.open, .closed])
        #expect(DinoViseme.sequence(for: "Hi!") == [.small, .smile, .closed])
        #expect(DinoViseme.sequence(for: "five") == [.teethLip, .smile, .teethLip, .smile, .closed])
    }
}
