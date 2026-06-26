//
//  ImageAPI.swift
//  osaurus
//
//  HTTP DTOs for the OpenAI-compatible `/v1/images/*` surface. The route
//  shapes follow `OSAURUS_IMAGE_OPENAPI.json` from vmlx-swift. Request DTOs
//  decode the wire body; response/event DTOs encode it. The handlers in
//  `HTTPHandler` translate between these and `ImageGenerationService`'s
//  osaurus-native types.
//

import Foundation

// MARK: - Requests

struct ImageGenerationRequestDTO: Decodable {
    /// Optional: when omitted/empty the handler falls back to the configured
    /// `defaultImageGenerationModelId` (Settings → Agent Delegation), matching
    /// the agent `image` tool's default-resolution behavior.
    let model: String?
    let prompt: String
    let negative_prompt: String?
    let n: Int?
    let size: String?
    let width: Int?
    let height: Int?
    let steps: Int?
    let guidance: Double?
    let seed: UInt64?
    let response_format: String?  // "url" | "b64_json"
    let output_format: String?  // "png" | "jpeg" | "webp"
    let stream: Bool?
}

struct ImageEditRequestDTO: Decodable {
    /// Optional: when omitted/empty the handler falls back to the configured
    /// `defaultImageEditModelId` (Settings → Agent Delegation), matching the
    /// agent `image` tool's (edit mode) default-resolution behavior.
    let model: String?
    let prompt: String
    let image: String?
    let images: [String]?
    let mask: String?
    let strength: Double?
    let negative_prompt: String?
    let size: String?
    let width: Int?
    let height: Int?
    let steps: Int?
    let guidance: Double?
    let seed: UInt64?
    let response_format: String?
    let output_format: String?
    let stream: Bool?
}

struct ImageUpscaleRequestDTO: Decodable {
    let model: String
    let image: String
    let scale: Int?
    let steps: Int?
    let seed: UInt64?
    let response_format: String?
    let output_format: String?
    let stream: Bool?
}

struct ImageCancelRequestDTO: Decodable {
    let job_id: String
}

// MARK: - Models list

struct ImageCapabilitiesDTO: Encodable {
    let text_to_image: Bool
    let image_edit: Bool
    let upscale: Bool
    let negative_prompt: Bool
    let mask: Bool
    let multiple_source_images: Bool
    let lora: Bool
}

struct ImageDefaultsDTO: Encodable {
    let steps: Int?
    let guidance: Double?
}

struct ImageLimitsDTO: Encodable {
    let min_steps: Int
    let max_steps: Int
    let size_multiple: Int
    let max_pixels: Int
    let supported_sizes: [String]
}

struct ImageModelDTO: Encodable {
    let id: String
    let object: String
    let display_name: String
    let kind: String
    let ready: Bool
    let quantization_bits: Int?
    let capabilities: ImageCapabilitiesDTO
    let defaults: ImageDefaultsDTO
    let limits: ImageLimitsDTO
    let blocked_reasons: [String]
}

struct ImageModelsResponseDTO: Encodable {
    let object: String
    let data: [ImageModelDTO]
}

// MARK: - Non-streaming result

struct ImageResultDTO: Encodable {
    let url: String?
    let b64_json: String?
    let seed: UInt64
}

struct ImagesResponseDTO: Encodable {
    let created: Int
    let data: [ImageResultDTO]
}

// MARK: - Streaming (SSE) event

/// One SSE `data:` payload. A single struct with optional fields — the
/// synthesized encoder omits nil keys, so each event type only carries the
/// fields the spec lists for it (`queued`, `loading_model`, `step`,
/// `preview`, `completed`, `error`, `cancelled`).
struct ImageStreamEventDTO: Encodable {
    let type: String
    var job_id: String? = nil
    var model: String? = nil
    var step: Int? = nil
    var total: Int? = nil
    var progress: Double? = nil
    var eta_seconds: Double? = nil
    var image: String? = nil
    var images: [ImageResultDTO]? = nil
    var message: String? = nil
    var hf_auth: Bool? = nil
}
