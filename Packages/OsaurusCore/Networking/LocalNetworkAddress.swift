//
//  LocalNetworkAddress.swift
//  osaurus
//
//  The IPv4 address other machines on the LAN use to reach this Mac. Shared
//  by the server status panel and the n8n pairing code so both show the
//  same address.
//

import Darwin
import Foundation

enum LocalNetworkAddress {
    /// First running, non-loopback IPv4 address on an `en*` interface
    /// (Wi-Fi / Ethernet on macOS). Falls back to `127.0.0.1` when none is
    /// up, so callers can compare against loopback to detect "not on a LAN".
    static func primaryIPv4() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return address }
        guard let firstAddr = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee

            // Running IPv4 interface that is not loopback.
            guard (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING),
                addr.sa_family == AF_INET
            else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    ptr.pointee.ifa_addr,
                    socklen_t(addr.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    socklen_t(0),
                    NI_NUMERICHOST
                ) == 0
            else { continue }

            // Trim at NUL terminator before decoding to avoid deprecated cString initializer.
            let nulTrimmed = hostname.prefix { $0 != 0 }
            let ip = String(decoding: nulTrimmed.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = String(cString: ptr.pointee.ifa_name)
            if name.starts(with: "en") {
                address = ip
                break
            }
        }
        return address
    }
}
