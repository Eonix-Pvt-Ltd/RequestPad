import Foundation

/// Keeps a URL's query string and the query-params table in sync (F01.2). Works on template text, so `{{vars}}`
/// are preserved and never percent-encoded.
public enum QueryParameters {
    /// Parses the query part of `url` into rows. `a=1&b&c=` → `[a:1, b:"", c:""]`. Percent-escapes are decoded
    /// except inside `{{…}}`.
    public static func parse(fromURL url: String) -> [KeyValue] {
        guard let query = queryString(of: url), !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = decode(String(parts[0]))
            let value = parts.count > 1 ? decode(String(parts[1])) : ""
            return KeyValue(name: name, value: value)
        }
    }

    /// Returns `url` with its query replaced by the enabled rows (disabled rows are omitted, F01.2).
    /// Rows are encoded minimally so templates remain readable.
    public static func url(_ url: String, replacingQueryWith rows: [KeyValue]) -> String {
        let (base, fragment) = splitFragment(url)
        let withoutQuery =
            base.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? base
        let encoded = rows.filter { $0.isEnabled && !$0.name.isEmpty }.map { row in
            row.value.isEmpty ? encode(row.name) : "\(encode(row.name))=\(encode(row.value))"
        }
        var result = withoutQuery
        if !encoded.isEmpty { result += "?" + encoded.joined(separator: "&") }
        if let fragment { result += "#" + fragment }
        return result
    }

    /// Merges parsed URL rows with existing rows so disabled rows (not present in the URL) are kept in place.
    public static func merge(urlRows: [KeyValue], into existing: [KeyValue]) -> [KeyValue] {
        var remaining = urlRows
        var result: [KeyValue] = []
        for row in existing {
            if !row.isEnabled {
                result.append(row)
            } else if !remaining.isEmpty {
                var updated = remaining.removeFirst()
                updated.id = row.id
                updated.annotations = row.annotations
                result.append(updated)
            }
        }
        result.append(contentsOf: remaining)
        return result
    }

    static func queryString(of url: String) -> String? {
        let (base, _) = splitFragment(url)
        guard let mark = base.firstIndex(of: "?") else { return nil }
        return String(base[base.index(after: mark)...])
    }

    private static func splitFragment(_ url: String) -> (String, String?) {
        guard let hash = url.firstIndex(of: "#") else { return (url, nil) }
        return (String(url[..<hash]), String(url[url.index(after: hash)...]))
    }

    private static let unreservedInQuery: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#")
        return set
    }()

    static func encode(_ text: String) -> String {
        var output = ""
        var cursor = text.startIndex
        for token in Interpolator.tokens(in: text) {
            output +=
                text[cursor..<token.range.lowerBound].addingPercentEncoding(withAllowedCharacters: unreservedInQuery)
                ?? ""
            output += text[token.range]
            cursor = token.range.upperBound
        }
        output += text[cursor...].addingPercentEncoding(withAllowedCharacters: unreservedInQuery) ?? ""
        return output
    }

    static func decode(_ text: String) -> String {
        let plusDecoded = text.replacingOccurrences(of: "+", with: " ")
        return plusDecoded.removingPercentEncoding ?? plusDecoded
    }
}
