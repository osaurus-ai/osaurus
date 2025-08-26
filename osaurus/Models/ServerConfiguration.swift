//
//  ServerConfiguration.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation

/// Configuration settings for the server
public struct ServerConfiguration {
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
