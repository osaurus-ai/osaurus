//
//  WorkflowArtifact.swift
//  osaurus
//
//  A file a workflow run hands the person: an output field marked
//  `"format": "file"` in the workflow's output schema, a file a step
//  shared with `share_artifact`, or an image or video a media step made.
//  The run tab shows each as a file card (media in a gallery), and a chat
//  that called the workflow gets it as an attachment.
//

import Foundation

public struct WorkflowArtifact: Codable, Sendable, Equatable, Identifiable {
    public enum Source: String, Codable, Sendable {
        /// A `format: "file"` field of the run's output, shown where it is.
        case output
        /// A step's `share_artifact`, copied into the run's files.
        case shared
        /// An image or video a media step made, saved in the run's files.
        case generated
    }

    public var id: String
    public var source: Source
    /// The output field, for `.output`.
    public var field: String?
    /// The step that shared or made it, for `.shared` and `.generated`.
    public var nodeID: String?
    public var filename: String
    public var mimeType: String
    /// Host path; empty when `problem` is set.
    public var path: String
    public var fileSize: Int
    public var isDirectory: Bool
    public var description: String?
    /// Why the file cannot be shown: missing, or outside the run's folders.
    public var problem: String?
    /// For `.generated`: the settings that made it (prompt, model, seed,
    /// steps, guidance, size, ...), so it can be reproduced.
    public var metadata: [String: JSONValue]?

    public init(
        id: String = UUID().uuidString, source: Source, field: String? = nil, nodeID: String? = nil,
        filename: String, mimeType: String? = nil, path: String, fileSize: Int = 0, isDirectory: Bool = false,
        description: String? = nil, problem: String? = nil, metadata: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.source = source
        self.field = field
        self.nodeID = nodeID
        self.filename = filename
        self.mimeType = mimeType ?? (isDirectory ? "inode/directory" : SharedArtifact.mimeType(from: filename))
        self.path = path
        self.fileSize = fileSize
        self.isDirectory = isDirectory
        self.description = description
        self.problem = problem
        self.metadata = metadata
    }

    public var isAvailable: Bool { problem == nil && !path.isEmpty }

    public var isImage: Bool { mimeType.hasPrefix("image/") }
    public var isVideo: Bool { mimeType.hasPrefix("video/") }
    public var isMedia: Bool { !isDirectory && (isImage || isVideo) }

    /// The same file as a chat artifact, for its type helpers.
    public var shared: SharedArtifact {
        SharedArtifact(
            id: id, contextId: "", contextType: .chat, filename: filename, mimeType: mimeType, fileSize: fileSize,
            hostPath: path, isDirectory: isDirectory, description: description)
    }

    enum CodingKeys: String, CodingKey {
        case id, source, field
        case nodeID = "node_id"
        case filename
        case mimeType = "mime_type"
        case path
        case fileSize = "file_size"
        case isDirectory = "is_directory"
        case description, problem, metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decode(Source.self, forKey: .source)
        field = try c.decodeIfPresent(String.self, forKey: .field)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID)
        filename = try c.decode(String.self, forKey: .filename)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? SharedArtifact.mimeType(from: filename)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        fileSize = try c.decodeIfPresent(Int.self, forKey: .fileSize) ?? 0
        isDirectory = try c.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
        description = try c.decodeIfPresent(String.self, forKey: .description)
        problem = try c.decodeIfPresent(String.self, forKey: .problem)
        metadata = try c.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
    }
}
