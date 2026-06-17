//
//  AutonomyPolicy.swift
//  OsaurusCore — Computer Use
//
//  The configurable autonomy model the real `ComputerUseGate` enforces.
//  PR1 hardwired "anything past navigate confirms"; PR2 replaces that with
//  a user-tunable policy:
//
//    • `AutonomyPreset` — five named stances mapping each `EffectClass` to a
//      `AutonomyDisposition` (allow / confirm / deny).
//    • `AutonomyPolicy` — a global preset + per-app overrides + an optional
//      app allowlist, persisted by `ComputerUsePolicyStore`.
//    • `AutonomyCeiling` — a per-agent hard cap (the SOUL.md "ceiling" from
//      the spec, expressed as structured settings rather than parsed prose).
//
//  The merge is STRICTEST-WINS across the global preset, the per-app
//  override, and the agent ceiling. A per-app override can therefore only
//  add caution, never remove it — to grant an app MORE autonomy, raise the
//  global preset. The allowlist (when set) is checked first and rejects any
//  app not on it. This keeps the safe default impossible to weaken by
//  accident.
//

import Foundation

// MARK: - Disposition

/// What the policy says to do with an action of a given effect. Ordered
/// least → most restrictive so the merge can take the strictest with `max`.
public enum AutonomyDisposition: String, Sendable, Codable, CaseIterable, Comparable {
    /// Run with no prompt.
    case allow
    /// Pause and ask the user.
    case confirm
    /// Refuse outright; the reason is fed back to the model.
    case deny

    private var rank: Int {
        switch self {
        case .allow: return 0
        case .confirm: return 1
        case .deny: return 2
        }
    }

    public static func < (lhs: AutonomyDisposition, rhs: AutonomyDisposition) -> Bool {
        lhs.rank < rhs.rank
    }

    /// The more restrictive (higher) of two dispositions — the merge primitive.
    public static func strictest(_ a: AutonomyDisposition, _ b: AutonomyDisposition)
        -> AutonomyDisposition
    {
        a >= b ? a : b
    }

    public var displayLabel: String {
        switch self {
        case .allow: return "Auto-run"
        case .confirm: return "Ask first"
        case .deny: return "Block"
        }
    }
}

// MARK: - Preset

/// A named autonomy stance. The model never sees these — they only shape
/// what auto-runs vs. confirms vs. blocks. `read` is always `allow`
/// (perception never mutates anything), so presets only differ on
/// navigate / edit / consequential.
public enum AutonomyPreset: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Explore freely but never modify: edits and consequential actions are
    /// blocked outright; reads and navigation run.
    case readOnly = "read_only"
    /// Ask before doing anything but looking: navigation, edits, and
    /// consequential actions all confirm.
    case cautious
    /// The default. Reads and navigation run; edits and consequential
    /// actions confirm (matches PR1's hardwired behavior).
    case balanced
    /// Edits run; only consequential actions (send / delete / purchase)
    /// confirm.
    case trusted
    /// Everything runs without prompting (still subject to the per-agent
    /// ceiling, the allowlist, and the classifier's escalation).
    case autonomous

    public var id: String { rawValue }

    /// The shipped default (spec preset "b").
    public static let `default`: AutonomyPreset = .balanced

    /// The disposition this preset assigns to a given effect.
    public func disposition(for effect: EffectClass) -> AutonomyDisposition {
        switch self {
        case .readOnly:
            switch effect {
            case .read, .navigate: return .allow
            case .edit, .consequential: return .deny
            }
        case .cautious:
            switch effect {
            case .read: return .allow
            case .navigate, .edit, .consequential: return .confirm
            }
        case .balanced:
            switch effect {
            case .read, .navigate: return .allow
            case .edit, .consequential: return .confirm
            }
        case .trusted:
            switch effect {
            case .read, .navigate, .edit: return .allow
            case .consequential: return .confirm
            }
        case .autonomous:
            return .allow
        }
    }

    public var displayLabel: String {
        switch self {
        case .readOnly: return "Read-only"
        case .cautious: return "Cautious"
        case .balanced: return "Balanced"
        case .trusted: return "Trusted"
        case .autonomous: return "Autonomous"
        }
    }

    public var detail: String {
        switch self {
        case .readOnly: return "Look and navigate freely; never edit."
        case .cautious: return "Ask before every action except reading."
        case .balanced: return "Reads and navigation run; edits and risky actions ask first."
        case .trusted: return "Edits run; only sending, deleting, and similar ask first."
        case .autonomous: return "Everything runs without asking."
        }
    }
}

// MARK: - Ceiling

/// A per-agent hard cap on autonomy, merged strictest-wins on top of the
/// user's policy. This is the spec's "SOUL.md ceiling", implemented as
/// structured settings (per decision in the plan) rather than parsed prose.
/// A `nil` field means "no cap for this effect"; `read` is never capped
/// because perception is always safe.
public struct AutonomyCeiling: Codable, Sendable, Equatable {
    public var navigate: AutonomyDisposition?
    public var edit: AutonomyDisposition?
    public var consequential: AutonomyDisposition?

    public init(
        navigate: AutonomyDisposition? = nil,
        edit: AutonomyDisposition? = nil,
        consequential: AutonomyDisposition? = nil
    ) {
        self.navigate = navigate
        self.edit = edit
        self.consequential = consequential
    }

    /// The cap for an effect, or `nil` when uncapped.
    public func cap(for effect: EffectClass) -> AutonomyDisposition? {
        switch effect {
        case .read: return nil
        case .navigate: return navigate
        case .edit: return edit
        case .consequential: return consequential
        }
    }

    /// Whether any cap is set (so callers can skip an empty ceiling).
    public var isEmpty: Bool { navigate == nil && edit == nil && consequential == nil }

    /// A ceiling that caps every effect at the disposition a preset assigns —
    /// i.e. "this agent may be at most as autonomous as `preset`". Lets the
    /// per-agent UI express the structured ceiling as one familiar picker.
    public static func cappedAt(_ preset: AutonomyPreset) -> AutonomyCeiling {
        AutonomyCeiling(
            navigate: preset.disposition(for: .navigate),
            edit: preset.disposition(for: .edit),
            consequential: preset.disposition(for: .consequential)
        )
    }

    /// The preset this ceiling exactly matches, for round-tripping the picker.
    /// `nil` when a hand-edited ceiling doesn't correspond to any preset.
    public var matchingPreset: AutonomyPreset? {
        AutonomyPreset.allCases.first { Self.cappedAt($0) == self }
    }
}

// MARK: - Policy

/// The persisted user policy: a global preset, optional per-app overrides,
/// and an optional app allowlist. Stored at
/// `~/.osaurus/config/computer-use.json` by `ComputerUsePolicyStore`.
public struct AutonomyPolicy: Codable, Sendable, Equatable {
    /// The baseline stance applied to every app.
    public var globalPreset: AutonomyPreset
    /// Per-app overrides keyed by normalized app name (lowercased). Can only
    /// make an app stricter than the global preset (strictest-wins merge).
    public var perApp: [String: AutonomyPreset]
    /// When non-empty, ONLY these apps (normalized names) may be driven; any
    /// other app is rejected before disposition is even consulted. `nil` or
    /// empty means every app is allowed.
    public var allowlist: [String]?

    public init(
        globalPreset: AutonomyPreset = .default,
        perApp: [String: AutonomyPreset] = [:],
        allowlist: [String]? = nil
    ) {
        self.globalPreset = globalPreset
        self.perApp = perApp
        self.allowlist = allowlist
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        globalPreset = try c.decodeIfPresent(AutonomyPreset.self, forKey: .globalPreset) ?? .default
        perApp = try c.decodeIfPresent([String: AutonomyPreset].self, forKey: .perApp) ?? [:]
        allowlist = try c.decodeIfPresent([String].self, forKey: .allowlist)
    }

    private enum CodingKeys: String, CodingKey {
        case globalPreset
        case perApp
        case allowlist
    }

    /// Normalize an app name / bundle id for case-insensitive matching.
    public static func normalize(_ app: String) -> String {
        app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether an app may be driven at all. The allowlist is checked first,
    /// before any disposition. An unknown (`nil`) app under an active
    /// allowlist is rejected — we can't confirm it's permitted.
    public func isAppAllowed(_ app: String?) -> Bool {
        guard let allowlist, !allowlist.isEmpty else { return true }
        guard let app, !app.isEmpty else { return false }
        let n = Self.normalize(app)
        return allowlist.contains { Self.normalize($0) == n }
    }

    /// The effective disposition for an effect in an app, merged
    /// strictest-wins across the global preset, the per-app override, and the
    /// agent ceiling.
    public func disposition(
        for effect: EffectClass,
        app: String?,
        ceiling: AutonomyCeiling?
    ) -> AutonomyDisposition {
        var disposition = globalPreset.disposition(for: effect)
        if let app, let override = perApp[Self.normalize(app)] {
            disposition = AutonomyDisposition.strictest(disposition, override.disposition(for: effect))
        }
        if let cap = ceiling?.cap(for: effect) {
            disposition = AutonomyDisposition.strictest(disposition, cap)
        }
        return disposition
    }

    /// The shipped default policy: balanced everywhere, no per-app overrides,
    /// no allowlist.
    public static var defaultPolicy: AutonomyPolicy { AutonomyPolicy() }
}
