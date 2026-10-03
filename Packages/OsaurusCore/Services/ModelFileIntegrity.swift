import CryptoKit
import Darwin
import Foundation

/// Hub LFS objects carry a content SHA-256; ordinary files carry a Git blob
/// SHA-1 (which includes the blob header). Neither is a file-size check.
enum ModelFileDigest: Equatable, Sendable {
    case sha256(String)
    case gitBlobSHA1(String)

    func matches(
        _ url: URL,
        size: Int64,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256()
        var sha1 = Insecure.SHA1()
        if case .gitBlobSHA1 = self { sha1.update(data: Data("blob \(size)\0".utf8)) }
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            try checkCancellation()
            switch self {
            case .sha256: sha256.update(data: data)
            case .gitBlobSHA1: sha1.update(data: data)
            }
        }
        switch self {
        case .sha256(let expected):
            return sha256.finalize().map { String(format: "%02x", $0) }.joined() == expected.lowercased()
        case .gitBlobSHA1(let expected):
            return sha1.finalize().map { String(format: "%02x", $0) }.joined() == expected.lowercased()
        }
    }
}

enum ModelFileIntegrity {
    static func matches(
        _ url: URL,
        size: Int64,
        digest: ModelFileDigest? = nil,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Bool {
        try checkCancellation()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
            (attrs[.size] as? NSNumber)?.int64Value == size
        else { return false }
        return try digest?.matches(url, size: size, checkCancellation: checkCancellation) ?? true
    }

    static func validate(
        _ url: URL,
        size: Int64,
        digest: ModelFileDigest? = nil,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        guard try matches(url, size: size, digest: digest, checkCancellation: checkCancellation) else {
            throw URLError(
                .cannotDecodeContentData,
                userInfo: [
                    NSLocalizedDescriptionKey: "Size or checksum mismatch for \(url.lastPathComponent)"
                ]
            )
        }
    }

    /// Both paths must be on the destination volume. POSIX rename atomically
    /// replaces the directory entry; a failed replacement leaves the old file
    /// intact. Never unlink a usable model file before the new one is ready.
    static func commit(staged: URL, to destination: URL) throws {
        guard rename(staged.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
