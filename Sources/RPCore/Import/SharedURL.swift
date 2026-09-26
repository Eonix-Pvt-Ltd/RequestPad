import Foundation

/// Reads a URL from text shared with RequestPad (macOS Services "Send URL with RequestPad", X01.3). The text is
/// untrusted: only a single http(s) URL, or a bare host with an optional path, is accepted.
public enum SharedURL {
    /// Longer selections are not URLs worth opening.
    public static let maximumLength = 8 * 1024

    /// Returns a normalized `http`/`https` URL string, or `nil` when the text isn't one URL.
    public static func url(from text: String) -> String? {
        guard text.utf8.count <= maximumLength else { return nil }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var candidate = firstLine.trimmingCharacters(in: .whitespaces)
        // Common wrappers when copying from prose, Markdown or email: <…>, "…", '…', `…`.
        for (open, close) in [("<", ">"), ("\"", "\""), ("'", "'"), ("`", "`")]
        where candidate.count >= 2 && candidate.hasPrefix(open) && candidate.hasSuffix(close) {
            candidate = String(candidate.dropFirst().dropLast())
        }
        guard !candidate.isEmpty, !candidate.contains(where: \.isWhitespace) else { return nil }
        if let scheme = candidate.range(of: "://").map({ candidate[..<$0.lowerBound].lowercased() }) {
            guard scheme == "http" || scheme == "https" else { return nil }
        } else {
            // No scheme: only a host (with a dot, or localhost) followed by an optional port/path/query.
            let host = candidate.prefix { $0 != "/" && $0 != ":" && $0 != "?" && $0 != "#" }
            guard host.contains(".") || host.lowercased() == "localhost" else { return nil }
            candidate = RequestResolver.addingDefaultScheme(to: candidate)
        }
        guard let components = URLComponents(string: candidate), let host = components.host, !host.isEmpty,
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return candidate
    }

    /// A short name for a request made from a shared URL: the host.
    public static func requestName(for url: String) -> String {
        URLComponents(string: url)?.host ?? url
    }
}
