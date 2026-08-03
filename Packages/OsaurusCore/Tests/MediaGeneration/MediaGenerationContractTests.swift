import Foundation
import Testing

@testable import OsaurusCore

@Suite("Media generation contracts", .serialized)
struct MediaGenerationContractTests {
    @Test
    func veniceCatalogPartitionsChatImageAndSupportedVideoModels() throws {
        let providerID = UUID()
        let data = Data(
            """
            {
              "data": [
                {"id":"chat-model","type":"text","model_spec":{"name":"Chat","privacy":"private"}},
                {
                  "id":"image-model",
                  "type":"image",
                  "model_spec":{
                    "name":"Image",
                    "privacy":"private",
                    "constraints":{
                      "aspectRatios":["1:1","16:9"],
                      "defaultAspectRatio":"1:1",
                      "resolutions":["1K","2K"],
                      "defaultResolution":"1K",
                      "qualities":["low","high"],
                      "defaultQuality":"high",
                      "promptCharacterLimit":2048,
                      "steps":{"default":25,"max":50},
                      "widthHeightDivisor":8
                    },
                    "pricing":{"generation":{"usd":0.1,"diem":0.1}}
                  }
                },
                {
                  "id":"video-text",
                  "type":"video",
                  "model_spec":{
                    "name":"Video Text",
                    "privacy":"anonymized",
                    "constraints":{
                      "aspect_ratios":["16:9"],
                      "resolutions":["720p"],
                      "durations":["5s","10s"],
                      "model_type":"text-to-video",
                      "audio":true,
                      "audio_configurable":true,
                      "prompt_character_limit":1000
                    }
                  }
                },
                {
                  "id":"video-reference-to-video",
                  "type":"video",
                  "model_spec":{
                    "constraints":{
                      "model_type":"image-to-video",
                      "aspect_ratios":[],
                      "resolutions":[],
                      "durations":["5s"],
                      "audio":false,
                      "audio_configurable":false
                    }
                  }
                }
              ]
            }
            """.utf8
        )

        let discovery = try VeniceModelDiscovery.decode(
            data,
            providerID: providerID,
            providerName: "Venice"
        )

        #expect(discovery.chatModelIDs == ["chat-model"])
        #expect(discovery.mediaModels.count == 2)
        let image = try #require(discovery.mediaModels.first { $0.kind == .image })
        #expect(image.constraints.aspectRatios == ["1:1", "16:9"])
        #expect(image.constraints.defaultResolution == "1K")
        #expect(image.constraints.defaultSteps == 25)
        #expect(image.constraints.maxSteps == 50)
        #expect(image.constraints.dimensionDivisor == 8)
        let video = try #require(discovery.mediaModels.first { $0.kind == .textToVideo })
        #expect(video.constraints.durations == ["5s", "10s"])
        #expect(video.constraints.audioConfigurable)
        #expect(video.constraints.promptCharacterLimit == 1000)
        #expect(video.target == MediaModelTarget(backend: .remoteProvider(providerID), modelID: "video-text"))
    }

    @Test
    func legacyImageModelMigratesToLocalStableTarget() throws {
        let data = Data(#"{"defaultImageGenerationModelId":" legacy-image "}"#.utf8)
        let config = try JSONDecoder().decode(SubagentConfiguration.self, from: data)
        #expect(
            config.defaultImageGenerationTarget
                == MediaModelTarget(backend: .local, modelID: "legacy-image")
        )
    }

    @Test
    func typedHTTPMediaTargetsFailClosed() {
        let providerID = UUID()
        #expect(
            MediaTargetRequestDTO(
                backend: "remote_provider",
                provider_id: providerID,
                model: "video-model"
            ).target()
                == MediaModelTarget(backend: .remoteProvider(providerID), modelID: "video-model")
        )
        #expect(
            MediaTargetRequestDTO(
                backend: "remote_provider",
                provider_id: nil,
                model: "video-model"
            ).target() == nil
        )
        #expect(
            MediaTargetRequestDTO(
                backend: "unknown",
                provider_id: nil,
                model: "video-model"
            ).target() == nil
        )
    }

    @Test
    func oldComposerSettingsDecodeWithoutMediaFields() throws {
        let data = Data(
            """
            {"negativePrompt":"","steps":20,"guidance":3.5,"width":512,"height":512,"seed":"","strength":0.75}
            """.utf8
        )
        let settings = try JSONDecoder().decode(ImageComposerSettings.self, from: data)
        #expect(settings.aspectRatio == nil)
        #expect(settings.resolution == nil)
        #expect(settings.quality == nil)
        #expect(settings.duration == nil)
        #expect(settings.audio == nil)
    }

    @Test
    func cloudCatalogIgnoresUnknownOperations() throws {
        let data = Data(
            """
            {
              "version":"1",
              "models":[
                {
                  "id":"known",
                  "display_name":"Known",
                  "operation":"image",
                  "constraints":{},
                  "offline":false
                },
                {
                  "id":"future",
                  "display_name":"Future",
                  "operation":"audio",
                  "constraints":{},
                  "offline":false
                }
              ]
            }
            """.utf8
        )
        let response = try JSONDecoder().decode(CloudMediaCatalogResponse.self, from: data)
        #expect(response.models.compactMap(\.modelInfo).map(\.target.modelID) == ["known"])
    }

    @Test
    func cloudCatalogPreservesSparsePricingConstraintsAndCamelCaseVideoOperations() throws {
        let data = Data(
            """
            {
              "version":"1",
              "models":[{
                "id":"video-model",
                "display_name":"Video Model",
                "operation":"textToVideo",
                "constraints":{
                  "aspectRatios":["16:9","9:16"],
                  "durations":[5,10],
                  "steps":{"default":20,"max":50},
                  "supports_audio":true
                },
                "pricing":{"generation":{"usd":0.12}},
                "privacy":"anonymized",
                "offline":false
              }]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(CloudMediaCatalogResponse.self, from: data)
        let model = try #require(response.models.first?.modelInfo)
        #expect(model.kind == .textToVideo)
        #expect(model.constraints.aspectRatios == ["16:9", "9:16"])
        #expect(model.constraints.durations == ["5", "10"])
        #expect(model.constraints.defaultSteps == 20)
        #expect(model.constraints.maxSteps == 50)
        #expect(model.constraints.supportsAudio)
        #expect(model.constraints.audioConfigurable)
        #expect(model.pricing?.generation?.usd == 0.12)
        #expect(model.privacy == "anonymized")
    }

    @Test
    func durableVideoJobSurvivesStoreReinitialization() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-media-job-test-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("jobs.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let job = DurableMediaJob(
            id: id,
            backend: .osaurusCloud,
            providerID: nil,
            modelID: "video-model",
            kind: .textToVideo,
            queueID: "provider-job",
            downloadURL: nil,
            quoteUSD: 0.42,
            state: .queued,
            outputURL: nil,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let first = MediaJobStore(fileURL: file)
        try await first.upsert(job)

        let restored = await MediaJobStore(fileURL: file).job(id: id)
        #expect(restored?.queueID == "provider-job")
        #expect(restored?.state == .queued)
        #expect(restored?.quoteUSD == 0.42)
    }

    @Test
    func veniceImageRequestOmitsUnsupportedFieldsAndUsesBearerHeader() async throws {
        try await StoragePathsTestLock.shared.run {
            let previous = OsaurusPaths.overrideRoot
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-venice-image-\(UUID().uuidString)", isDirectory: true)
            OsaurusPaths.overrideRoot = root
            defer {
                VeniceMediaURLProtocol.handler = nil
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: root)
            }
            VeniceMediaURLProtocol.handler = { request in
                #expect(request.url?.path == "/api/v1/image/generate")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
                let body = try requestBody(request)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(json["model"] as? String == "image-model")
                #expect(json["aspect_ratio"] as? String == "16:9")
                #expect(json["resolution"] as? String == "2K")
                #expect(json["width"] == nil)
                #expect(json["height"] == nil)
                #expect(json["negative_prompt"] == nil)
                return (
                    200,
                    Data(
                        #"{"id":"image-request","images":["iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="]}"#
                            .utf8
                    ),
                    ["content-type": "application/json"]
                )
            }
            let client = try VeniceMediaClient(
                provider: Self.veniceProvider(),
                session: Self.mockSession()
            )
            let media = try await client.generateImage(
                MediaImageGenerationRequest(
                    target: MediaModelTarget(backend: .remoteProvider(UUID()), modelID: "image-model"),
                    prompt: "A lighthouse",
                    negativePrompt: nil,
                    width: nil,
                    height: nil,
                    aspectRatio: "16:9",
                    resolution: "2K",
                    quality: nil,
                    steps: nil,
                    guidance: nil,
                    seed: nil,
                    count: 1,
                    format: .png
                )
            )
            #expect(media.count == 1)
            #expect(
                try Data(contentsOf: media[0].url)
                    == Data(
                        base64Encoded:
                            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
                    )
            )
        }
    }

    @Test
    func veniceImageResponseUsesDetectedFormatAndDoesNotRequireProviderID() async throws {
        try await StoragePathsTestLock.shared.run {
            let previous = OsaurusPaths.overrideRoot
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-venice-format-\(UUID().uuidString)", isDirectory: true)
            OsaurusPaths.overrideRoot = root
            defer {
                VeniceMediaURLProtocol.handler = nil
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: root)
            }
            let webP = Data([
                0x52, 0x49, 0x46, 0x46,
                0x04, 0x00, 0x00, 0x00,
                0x57, 0x45, 0x42, 0x50,
            ])
            VeniceMediaURLProtocol.handler = { _ in
                let response = try JSONSerialization.data(
                    withJSONObject: ["images": [webP.base64EncodedString()]]
                )
                return (200, response, ["content-type": "application/json"])
            }
            let client = try VeniceMediaClient(
                provider: Self.veniceProvider(),
                session: Self.mockSession()
            )
            let media = try await client.generateImage(
                MediaImageGenerationRequest(
                    target: MediaModelTarget(backend: .remoteProvider(UUID()), modelID: "image-model"),
                    prompt: "A lighthouse",
                    negativePrompt: nil,
                    width: 1_024,
                    height: 1_024,
                    aspectRatio: nil,
                    resolution: nil,
                    quality: nil,
                    steps: nil,
                    guidance: nil,
                    seed: nil,
                    count: 1,
                    format: .png
                )
            )

            #expect(media.count == 1)
            #expect(media[0].mimeType == "image/webp")
            #expect(media[0].url.pathExtension == "webp")
            #expect(try Data(contentsOf: media[0].url) == webP)
        }
    }

    @Test
    func videoQuoteReceiptsAreBoundAndSingleUse() async throws {
        let store = MediaQuoteStore(lifetime: 60)
        let request = Self.videoRequest(duration: "5s")
        let receipt = await store.issue(for: request, quote: MediaVideoQuote(usd: 0.42))

        let quote = try await store.consume(token: receipt.token, for: request)
        #expect(quote.usd == 0.42)
        await #expect(throws: MediaGenerationError.self) {
            try await store.consume(token: receipt.token, for: request)
        }

        let mismatchReceipt = await store.issue(
            for: request,
            quote: MediaVideoQuote(usd: 0.42)
        )
        await #expect(throws: MediaGenerationError.self) {
            try await store.consume(
                token: mismatchReceipt.token,
                for: Self.videoRequest(duration: "10s")
            )
        }
    }

    @Test
    func remoteSourceImagePreservesMIMEAndRejectsFileURLs() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let dataURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        let decoded = try #require(HTTPHandler.decodeImageInputWithMIME(dataURL))
        #expect(decoded.data == jpeg)
        #expect(decoded.mimeType == "image/jpeg")
        #expect(HTTPHandler.decodeImageInputWithMIME("file:///tmp/private.jpg") == nil)
        #expect(
            HTTPHandler.decodeImageInputWithMIME(
                "data:image/png;base64,\(jpeg.base64EncodedString())"
            ) == nil
        )
    }

    @Test
    func mediaValidationRejectsMislabeledProviderBytes() throws {
        #expect(throws: MediaGenerationError.self) {
            try MediaFileValidation.validateImage(Data("not an image".utf8), expectedFormat: .png)
        }
        var mp4 = Data([0, 0, 0, 24])
        mp4.append(Data("ftypisom".utf8))
        try MediaFileValidation.validateVideo(mp4)
    }

    @Test
    func veniceVideoQueueUsesOnlySelectedCatalogOptions() async throws {
        defer { VeniceMediaURLProtocol.handler = nil }
        VeniceMediaURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/video/queue")
            let body = try requestBody(request)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "video-model")
            #expect(json["duration"] as? String == "5s")
            #expect(json["resolution"] as? String == "720p")
            #expect(json["aspect_ratio"] == nil)
            #expect(json["audio"] == nil)
            #expect(json["image_url"] == nil)
            return (
                200,
                Data(#"{"model":"video-model","queue_id":"queue-1"}"#.utf8),
                ["content-type": "application/json"]
            )
        }
        let client = try VeniceMediaClient(
            provider: Self.veniceProvider(),
            session: Self.mockSession()
        )
        let queued = try await client.queueVideo(
            MediaVideoGenerationRequest(
                target: MediaModelTarget(backend: .remoteProvider(UUID()), modelID: "video-model"),
                prompt: "Ocean waves",
                negativePrompt: nil,
                sourceImage: nil,
                sourceImageMIMEType: nil,
                duration: "5s",
                aspectRatio: nil,
                resolution: "720p",
                audio: nil
            )
        )
        #expect(queued.queueID == "queue-1")
        #expect(queued.downloadURL == nil)
    }

    @Test
    func providerDiagnosticsRedactMediaCredentials() {
        let headers = RemoteProviderHeaderRedactor.redactedHeaders([
            "Authorization": "Bearer test-secret",
            "X-Request-ID": "safe-id",
        ])
        #expect(headers["Authorization"] == RemoteProviderHeaderRedactor.redactedValue)
        #expect(headers["X-Request-ID"] == "safe-id")
    }

    private static func veniceProvider() -> RemoteProvider {
        RemoteProvider(
            name: "Venice",
            host: "api.venice.ai",
            basePath: "/api/v1",
            customHeaders: ["Authorization": "Bearer test-secret"],
            authType: .none,
            providerType: .openaiLegacy
        )
    }

    private static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VeniceMediaURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func videoRequest(duration: String) -> MediaVideoGenerationRequest {
        MediaVideoGenerationRequest(
            target: MediaModelTarget(backend: .osaurusCloud, modelID: "video-model"),
            prompt: "Ocean waves",
            negativePrompt: nil,
            sourceImage: nil,
            sourceImageMIMEType: nil,
            duration: duration,
            aspectRatio: "16:9",
            resolution: "720p",
            audio: false
        )
    }
}

private final class VeniceMediaURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try #require(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}
