import Foundation

/// Classifies hosts as local (loopback, `.local`, unqualified, RFC 1918, link-local, unique-local IPv6). Mirrors the
/// ATS exceptions in `Info.plist` (ADR-0010): plain HTTP is only possible to these hosts, and on iOS the local
/// network permission explainer is shown only for them (F01.8, F01.9).
public enum LocalAddress {
    public static func isLocal(host rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if let ipv4 = ipv4Octets(host) { return isLocalIPv4(ipv4) }
        if host.contains(":") { return isLocalIPv6(host) }
        // Unqualified single-label names (e.g. `devbox`) resolve on the local network.
        return !host.contains(".")
    }

    /// Whether `host` is a loopback address or name (no Local Network permission is needed for these).
    public static func isLoopback(host rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return true }
        if let octets = ipv4Octets(host) { return octets[0] == 127 }
        return false
    }

    static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let value = Int(part), value <= 255
            else { return nil }
            return value
        }
        return octets.count == 4 ? octets : nil
    }

    private static func isLocalIPv4(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): true
        case (172, 16...31): true
        default: false
        }
    }

    private static func isLocalIPv6(_ host: String) -> Bool {
        if host == "::1" { return true }
        let firstGroup = host.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard let value = UInt16(firstGroup, radix: 16) else { return false }
        // fe80::/10 link-local, fc00::/7 unique local.
        return (value & 0xFFC0) == 0xFE80 || (value & 0xFE00) == 0xFC00
    }
}
