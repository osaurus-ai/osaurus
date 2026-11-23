//
//  CLIAccessStore.swift
//  osaurus
//
//  Approvals for the `osaurus` command-line tool. When loopback trust is off
//  (Expose to Network) or a route needs a key (Require Access Key for Local
//  Admin Routes), the CLI asks once; the owner clicks Allow on this Mac and
//  the CLI keeps the token it gets back. Only SHA-256 hashes are stored here.
//

import CryptoKit
import Foundation
import os

extension Notification.Name {
    /// Posted on the main queue after a CLI approval is added or revoked.
    static let cliAccessChanged = Notification.Name("ai.osaurus.cliAccess.changed")
}

/// Lock-based rather than an actor because the HTTP auth gate runs
/// synchronously on the event loop.
final class CLIAccessStore: @unchecked Sendable {
    static let shared = CLIAccessStore(fileURL: nil)

    /// Header the CLI presents the token on. The CLI's copy of this literal
    /// lives in `LocalServerClient`.
    static let headerName = "X-Osaurus-CLI-Token"
    static let tokenPrefix = "osc_"
    /// Oldest approvals are dropped past this, so a loop of approvals
    /// cannot grow the file without bound.
    static let maxApprovals = 16
    /// After Don't Allow, new requests are refused for this long so a
    /// script cannot re-raise the prompt in a loop.
    static let denyCooldown: TimeInterval = 30

    struct Approval: Codable, Equatable, Sendable {
        let hash: String
        let createdAt: Date
        /// What the CLI said it was running when it asked (untrusted, shown
        /// only as a hint).
        let label: String
    }

    private struct File: Codable {
        var approvals: [Approval]
    }

    enum Admission: Equatable {
        case open
        case promptAlreadyOpen
        case coolingDown(retryAfter: TimeInterval)
    }

    private let lock = NSLock()
    private let explicitFileURL: URL?
    private var loaded = false
    private var approvals: [Approval] = []
    private var promptOpen = false
    private var deniedAt: Date?

    private static let log = Logger(subsystem: "com.dinoki.osaurus", category: "CLIAccess")

    /// `fileURL` nil resolves `~/.osaurus/config/cli-access.json` on first
    /// use, so a test root set after launch is honored.
    init(fileURL: URL?) {
        explicitFileURL = fileURL
    }

    private var fileURL: URL {
        explicitFileURL ?? OsaurusPaths.config().appendingPathComponent("cli-access.json")
    }

    // MARK: - Tokens

    /// Mints a token, stores its hash, and returns the only plain copy.
    func mint(label: String, now: Date = Date()) -> String {
        let token = Self.makeToken()
        lock.lock()
        loadIfNeeded()
        approvals.append(Approval(hash: Self.hash(token), createdAt: now, label: Self.sanitizedLabel(label)))
        if approvals.count > Self.maxApprovals {
            approvals.removeFirst(approvals.count - Self.maxApprovals)
        }
        persist()
        lock.unlock()
        Self.log.info("CLI access approved")
        notifyChanged()
        return token
    }

    func isValid(_ token: String?) -> Bool {
        guard let token, token.hasPrefix(Self.tokenPrefix), token.utf8.count < 256 else { return false }
        let presented = Array(Self.hash(token).utf8)
        lock.lock()
        loadIfNeeded()
        let hashes = approvals.map { Array($0.hash.utf8) }
        lock.unlock()
        var match = false
        for stored in hashes where stored.count == presented.count {
            var diff: UInt8 = 0
            for index in stored.indices { diff |= stored[index] ^ presented[index] }
            if diff == 0 { match = true }
        }
        return match
    }

    func list() -> [Approval] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return approvals
    }

    /// Settings → Server → Command-Line Tool Access → Revoke.
    func revokeAll() {
        lock.lock()
        loadIfNeeded()
        approvals.removeAll()
        persist()
        lock.unlock()
        Self.log.info("CLI access revoked")
        notifyChanged()
    }

    // MARK: - Prompt admission

    /// One prompt at a time, and none during the cooldown after Don't Allow.
    func beginPrompt(now: Date = Date()) -> Admission {
        lock.lock()
        defer { lock.unlock() }
        if promptOpen { return .promptAlreadyOpen }
        if let deniedAt {
            let remaining = Self.denyCooldown - now.timeIntervalSince(deniedAt)
            if remaining > 0 { return .coolingDown(retryAfter: remaining.rounded(.up)) }
        }
        promptOpen = true
        return .open
    }

    func endPrompt(denied: Bool, now: Date = Date()) {
        lock.lock()
        promptOpen = false
        if denied { deniedAt = now }
        lock.unlock()
    }

    // MARK: - Private

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        approvals = (try? decoder.decode(File.self, from: data))?.approvals ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(File(approvals: approvals)) else { return }
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Self.log.error("Could not save CLI approvals: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .cliAccessChanged, object: nil)
        }
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Keeps the label printable and short; it comes from the requester.
    static func sanitizedLabel(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_./:"))
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { allowed.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(48))
    }

    /// 32 bytes of CSPRNG output, URL-safe.
    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0 ... 255) }
        }
        return tokenPrefix
            + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
