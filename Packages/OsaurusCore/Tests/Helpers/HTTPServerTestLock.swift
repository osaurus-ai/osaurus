//
//  HTTPServerTestLock.swift
//  OsaurusCoreTests
//
//  Process-wide serialization for tests that boot real loopback NIO servers.
//  `@Suite(.serialized)` only serializes tests within one suite, while the
//  networking suites all share URLSession, NIO loopback sockets, and the same
//  host scheduler. Running many tiny servers at once can starve individual
//  URLSession requests until they hit the 60s default timeout.
//

import Foundation

actor HTTPServerTestLock {
    static let shared = HTTPServerTestLock()

    private var holder = false
    private var activeLeaseIDs: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async -> HTTPServerTestLease {
        if !holder {
            holder = true
            return makeLease()
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        return makeLease()
    }

    fileprivate func release(id: UUID) {
        guard activeLeaseIDs.remove(id) != nil else {
            return
        }

        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            holder = false
        }
    }

    private func makeLease() -> HTTPServerTestLease {
        let id = UUID()
        activeLeaseIDs.insert(id)
        return HTTPServerTestLease(lock: self, id: id)
    }
}

final class HTTPServerTestLease: @unchecked Sendable {
    private let lock: HTTPServerTestLock
    private let id: UUID

    fileprivate init(lock: HTTPServerTestLock, id: UUID) {
        self.lock = lock
        self.id = id
    }

    func release() async {
        await lock.release(id: id)
    }
}
