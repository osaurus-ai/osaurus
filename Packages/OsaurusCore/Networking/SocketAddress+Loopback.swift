//
//  SocketAddress+Loopback.swift
//  osaurus
//
//  Tiny `SocketAddress` extension lifted out of `HTTPHandler.swift` so the
//  loopback test stands on its own and HTTPHandler.swift stays focused on
//  the channel-handler surface.
//

import NIOCore

extension SocketAddress {
    var isLoopback: Bool {
        switch self {
        case .v4(let addr): return addr.host == "127.0.0.1"
        case .v6(let addr): return addr.host == "::1"
        default: return false
        }
    }
}
