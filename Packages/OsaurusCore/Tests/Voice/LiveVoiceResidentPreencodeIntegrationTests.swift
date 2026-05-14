//
//  LiveVoiceResidentPreencodeIntegrationTests.swift
//  OsaurusCoreTests
//

import Foundation
import MLXLMCommon
import MLXVLM
import Testing

@testable import OsaurusCore

private let isResidentOmniPreencodeEnabled =
    ProcessInfo.processInfo.environment["OSAURUS_RUN_REAL_OMNI_PREENCODE"] == "1"

@Suite(
    "Resident Nemotron Omni live voice preencode integration",
    .serialized,
    .disabled(
        if: !isResidentOmniPreencodeEnabled,
        "Set OSAURUS_RUN_REAL_OMNI_PREENCODE=1, OSU_MODELS_DIR, OSAURUS_OMNI_MODEL, and OSAURUS_OMNI_AUDIO to run."
    )
)
struct LiveVoiceResidentPreencodeIntegrationTests {
    @Test("resident model stores fresh preencoded live audio")
    func residentModelStoresFreshPreencodedLiveAudio() async throws {
        try Self.prepareMLXMetallibForSwiftPMTest()

        let env = ProcessInfo.processInfo.environment
        let modelName = env["OSAURUS_OMNI_MODEL"] ?? "nemotron-omni-nano-jangtq-crack"
        let audioPath = try #require(
            env["OSAURUS_OMNI_AUDIO"],
            "OSAURUS_OMNI_AUDIO must point to a real audio file."
        )
        let audioURL = URL(fileURLWithPath: audioPath)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))

        LiveVoiceAudioInputRegistry.shared.removeAll()
        defer { LiveVoiceAudioInputRegistry.shared.removeAll() }

        let warmStart = CFAbsoluteTimeGetCurrent()
        _ = try await MLXService.shared.generateOneShot(
            messages: [ChatMessage(role: "user", content: "Reply with: ready")],
            parameters: GenerationParameters(
                temperature: 0,
                maxTokens: 4,
                modelOptions: ["reasoningEffort": .string("no_think")]
            ),
            requestedModel: modelName
        )
        let warmMs = Int((CFAbsoluteTimeGetCurrent() - warmStart) * 1000)

        let resident = try #require(
            await ModelRuntime.shared.cachedModelSummaries()
                .first { ModelFamilyNames.isNemotronOmniFamily($0.name) },
            "Expected a resident Nemotron Omni model after warmup."
        )

        let samples = try nemotronOmniLoadAudioFile(audioURL, targetSampleRate: 16_000)
        #expect(!samples.isEmpty)

        let attachmentId = UUID()
        let result = await ModelRuntime.shared.preencodeLiveVoiceAudioIfResident(
            modelName: resident.name,
            attachmentId: attachmentId,
            samples: samples,
            sampleRate: 16_000
        )

        #expect(result.status == .stored)
        #expect(result.sampleCount == samples.count)
        #expect(result.sampleRate == 16_000)
        #expect(result.encodeMs > 0)

        let metadata = try #require(LiveVoiceAudioInputRegistry.shared.preencodedMetadata(for: attachmentId))
        #expect(metadata.sourceSampleCount == samples.count)
        #expect(metadata.sampleRate == 16_000)
        #expect(metadata.encodeMs == result.encodeMs)

        let preencoded = try #require(
            LiveVoiceAudioInputRegistry.shared.freshPreencodedAudio(
                for: attachmentId,
                sourceSampleCount: samples.count,
                sampleRate: 16_000
            )
        )
        guard case .preEncoded(let encodedSamples, let encodedSampleRate, let embedding) = preencoded else {
            Issue.record("Expected fresh registry lookup to return preEncoded audio.")
            return
        }

        #expect(!encodedSamples.isEmpty)
        #expect(encodedSampleRate == 16_000)
        #expect(!embedding.shape.isEmpty)

        #expect(
            LiveVoiceAudioInputRegistry.shared.freshPreencodedAudio(
                for: attachmentId,
                sourceSampleCount: samples.count + 1,
                sampleRate: 16_000
            ) == nil
        )

        let snapshot = LiveVoiceAudioSnapshot(samples: samples, sampleRate: 16_000)
        LiveVoiceAudioInputRegistry.shared.store(snapshot: snapshot, for: attachmentId)
        let audioAttachment = Attachment(
            id: attachmentId,
            kind: .audio(snapshot.wavData(), format: "wav", filename: "voice-input.wav")
        )
        let chatMessage = await MainActor.run {
            ChatSession.buildUserChatMessage(
                content: "What is in this audio?",
                attachments: [audioAttachment],
                supportsImages: false,
                supportsAudio: true,
                supportsVideo: false
            )
        }
        #expect(chatMessage.audioInputsWithLocalSamples.count == 1)
        #expect(chatMessage.audioInputsWithLocalSamples[0].localSamples?.preencodedAttachmentId == attachmentId)

        let mapped = ModelRuntime.mapOpenAIChatToMLX([chatMessage])
        #expect(mapped.count == 1)
        #expect(mapped[0].audios.count == 1)
        guard
            case .preEncoded(let submittedSamples, let submittedSampleRate, let submittedEmbedding) =
                mapped[0].audios[0]
        else {
            Issue.record("Composer-style audio submit should consume fresh preencoded audio.")
            return
        }
        #expect(submittedSamples.count == samples.count)
        #expect(submittedSampleRate == 16_000)
        #expect(submittedEmbedding.shape == embedding.shape)

        print(
            "[Osaurus][LiveVoiceIntegration] model=\(resident.name) warm_ms=\(warmMs) samples=\(samples.count) encode_ms=\(result.encodeMs) embedding_shape=\(embedding.shape) composer_submit=preencoded"
        )
    }

    private static func prepareMLXMetallibForSwiftPMTest() throws {
        let fileManager = FileManager.default
        guard let sourceURL = try findMLXMetallib(fileManager: fileManager) else {
            throw NSError(
                domain: "LiveVoiceResidentPreencodeIntegrationTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unable to find MLX default.metallib. Build the osaurus app first or set OSAURUS_MLX_METALLIB to the metallib path."
                ]
            )
        }

        for directory in metallibDestinationDirectories(fileManager: fileManager) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for filename in ["default.metallib", "mlx.metallib"] {
                let destination = directory.appendingPathComponent(filename)
                if !fileManager.fileExists(atPath: destination.path) {
                    try fileManager.copyItem(at: sourceURL, to: destination)
                }
            }
        }
    }

    private static func findMLXMetallib(fileManager: FileManager) throws -> URL? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [URL] = []

        if let envPath = env["OSAURUS_MLX_METALLIB"], !envPath.isEmpty {
            candidates.append(URL(fileURLWithPath: envPath))
        }
        for directory in metallibDestinationDirectories(fileManager: fileManager) {
            candidates.append(directory.appendingPathComponent("default.metallib"))
            candidates.append(directory.appendingPathComponent("mlx.metallib"))
        }

        let root = repoRoot
        candidates.append(
            root.appendingPathComponent(
                "build/XcodeDerivedData-livevoice/Build/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
            )
        )
        candidates.append(
            root.appendingPathComponent(
                "build/XcodeDerivedData-livevoice/Build/Products/Debug/osaurus.app/Contents/Resources/default.metallib"
            )
        )
        candidates.append(
            root.appendingPathComponent(
                "build/XcodeDerivedData-livevoice/Build/Products/Debug/default.metallib"
            )
        )

        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func metallibDestinationDirectories(fileManager: FileManager) -> [URL] {
        var candidates: [URL] = []

        if let executableURL = Bundle.main.executableURL {
            candidates.append(executableURL.deletingLastPathComponent())
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL)
        }
        if let firstArgument = CommandLine.arguments.first, !firstArgument.isEmpty {
            candidates.append(URL(fileURLWithPath: firstArgument).deletingLastPathComponent())
        }

        let packageRoot = packageRoot
        candidates.append(packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug"))
        candidates.append(
            packageRoot.appendingPathComponent(
                ".build/arm64-apple-macosx/debug/OsaurusCorePackageTests.xctest/Contents/MacOS"
            )
        )
        candidates.append(
            packageRoot.appendingPathComponent(
                ".build/arm64-apple-macosx/debug/OsaurusCorePackageTests.xctest/Contents/Resources"
            )
        )
        candidates.append(packageRoot.appendingPathComponent(".build/debug"))
        candidates.append(
            packageRoot.appendingPathComponent(
                ".build/debug/OsaurusCorePackageTests.xctest/Contents/MacOS"
            )
        )
        candidates.append(
            packageRoot.appendingPathComponent(
                ".build/debug/OsaurusCorePackageTests.xctest/Contents/Resources"
            )
        )

        var seen: Set<String> = []
        return candidates.compactMap { url in
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(packageRoot.path + "/") else {
                return nil
            }
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }

    private static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let repoRoot: URL =
        packageRoot
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
