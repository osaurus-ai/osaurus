//
//  ThemeShareService.swift
//  osaurus
//
//  High-level orchestration for sharing and importing themes via
//  themes.osaurus.ai. Combines a canonical encoder, the master-key
//  EIP-191 signer, and ThemeConfigurationStore.importTheme to keep
//  ThemesView and the deeplink router free of crypto/network details.
//

import CryptoKit
import Foundation
import LocalAuthentication

// MARK: - Public types

/// What the share UI needs to render after a successful upload.
public struct ThemeShareOutcome: Sendable {
    public let hash: String
    public let serverURL: URL
    public let deepLinkURL: URL
}

public enum ThemeShareError: LocalizedError, Sendable {
    case noMasterKey
    case bodyTooLarge(Int)
    case decodeFailed
    case writeFailed
    case invalidIdentifier
    case identity(OsaurusIdentityError)
    case api(ThemesAPIError)

    public var errorDescription: String? {
        switch self {
        case .noMasterKey:
            return "No Osaurus identity is set up yet. Create one in Identity settings before sharing themes."
        case .bodyTooLarge(let size):
            let mb = Double(size) / (1024 * 1024)
            return String(
                format: "Theme is too large to share (%.2f MB, limit 5 MB). Try a smaller background image.",
                mb
            )
        case .decodeFailed:
            return "Downloaded theme could not be decoded."
        case .writeFailed:
            return "Failed to save the imported theme."
        case .invalidIdentifier:
            return "Not a valid theme ID. Paste a 64-character hex hash or an osaurus://themes-install link."
        case .identity(let err):
            return err.errorDescription
        case .api(let err):
            return err.errorDescription
        }
    }

    /// Optional technical detail to surface as a quiet footnote in the UI.
    /// Lets us show e.g. `metadata_write_failed (HTTP 503)` without
    /// drowning the main "Themes server is temporarily unavailable" line.
    public var diagnosticHint: String? {
        switch self {
        case .api(let err):
            return err.diagnosticHint
        case .noMasterKey, .bodyTooLarge, .decodeFailed, .writeFailed,
            .invalidIdentifier, .identity:
            return nil
        }
    }
}

// MARK: - Service

@MainActor
public final class ThemeShareService {

    public static let shared = ThemeShareService()

    /// Deep link constants. Mirrors `osaurus://plugins-install?tool=…`.
    public nonisolated static let deepLinkScheme = "osaurus"
    public nonisolated static let deepLinkHost = "themes-install"
    public nonisolated static let deepLinkHashParam = "hash"

    private let api: ThemesAPIClient

    public init(api: ThemesAPIClient = .shared) {
        self.api = api
    }

    // MARK: - Share

    /// Encode `theme`, sign with the master key, and POST to the themes
    /// server. Triggers one biometric prompt to read the master key.
    public func share(_ theme: CustomTheme) async throws -> ThemeShareOutcome {
        let body = try Self.canonicalEncode(theme)
        guard body.count <= ThemesAPIClient.maxBodyBytes else {
            throw ThemeShareError.bodyTooLarge(body.count)
        }
        let bodyHash = Self.sha256Hex(body)

        // Read the master key once. The address-derived from the same key
        // is what the server records as `owner`, so we keep them consistent
        // by deriving both from the same bytes.
        guard MasterKey.exists() else {
            throw ThemeShareError.noMasterKey
        }
        let context = OsaurusIdentityContext.biometric()
        var privateKey: Data
        do {
            privateKey = try MasterKey.getPrivateKey(context: context)
        } catch let error as OsaurusIdentityError {
            throw ThemeShareError.identity(error)
        } catch {
            throw ThemeShareError.identity(.keychainReadFailed)
        }
        defer { privateKey.zeroOut() }

        let address: String
        do {
            address = try deriveOsaurusId(from: privateKey).lowercased()
        } catch let error as OsaurusIdentityError {
            throw ThemeShareError.identity(error)
        } catch {
            throw ThemeShareError.identity(.signingFailed)
        }

        let nonce: String
        do {
            nonce = try await api.requestNonce(address: address)
        } catch let error as ThemesAPIError {
            throw ThemeShareError.api(error)
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let message = "osaurus-theme:\(address):\(bodyHash):\(nonce):\(timestamp)"
        let signature: String
        do {
            let sigBytes = try signEIP191Message(message, privateKey: privateKey)
            signature = "0x" + sigBytes.hexEncodedString
        } catch let error as OsaurusIdentityError {
            throw ThemeShareError.identity(error)
        } catch {
            throw ThemeShareError.identity(.signingFailed)
        }

        let result: ThemesShareResult
        do {
            result = try await api.uploadTheme(
                body: body,
                address: address,
                nonce: nonce,
                timestamp: timestamp,
                signature: signature
            )
        } catch let error as ThemesAPIError {
            throw ThemeShareError.api(error)
        }

        let deepLink = Self.deepLink(for: result.hash)
        return ThemeShareOutcome(
            hash: result.hash,
            serverURL: result.url,
            deepLinkURL: deepLink
        )
    }

    // MARK: - Install

    /// Download a theme by hash (or paste of a deep link / web URL),
    /// import it via `ThemeConfigurationStore` so it gets a fresh local UUID.
    @discardableResult
    public func install(hashOrLink rawInput: String) async throws -> CustomTheme {
        guard let hash = Self.parseHash(from: rawInput) else {
            throw ThemeShareError.invalidIdentifier
        }

        let data: Data
        do {
            data = try await api.downloadTheme(hash: hash)
        } catch let error as ThemesAPIError {
            throw ThemeShareError.api(error)
        }

        // Decode first so we surface a friendly error on garbage payloads
        // before touching the filesystem.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard (try? decoder.decode(CustomTheme.self, from: data)) != nil else {
            throw ThemeShareError.decodeFailed
        }

        // ThemeConfigurationStore.importTheme handles the UUID rebase and
        // active-state side effects. Round-trip through a temp file so we
        // reuse exactly that code path.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-share-\(UUID().uuidString).json")
        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            throw ThemeShareError.writeFailed
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            let serverURL = await api.themeURL(hash: hash)
            let imported = try ThemeConfigurationStore.importTheme(
                from: tempURL,
                libraryInfo: ThemeLibraryInfo(
                    source: .shared,
                    importedAt: Date(),
                    remoteHash: hash,
                    remoteURL: serverURL.absoluteString,
                    sourceDetail: "Import by ID"
                )
            )
            ThemeManager.shared.refreshInstalledThemes()
            return imported
        } catch {
            throw ThemeShareError.writeFailed
        }
    }

    // MARK: - Helpers

    /// Build the Osaurus deep link for a content hash.
    public nonisolated static func deepLink(for hash: String) -> URL {
        var components = URLComponents()
        components.scheme = deepLinkScheme
        components.host = deepLinkHost
        components.queryItems = [URLQueryItem(name: deepLinkHashParam, value: hash)]
        // safe: scheme + host + a single ASCII-hex query param always make a valid URL
        return components.url ?? URL(string: "\(deepLinkScheme)://\(deepLinkHost)?\(deepLinkHashParam)=\(hash)")!
    }

    /// Accepts a 64-char hex hash, an `osaurus://themes-install?hash=…` deep
    /// link, or the public web URL `https://themes.osaurus.ai/themes/<hash>`.
    public nonisolated static func parseHash(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isValidHash(trimmed) {
            return trimmed.lowercased()
        }

        guard let url = URL(string: trimmed),
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let scheme = url.scheme?.lowercased()

        if scheme == deepLinkScheme, url.host?.lowercased() == deepLinkHost {
            if let value = comps.queryItems?
                .first(where: { $0.name.lowercased() == deepLinkHashParam })?.value,
                isValidHash(value)
            {
                return value.lowercased()
            }
            return nil
        }

        if scheme == "https" || scheme == "http" {
            // Last path component should be the hash.
            let candidate = url.lastPathComponent
            if isValidHash(candidate) {
                return candidate.lowercased()
            }
        }

        return nil
    }

    public nonisolated static func isValidHash(_ candidate: String) -> Bool {
        guard candidate.count == 64 else { return false }
        return candidate.allSatisfy { $0.isHexDigit }
    }

    /// Stable JSON encoding for hashing/deduplication. Strips per-import
    /// fields so the same look from different installations produces the
    /// same SHA-256.
    public nonisolated static func canonicalEncode(_ theme: CustomTheme) throws -> Data {
        var canonical = theme
        canonical.metadata.id = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )
        canonical.metadata.createdAt = Date(timeIntervalSince1970: 0)
        canonical.metadata.updatedAt = Date(timeIntervalSince1970: 0)
        canonical.isBuiltIn = false
        canonical.library = nil

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(canonical)
    }

    private nonisolated static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
