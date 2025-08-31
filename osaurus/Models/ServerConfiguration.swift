//
//  ServerConfiguration.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation

/// Configuration settings for the server
public struct ServerConfiguration: Codable, Equatable {
    /// Server port (1-65535)
    public var port: Int
    
    /// Expose the server to the local network (0.0.0.0) or keep it on localhost (127.0.0.1)
    public var exposeToNetwork: Bool
    
    /// Number of threads for the event loop group
    public let numberOfThreads: Int
    
    /// Server backlog size
    public let backlog: Int32
    
    // MARK: - Generation Settings (UI adjustable)
    /// Default top-p sampling for generation (can be overridden per request)
    public var genTopP: Float
    /// KV cache quantization bits (nil to disable)
    public var genKVBits: Int?
    /// KV cache quantization group size
    public var genKVGroupSize: Int
    /// Token offset to begin quantizing KV cache
    public var genQuantizedKVStart: Int
    /// Maximum KV cache size (tokens); nil for unlimited
    public var genMaxKVSize: Int?
    /// Prefill step size (tokens per prefill chunk)
    public var genPrefillStepSize: Int
    
    private enum CodingKeys: String, CodingKey {
        case port
        case exposeToNetwork
        case numberOfThreads
        case backlog
        case genTopP
        case genKVBits
        case genKVGroupSize
        case genQuantizedKVStart
        case genMaxKVSize
        case genPrefillStepSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerConfiguration.default
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        self.exposeToNetwork = try container.decodeIfPresent(Bool.self, forKey: .exposeToNetwork) ?? defaults.exposeToNetwork
        self.numberOfThreads = try container.decodeIfPresent(Int.self, forKey: .numberOfThreads) ?? defaults.numberOfThreads
        self.backlog = try container.decodeIfPresent(Int32.self, forKey: .backlog) ?? defaults.backlog
        self.genTopP = try container.decodeIfPresent(Float.self, forKey: .genTopP) ?? defaults.genTopP
        self.genKVBits = try container.decodeIfPresent(Int.self, forKey: .genKVBits)
        self.genKVGroupSize = try container.decodeIfPresent(Int.self, forKey: .genKVGroupSize) ?? defaults.genKVGroupSize
        self.genQuantizedKVStart = try container.decodeIfPresent(Int.self, forKey: .genQuantizedKVStart) ?? defaults.genQuantizedKVStart
        self.genMaxKVSize = try container.decodeIfPresent(Int.self, forKey: .genMaxKVSize)
        self.genPrefillStepSize = try container.decodeIfPresent(Int.self, forKey: .genPrefillStepSize) ?? defaults.genPrefillStepSize
    }

    public init(
        port: Int,
        exposeToNetwork: Bool,
        numberOfThreads: Int,
        backlog: Int32,
        genTopP: Float,
        genKVBits: Int?,
        genKVGroupSize: Int,
        genQuantizedKVStart: Int,
        genMaxKVSize: Int?,
        genPrefillStepSize: Int
    ) {
        self.port = port
        self.exposeToNetwork = exposeToNetwork
        self.numberOfThreads = numberOfThreads
        self.backlog = backlog
        self.genTopP = genTopP
        self.genKVBits = genKVBits
        self.genKVGroupSize = genKVGroupSize
        self.genQuantizedKVStart = genQuantizedKVStart
        self.genMaxKVSize = genMaxKVSize
        self.genPrefillStepSize = genPrefillStepSize
    }
    
    /// Default configuration
    public static var `default`: ServerConfiguration {
        ServerConfiguration(
            port: 8080,
            exposeToNetwork: false, // Default to false (localhost)
            numberOfThreads: ProcessInfo.processInfo.activeProcessorCount,
            backlog: 256,
            genTopP: 0.95,
            genKVBits: 4,
            genKVGroupSize: 64,
            genQuantizedKVStart: 0,
            genMaxKVSize: nil,
            genPrefillStepSize: 4096
        )
    }
    
    /// Validates if the port is in valid range
    public var isValidPort: Bool {
        (1..<65536).contains(port)
    }
}
