import Foundation

/// A key/value entry of a `.bru` dictionary block.
public struct BruPair: Hashable, Sendable {
    public enum Value: Hashable, Sendable {
        case single(String)
        /// A `'''` block. `suffix` holds text after the closing quotes (e.g. `@contentType(application/json)`).
        case multiline(String, suffix: String)
        /// A `[ … ]` list (e.g. `meta.tags`).
        case list([String])
    }

    public var key: String
    public var isDisabled: Bool
    public var value: Value
    /// Annotation lines (e.g. `@description('…')`), verbatim without indentation.
    public var annotations: [String]

    public init(key: String, value: Value, isDisabled: Bool = false, annotations: [String] = []) {
        self.key = key
        self.value = value
        self.isDisabled = isDisabled
        self.annotations = annotations
    }

    public init(key: String, text: String, isDisabled: Bool = false, annotations: [String] = []) {
        let value: Value = text.contains("\n") || text.contains("\r") ? .multiline(text, suffix: "") : .single(text)
        self.init(key: key, value: value, isDisabled: isDisabled, annotations: annotations)
    }

    /// The value as one string. Multiline values keep their suffix after a space (Bruno's representation).
    public var text: String {
        switch value {
        case .single(let text): text
        case .multiline(let text, let suffix): suffix.isEmpty ? text : "\(text) \(suffix)"
        case .list(let items): items.joined(separator: ",")
        }
    }
}

/// Parses and serializes the key/value body of `.bru` dictionary blocks, following Bruno's grammar: optional `~`
/// (disabled), optional double-quoted key with `\"` escapes, `:` separator, single-line or `'''` multiline values,
/// `[ … ]` lists, and `@annotation(…)` lines before a pair.
public enum BruDictionary {
    public static func parse(_ block: BruDocument.Block) throws(CoreError) -> [BruPair] {
        try parse(lines: block.lines, firstLine: block.line + 1)
    }

    public static func parse(lines: [String], firstLine: Int) throws(CoreError) -> [BruPair] {
        var pairs: [BruPair] = []
        var annotations: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineNumber = firstLine + index
            if trimmed.isEmpty {
                index += 1
                continue
            }
            if isAnnotation(trimmed) {
                var annotation = trimmed
                // Multiline annotation arguments are delimited by ''' … ''').
                if trimmed.components(separatedBy: "'''").count == 2 {
                    index += 1
                    while index < lines.count {
                        annotation += "\n" + lines[index]
                        if lines[index].contains("'''") { break }
                        index += 1
                    }
                }
                annotations.append(annotation)
                index += 1
                continue
            }
            let (key, isDisabled, splitRest) = try splitKey(trimmed, line: lineNumber)
            var rest = splitRest
            rest = rest.trimmingCharacters(in: .whitespaces)
            let value: BruPair.Value
            if rest.hasPrefix("'''"), rest.trimmingCharacters(in: .whitespaces) == "'''" {
                var content: [String] = []
                var suffix = ""
                var closed = false
                index += 1
                while index < lines.count {
                    let candidate = lines[index]
                    let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                    if candidateTrimmed.hasPrefix("'''") {
                        suffix = String(candidateTrimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        closed = true
                        break
                    }
                    content.append(removeIndent(candidate, upTo: 4))
                    index += 1
                }
                guard closed else {
                    throw .bruSyntax(
                        position: TextPosition(line: lineNumber, column: 1), reason: "A ''' value is not closed")
                }
                value = .multiline(content.joined(separator: "\n"), suffix: suffix)
            } else if rest == "[" {
                var items: [String] = []
                var closed = false
                index += 1
                while index < lines.count {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    if item == "]" {
                        closed = true
                        break
                    }
                    if !item.isEmpty { items.append(item) }
                    index += 1
                }
                guard closed else {
                    throw .bruSyntax(
                        position: TextPosition(line: lineNumber, column: 1), reason: "A list is not closed")
                }
                value = .list(items)
            } else {
                value = .single(rest)
            }
            pairs.append(BruPair(key: key, value: value, isDisabled: isDisabled, annotations: annotations))
            annotations = []
            index += 1
        }
        return pairs
    }

    /// Serializes pairs as indented dictionary lines (2 spaces), in the style Bruno writes.
    public static func lines(for pairs: [BruPair], quoteKeys: Bool = true) -> [String] {
        var output: [String] = []
        for pair in pairs {
            for annotation in pair.annotations {
                output.append(
                    contentsOf: annotation.components(separatedBy: "\n").enumerated().map { offset, line in
                        offset == 0 ? "  " + line : line
                    })
            }
            let key = (pair.isDisabled ? "~" : "") + (quoteKeys ? keyString(pair.key) : pair.key)
            switch pair.value {
            case .single(let text):
                output.append(text.isEmpty ? "  \(key): " : "  \(key): \(text)")
            case .multiline(let text, let suffix):
                output.append("  \(key): '''")
                output.append(contentsOf: text.components(separatedBy: "\n").map { $0.isEmpty ? "    " : "    " + $0 })
                output.append(suffix.isEmpty ? "  '''" : "  ''' \(suffix)")
            case .list(let items):
                output.append("  \(key): [")
                output.append(contentsOf: items.map { "    " + $0 })
                output.append("  ]")
            }
        }
        return output
    }

    /// Bruno quotes keys containing `:`, `"`, `{`, `}` or a space.
    public static func keyString(_ key: String) -> String {
        guard key.contains(where: { ":\"{} ".contains($0) }) else { return key }
        return "\"" + key.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func removeIndent(_ line: String, upTo count: Int) -> String {
        var removed = 0
        var result = Substring(line)
        while removed < count, result.first == " " {
            result = result.dropFirst()
            removed += 1
        }
        return String(result)
    }

    private static func isAnnotation(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("@") else { return false }
        let afterAt = trimmed.dropFirst()
        let name = afterAt.prefix(while: { !"() \t:".contains($0) })
        guard !name.isEmpty else { return false }
        let rest = afterAt.dropFirst(name.count)
        if rest.isEmpty { return true }
        return rest.first == "("
    }

    private static func splitKey(_ trimmed: String, line: Int) throws(CoreError) -> (String, Bool, String) {
        var remainder = Substring(trimmed)
        var isDisabled = false
        if remainder.first == "~" {
            isDisabled = true
            remainder = remainder.dropFirst()
        }
        if remainder.first == "\"" {
            var key = ""
            var cursor = remainder.index(after: remainder.startIndex)
            var closed = false
            while cursor < remainder.endIndex {
                let character = remainder[cursor]
                if character == "\\", remainder.index(after: cursor) < remainder.endIndex,
                    remainder[remainder.index(after: cursor)] == "\""
                {
                    key.append("\"")
                    cursor = remainder.index(cursor, offsetBy: 2)
                    continue
                }
                if character == "\"" {
                    closed = true
                    cursor = remainder.index(after: cursor)
                    break
                }
                key.append(character)
                cursor = remainder.index(after: cursor)
            }
            let after = remainder[cursor...].drop(while: { $0 == " " || $0 == "\t" })
            guard closed, after.first == ":" else {
                throw .bruSyntax(position: TextPosition(line: line, column: 1), reason: "Expected “\"key\": value”")
            }
            return (key, isDisabled, String(after.dropFirst()))
        }
        guard let colon = remainder.firstIndex(of: ":") else {
            throw .bruSyntax(position: TextPosition(line: line, column: 1), reason: "Expected “key: value”")
        }
        let key = remainder[..<colon].trimmingCharacters(in: .whitespaces)
        return (key, isDisabled, String(remainder[remainder.index(after: colon)...]))
    }
}

/// Text blocks (`body:json`, `docs`, `script:*`): content is indented two spaces in the file.
public enum BruText {
    public static func text(of block: BruDocument.Block) -> String {
        var lines = block.lines
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return lines.map { BruDictionary.removeIndent($0, upTo: 2) }.joined(separator: "\n")
    }

    public static func lines(for text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n").map { "  " + $0 }
    }
}
