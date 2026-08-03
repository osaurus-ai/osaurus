//
//  VeniceMediaClient.swift
//  osaurus
//

import Foundation

struct VeniceQueuedVideo: Codable, Sendable, Equatable {
    var model: String
    var queueID: String
    var downloadURL: URL?

    private enum CodingKeys: String, CodingKey {
        case model
        case queueID = "queue_id"
        case downloadURL = "download_url"
    }
}

enum VeniceVideoRetrieval: Sendable, Equatable {
    case processing(etaSeconds: Double?)
    case completed(URL)
    case privateDownloadReady
}

actor VeniceMediaClient {
    private let provider: RemoteProvider
    private let session: URLSession

    init(provider: RemoteProvider, session: URLSession? = nil) throws {
        guard RemoteProviderService.isVeniceProvider(provider) else {
            throw MediaGenerationError.providerUnavailable
        }
        self.provider = provider
        self.session = session ?? GlobalProxySettings.sharedSession()
    }

    func generateImage(_ request: MediaImageGenerationRequest) async throws -> [GeneratedMedia] {
        let startedAt = ContinuousClock.now
        let width = request.width.map { String($0) } ?? "nil"
        let height = request.height.map { String($0) } ?? "nil"
        let steps = request.steps.map { String($0) } ?? "nil"
        let guidance = request.guidance.map { String($0) } ?? "nil"
        debugLog(
            "[MediaGeneration] Venice image request model=\(request.target.modelID) "
                + "count=\(request.count) format=\(request.format.rawValue) "
                + "width=\(width) height=\(height) "
                + "aspectRatio=\(request.aspectRatio ?? "nil") "
                + "resolution=\(request.resolution ?? "nil") "
                + "quality=\(request.quality ?? "nil") "
                + "steps=\(steps) guidance=\(guidance) "
                + "seedSet=\(request.seed != nil)"
        )
        let body = VeniceImageRequest(
            model: request.target.modelID,
            prompt: request.prompt,
            negativePrompt: request.negativePrompt,
            width: request.width,
            height: request.height,
            steps: request.steps,
            cfgScale: request.guidance,
            seed: request.seed,
            variants: max(1, request.count),
            format: request.format.rawValue,
            aspectRatio: request.aspectRatio,
            resolution: request.resolution,
            quality: request.quality,
            returnBinary: false
        )
        let (data, http) = try await rawJSONRequest(path: "/image/generate", body: body)
        let contentType = http.value(forHTTPHeaderField: "content-type") ?? "missing"
        let elapsed = startedAt.duration(to: .now).components
        let elapsedMilliseconds =
            elapsed.seconds * 1_000
            + elapsed.attoseconds / 1_000_000_000_000_000
        debugLog(
            "[MediaGeneration] Venice image response status=\(http.statusCode) "
                + "contentType=\(contentType) bytes=\(data.count) "
                + "elapsedMs=\(elapsedMilliseconds)"
        )
        let response: VeniceImageResponse
        do {
            response = try JSONDecoder().decode(VeniceImageResponse.self, from: data)
        } catch {
            debugLog(
                "[MediaGeneration] Venice image JSON decode failed "
                    + "error=\(String(reflecting: error)) topLevelKeys=\(Self.jsonTopLevelKeys(data))"
            )
            throw MediaGenerationError.server(
                status: http.statusCode,
                message: "Venice returned image JSON in an unsupported shape."
            )
        }
        guard !response.images.isEmpty, response.images.count <= max(1, request.count) else {
            debugLog(
                "[MediaGeneration] Venice image count invalid "
                    + "received=\(response.images.count) requested=\(request.count)"
            )
            throw MediaGenerationError.server(
                status: http.statusCode,
                message: "Venice returned \(response.images.count) image variants; expected 1–\(request.count)."
            )
        }
        let trimmedResponseID = response.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID =
            trimmedResponseID?.isEmpty == false
            ? trimmedResponseID!
            : UUID().uuidString.lowercased()
        return try response.images.enumerated().map { index, encoded in
            guard let bytes = Self.decodeBase64Payload(encoded) else {
                debugLog(
                    "[MediaGeneration] Venice image base64 decode failed "
                        + "index=\(index) encodedCharacters=\(encoded.count)"
                )
                throw MediaGenerationError.server(
                    status: http.statusCode,
                    message: "Venice returned image data that could not be decoded."
                )
            }
            let detectedFormat: ImageOutputFormat
            do {
                detectedFormat = try MediaFileValidation.detectImageFormat(bytes)
            } catch {
                debugLog(
                    "[MediaGeneration] Venice image media validation failed "
                        + "index=\(index) decodedBytes=\(bytes.count) "
                        + "prefix=\(Self.hexPrefix(bytes))"
                )
                throw MediaGenerationError.server(
                    status: http.statusCode,
                    message: "Venice returned bytes that are not a supported image."
                )
            }
            if detectedFormat != request.format {
                debugLog(
                    "[MediaGeneration] Venice image format differed "
                        + "requested=\(request.format.rawValue) actual=\(detectedFormat.rawValue)"
                )
            }
            let url = try Self.persist(
                bytes,
                directory: OsaurusPaths.generatedImages(),
                extension: detectedFormat.rawValue,
                stem: "venice-\(requestID)-\(index + 1)"
            )
            return GeneratedMedia(
                url: url,
                mimeType: "image/\(detectedFormat.rawValue)",
                modelID: request.target.modelID,
                kind: .image
            )
        }
    }

    func quoteVideo(_ request: MediaVideoGenerationRequest) async throws -> MediaVideoQuote {
        let body = VeniceVideoQuoteRequest(
            model: request.target.modelID,
            duration: request.duration,
            aspectRatio: request.aspectRatio,
            resolution: request.resolution,
            audio: request.audio
        )
        let data = try await jsonRequest(path: "/video/quote", body: body)
        struct Response: Decodable { let quote: Double }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw MediaGenerationError.invalidResponse
        }
        return MediaVideoQuote(usd: response.quote)
    }

    func queueVideo(_ request: MediaVideoGenerationRequest) async throws -> VeniceQueuedVideo {
        let imageURL = request.sourceImage.map {
            let type = request.sourceImageMIMEType ?? "image/png"
            return "data:\(type);base64,\($0.base64EncodedString())"
        }
        let body = VeniceVideoQueueRequest(
            model: request.target.modelID,
            prompt: request.prompt,
            negativePrompt: request.negativePrompt,
            duration: request.duration,
            aspectRatio: request.aspectRatio,
            resolution: request.resolution,
            audio: request.audio,
            imageURL: imageURL
        )
        let data = try await jsonRequest(path: "/video/queue", body: body)
        do {
            return try JSONDecoder().decode(VeniceQueuedVideo.self, from: data)
        } catch {
            throw MediaGenerationError.invalidResponse
        }
    }

    func retrieveVideo(_ queued: VeniceQueuedVideo) async throws -> VeniceVideoRetrieval {
        struct Request: Encodable {
            let model: String
            let queue_id: String
            let delete_media_on_completion = false
        }
        let request = try await makeJSONRequest(
            path: "/video/retrieve",
            body: Request(model: queued.model, queue_id: queued.queueID)
        )
        let temporaryURL: URL
        let rawResponse: URLResponse
        do {
            (temporaryURL, rawResponse) = try await session.download(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MediaGenerationError.transport(error.localizedDescription)
        }
        guard let response = rawResponse as? HTTPURLResponse else {
            throw MediaGenerationError.invalidResponse
        }
        let contentType = (response.value(forHTTPHeaderField: "content-type") ?? "").lowercased()
        if contentType.contains("video/mp4") {
            try Self.validateDownloadedVideo(at: temporaryURL, response: response)
            return .completed(temporaryURL)
        }
        let data = try Data(contentsOf: temporaryURL)
        try Self.validate(data: data, response: response)
        struct Status: Decodable {
            let status: String
            let average_execution_time: Double?
            let execution_duration: Double?
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else {
            throw MediaGenerationError.invalidResponse
        }
        switch status.status.uppercased() {
        case "PROCESSING":
            let remainingMilliseconds = status.average_execution_time.map {
                max(0, $0 - (status.execution_duration ?? 0))
            }
            return .processing(etaSeconds: remainingMilliseconds.map { $0 / 1_000 })
        case "COMPLETED":
            return queued.downloadURL == nil ? .processing(etaSeconds: nil) : .privateDownloadReady
        default:
            throw MediaGenerationError.server(status: response.statusCode, message: status.status)
        }
    }

    func downloadPrivateVideo(from url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 300
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MediaGenerationError.invalidResponse
        }
        try Self.validateDownloadedVideo(at: temporaryURL, response: http)
        return temporaryURL
    }

    func persistCompletedVideo(
        at temporaryURL: URL,
        queued: VeniceQueuedVideo
    ) async throws -> (media: GeneratedMedia, cleanupSucceeded: Bool) {
        try MediaFileValidation.validateVideo(at: temporaryURL)
        let directory = OsaurusPaths.generatedVideos()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = MediaFileValidation.safeFileComponent(
            "venice-\(queued.queueID)",
            fallback: UUID().uuidString.lowercased()
        )
        let url = directory.appendingPathComponent("\(stem).mp4")
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: temporaryURL, to: staging)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: staging, to: url)

        let cleanupSucceeded = await cleanupVideo(queued)
        return (
            GeneratedMedia(
                url: url,
                mimeType: "video/mp4",
                modelID: queued.model,
                kind: .textToVideo
            ),
            cleanupSucceeded
        )
    }

    func cleanupVideo(_ queued: VeniceQueuedVideo) async -> Bool {
        do {
            try await completeVideo(queued)
            if let privateURL = queued.downloadURL {
                var delete = URLRequest(url: privateURL)
                delete.httpMethod = "DELETE"
                let (_, response) = try await session.data(for: delete)
                guard
                    let http = response as? HTTPURLResponse,
                    (200..<300).contains(http.statusCode)
                else { return false }
            }
            return true
        } catch {
            return false
        }
    }

    func completeVideo(_ queued: VeniceQueuedVideo) async throws {
        struct Request: Encodable {
            let model: String
            let queue_id: String
        }
        _ = try await jsonRequest(
            path: "/video/complete",
            body: Request(model: queued.model, queue_id: queued.queueID)
        )
    }

    private func jsonRequest<Body: Encodable>(path: String, body: Body) async throws -> Data {
        try await rawJSONRequest(path: path, body: body).0
    }

    private func rawJSONRequest<Body: Encodable>(
        path: String,
        body: Body
    ) async throws -> (Data, HTTPURLResponse) {
        let request = try await makeJSONRequest(path: path, body: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MediaGenerationError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MediaGenerationError.invalidResponse
        }
        try Self.validate(data: data, response: http)
        return (data, http)
    }

    private func makeJSONRequest<Body: Encodable>(
        path: String,
        body: Body
    ) async throws -> URLRequest {
        guard let url = provider.url(for: path) else {
            throw MediaGenerationError.providerUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, video/mp4", forHTTPHeaderField: "Accept")
        for (name, value) in await provider.resolvedHeadersOffMainActor()
        where RemoteProviderService.isSafeHeader(name: name, value: value) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func validate(data: Data, response: HTTPURLResponse) throws {
        guard !(200 ..< 300).contains(response.statusCode) else { return }
        let message = providerErrorMessage(data)
            ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        debugLog(
            "[MediaGeneration] Venice request failed status=\(response.statusCode) "
                + "contentType=\(response.value(forHTTPHeaderField: "content-type") ?? "missing") "
                + "bytes=\(data.count) message=\(message)"
        )
        switch response.statusCode {
        case 401: throw MediaGenerationError.authenticationRequired
        case 402: throw MediaGenerationError.insufficientFunds
        case 403: throw MediaGenerationError.regionRestricted
        case 422: throw MediaGenerationError.contentPolicy(message)
        default: throw MediaGenerationError.server(status: response.statusCode, message: message)
        }
    }

    private static func validateDownloadedVideo(
        at url: URL,
        response: HTTPURLResponse
    ) throws {
        guard (200 ..< 300).contains(response.statusCode) else {
            let data = (try? Data(contentsOf: url)) ?? Data()
            try validate(data: data, response: response)
            throw MediaGenerationError.invalidResponse
        }
        let contentType = (response.value(forHTTPHeaderField: "content-type") ?? "").lowercased()
        guard contentType.contains("video/mp4") || contentType.contains("application/octet-stream")
        else {
            throw MediaGenerationError.invalidResponse
        }
        try MediaFileValidation.validateVideo(at: url)
    }

    private static func decodeBase64Payload(_ value: String) -> Data? {
        let payload = value.split(separator: ",", maxSplits: 1).last.map(String.init) ?? value
        return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
    }

    private static func providerErrorMessage(_ data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"]
        else { return nil }
        if let message = error as? String {
            return message
        }
        if let envelope = error as? [String: Any] {
            return envelope["message"] as? String
                ?? envelope["code"] as? String
        }
        return nil
    }

    private static func jsonTopLevelKeys(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "not-json"
        }
        return object.keys.sorted().joined(separator: ",")
    }

    private static func hexPrefix(_ data: Data) -> String {
        data.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func persist(
        _ data: Data,
        directory: URL,
        extension fileExtension: String,
        stem: String
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeStem = stem.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "-",
            options: .regularExpression
        )
        let url = directory.appendingPathComponent("\(safeStem).\(fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }
}

private struct VeniceImageRequest: Encodable {
    let model: String
    let prompt: String
    let negativePrompt: String?
    let width: Int?
    let height: Int?
    let steps: Int?
    let cfgScale: Double?
    let seed: Int?
    let variants: Int
    let format: String
    let aspectRatio: String?
    let resolution: String?
    let quality: String?
    let returnBinary: Bool

    private enum CodingKeys: String, CodingKey {
        case model, prompt, width, height, steps, seed, variants, format, resolution, quality
        case negativePrompt = "negative_prompt"
        case cfgScale = "cfg_scale"
        case aspectRatio = "aspect_ratio"
        case returnBinary = "return_binary"
    }
}

private struct VeniceImageResponse: Decodable {
    let id: String?
    let images: [String]
}

private struct VeniceVideoQuoteRequest: Encodable {
    let model: String
    let duration: String
    let aspectRatio: String?
    let resolution: String?
    let audio: Bool?

    private enum CodingKeys: String, CodingKey {
        case model, duration, resolution, audio
        case aspectRatio = "aspect_ratio"
    }
}

private struct VeniceVideoQueueRequest: Encodable {
    let model: String
    let prompt: String
    let negativePrompt: String?
    let duration: String
    let aspectRatio: String?
    let resolution: String?
    let audio: Bool?
    let imageURL: String?

    private enum CodingKeys: String, CodingKey {
        case model, prompt, duration, resolution, audio
        case negativePrompt = "negative_prompt"
        case aspectRatio = "aspect_ratio"
        case imageURL = "image_url"
    }
}
