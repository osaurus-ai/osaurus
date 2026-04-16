//
//  FileImportDescriptor.swift
//  osaurus
//
//  Describes a file importer and the file formats it can normalize into
//  chat-ready attachments.
//

import Foundation
import UniformTypeIdentifiers

public enum FileImportSource: String, Codable, Sendable, CaseIterable {
    case core
    case nativePlugin = "native_plugin"
    case sandboxPlugin = "sandbox_plugin"
}

public enum FileImportOutputMode: String, Codable, Sendable, CaseIterable {
    case normalizedText = "normalized_text"
    case artifactSummary = "artifact_summary"
}

public struct FileImportDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let extensions: [String]
    public let utTypes: [String]
    public let mimeTypes: [String]
    public let maxBytes: Int
    public let source: FileImportSource
    public let outputMode: FileImportOutputMode
    public let toolId: String?
    public let outputSchemaVersion: Int

    public init(
        id: String,
        extensions: [String],
        utTypes: [String] = [],
        mimeTypes: [String] = [],
        maxBytes: Int,
        source: FileImportSource,
        outputMode: FileImportOutputMode,
        toolId: String? = nil,
        outputSchemaVersion: Int = 1
    ) {
        self.id = id
        self.extensions = extensions.map { $0.lowercased() }
        self.utTypes = utTypes
        self.mimeTypes = mimeTypes
        self.maxBytes = maxBytes
        self.source = source
        self.outputMode = outputMode
        self.toolId = toolId
        self.outputSchemaVersion = outputSchemaVersion
    }

    public func matches(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, normalizedExtensions.contains(ext) {
            return true
        }

        guard !supportedUTTypes.isEmpty else { return false }

        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
            supportedUTTypes.contains(where: { contentType == $0 || contentType.conforms(to: $0) })
        {
            return true
        }

        if let inferredType = UTType(filenameExtension: ext),
            supportedUTTypes.contains(where: { inferredType == $0 || inferredType.conforms(to: $0) })
        {
            return true
        }

        return false
    }

    public var supportedUTTypes: [UTType] {
        var results: [UTType] = []
        var seen = Set<String>()

        for identifier in utTypes {
            guard let type = UTType(identifier), seen.insert(type.identifier).inserted else { continue }
            results.append(type)
        }

        for ext in extensions {
            guard let type = UTType(filenameExtension: ext), seen.insert(type.identifier).inserted else { continue }
            results.append(type)
        }

        return results
    }

    private var normalizedExtensions: Set<String> {
        Set(extensions.map { $0.lowercased() })
    }
}
