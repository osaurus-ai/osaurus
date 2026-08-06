//
//  SandboxAlpinePackageTokens.swift
//  osaurus
//
//  Strict Alpine package-atom validation for every root `apk add` path.
//
//  Root exec is necessarily `sh -c` / `su … -c` (see SandboxManager.exec),
//  so package tokens from agents, plugin recipes, and legacy persisted
//  plugins are untrusted shell material until they pass this grammar.
//  Callers must validate before privileged execution and before
//  persisting/staging plugin dependencies. Fail closed: one bad token
//  rejects the install request; cold-boot repair skips unsafe legacy
//  entries without invoking root.
//

import Foundation

/// Shared Alpine `apk` package-token contract used by `sandbox_install`
/// and sandbox plugin dependency install/repair.
enum SandboxAlpinePackageTokens {

    /// Why a package token was rejected. Reasons are model-readable so
    /// `sandbox_install` can surface them in an `invalid_args` envelope.
    enum Rejection: Error, Equatable, Sendable {
        case empty
        case whitespace
        case leadingOption
        case shellSyntax
        case invalidGrammar
        case tooLong

        var reason: String {
            switch self {
            case .empty:
                return "package token is empty"
            case .whitespace:
                return "package token contains whitespace"
            case .leadingOption:
                return "package token must not start with `-` (apk options are not allowed)"
            case .shellSyntax:
                return "package token contains shell metacharacters or quoting"
            case .invalidGrammar:
                return "package token is not a valid Alpine package atom "
                    + "(name, optional @repository, optional =/>/</>=/<=/~ version)"
            case .tooLong:
                return "package token exceeds maximum length (\(maxTokenLength))"
            }
        }
    }

    /// Alpine package names are short; cap well below shell ARG_MAX so a
    /// single malicious token cannot bloat the root command line.
    static let maxTokenLength = 128

    // MARK: - Grammar
    //
    // Accepted atoms (apk "world" package atoms used by this codebase):
    //
    //   name
    //   name=1.2.3-r0
    //   name>1.0
    //   name>=1.0
    //   name<2.0
    //   name<=2.0
    //   name~1.2
    //   name@repository
    //   name@repository=1.2.3-r0
    //
    // name:      [A-Za-z0-9][A-Za-z0-9+._-]*
    // repo tag:  @[A-Za-z0-9][A-Za-z0-9._-]*
    // version:   [A-Za-z0-9][A-Za-z0-9+._:-]*  (epoch `1:…` and `-r0` allowed)
    //
    // Rejected: empty, whitespace, shell metacharacters, quotes,
    // backslashes, redirections, leading `-`/`--` option forms, `!`
    // world negation, command substitution, and anything outside the
    // grammar above.

    // swiftlint:disable:next force_try
    private static let atomPattern = try! NSRegularExpression(
        pattern:
            #"^[A-Za-z0-9][A-Za-z0-9+._-]*(?:@[A-Za-z0-9][A-Za-z0-9._-]*)?(?:(?:=|>=|<=|>|<|~)[A-Za-z0-9][A-Za-z0-9+._:-]*)?$"#
    )

    /// Characters that must never appear in a package token because the
    /// root boundary is `sh -c`. Kept as an explicit set so the security
    /// invariant is reviewable without decoding the regex.
    private static let shellMetacharacters: Set<Character> = [
        ";", "|", "&", "$", "`", "(", ")", "{", "}",
        "'", "\"", "\\", "\n", "\r", "\t", " ",
        "<", ">",  // redirections; version ops are matched only via grammar
        "!", "*", "?", "[", "]", "~",  // glob / history / world-negation noise
        "#",  // shell comment
    ]

    // MARK: - Validate

    /// Validate a single Alpine package atom. On success returns the same
    /// string (no normalization) so apk sees the caller's exact pin.
    static func validate(_ token: String) -> Result<String, Rejection> {
        if token.isEmpty { return .failure(.empty) }
        if token.count > maxTokenLength { return .failure(.tooLong) }

        // Fail closed on any whitespace before the grammar check so
        // multi-word injection like `curl; id` never reaches apk.
        if token.contains(where: { $0.isWhitespace || $0 == "\0" }) {
            return .failure(.whitespace)
        }

        // Leading `-` would be parsed as an apk option (`--allow-untrusted`,
        // `-f`, …) if it ever reached `apk add`.
        if token.hasPrefix("-") {
            return .failure(.leadingOption)
        }

        // Reject shell metacharacters unless they are part of a version
        // operator that the grammar below explicitly allows (`>`, `<`, `~`
        // only in the operator position). Scan first for obvious shell
        // syntax so error messages stay specific.
        if token.contains(where: { shellMetacharacters.contains($0) && $0 != ">" && $0 != "<" && $0 != "~" }) {
            return .failure(.shellSyntax)
        }
        // Bare `>`, `<`, `~` without a surrounding atom is shell syntax /
        // invalid grammar; the regex gate below rejects those forms.

        let range = NSRange(token.startIndex..., in: token)
        guard atomPattern.firstMatch(in: token, options: [], range: range) != nil else {
            // Distinguish pure shell-ish operators from other grammar fails.
            if token.contains(where: { shellMetacharacters.contains($0) }) {
                return .failure(.shellSyntax)
            }
            return .failure(.invalidGrammar)
        }
        return .success(token)
    }

    /// Validate every token. Fail closed on the first rejection — partial
    /// installs would leave callers unsure which packages landed.
    static func validateAll(_ tokens: [String]) -> Result<[String], Rejection> {
        var validated: [String] = []
        validated.reserveCapacity(tokens.count)
        for token in tokens {
            switch validate(token) {
            case .success(let safe):
                validated.append(safe)
            case .failure(let rejection):
                return .failure(rejection)
            }
        }
        return .success(validated)
    }

    /// Validate, drop duplicates (first occurrence wins), preserve order.
    /// Used by interactive `sandbox_install` so repeated names still
    /// produce one root install of unique packages.
    static func validateUniquePreservingOrder(
        _ tokens: [String]
    ) -> Result<[String], Rejection> {
        switch validateAll(tokens) {
        case .failure(let rejection):
            return .failure(rejection)
        case .success(let validated):
            var seen = Set<String>()
            var unique: [String] = []
            unique.reserveCapacity(validated.count)
            for token in validated where seen.insert(token).inserted {
                unique.append(token)
            }
            return .success(unique)
        }
    }

    /// Partition into valid (deduped, sorted) and rejected tokens.
    /// Cold-boot repair uses this so legacy unsafe persisted dependencies
    /// are skipped without aborting sibling valid packages — and without
    /// ever handing unsafe tokens to root.
    static func partitionForRepair(
        _ tokens: some Sequence<String>
    ) -> (valid: [String], rejected: [(token: String, rejection: Rejection)]) {
        var seen = Set<String>()
        var valid: [String] = []
        var rejected: [(String, Rejection)] = []
        for token in tokens {
            switch validate(token) {
            case .success(let safe):
                if seen.insert(safe).inserted {
                    valid.append(safe)
                }
            case .failure(let rejection):
                rejected.append((token, rejection))
            }
        }
        return (valid.sorted(), rejected)
    }

    // MARK: - Shell rendering

    /// Render already-validated package tokens as a single shell-safe
    /// argument list for `sh -c`.
    ///
    /// Tokens are single-quoted. Validation rejects `'` and every other
    /// shell metacharacter, so quoting cannot be broken by a token that
    /// reached this function through the audited validator. Callers must
    /// not pass unvalidated strings.
    static func renderShellArguments(_ validatedTokens: [String]) -> String {
        validatedTokens.map { "'\($0)'" }.joined(separator: " ")
    }

    /// Build the root `apk add --no-cache …` command from untrusted tokens.
    /// Returns `nil` when no valid packages remain (caller must not invoke
    /// root). Interactive install paths should prefer `validateUnique…`
    /// and surface the rejection instead of silently dropping packages.
    static func makeApkAddCommand(fromUntrusted packages: [String]) -> (
        command: String?,
        valid: [String],
        rejected: [(token: String, rejection: Rejection)]
    ) {
        let (valid, rejected) = partitionForRepair(packages)
        guard !valid.isEmpty else {
            return (nil, valid, rejected)
        }
        let command = "apk add --no-cache \(renderShellArguments(valid))"
        return (command, valid, rejected)
    }

    /// Human-readable message naming the offending token for tool envelopes.
    static func invalidArgsMessage(token: String, rejection: Rejection) -> String {
        "Invalid Alpine package `\(token)`: \(rejection.reason). "
            + "Pass plain package names (optionally with @repository or "
            + "=/>/</>=/<=/~ version constraints); shell syntax is not allowed."
    }

    /// Locate the first invalid token in `tokens` (for structured errors).
    static func firstRejection(
        in tokens: [String]
    ) -> (token: String, rejection: Rejection)? {
        for token in tokens {
            if case .failure(let rejection) = validate(token) {
                return (token, rejection)
            }
        }
        return nil
    }
}

// MARK: - Plugin dependency validation

extension SandboxPlugin {
    /// Validate `dependencies` against the shared Alpine package-token
    /// contract. Returns human-readable errors; empty means safe to register,
    /// import, and install. Install and repair paths also fail closed on
    /// legacy unsafe records that predate this validator.
    func validateDependencies() -> [String] {
        guard let dependencies, !dependencies.isEmpty else { return [] }
        var errors: [String] = []
        for dep in dependencies {
            if case .failure(let rejection) = SandboxAlpinePackageTokens.validate(dep) {
                errors.append(SandboxAlpinePackageTokens.invalidArgsMessage(
                    token: dep,
                    rejection: rejection
                ))
            }
        }
        return errors
    }
}
