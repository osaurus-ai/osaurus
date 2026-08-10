import Foundation

enum MediaFileValidation {
    static let maximumImageBytes = 50 * 1_024 * 1_024
    static let maximumVideoBytes = 1_024 * 1_024 * 1_024

    static func validateImage(_ data: Data, expectedFormat: ImageOutputFormat) throws {
        guard !data.isEmpty, data.count <= maximumImageBytes else {
            throw MediaGenerationError.invalidResponse
        }
        guard try detectImageFormat(data) == expectedFormat else {
            throw MediaGenerationError.invalidResponse
        }
    }

    static func detectImageFormat(_ data: Data) throws -> ImageOutputFormat {
        guard !data.isEmpty, data.count <= maximumImageBytes else {
            throw MediaGenerationError.invalidResponse
        }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return .png
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return .jpeg
        }
        if bytes.count >= 12,
            Array(bytes[0 ..< 4]) == Array("RIFF".utf8),
            Array(bytes[8 ..< 12]) == Array("WEBP".utf8)
        {
            return .webp
        }
        throw MediaGenerationError.invalidResponse
    }

    static func validateVideo(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
            let size = values.fileSize,
            size > 0,
            size <= maximumVideoBytes
        else {
            throw MediaGenerationError.invalidResponse
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 64) ?? Data()
        guard isMP4(prefix) else { throw MediaGenerationError.invalidResponse }
    }

    static func validateVideo(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumVideoBytes, isMP4(data.prefix(64)) else {
            throw MediaGenerationError.invalidResponse
        }
    }

    static func safeFileComponent(_ value: String, fallback: String) -> String {
        let sanitized = value.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "-",
            options: .regularExpression
        )
        return sanitized.isEmpty ? fallback : String(sanitized.prefix(160))
    }

    private static func isMP4(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let bytes = [UInt8](data)
        // ISO Base Media File Format starts with a sized box whose type is
        // `ftyp`; accepted MP4 brands vary, so checking the box is less brittle
        // than hard-coding one brand.
        return Array(bytes[4 ..< 8]) == Array("ftyp".utf8)
    }
}
