import Foundation

/// A cookie stored in the jar (P07). Semantics follow RFC 6265 §5.
public struct Cookie: Hashable, Sendable, Codable, Identifiable {
    public var name: String
    public var value: String
    /// Lower-cased domain without a leading dot.
    public var domain: String
    public var path: String
    /// `nil` for session cookies (kept until the jar is cleared, since the app has no browser session).
    public var expiresAt: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public var sameSite: String?
    /// Sent only to exactly `domain` (no `Domain` attribute was given).
    public var isHostOnly: Bool
    public var createdAt: Date

    public var id: String { "\(domain)|\(path)|\(name)" }

    public init(
        name: String, value: String, domain: String, path: String = "/", expiresAt: Date? = nil, isSecure: Bool = false,
        isHTTPOnly: Bool = false, sameSite: String? = nil, isHostOnly: Bool = true, createdAt: Date = Date()
    ) {
        self.name = name
        self.value = value
        self.domain = domain.lowercased()
        self.path = path
        self.expiresAt = expiresAt
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSite = sameSite
        self.isHostOnly = isHostOnly
        self.createdAt = createdAt
    }

    public func isExpired(at date: Date) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }
}

/// An in-memory cookie jar with RFC 6265 storage and retrieval rules. Persistence is handled by RPData.
public struct CookieJar: Hashable, Sendable, Codable {
    public static let maximumCookies = 3000
    public static let maximumCookiesPerDomain = 50
    public static let maximumCookieBytes = 4096

    public private(set) var cookies: [Cookie]

    public init(cookies: [Cookie] = []) {
        self.cookies = cookies
    }

    /// Stores cookies from `Set-Cookie` header values received for `url`. Invalid cookies are ignored.
    public mutating func store(setCookieHeaders: [String], from url: URL, now: Date) {
        for header in setCookieHeaders {
            guard let cookie = Self.parse(setCookie: header, from: url, now: now) else { continue }
            let identity = cookie.id
            let existing = cookies.firstIndex { $0.id == identity }
            if cookie.isExpired(at: now) {
                if let existing { cookies.remove(at: existing) }
                continue
            }
            if let existing {
                var updated = cookie
                updated.createdAt = cookies[existing].createdAt
                cookies[existing] = updated
            } else {
                cookies.append(cookie)
            }
        }
        enforceLimits(now: now)
    }

    /// Cookies to send to `url`, most specific path first, then oldest first (RFC 6265 §5.4).
    public func cookies(for url: URL, now: Date) -> [Cookie] {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return [] }
        let requestPath = url.path(percentEncoded: true).isEmpty ? "/" : url.path(percentEncoded: true)
        let isSecureChannel = url.scheme?.lowercased() == "https" || LocalAddress.isLoopback(host: host)
        return cookies.filter { cookie in
            !cookie.isExpired(at: now)
                && (cookie.isHostOnly ? host == cookie.domain : Self.domainMatches(host: host, domain: cookie.domain))
                && Self.pathMatches(requestPath: requestPath, cookiePath: cookie.path)
                && (!cookie.isSecure || isSecureChannel)
        }.sorted { lhs, rhs in
            lhs.path.count != rhs.path.count ? lhs.path.count > rhs.path.count : lhs.createdAt < rhs.createdAt
        }
    }

    /// The `Cookie` header value for `url`, or `nil` when no cookie matches.
    public func headerValue(for url: URL, now: Date) -> String? {
        let matching = cookies(for: url, now: now)
        return matching.isEmpty ? nil : matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public mutating func remove(id: String) { cookies.removeAll { $0.id == id } }
    public mutating func removeAll(domain: String) { cookies.removeAll { $0.domain == domain.lowercased() } }
    public mutating func removeAll() { cookies.removeAll() }
    public mutating func removeExpired(now: Date) { cookies.removeAll { $0.isExpired(at: now) } }

    /// Adds or replaces a cookie edited by the user.
    public mutating func upsert(_ cookie: Cookie, now: Date) {
        cookies.removeAll { $0.id == cookie.id }
        cookies.append(cookie)
        enforceLimits(now: now)
    }

    public var domains: [String] { Array(Set(cookies.map(\.domain))).sorted() }

    private mutating func enforceLimits(now: Date) {
        removeExpired(now: now)
        var evict: Set<String> = []
        for (_, domainCookies) in Dictionary(grouping: cookies, by: \.domain)
        where domainCookies.count > Self.maximumCookiesPerDomain {
            let oldestFirst = domainCookies.sorted { $0.createdAt < $1.createdAt }
            evict.formUnion(oldestFirst.prefix(domainCookies.count - Self.maximumCookiesPerDomain).map(\.id))
        }
        if !evict.isEmpty { cookies.removeAll { evict.contains($0.id) } }
        if cookies.count > Self.maximumCookies {
            cookies.sort { $0.createdAt < $1.createdAt }
            cookies.removeFirst(cookies.count - Self.maximumCookies)
        }
    }

    // MARK: Parsing (RFC 6265 §5.2)

    static func parse(setCookie header: String, from url: URL, now: Date) -> Cookie? {
        guard header.utf8.count <= maximumCookieBytes, let host = url.host(percentEncoded: false)?.lowercased() else {
            return nil
        }
        var parts = header.split(separator: ";", omittingEmptySubsequences: false).map { String($0) }
        let pair = parts.removeFirst()
        guard let equals = pair.firstIndex(of: "=") else { return nil }
        let name = pair[..<equals].trimmingCharacters(in: .whitespaces)
        let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        var expires: Date?
        var maxAge: Date?
        var domainAttribute: String?
        var path: String?
        var secure = false
        var httpOnly = false
        var sameSite: String?
        for attribute in parts {
            let pieces = attribute.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
            let argument = pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespaces) : ""
            switch key {
            case "expires": if let date = HTTPDate.parse(argument) { expires = date }
            case "max-age":
                if let seconds = Int(argument) {
                    maxAge =
                        seconds <= 0 ? .distantPast : now.addingTimeInterval(TimeInterval(min(seconds, 400 * 86_400)))
                }
            case "domain":
                let trimmed = argument.hasPrefix(".") ? String(argument.dropFirst()) : argument
                if !trimmed.isEmpty { domainAttribute = trimmed.lowercased() }
            case "path": if argument.hasPrefix("/") { path = argument }
            case "secure": secure = true
            case "httponly": httpOnly = true
            case "samesite": sameSite = argument.isEmpty ? nil : argument.capitalized
            default: break
            }
        }
        if secure, url.scheme?.lowercased() != "https", !LocalAddress.isLoopback(host: host) { return nil }
        let domain: String
        let hostOnly: Bool
        if let domainAttribute {
            guard domainMatches(host: host, domain: domainAttribute),
                LocalAddress.ipv4Octets(host) == nil || host == domainAttribute,
                domainAttribute.contains(".") || domainAttribute == host
            else { return nil }
            domain = domainAttribute
            hostOnly = false
        } else {
            domain = host
            hostOnly = true
        }
        return Cookie(
            name: name, value: value, domain: domain, path: path ?? defaultPath(for: url), expiresAt: maxAge ?? expires,
            isSecure: secure, isHTTPOnly: httpOnly, sameSite: sameSite, isHostOnly: hostOnly, createdAt: now)
    }

    static func domainMatches(host: String, domain: String) -> Bool {
        host == domain || (host.hasSuffix("." + domain) && LocalAddress.ipv4Octets(host) == nil)
    }

    static func pathMatches(requestPath: String, cookiePath: String) -> Bool {
        if requestPath == cookiePath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        return cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).first == "/"
    }

    static func defaultPath(for url: URL) -> String {
        let path = url.path(percentEncoded: true)
        guard path.hasPrefix("/"), let lastSlash = path.lastIndex(of: "/"), lastSlash != path.startIndex else {
            return "/"
        }
        return String(path[..<lastSlash])
    }
}

/// Parses HTTP dates used in `Expires` (RFC 6265 §5.1.1 accepts several formats).
enum HTTPDate {
    private static let formats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy",
        "EEE, dd-MMM-yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z",
    ]

    static func parse(_ text: String) -> Date? {
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
