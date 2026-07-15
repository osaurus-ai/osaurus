//
//  SandboxEgressPolicy.swift
//  osaurus
//
//  Pure policy engine for sandbox network egress. Three modes:
//
//  - `.open`      — unrestricted outbound (shared-NAT vmnet, today's
//                   default). Explicitly user-chosen behavior.
//  - `.allowlist` — host-only vmnet + host-side CONNECT proxy; only
//                   exact / `*.wildcard` domain matches may connect.
//  - `.none`      — no guest networking at all.
//
//  The matcher rejects IP literals and private/reserved destinations
//  outright in allowlist mode: an allowlist names *domains*, and letting
//  raw IPs through would bypass both the name policy and the
//  DNS-rebinding defense (the proxy re-checks resolved addresses with
//  `isBlockedAddress` before connecting).
//
//  Everything here is synchronous and dependency-free so the full
//  matrix (wildcards, IDNA-ish edge cases, rebinding ranges) is unit
//  tested without a VM or a socket.
//

import Foundation

#if os(macOS)

    public enum SandboxEgressMode: Equatable, Sendable {
        /// Unrestricted outbound NAT — the user explicitly chose no filter.
        case open
        /// Host-only network; egress only through the filtering proxy.
        case allowlist([String])
        /// No guest networking.
        case none
    }

    public enum SandboxEgressPolicy {

        // MARK: - Mode resolution

        /// Resolve the boot-time egress mode from the provisioning agent's
        /// autonomous-exec configuration. `sandboxNetworkEnabled == false`
        /// wins (no network); otherwise a non-empty domain list selects the
        /// proxy path and an empty/absent list keeps today's unrestricted
        /// NAT. The VM is still shared across agents, so this is the
        /// *boot* mode; per-agent allowlists are enforced per-connection
        /// by the proxy using the caller's bridge token.
        public static func mode(
            networkEnabled: Bool,
            allowedDomains: [String]?
        ) -> SandboxEgressMode {
            guard networkEnabled else { return .none }
            let domains = normalizedAllowlist(allowedDomains)
            return domains.isEmpty ? .open : .allowlist(domains)
        }

        /// Lowercase, trim, drop empties and invalid patterns. Accepts
        /// `example.com` (exact) and `*.example.com` (any single-or-deeper
        /// subdomain, NOT the apex).
        public static func normalizedAllowlist(_ raw: [String]?) -> [String] {
            guard let raw else { return [] }
            return raw
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { isValidPattern($0) }
        }

        static func isValidPattern(_ pattern: String) -> Bool {
            guard !pattern.isEmpty, pattern.count <= 255 else { return false }
            let body = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
            guard !body.isEmpty, !body.contains("*") else { return false }
            // Must look like a dotted domain, not an IP literal or a
            // single label (single labels are almost always internal
            // hostnames — reject them; users can still pick `.open`).
            guard body.contains("."), !isIPLiteral(body) else { return false }
            let labelPattern = "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"
            for label in body.split(separator: ".") {
                guard label.range(of: labelPattern, options: .regularExpression) != nil else {
                    return false
                }
            }
            return true
        }

        // MARK: - Host matching

        /// Whether `host` (a DNS name from a CONNECT / absolute-URI proxy
        /// request) is allowed by `allowlist`. IP literals are always
        /// rejected here — allowlists name domains, and the proxy
        /// separately re-validates resolved addresses.
        public static func hostAllowed(_ host: String, allowlist: [String]) -> Bool {
            let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !normalized.isEmpty, !isIPLiteral(normalized) else { return false }
            for pattern in allowlist {
                if pattern.hasPrefix("*.") {
                    let suffix = String(pattern.dropFirst(1))  // ".example.com"
                    if normalized.hasSuffix(suffix), normalized.count > suffix.count {
                        return true
                    }
                } else if normalized == pattern {
                    return true
                }
            }
            return false
        }

        // MARK: - IP literal / private-range rejection

        /// True when `host` parses as an IPv4 or IPv6 literal (including
        /// bracketed IPv6 as it appears in URLs / CONNECT targets).
        public static func isIPLiteral(_ host: String) -> Bool {
            var trimmed = host
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                trimmed = String(trimmed.dropFirst().dropLast())
            }
            var v4 = in_addr()
            if inet_pton(AF_INET, trimmed, &v4) == 1 { return true }
            var v6 = in6_addr()
            if inet_pton(AF_INET6, trimmed, &v6) == 1 { return true }
            return false
        }

        /// True when a *resolved* address must not be connected to from the
        /// filtering proxy: loopback, RFC1918/ULA private space, link-local,
        /// CGNAT, multicast/reserved, and the unspecified address. This is
        /// the DNS-rebinding defense — a public hostname that resolves into
        /// the host's LAN is refused even though its *name* was allowed.
        public static func isBlockedAddress(_ address: String) -> Bool {
            var trimmed = address
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                trimmed = String(trimmed.dropFirst().dropLast())
            }

            var v4 = in_addr()
            if inet_pton(AF_INET, trimmed, &v4) == 1 {
                let value = UInt32(bigEndian: v4.s_addr)
                let blockedV4: [(UInt32, UInt32)] = [
                    (0x0000_0000, 0xFF00_0000),  // 0.0.0.0/8
                    (0x0A00_0000, 0xFF00_0000),  // 10/8
                    (0x6440_0000, 0xFFC0_0000),  // 100.64/10 CGNAT
                    (0x7F00_0000, 0xFF00_0000),  // 127/8 loopback
                    (0xA9FE_0000, 0xFFFF_0000),  // 169.254/16 link-local
                    (0xAC10_0000, 0xFFF0_0000),  // 172.16/12
                    (0xC0A8_0000, 0xFFFF_0000),  // 192.168/16
                    (0xE000_0000, 0xF000_0000),  // 224/4 multicast
                    (0xF000_0000, 0xF000_0000),  // 240/4 reserved + broadcast
                ]
                return blockedV4.contains { value & $0.1 == $0.0 }
            }

            var v6 = in6_addr()
            if inet_pton(AF_INET6, trimmed, &v6) == 1 {
                let bytes = withUnsafeBytes(of: v6) { Array($0) }
                // ::/128 unspecified and ::1/128 loopback
                if bytes[0..<15].allSatisfy({ $0 == 0 }) && (bytes[15] == 0 || bytes[15] == 1) {
                    return true
                }
                // ::ffff:a.b.c.d — recheck the embedded IPv4.
                if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                    let mapped = "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
                    return isBlockedAddress(mapped)
                }
                if bytes[0] == 0xFC || bytes[0] == 0xFD { return true }  // fc00::/7 ULA
                if bytes[0] == 0xFE, (bytes[1] & 0xC0) == 0x80 { return true }  // fe80::/10
                if bytes[0] == 0xFF { return true }  // ff00::/8 multicast
                return false
            }

            // Not parseable as an address at all — block, fail closed.
            return true
        }

        // MARK: - Per-agent allowlist resolution

        /// Union of the agent's own configured domains and the domain
        /// allowlists declared by that agent's installed plugins
        /// (`permissions.network` as a comma-separated domain list —
        /// "outbound"/"none" contribute nothing). This is what the proxy
        /// enforces per token-authenticated connection.
        public static func resolvedAllowlist(
            agentDomains: [String]?,
            pluginNetworkPermissions: [String?]
        ) -> [String] {
            var patterns = normalizedAllowlist(agentDomains)
            for permission in pluginNetworkPermissions {
                guard let permission, permission != "outbound", permission != "none" else {
                    continue
                }
                let domains = permission.split(separator: ",").map(String.init)
                patterns.append(contentsOf: normalizedAllowlist(domains))
            }
            var seen = Set<String>()
            return patterns.filter { seen.insert($0).inserted }
        }
    }

#endif
