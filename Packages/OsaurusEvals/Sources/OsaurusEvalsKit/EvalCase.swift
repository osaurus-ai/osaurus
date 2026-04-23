//
//  EvalCase.swift
//  OsaurusEvalsKit
//
//  JSON schema for a single behaviour case. Cases live as small JSON
//  files under `Suites/<domain>/` so non-Swift contributors can add new
//  ones with a text editor. Schema design:
//    - `domain` is the eval family (today: "preflight"). It selects
//      which runner code-path executes the case.
//    - `fixtures` describes the world the case should run against
//      (preflight mode, required plugins). The runner uses
//      `requirePlugins` to skip cases the local install can't satisfy
//      instead of failing them — a contributor without `osaurus.browser`
//      should still be able to run the rest of the suite.
//    - `expect` is what we'd score against. All matchers are optional
//      so a case can scope to just tools, just companions, or both.
//

import Foundation

public struct EvalCase: Sendable, Codable, Identifiable {
    /// Unique slug, e.g. `preflight.browser.amazon-orders`. Surfaced in
    /// reports for diffing across runs.
    public let id: String
    /// Selects the runner code path. Exactly one domain is supported
    /// today (`preflight`); future domains will live under sibling
    /// directories (`Suites/AgentLoop/`, `Suites/ToolCalling/`, ...).
    public let domain: String
    /// Optional human label for reports — falls back to `id` when nil.
    public let label: String?
    /// User message the case sends through preflight.
    public let query: String
    public let fixtures: Fixtures
    public let expect: Expectations

    public init(
        id: String,
        domain: String,
        label: String? = nil,
        query: String,
        fixtures: Fixtures,
        expect: Expectations
    ) {
        self.id = id
        self.domain = domain
        self.label = label
        self.query = query
        self.fixtures = fixtures
        self.expect = expect
    }

    public struct Fixtures: Sendable, Codable {
        /// Preflight aggressiveness for the case. Default `.balanced`
        /// matches the production default — over-narrow cases should
        /// opt down explicitly so the picker behaviour they're asserting
        /// is the same one users see.
        public let preflightMode: PreflightMode?
        /// Plugin ids the case needs in the local registry. Cases with
        /// missing requirements are SKIPPED in the report (not failed)
        /// so an incomplete local setup doesn't mask real regressions.
        public let requirePlugins: [String]?

        public init(
            preflightMode: PreflightMode? = nil,
            requirePlugins: [String]? = nil
        ) {
            self.preflightMode = preflightMode
            self.requirePlugins = requirePlugins
        }
    }

    /// Mirror of `OsaurusCore.PreflightSearchMode` decoded from JSON.
    /// We don't import the OsaurusCore enum directly because we want
    /// the JSON to use lowercase strings (`"balanced"`) and don't want
    /// the schema to break if the upstream enum gains cases.
    public enum PreflightMode: String, Sendable, Codable {
        case off, narrow, balanced, wide
    }

    /// What we score against. All sub-fields are optional so a case can
    /// scope its assertions narrowly. An empty `Expectations` is valid
    /// — it acts as a smoke-test that just records what preflight did
    /// without scoring anything (useful while bootstrapping a new case).
    public struct Expectations: Sendable, Codable {
        public let tools: ToolExpectations?
        public let companions: CompanionExpectations?

        public init(
            tools: ToolExpectations? = nil,
            companions: CompanionExpectations? = nil
        ) {
            self.tools = tools
            self.companions = companions
        }
    }

    public struct ToolExpectations: Sendable, Codable {
        /// Tool names that MUST appear in the picked set. Each missing
        /// name costs a fixed weight (see `Scorers.scoreTools`).
        public let mustInclude: [String]?
        /// Tool names that must NOT appear. Each spurious pick fails
        /// the contract.
        public let mustNotInclude: [String]?

        public init(mustInclude: [String]? = nil, mustNotInclude: [String]? = nil) {
            self.mustInclude = mustInclude
            self.mustNotInclude = mustNotInclude
        }
    }

    public struct CompanionExpectations: Sendable, Codable {
        /// Plugin skills (by name) that should surface in the teaser.
        /// A case asserts on names rather than the full skill object so
        /// the schema stays compact.
        public let skills: [String]?
        /// Sibling-tool overlap matcher: AT LEAST `minOverlap` of these
        /// candidates should appear in the teaser. Captures "the right
        /// SHAPE of siblings showed up" without pinning the exact list,
        /// which is helpful when sibling ordering is query-dependent.
        public let siblings: SiblingMatcher?

        public init(skills: [String]? = nil, siblings: SiblingMatcher? = nil) {
            self.skills = skills
            self.siblings = siblings
        }

        public struct SiblingMatcher: Sendable, Codable {
            public let minOverlap: Int
            public let candidates: [String]

            public init(minOverlap: Int, candidates: [String]) {
                self.minOverlap = minOverlap
                self.candidates = candidates
            }
        }
    }
}
