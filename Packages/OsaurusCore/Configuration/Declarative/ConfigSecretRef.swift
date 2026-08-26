//
//  ConfigSecretRef.swift
//  osaurus
//
//  Phase 4 — secrets by reference. A `*_ref` document value names WHERE a
//  credential can be read at apply time; the credential itself never
//  appears in a document, a plan, or an apply result. Two sources:
//
//    env:VAR_NAME                 the app process environment
//    keychain:SERVICE/ACCOUNT     a generic password in the login Keychain
//                                 (create with: security add-generic-password
//                                  -s SERVICE -a ACCOUNT -w)
//
//  Refs are write-only request values: the exporter never emits them, and
//  re-applying the same ref is an idempotent overwrite of the stored copy.
//

import Foundation

public struct ConfigSecretRef: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case env(String)
        case keychain(service: String, account: String)
    }

    public let source: Source

    /// Safe to show in plans and results — names the source, never the value.
    public var display: String {
        switch source {
        case .env(let name): return "env:\(name)"
        case .keychain(let service, let account): return "keychain:\(service)/\(account)"
        }
    }

    /// Test seam: planner/applier env lookups read this map when set, so
    /// suites don't depend on `setenv` racing `ProcessInfo` snapshots.
    nonisolated(unsafe) public static var environmentOverrideForTests: [String: String]?

    /// Parse outcome: the ref, or the validation message for the planner.
    public enum ParseOutcome: Equatable, Sendable {
        case success(ConfigSecretRef)
        case failure(String)
    }

    /// Parse the ref grammar; failure returns the validation message.
    public static func parse(_ raw: String) -> ParseOutcome {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = trimmed.removingPrefix("env:") {
            guard isValidEnvName(name) else {
                return .failure(
                    "`\(raw)` is not a valid env reference — expected env:VAR_NAME "
                        + "(letters, digits, underscore).")
            }
            return .success(ConfigSecretRef(source: .env(name)))
        }
        if let rest = trimmed.removingPrefix("keychain:") {
            guard let slash = rest.firstIndex(of: "/") else {
                return .failure(
                    "`\(raw)` is not a valid keychain reference — expected "
                        + "keychain:SERVICE/ACCOUNT.")
            }
            let service = String(rest[..<slash])
            let account = String(rest[rest.index(after: slash)...])
            guard !service.isEmpty, !account.isEmpty else {
                return .failure(
                    "`\(raw)` is not a valid keychain reference — SERVICE and ACCOUNT "
                        + "must both be non-empty.")
            }
            return .success(ConfigSecretRef(source: .keychain(service: service, account: account)))
        }
        return .failure(
            "`\(raw)` is not a secret reference — expected env:VAR_NAME or "
                + "keychain:SERVICE/ACCOUNT (secrets themselves never go in the document).")
    }

    /// Read the referenced secret. `nil` means missing or empty — callers
    /// report the failure by `display`, never by value. `environment` is a
    /// test seam; production callers pass nothing.
    public func resolve(environment: [String: String]? = nil) -> String? {
        switch source {
        case .env(let name):
            let environment =
                environment
                ?? Self.environmentOverrideForTests
                ?? ProcessInfo.processInfo.environment
            let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        case .keychain(let service, let account):
            guard let data = Keychain.read(service: service, account: account),
                let value = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else { return nil }
            return value
        }
    }

    /// Env refs are checked for presence at plan time (cheap and prompt-free);
    /// keychain refs are only format-checked — reading the Keychain can show
    /// a macOS confirmation dialog, which planning must never trigger.
    public func planTimeIssue(label: String, environment: [String: String]? = nil) -> String? {
        switch source {
        case .env(let name):
            let environment =
                environment
                ?? Self.environmentOverrideForTests
                ?? ProcessInfo.processInfo.environment
            let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if value?.isEmpty ?? true {
                return "\(label): env var `\(name)` is not set (checked in the app process — "
                    + "launchd apps do not inherit your shell profile)."
            }
            return nil
        case .keychain:
            return nil
        }
    }
}

extension String {
    fileprivate func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

extension ConfigSecretRef {
    fileprivate static func isValidEnvName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
