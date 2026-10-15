import Foundation

/// Resolves local video values before residency changes or weight loading.
/// No frame, size or sampler setting is silently clamped.
struct LocalVideoRequestPolicy: Sendable {
    let width: Int
    let height: Int
    let frames: Int
    let fps: Int
    let steps: Int
    let guidance: Float

    init(_ request: MediaVideoGenerationRequest) throws {
        guard request.audio != true else {
            throw MediaGenerationError.invalidRequest("Wan 2.1 does not generate audio.")
        }
        switch (request.resolution ?? "480p", request.aspectRatio ?? "16:9") {
        case ("480p", "16:9"): width = request.width ?? 832; height = request.height ?? 480
        case ("480p", "9:16"): width = request.width ?? 480; height = request.height ?? 832
        case ("480p", "1:1"): width = request.width ?? 480; height = request.height ?? 480
        case ("720p", "16:9"): width = request.width ?? 1280; height = request.height ?? 720
        case ("720p", "9:16"): width = request.width ?? 720; height = request.height ?? 1280
        case ("720p", "1:1"): width = request.width ?? 720; height = request.height ?? 720
        default: throw MediaGenerationError.invalidRequest("Unsupported local video resolution or aspect ratio.")
        }
        fps = request.fps ?? 16
        steps = request.steps ?? 50
        guidance = request.guidance ?? 5
        let durationText = request.duration.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = durationText.hasSuffix("s") ? String(durationText.dropLast()) : durationText
        guard let seconds = Double(number), seconds.isFinite, seconds > 0,
            (1...240).contains(fps), seconds * Double(fps) < Double(Int32.max) else {
            throw MediaGenerationError.invalidRequest("Video duration and fps must be positive and finite.")
        }
        let exactFrames = seconds * Double(fps)
        frames = request.frameCount ?? Int(exactFrames.rounded())
        guard frames > 0, frames % 4 == 1, abs(Double(frames) - exactFrames) < 0.0001 else {
            throw MediaGenerationError.invalidRequest("Wan requires 4n+1 frames and duration = frames/fps; 49 frames at 16 fps is 3.0625s.")
        }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard width >= 16, height >= 16, width % 16 == 0, height % 16 == 0,
            !pixels.overflow, pixels.partialValue <= Int(Int32.max) / frames,
            steps > 0, guidance.isFinite, guidance >= 0 else {
            throw MediaGenerationError.invalidRequest("Wan requires positive multiples of 16, valid tensor dimensions, positive steps and finite guidance.")
        }
    }
}
