//
//  OAuthFormEncoding.swift
//  osaurus
//
//  Shared `application/x-www-form-urlencoded` body builder for OAuth token requests.
//
//  Sorts the output for deterministic test fixtures and percent-encodes per
//  RFC 6749 §A.* (excluding the `&`, `=`, and `+` reserved characters).
//

import Foundation

public enum OAuthFormEncoding {
    public static func encode(_ values: [String: String]) -> String {
        values
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .sorted()
            .joined(separator: "&")
    }

    public static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
