//
//  KnowledgeIgnoreRules.swift
//  osaurus
//
//  Gitignore-style ignore matching for knowledge indexing. Two sources feed
//  the same engine: a bundled default set of "never knowledge" patterns
//  (lockfiles, minified/generated assets, sourcemaps, media, archives) and
//  the collection folder's own `.gitignore`. This is what lets a
//  non-technical user drop a repo in and get sensible results without
//  writing include/exclude globs — those remain the power-user override on
//  top (see `KnowledgeCollection.includeGlobs`/`excludeGlobs`).
//
//  Supported gitignore subset: comments (`#`), blank lines, negation (`!`,
//  last-match-wins), leading-slash anchoring, trailing-slash directory rules,
//  and `*` / `**` / `?` wildcards (via `KnowledgeGlob`). NOT supported:
//  nested per-directory `.gitignore` files (only the folder root is read),
//  and character classes (`[a-z]`). Documented so callers don't assume full
//  git parity.
//

import Foundation

public struct KnowledgeIgnoreRules {
    private struct Rule {
        /// Concrete `KnowledgeGlob` patterns that, if any matches the
        /// relative path, count as this rule matching.
        let patterns: [String]
        let negated: Bool
    }

    private let rules: [Rule]

    private init(rules: [Rule]) {
        self.rules = rules
    }

    /// True when `relPath` (collection-relative, `/`-separated) is ignored.
    /// Later rules override earlier ones, so a `!pattern` can re-include a
    /// path an earlier rule excluded — matching git's semantics.
    public func isIgnored(_ relPath: String) -> Bool {
        var ignored = false
        for rule in rules {
            if rule.patterns.contains(where: { KnowledgeGlob.matchesPattern(relPath, pattern: $0) }) {
                ignored = !rule.negated
            }
        }
        return ignored
    }

    public var isEmpty: Bool { rules.isEmpty }

    // MARK: - Parsing

    /// Parse gitignore text into rules.
    public static func parse(_ text: String) -> KnowledgeIgnoreRules {
        var rules: [Rule] = []
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            if let rule = parseLine(String(rawLine)) { rules.append(rule) }
        }
        return KnowledgeIgnoreRules(rules: rules)
    }

    /// Combine the built-in defaults with the folder's own `.gitignore`
    /// (defaults first, so the folder file can re-include via `!`). Returns
    /// the defaults alone when no `.gitignore` is present.
    public static func forFolder(_ folderURL: URL) -> KnowledgeIgnoreRules {
        var combined = defaults.rules
        let gitignoreURL = folderURL.appendingPathComponent(".gitignore")
        if let text = try? String(contentsOf: gitignoreURL, encoding: .utf8) {
            combined.append(contentsOf: parse(text).rules)
        }
        return KnowledgeIgnoreRules(rules: combined)
    }

    private static func parseLine(_ raw: String) -> Rule? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

        var negated = false
        if line.hasPrefix("!") {
            negated = true
            line.removeFirst()
        }
        // An escaped leading `#`/`!` is a literal character in git.
        if line.hasPrefix("\\#") || line.hasPrefix("\\!") { line.removeFirst() }

        var dirOnly = false
        if line.hasSuffix("/") {
            dirOnly = true
            line.removeLast()
        }
        guard !line.isEmpty else { return nil }

        // A slash anywhere but the trailing position anchors the pattern to
        // the folder root; otherwise it matches by name at any depth.
        let anchored = line.hasPrefix("/") || line.contains("/")
        var core = line
        if core.hasPrefix("/") { core.removeFirst() }
        guard !core.isEmpty else { return nil }

        let bases = anchored ? [core] : ["**/" + core]
        var patterns: [String] = []
        for base in bases {
            // The entry itself (a file), unless the rule is directory-only.
            if !dirOnly { patterns.append(base) }
            // Everything under it (ignoring a dir ignores its contents).
            patterns.append(base + "/**")
        }
        return Rule(patterns: patterns, negated: negated)
    }

    // MARK: - Built-in defaults

    /// The bundled "never curated knowledge" set. Deliberately junk-only:
    /// dependency locks, minified/generated output, sourcemaps, media, and
    /// archives — NOT source code, which stays searchable. Directory names
    /// like `node_modules` are additionally pruned up front in
    /// `KnowledgeIndexService` so their subtrees aren't even enumerated.
    public static let defaults: KnowledgeIgnoreRules = parse(
        """
        # Dependency lockfiles
        *.lock
        package-lock.json
        yarn.lock
        pnpm-lock.yaml
        bun.lockb
        Cargo.lock
        Gemfile.lock
        poetry.lock
        composer.lock
        Podfile.lock
        # Minified / generated / sourcemaps
        *.min.js
        *.min.css
        *.map
        *.generated.*
        # Images and media
        *.png
        *.jpg
        *.jpeg
        *.gif
        *.svg
        *.ico
        *.webp
        *.mp4
        *.mov
        *.mp3
        *.wav
        # Archives and binaries
        *.zip
        *.tar
        *.gz
        *.tgz
        *.wasm
        # OS / editor noise
        .DS_Store
        Thumbs.db
        """
    )
}
