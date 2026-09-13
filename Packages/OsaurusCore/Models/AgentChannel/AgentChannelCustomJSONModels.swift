//
//  AgentChannelCustomJSONModels.swift
//  osaurus
//
//  Safety and mapping options for configuration-only custom JSON channels.
//

import Foundation

struct AgentChannelCustomHTTPResponseMapping: Codable, Equatable, Sendable {
    static let maxPathLength = 160
    static let maxPathSegments = 12
    static let maxArrayIndex = 1_000

    var itemsPath: String?
    var idPath: String?
    var namePath: String?
    var roomIdPath: String?
    var threadIdPath: String?
    var contentPath: String?
    var authorIdPath: String?
    var authorNamePath: String?
    var timestampPath: String?
    var cursorPath: String?

    init(
        itemsPath: String? = nil,
        idPath: String? = nil,
        namePath: String? = nil,
        roomIdPath: String? = nil,
        threadIdPath: String? = nil,
        contentPath: String? = nil,
        authorIdPath: String? = nil,
        authorNamePath: String? = nil,
        timestampPath: String? = nil,
        cursorPath: String? = nil
    ) {
        self.itemsPath = Self.trimmed(itemsPath)
        self.idPath = Self.trimmed(idPath)
        self.namePath = Self.trimmed(namePath)
        self.roomIdPath = Self.trimmed(roomIdPath)
        self.threadIdPath = Self.trimmed(threadIdPath)
        self.contentPath = Self.trimmed(contentPath)
        self.authorIdPath = Self.trimmed(authorIdPath)
        self.authorNamePath = Self.trimmed(authorNamePath)
        self.timestampPath = Self.trimmed(timestampPath)
        self.cursorPath = Self.trimmed(cursorPath)
    }

    var normalized: AgentChannelCustomHTTPResponseMapping {
        AgentChannelCustomHTTPResponseMapping(
            itemsPath: itemsPath,
            idPath: idPath,
            namePath: namePath,
            roomIdPath: roomIdPath,
            threadIdPath: threadIdPath,
            contentPath: contentPath,
            authorIdPath: authorIdPath,
            authorNamePath: authorNamePath,
            timestampPath: timestampPath,
            cursorPath: cursorPath
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var allConfiguredPaths: [String] {
        [
            itemsPath,
            idPath,
            namePath,
            roomIdPath,
            threadIdPath,
            contentPath,
            authorIdPath,
            authorNamePath,
            timestampPath,
            cursorPath,
        ].compactMap { $0 }
    }

    static func validatePath(_ path: String) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.utf8.count <= maxPathLength else {
            throw AgentChannelCustomJSONRunnerError.invalidResponse(
                "Response mapping path is too long.",
                partialWriteStatus: nil
            )
        }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
            !trimmed.contains("{{"),
            !trimmed.contains("}}"),
            !trimmed.contains("["),
            !trimmed.contains("]"),
            !trimmed.contains("*")
        else {
            throw AgentChannelCustomJSONRunnerError.invalidResponse(
                "Response mapping path `\(trimmed)` contains unsupported characters.",
                partialWriteStatus: nil
            )
        }

        let withoutRoot: String
        if trimmed == "$" {
            return
        } else if trimmed.hasPrefix("$.") {
            withoutRoot = String(trimmed.dropFirst(2))
        } else {
            withoutRoot = trimmed
        }

        let segments = withoutRoot.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty,
            segments.count <= maxPathSegments,
            segments.allSatisfy({ !$0.isEmpty })
        else {
            throw AgentChannelCustomJSONRunnerError.invalidResponse(
                "Response mapping path `\(trimmed)` exceeds supported depth or has empty segments.",
                partialWriteStatus: nil
            )
        }

        for segment in segments {
            if segment.allSatisfy(\.isNumber) {
                guard let index = Int(segment), index <= maxArrayIndex else {
                    throw AgentChannelCustomJSONRunnerError.invalidResponse(
                        "Response mapping path `\(trimmed)` has an array index outside the supported range.",
                        partialWriteStatus: nil
                    )
                }
                continue
            }
            guard segment.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                throw AgentChannelCustomJSONRunnerError.invalidResponse(
                    "Response mapping path `\(trimmed)` contains unsupported segment `\(segment)`.",
                    partialWriteStatus: nil
                )
            }
        }
    }
}
/// Optional HMAC over the rendered request body, attached as a header so the
/// receiver (an n8n Webhook trigger, for example) can verify the payload came
/// from this Osaurus connection. The secret is resolved from the connection's
/// `secrets` by name at request time and is never rendered into the body.
struct AgentChannelCustomHTTPBodySignature: Codable, Equatable, Sendable {
    static let defaultHeader = "X-Osaurus-Channel-Signature"
    static let defaultPrefix = "sha256="
    static let hmacSHA256 = "hmac_sha256"

    var header: String
    var secretName: String
    var algorithm: String
    var prefix: String

    init(
        header: String = AgentChannelCustomHTTPBodySignature.defaultHeader,
        secretName: String,
        algorithm: String = AgentChannelCustomHTTPBodySignature.hmacSHA256,
        prefix: String = AgentChannelCustomHTTPBodySignature.defaultPrefix
    ) {
        let trimmedHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
        self.header = trimmedHeader.isEmpty ? Self.defaultHeader : trimmedHeader
        self.secretName = secretName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlgorithm = algorithm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.algorithm = trimmedAlgorithm.isEmpty ? Self.hmacSHA256 : trimmedAlgorithm
        self.prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            header: try container.decodeIfPresent(String.self, forKey: .header) ?? Self.defaultHeader,
            secretName: try container.decode(String.self, forKey: .secretName),
            algorithm: try container.decodeIfPresent(String.self, forKey: .algorithm) ?? Self.hmacSHA256,
            prefix: try container.decodeIfPresent(String.self, forKey: .prefix) ?? Self.defaultPrefix
        )
    }

    var normalized: AgentChannelCustomHTTPBodySignature {
        AgentChannelCustomHTTPBodySignature(
            header: header,
            secretName: secretName,
            algorithm: algorithm,
            prefix: prefix
        )
    }
}

struct AgentChannelCustomHTTPIdempotency: Codable, Equatable, Sendable {
    var header: String?
    var keyTemplate: String?
    var responseIdPath: String?

    init(
        header: String? = "Idempotency-Key",
        keyTemplate: String? = nil,
        responseIdPath: String? = nil
    ) {
        self.header = Self.trimmed(header)
        self.keyTemplate = Self.trimmed(keyTemplate)
        self.responseIdPath = Self.trimmed(responseIdPath)
    }

    var normalized: AgentChannelCustomHTTPIdempotency {
        AgentChannelCustomHTTPIdempotency(
            header: header,
            keyTemplate: keyTemplate,
            responseIdPath: responseIdPath
        )
    }

    var configuredResponsePaths: [String] {
        [responseIdPath].compactMap { $0 }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
