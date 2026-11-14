//
//  OnboardingScene.swift
//  osaurus
//
//  The brand landscape behind the onboarding window, picked by the local
//  hour, and the pacing knob every onboarding choreography reads.
//

import Foundation

enum OnboardingScene: String, CaseIterable, Sendable {
    case morning, day, evening, night

    static func forHour(_ hour: Int) -> OnboardingScene {
        switch hour {
        case 5..<11: return .morning
        case 11..<17: return .day
        case 17..<21: return .evening
        default: return .night
        }
    }

    #if DEBUG
        /// Debug builds can pin the hour to preview every scene.
        static let hourOverrideKey = "onboardingSceneHourOverride"
    #endif

    static func current(now: Date = Date(), calendar: Calendar = .current) -> OnboardingScene {
        #if DEBUG
            if let hour = UserDefaults.standard.object(forKey: hourOverrideKey) as? Int {
                return forHour(hour)
            }
        #endif
        return forHour(calendar.component(.hour, from: now))
    }

    var imageName: String { "onboarding-scene-\(rawValue)" }

    /// The greeting's opening words.
    var salutation: String {
        switch self {
        case .morning: return L("Good morning")
        case .day: return L("Good afternoon")
        case .evening, .night: return L("Good evening")
        }
    }

    /// "Good morning." Never a name: the account's name is not always the
    /// person at the keyboard.
    var greeting: String { salutation + "." }
}

/// Pacing for the onboarding choreography. Debug builds can slow every
/// beat down to inspect it.
enum OnboardingChoreography {
    #if DEBUG
        static let speedKey = "onboardingChoreographySpeed"
        static var speed: Double {
            let stored = UserDefaults.standard.double(forKey: speedKey)
            return stored > 0 ? stored : 1
        }
    #else
        static let speed: Double = 1
    #endif

    /// `seconds` at the current pace.
    static func time(_ seconds: Double) -> Double { seconds / speed }

    static func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(time(seconds)))
    }
}
