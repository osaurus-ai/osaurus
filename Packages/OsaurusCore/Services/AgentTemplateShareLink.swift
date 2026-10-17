//
//  AgentTemplateShareLink.swift
//  osaurus
//
//  `osaurus://templates-import?t=<base64url(zlib(json))>` carries a whole
//  agent template inside a link, so a template can be pasted into a chat
//  message or a web page and opened with one click. The payload is the
//  template's own JSON, compressed because system prompts make raw JSON
//  too long for comfortable links, then base64url-encoded so it survives
//  URL handling untouched. Opening the link lands on Agents → Templates
//  with the Import sheet prefilled and the usual preview / collision
//  handling; nothing is saved until the user confirms.
//

import Foundation

public enum AgentTemplateShareLink {
    public static let scheme = "osaurus"
    public static let host = "templates-import"
    static let payloadKey = "t"

    /// Links longer than this are unlikely to survive chat clients and
    /// browsers intact; callers should fall back to Copy JSON.
    public static let maxURLLength = 8000

    public enum LinkError: Error, LocalizedError, Equatable {
        case tooLarge(Int)
        case notAShareLink
        case malformedPayload
        case invalidTemplate(String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let length):
                return "This template is too large for a share link (\(length) characters). Use Copy JSON instead."
            case .notAShareLink:
                return "That link is not an Osaurus agent template link."
            case .malformedPayload:
                return "That link's template data could not be read."
            case .invalidTemplate(let detail):
                return detail
            }
        }
    }

    public static func claims(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == host
    }

    /// Builds the link, or throws when the encoded form is too long.
    public static func url(for template: AgentTemplate) throws -> URL {
        let json = try template.jsonString()
        guard let compressed = try? (Data(json.utf8) as NSData).compressed(using: .zlib) as Data else {
            throw LinkError.malformedPayload
        }
        let payload = PKCE.base64URLEncoded(compressed)
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: payloadKey, value: payload)]
        guard let url = components.url else { throw LinkError.malformedPayload }
        guard url.absoluteString.count <= maxURLLength else {
            throw LinkError.tooLarge(url.absoluteString.count)
        }
        return url
    }

    /// The template JSON carried by the link, decompressed but not yet
    /// parsed, so the Import sheet can show it in the paste field.
    public static func templateJSON(from url: URL) throws -> String {
        guard claims(url) else { throw LinkError.notAShareLink }
        guard
            let payload = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == payloadKey })?.value,
            let compressed = PKCE.decodeBase64URL(payload),
            let data = try? (compressed as NSData).decompressed(using: .zlib) as Data,
            let json = String(data: data, encoding: .utf8)
        else { throw LinkError.malformedPayload }
        return json
    }

    /// Full decode: link → validated template.
    public static func template(from url: URL) throws -> AgentTemplate {
        let json = try templateJSON(from: url)
        do {
            return try AgentTemplate.parse(json)
        } catch {
            throw LinkError.invalidTemplate(error.localizedDescription)
        }
    }
}
