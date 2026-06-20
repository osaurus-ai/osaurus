//
//  EffectClass.swift
//  OsaurusCore — Computer Use
//
//  The four-level effect taxonomy the gate enforces autonomy against.
//  PR1 uses the verb-only baseline (`AgentAction.baselineEffect`) to
//  hardwire the gate ("anything past `navigate` is confirm/block"). PR2
//  layers a context-sensitive `EffectClassifier` on top (resolved role +
//  app context, default-stricter on ambiguity) that can only ever
//  *raise* the class, never lower it.
//

import Foundation

/// How consequential an action is. Ordered least → most severe so the
/// gate can compare against a policy disposition with `<`/`>=`.
public enum EffectClass: String, Sendable, Codable, CaseIterable, Comparable {
    /// Pure perception: re-observe, query elements, narrate. No mutation.
    case read
    /// Moves focus / viewport / app without committing a change: click a
    /// link or tab, scroll, switch app, focus a field.
    case navigate
    /// Mutates editable state the user can still review/undo: type into a
    /// field, set a value, clear a field.
    case edit
    /// Commits something hard to undo or crossing a trust boundary: send,
    /// submit, delete, purchase, share with recipients.
    case consequential

    private var rank: Int {
        switch self {
        case .read: return 0
        case .navigate: return 1
        case .edit: return 2
        case .consequential: return 3
        }
    }

    /// Human-readable label for confirm cards / activity feeds.
    public var displayLabel: String {
        switch self {
        case .read: return L("Read")
        case .navigate: return L("Navigate")
        case .edit: return L("Edit")
        case .consequential: return L("Consequential")
        }
    }

    public static func < (lhs: EffectClass, rhs: EffectClass) -> Bool {
        lhs.rank < rhs.rank
    }

    /// The stricter (higher) of two classes. Used by the PR2 classifier and
    /// the policy merge, both of which only ever escalate.
    public static func max(_ a: EffectClass, _ b: EffectClass) -> EffectClass {
        a >= b ? a : b
    }
}
