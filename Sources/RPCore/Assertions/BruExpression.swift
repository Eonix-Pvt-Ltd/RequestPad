import Foundation

/// Converts between ``ResponseSource`` and the subset of Bruno `res.*` expressions RequestPad evaluates without a
/// script engine: `res.status`, `res.responseTime`, `res.headers.name`, `res.headers["name"]`, `res.body`,
/// `res.body.a.b[0]`, `res.body["key with space"]`, and `res("a.b")` (Bruno's query shorthand for the body).
public enum BruExpression {
    public static func parse(_ expression: String) -> ResponseSource? {
        let text = expression.trimmingCharacters(in: .whitespaces)
        switch text {
        case "res.status", "res.getStatus()": return .status
        case "res.responseTime", "res.getResponseTime()": return .responseTime
        case "res.body", "res.getBody()": return .body(path: "$")
        default: break
        }
        if let header = headerName(in: text) { return .header(header) }
        if text.hasPrefix("res.body") {
            return bodyPath(String(text.dropFirst("res.body".count))).map { .body(path: $0) }
        }
        if text.hasPrefix("res(\""), text.hasSuffix("\")") {
            let inner = String(text.dropFirst(5).dropLast(2))
            guard !inner.isEmpty, !inner.contains("\"") else { return nil }
            return bodyPath("." + inner).map { .body(path: $0) }
        }
        return nil
    }

    public static func format(_ source: ResponseSource) -> String {
        switch source {
        case .status: return "res.status"
        case .responseTime: return "res.responseTime"
        case .header(let name):
            return isIdentifier(name) ? "res.headers.\(name)" : "res.headers[\"\(escape(name))\"]"
        case .body(let path):
            guard let segments = try? JSONPath(path).simpleSegments else { return "res.body" }
            var result = "res.body"
            for segment in segments {
                switch segment {
                case .key(let key):
                    result += isIdentifier(key) ? ".\(key)" : "[\"\(escape(key))\"]"
                case .index(let index):
                    result += "[\(index)]"
                }
            }
            return result
        }
    }

    private static func headerName(in text: String) -> String? {
        if text.hasPrefix("res.headers."), text.count > "res.headers.".count {
            let name = String(text.dropFirst("res.headers.".count))
            return isHeaderToken(name) ? name.lowercased() : nil
        }
        if text.hasPrefix("res.headers[\""), text.hasSuffix("\"]") {
            let name = String(text.dropFirst("res.headers[\"".count).dropLast(2))
            return isHeaderToken(name) ? name.lowercased() : nil
        }
        if text.hasPrefix("res.headers['"), text.hasSuffix("']") {
            let name = String(text.dropFirst("res.headers['".count).dropLast(2))
            return isHeaderToken(name) ? name.lowercased() : nil
        }
        return nil
    }

    /// Converts a JavaScript-style accessor suffix (`.a[0]["b"]`) to a JSON path. Returns nil for anything else
    /// (method calls, expressions).
    private static func bodyPath(_ accessor: String) -> String? {
        if accessor.isEmpty { return "$" }
        var path = "$"
        var index = accessor.startIndex
        while index < accessor.endIndex {
            let character = accessor[index]
            if character == "." {
                let start = accessor.index(after: index)
                var end = start
                while end < accessor.endIndex, accessor[end] != ".", accessor[end] != "[" {
                    end = accessor.index(after: end)
                }
                let key = String(accessor[start..<end])
                guard isIdentifier(key) else { return nil }
                path += ".\(key)"
                index = end
            } else if character == "[" {
                guard let close = accessor[index...].firstIndex(of: "]") else { return nil }
                let inner = String(accessor[accessor.index(after: index)..<close])
                if let number = Int(inner), number >= 0 {
                    path += "[\(number)]"
                } else if inner.count >= 2, let quote = inner.first, quote == "\"" || quote == "'", inner.last == quote
                {
                    let key = String(inner.dropFirst().dropLast())
                    guard !key.contains(quote) else { return nil }
                    path += "['\(key.replacingOccurrences(of: "'", with: "\\'"))']"
                } else {
                    return nil
                }
                index = accessor.index(after: close)
            } else {
                return nil
            }
        }
        return path
    }

    static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first,
            first == "_" || first == "$" || CharacterSet.letters.contains(first)
        else { return false }
        return text.unicodeScalars.allSatisfy {
            $0 == "_" || $0 == "$" || CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func isHeaderToken(_ text: String) -> Bool {
        HTTPMethod.isValidToken(text, maximumLength: 256)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
