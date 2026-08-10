//
//  SandboxPackageRequestNormalizer.swift
//  osaurus
//
//  Shared validation and shell encoding for sandbox package requests.
//

import Foundation

enum SandboxPackageRequestError: Error, Equatable, LocalizedError {
    case empty
    case tooMany(actual: Int, maximum: Int)
    case emptySpecifier(index: Int)
    case tooLong(index: Int, maximum: Int)
    case controlCharacter(index: Int)
    case optionInjection(index: Int)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "`packages` must contain at least one package specifier."
        case .tooMany(let actual, let maximum):
            return "`packages` contains \(actual) entries; the maximum is \(maximum)."
        case .emptySpecifier(let index):
            return "`packages[\(index)]` must not be empty."
        case .tooLong(let index, let maximum):
            return "`packages[\(index)]` exceeds the \(maximum)-character limit."
        case .controlCharacter(let index):
            return "`packages[\(index)]` contains a control character."
        case .optionInjection(let index):
            return
                "`packages[\(index)]` starts with `-`. Package-manager options are not "
                + "accepted as package names."
        }
    }
}

struct SandboxPackageRequest: Sendable, Equatable {
    static let maximumPackageCount = 32
    static let maximumSpecifierLength = 256

    let packages: [String]

    var shellArguments: String {
        packages.map(Self.shellQuote).joined(separator: " ")
    }

    static func normalize(_ rawPackages: [String]) throws -> SandboxPackageRequest {
        guard !rawPackages.isEmpty else {
            throw SandboxPackageRequestError.empty
        }
        guard rawPackages.count <= maximumPackageCount else {
            throw SandboxPackageRequestError.tooMany(
                actual: rawPackages.count,
                maximum: maximumPackageCount
            )
        }

        var normalized: [String] = []
        normalized.reserveCapacity(rawPackages.count)
        for (index, raw) in rawPackages.enumerated() {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw SandboxPackageRequestError.emptySpecifier(index: index)
            }
            guard value.count <= maximumSpecifierLength else {
                throw SandboxPackageRequestError.tooLong(
                    index: index,
                    maximum: maximumSpecifierLength
                )
            }
            guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw SandboxPackageRequestError.controlCharacter(index: index)
            }
            guard !value.hasPrefix("-") else {
                throw SandboxPackageRequestError.optionInjection(index: index)
            }
            normalized.append(value)
        }
        return SandboxPackageRequest(packages: normalized)
    }

    /// POSIX single-quote encoding. Embedded apostrophes close the quoted
    /// string, emit a quoted apostrophe, then reopen it.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
