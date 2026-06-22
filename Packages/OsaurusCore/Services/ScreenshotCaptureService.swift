//
//  ScreenshotCaptureService.swift
//  osaurus
//
//  Captures a single macOS screenshot into the chat artifact store.
//

@preconcurrency import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct ScreenshotImage: Sendable, Equatable {
    let pngData: Data
    let width: Int
    let height: Int
    let displayID: UInt32?
}

protocol ScreenshotPermissionChecking: Sendable {
    func hasScreenRecordingPermission() -> Bool
}

struct SystemScreenshotPermissionChecker: ScreenshotPermissionChecking {
    func hasScreenRecordingPermission() -> Bool {
        SystemPermissionProbe.screenRecordingGranted()
    }
}

protocol ScreenshotImageCapturing: Sendable {
    func capture(includeCursor: Bool) async throws -> ScreenshotImage
}

struct ScreenCaptureKitScreenshotCapturer: ScreenshotImageCapturing {
    func capture(includeCursor: Bool) async throws -> ScreenshotImage {
        let content = try await SCShareableContent.current
        guard let display = await Self.displayToCapture(from: content.displays) else {
            throw ScreenshotCaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        filter.includeMenuBar = true

        let config = SCStreamConfiguration()
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        let contentRect = filter.contentRect.isEmpty ? display.frame : filter.contentRect
        config.width = max(1, Int(contentRect.width * scale))
        config.height = max(1, Int(contentRect.height * scale))
        config.showsCursor = includeCursor
        config.captureResolution = .best
        config.queueDepth = 1
        config.shouldBeOpaque = true

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        let pngData = try Self.pngData(from: cgImage)
        return ScreenshotImage(
            pngData: pngData,
            width: cgImage.width,
            height: cgImage.height,
            displayID: display.displayID
        )
    }

    @MainActor
    private static func mainDisplayID() -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (NSScreen.main?.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private static func displayToCapture(from displays: [SCDisplay]) async -> SCDisplay? {
        guard !displays.isEmpty else { return nil }
        if let mainID = await mainDisplayID(),
            let main = displays.first(where: { $0.displayID == mainID })
        {
            return main
        }
        return displays.first
    }

    private static func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw ScreenshotCaptureError.pngEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotCaptureError.pngEncodingFailed
        }
        return data as Data
    }
}

enum ScreenshotCaptureError: Error, Equatable {
    case missingScreenRecordingPermission
    case missingSession
    case noDisplay
    case pngEncodingFailed
    case writeFailed(String)
}

struct ScreenshotCaptureOptions: Sendable, Equatable {
    let contextId: String
    let filename: String?
    let description: String?
    let includeCursor: Bool
    let now: Date

    init(
        contextId: String,
        filename: String? = nil,
        description: String? = nil,
        includeCursor: Bool = false,
        now: Date = Date()
    ) {
        self.contextId = contextId
        self.filename = filename
        self.description = description
        self.includeCursor = includeCursor
        self.now = now
    }
}

struct CapturedScreenshotArtifact: Sendable, Equatable {
    let artifact: SharedArtifact
    let width: Int
    let height: Int
    let displayID: UInt32?
    let includeCursor: Bool
    let capturedAt: Date
}

final class ScreenshotCaptureService: @unchecked Sendable {
    static let shared = ScreenshotCaptureService()

    private let permissionChecker: any ScreenshotPermissionChecking
    private let capturer: any ScreenshotImageCapturing
    private let fileManager: FileManager

    init(
        permissionChecker: any ScreenshotPermissionChecking = SystemScreenshotPermissionChecker(),
        capturer: any ScreenshotImageCapturing = ScreenCaptureKitScreenshotCapturer(),
        fileManager: FileManager = .default
    ) {
        self.permissionChecker = permissionChecker
        self.capturer = capturer
        self.fileManager = fileManager
    }

    func capture(options: ScreenshotCaptureOptions) async throws -> CapturedScreenshotArtifact {
        let contextId = options.contextId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contextId.isEmpty else {
            throw ScreenshotCaptureError.missingSession
        }
        guard permissionChecker.hasScreenRecordingPermission() else {
            throw ScreenshotCaptureError.missingScreenRecordingPermission
        }

        let image = try await capturer.capture(includeCursor: options.includeCursor)
        let contextDir = OsaurusPaths.contextArtifactsDir(contextId: contextId)
        do {
            try fileManager.createDirectory(at: contextDir, withIntermediateDirectories: true)
            let filename = uniqueFilename(
                base: Self.sanitizedFilename(options.filename, now: options.now),
                in: contextDir
            )
            let destination = contextDir.appendingPathComponent(filename, isDirectory: false)
            try image.pngData.write(to: destination, options: [.atomic])

            let byteCount =
                (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int)
                ?? image.pngData.count
            let artifact = SharedArtifact(
                contextId: contextId,
                contextType: .chat,
                filename: filename,
                mimeType: "image/png",
                fileSize: byteCount,
                hostPath: destination.path,
                isDirectory: false,
                content: nil,
                description: options.description,
                isFinalResult: false,
                createdAt: options.now
            )
            return CapturedScreenshotArtifact(
                artifact: artifact,
                width: image.width,
                height: image.height,
                displayID: image.displayID,
                includeCursor: options.includeCursor,
                capturedAt: options.now
            )
        } catch let error as ScreenshotCaptureError {
            throw error
        } catch {
            throw ScreenshotCaptureError.writeFailed(error.localizedDescription)
        }
    }

    static func sanitizedFilename(_ raw: String?, now: Date) -> String {
        let fallback = "screenshot-\(Int(now.timeIntervalSince1970))"
        let candidate =
            raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .last
            ?? ""
        let withoutExtension = (candidate as NSString).deletingPathExtension
        let stemSource = withoutExtension.isEmpty ? candidate : withoutExtension
        let sanitizedStem =
            stemSource
            .map { character -> Character in
                if character.isASCII,
                    character.isLetter || character.isNumber || character == "-" || character == "_"
                {
                    return character
                }
                return "-"
            }
            .reduce(into: "") { partial, character in
                if character == "-", partial.last == "-" {
                    return
                }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))

        let stem = sanitizedStem.isEmpty ? fallback : String(sanitizedStem.prefix(80))
        return "\(stem).png"
    }

    private func uniqueFilename(base: String, in directory: URL) -> String {
        let nsBase = base as NSString
        let stem = nsBase.deletingPathExtension
        let ext = nsBase.pathExtension.isEmpty ? "png" : nsBase.pathExtension
        var candidate = "\(stem).\(ext)"
        var suffix = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(stem)-\(suffix).\(ext)"
            suffix += 1
        }
        return candidate
    }
}
