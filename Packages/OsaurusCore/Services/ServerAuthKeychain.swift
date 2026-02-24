//
//  ServerAuthKeychain.swift
//  osaurus
//
//  Secure Keychain storage for the HTTP server authentication token.
//  Generates a random bearer token on first use and stores it in the Keychain.
//

import Foundation
import Security

/// Keychain wrapper for the HTTP server bearer token
public enum ServerAuthKeychain {
    private static let service = "ai.osaurus.server"
    private static let account = "server-auth-token"

    /// Retrieve the server auth token, generating one if it doesn't exist.
    /// - Returns: The bearer token string
    public static func getOrCreateToken() -> String {
        if let existing = getToken() {
            return existing
        }
        let token = generateToken()
        saveToken(token)
        return token
    }

    /// Retrieve the current server auth token.
    /// - Returns: The token if it exists, nil otherwise
    public static func getToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    /// Regenerate the server auth token.
    /// - Returns: The new token
    @discardableResult
    public static func regenerateToken() -> String {
        deleteToken()
        let token = generateToken()
        saveToken(token)
        return token
    }

    /// Delete the stored token.
    public static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Private

    private static func saveToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    /// Generate a cryptographically random 32-byte token encoded as URL-safe base64.
    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
