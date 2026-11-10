//
//  SyncError+Osaurus.swift
//  osaurus
//
//  User-facing copy for sync errors. `detail` is for logs only.
//

import Foundation
import OsaurusSync

extension SyncError {
    var userMessage: String {
        switch code {
        case SyncErrorCode.storage:
            return String(localized: "Osaurus couldn't write your conversations to disk. Check that the disk has free space.", bundle: .module)
        case SyncErrorCode.invalidInput:
            return String(localized: "That value isn't valid. Check it and try again.", bundle: .module)
        case SyncErrorCode.notFound:
            return String(localized: "That conversation or device no longer exists.", bundle: .module)
        case SyncErrorCode.permissionDenied:
            return String(localized: "You don't have permission to change that.", bundle: .module)
        case SyncErrorCode.crypto, SyncErrorCode.malformed:
            return String(localized: "Some sync data couldn't be verified and was ignored.", bundle: .module)
        case SyncErrorCode.alreadyOpen:
            return String(localized: "Another copy of Osaurus is using your conversations. Quit it and reopen Osaurus.", bundle: .module)
        case SyncErrorCode.deviceRevoked:
            return String(localized: "This Mac was removed from your devices, so sync has stopped.", bundle: .module)
        case SyncErrorCode.noKey:
            return String(localized: "This conversation can't be read on this Mac yet. It will open once another of your devices shares its key.", bundle: .module)
        case SyncErrorCode.network:
            return String(localized: "Osaurus couldn't reach your other devices. Check the network connection.", bundle: .module)
        case SyncErrorCode.incompatibleVersion, SyncErrorCode.newerDatabase:
            return String(localized: "Your conversations were saved by a newer version of Osaurus. Update Osaurus to open them.", bundle: .module)
        case SyncErrorCode.pairing:
            return String(localized: "Pairing didn't finish. Check the code and try again.", bundle: .module)
        case SyncErrorCode.closed:
            return String(localized: "Sync is shutting down.", bundle: .module)
        case SyncErrorCode.keyStore:
            return String(localized: "Osaurus couldn't read its sync keys from the Keychain.", bundle: .module)
        case SyncErrorCode.corrupt:
            return String(localized: "The conversation database is damaged. Reset it under General → Advanced → Data & Storage → Stores Needing Attention, then add this Mac again in Sharing → Devices to download your conversations from your other devices.", bundle: .module)
        default:
            return String(localized: "Something went wrong with sync. Save a support report from Sharing → Devices → Support and send it to us.", bundle: .module)
        }
    }

    var logDetail: String {
        switch self {
        case let .Storage(_, detail), let .InvalidInput(_, detail), let .NotFound(_, detail),
            let .PermissionDenied(_, detail), let .Crypto(_, detail), let .Malformed(_, detail),
            let .AlreadyOpen(_, detail), let .DeviceRevoked(_, detail), let .NoKey(_, detail),
            let .Network(_, detail), let .IncompatibleVersion(_, detail), let .Pairing(_, detail),
            let .Closed(_, detail), let .KeyStore(_, detail), let .Internal(_, detail),
            let .Corrupt(_, detail), let .NewerDatabase(_, detail):
            return "sync error \(code): \(detail)"
        }
    }
}

extension SyncError: ForwardVersionStoreError {
    public var isForwardVersion: Bool {
        code == SyncErrorCode.newerDatabase || code == SyncErrorCode.incompatibleVersion
    }

    /// How Storage → Stores Needing Attention presents a failed open.
    var storageIssueKind: StorageOpenIssueKind {
        switch code {
        case SyncErrorCode.newerDatabase, SyncErrorCode.incompatibleVersion: return .forwardVersion
        case SyncErrorCode.corrupt: return .corrupt
        case SyncErrorCode.keyStore: return .locked
        default: return .unknown
        }
    }
}

extension Error {
    /// Copy for an error thrown by a sync call, or the error's own description.
    var syncUserMessage: String {
        (self as? SyncError)?.userMessage ?? localizedDescription
    }

    /// Code and detail for logs.
    var syncLogDetail: String {
        (self as? SyncError)?.logDetail ?? String(describing: self)
    }
}
