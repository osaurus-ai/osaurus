//
//  AccessKeyLifecycleService.swift
//  OsaurusCore
//
//  User-facing access-key lifecycle operations.
//

import Foundation

public protocol AccessKeyLifecycleManaging: AnyObject {
    func generate(
        label: String,
        expiration: AccessKeyExpiration,
        agentIndex: UInt32?
    ) throws -> (fullKey: String, info: AccessKeyInfo)

    func delete(id: UUID)
    func listKeys() -> [AccessKeyInfo]
    func reload()
}

extension APIKeyManager: AccessKeyLifecycleManaging {}

public final class AccessKeyLifecycleService: @unchecked Sendable {
    public static let shared = AccessKeyLifecycleService()

    public static let maximumLabelLength = 80

    private let manager: AccessKeyLifecycleManaging

    public init(manager: AccessKeyLifecycleManaging = APIKeyManager.shared) {
        self.manager = manager
    }

    public func create(
        label: String,
        expiration: AccessKeyExpiration,
        agentIndex: UInt32? = nil
    ) throws -> (fullKey: String, info: AccessKeyInfo) {
        let cleanLabel = try Self.validatedLabel(label)
        return try manager.generate(
            label: cleanLabel,
            expiration: expiration,
            agentIndex: agentIndex
        )
    }

    @discardableResult
    public func revokeAndRemove(id: UUID) throws -> AccessKeyInfo {
        manager.reload()
        guard let existing = manager.listKeys().first(where: { $0.id == id }) else {
            throw AccessKeyLifecycleError.keyNotFound
        }

        manager.delete(id: id)

        if manager.listKeys().contains(where: { $0.id == id }) {
            throw AccessKeyLifecycleError.removalDidNotPersist
        }

        return existing
    }

    public static func validatedLabel(_ label: String) throws -> String {
        let clean =
            label
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        guard !clean.isEmpty else { throw AccessKeyLifecycleError.emptyLabel }
        guard clean.count <= maximumLabelLength else {
            throw AccessKeyLifecycleError.labelTooLong(maximumLabelLength)
        }
        return clean
    }
}

public enum AccessKeyLifecycleError: LocalizedError, Equatable {
    case emptyLabel
    case labelTooLong(Int)
    case keyNotFound
    case removalDidNotPersist

    public var errorDescription: String? {
        switch self {
        case .emptyLabel:
            return "Access key labels cannot be empty."
        case .labelTooLong(let maximum):
            return "Access key labels must be \(maximum) characters or fewer."
        case .keyNotFound:
            return "Access key could not be found."
        case .removalDidNotPersist:
            return "Access key revocation was recorded, but the key still appears in metadata."
        }
    }
}
