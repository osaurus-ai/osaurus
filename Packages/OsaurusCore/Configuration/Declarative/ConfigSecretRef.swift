//
//  ConfigSecretRef.swift
//  osaurus
//
//  Phase 4 — secrets by reference. A `*_ref` document value names WHERE a
//  credential can be read at apply time; the credential itself never
//  appears in a document, a plan, or an apply result. Three sources:
//
//    env:VAR_NAME                 the app process environment
//    keychain:SERVICE/ACCOUNT     a generic password in the login Keychain
//                                 (create with: security add-generic-password
//                                  -s SERVICE -a ACCOUNT -w)
//    credential:KEY               a key saved for all agents in the Vault
//
//  Refs are write-only request values: the exporter never emits them, and
//  re-applying the same ref is an idempotent overwrite of the stored copy.
//

import Foundation

public struct ConfigSecretRef: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case env(String)
        case keychain(service: String, account: String)
        case credential(String)
    }

    public let source: Source

    /// Safe to show in plans and results — names the source, never the value.
    public var display: String {
        switch source {
        case .env(let name): return "env:\(name)"
        case .keychain(let service, let account): return "keychain:\(service)/\(account)"
        case .credential(let key): return "credential:\(key)"
        }
    }

    /// Reading the value may touch the Keychain (resolve off the main actor).
    public var readsKeychain: Bool {
        switch source {
        case .env: return false
        case .keychain, .credential: return true
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
        if let key = trimmed.removingPrefix("credential:") {
            guard CredentialKeys.isValid(key) else {
                return .failure(
                    "`\(raw)` is not a valid credential reference — expected credential:KEY "
                        + "(letters, digits, underscore).")
            }
            return .success(ConfigSecretRef(source: .credential(key)))
        }
        return .failure(
            "`\(raw)` is not a secret reference — expected env:VAR_NAME, "
                + "keychain:SERVICE/ACCOUNT, or credential:KEY (secrets themselves never go in the document).")
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
        case .credential(let key):
            let value = CredentialResolver.value(key, agentId: nil)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
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
        case .credential(let key):
            // Index-only presence check: never reads the Keychain.
            if !CredentialStore.current.hasValue(key, scope: .global) {
                return "\(label): no key named `\(key)` is saved for all agents in the Vault."
            }
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
