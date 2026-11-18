//
//  DinoCatalog.swift
//  osaurus
//
//  Typed names for the inputs `dino.riv` exposes through its `ViewModel1`
//  view model. The raw values are the file's own numbers and trigger
//  names; they were read out of the file, so renaming a case here never
//  changes what the file draws.
//

import Foundation

/// `characterSelect`.
enum DinoSpecies: Int, CaseIterable, Sendable {
    case rex = 0
    case trice = 1
    case bronto = 2
}

/// `headwear`.
enum DinoHeadwear: Int, CaseIterable, Sendable {
    case none = 0
    case mecha = 1
    case fighterBlonde = 2
    case fighterDark = 3
    case brainBolt = 4
    case beret = 5
    case bow = 6
    case flowers = 7
    case heartGlasses = 8
    case starGlasses = 9
    case cowboy = 10
    case beanie = 11
}

/// `bodywear`.
enum DinoBodywear: Int, CaseIterable, Sendable {
    case none = 0
    case backpack = 1
    case purse = 2
    case tie = 3
    case scarf = 4
}

/// `expressions`.
enum DinoExpression: Int, CaseIterable, Sendable {
    case neutral = 0
    case tired = 1
    case sleepy = 2
    case curious = 3
    case determined = 4
}

/// The file's animation triggers. One-shots return to idle on their own;
/// `isLoop` ones keep playing until another trigger (usually `idleFront`).
enum DinoAction: String, CaseIterable, Sendable {
    case idleFront, idleSide
    case celebrate, code, cry, crying, dancing
    case dragPick, dragFall, dragLand
    case error, fireball, football, jawDrop
    case jumpBack, jumpQuick, jumpSlow
    case laughing, lookDown, lookUp, love
    case ridingScooter, roar, running, search, sit, skating
    case sleepBelly, sleeping, sweep, talking, thinking
    case walkingSad, walkingHappy, wave

    var isLoop: Bool {
        switch self {
        case .running, .walkingHappy, .walkingSad, .ridingScooter, .skating, .talking, .thinking,
            .laughing, .dancing, .crying, .sleeping, .sleepBelly, .sweep, .code, .search, .sit:
            return true
        default:
            return false
        }
    }

    /// Travel and big body moves. Under Reduce Motion these are dropped
    /// and the dino holds its pose.
    var isVigorous: Bool {
        switch self {
        case .running, .walkingHappy, .walkingSad, .ridingScooter, .skating,
            .jumpBack, .jumpQuick, .jumpSlow, .dragFall, .fireball, .football, .dancing, .roar:
            return true
        default:
            return false
        }
    }

    /// The reactions a click on the dino picks from.
    static let pokeReactions: [DinoAction] = [.laughing, .jawDrop, .love, .roar, .jumpQuick, .celebrate, .dancing]
}

/// `visemes`: mouth shapes, visible while `talking` plays.
enum DinoViseme: Int, Sendable {
    case closed = 0
    case small = 1
    case open = 3
    case smile = 4
    case smallO = 5
    case round = 6
    case teethLip = 7

    /// A mouth shape per letter, with repeats collapsed so each shape
    /// holds long enough to read. Spaces and punctuation close the mouth.
    static func sequence(for text: String) -> [DinoViseme] {
        var shapes: [DinoViseme] = []
        for character in text.lowercased() {
            let shape: DinoViseme
            switch character {
            case "a": shape = .open
            case "e", "i", "y": shape = .smile
            case "o": shape = .round
            case "u", "w", "q": shape = .smallO
            case "f", "v": shape = .teethLip
            case "m", "b", "p": shape = .closed
            case _ where character.isLetter: shape = .small
            default: shape = .closed
            }
            if shapes.last != shape { shapes.append(shape) }
        }
        if shapes.last != .closed { shapes.append(.closed) }
        return shapes
    }
}

/// One dinosaur's look.
struct DinoCostume: Equatable, Sendable {
    var species: DinoSpecies = .rex
    var headwear: DinoHeadwear = .none
    var bodywear: DinoBodywear = .none
    var expression: DinoExpression = .neutral

    /// The Osaurus guide with its brain on.
    static let guide = DinoCostume(headwear: .brainBolt)
}
