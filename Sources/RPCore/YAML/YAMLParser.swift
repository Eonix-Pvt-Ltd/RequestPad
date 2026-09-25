import Foundation

/// A YAML 1.2 subset parser sufficient for OpenAPI documents (ADR-0014), producing ``JSONValue``.
///
/// Supported: block mappings and sequences (including compact `- key: value`), flow collections spanning lines,
/// plain / single-quoted / double-quoted scalars with line folding, literal (`|`) and folded (`>`) block scalars
/// with chomping and indentation indicators, comments, `---`/`...` markers (first document only), anchors and
/// aliases (at most ``maximumAliasExpansions``), merge keys (`<<`), and core-schema tags (`!!str`, `!!int`, …).
/// Not supported (reported as errors): complex `?` keys, custom tags, directives other than `%YAML`.
public struct YAMLParser: Sendable {
    public static let defaultMaximumBytes = 10 * 1024 * 1024
    public static let maximumAliasExpansions = 100
    /// Largest number of nodes a document may expand to, counting every alias at its full size. Stops
    /// "billion laughs" documents that stay under the alias cap but grow exponentially.
    public static let maximumExpandedNodes = 1_000_000

    public var maximumBytes: Int
    public var maximumDepth: Int

    public init(maximumBytes: Int = defaultMaximumBytes, maximumDepth: Int = 64) {
        self.maximumBytes = maximumBytes
        self.maximumDepth = maximumDepth
    }

    public func parse(_ text: String) throws(CoreError) -> JSONValue {
        guard text.utf8.count <= maximumBytes else { throw .inputTooLarge(limitBytes: maximumBytes) }
        var reader = YAMLReader(text: text, maximumDepth: maximumDepth)
        return try reader.parseDocument()
    }
}

private struct YAMLLine {
    /// 1-based line number.
    let number: Int
    /// Leading spaces.
    var indent: Int
    /// Text after the indentation (comments not yet removed).
    var content: String
    /// The complete original line.
    let raw: String

    var isBlankOrComment: Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }
}

private struct YAMLReader {
    var lines: [YAMLLine]
    var index = 0
    let maximumDepth: Int
    var anchors: [String: JSONValue] = [:]
    var anchorSizes: [String: Int] = [:]
    var aliasExpansions = 0
    /// Nodes produced so far, with aliases counted at their expanded size.
    var expandedNodes = 0

    mutating func countNodes(_ count: Int, line: YAMLLine?) throws(CoreError) {
        expandedNodes += count
        guard expandedNodes <= YAMLParser.maximumExpandedNodes else {
            throw error("The document expands to more than \(YAMLParser.maximumExpandedNodes) values", line: line)
        }
    }

    mutating func resolveAlias(_ name: String, line: YAMLLine?) throws(CoreError) -> JSONValue {
        guard let value = anchors[name] else { throw error("Unknown alias *\(name)", line: line) }
        aliasExpansions += 1
        guard aliasExpansions <= YAMLParser.maximumAliasExpansions else {
            throw error("Too many aliases (limit \(YAMLParser.maximumAliasExpansions))", line: line)
        }
        try countNodes(anchorSizes[name] ?? 1, line: line)
        return value
    }

    mutating func defineAnchor(_ name: String, value: JSONValue, sizeSince start: Int) {
        anchors[name] = value
        anchorSizes[name] = max(expandedNodes - start, 1)
    }

    init(text: String, maximumDepth: Int) {
        self.maximumDepth = maximumDepth
        var result: [YAMLLine] = []
        var rawLines = text.components(separatedBy: "\n")
        if let first = rawLines.first, first.hasPrefix("\u{FEFF}") { rawLines[0] = String(first.dropFirst()) }
        for (offset, rawLine) in rawLines.enumerated() {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let indent = line.prefix(while: { $0 == " " }).count
            result.append(
                YAMLLine(number: offset + 1, indent: indent, content: String(line.dropFirst(indent)), raw: line))
        }
        lines = result
    }

    // MARK: Errors

    func error(_ reason: String, line: YAMLLine? = nil, column: Int? = nil) -> CoreError {
        let target = line ?? (index < lines.count ? lines[index] : lines.last)
        return .yamlSyntax(
            position: TextPosition(line: target?.number ?? 1, column: column ?? ((target?.indent ?? 0) + 1)),
            reason: reason)
    }

    // MARK: Document

    mutating func parseDocument() throws(CoreError) -> JSONValue {
        skipBlankLines()
        while index < lines.count, lines[index].indent == 0, lines[index].content.hasPrefix("%") {
            guard lines[index].content.hasPrefix("%YAML") else { throw error("Only the %YAML directive is supported") }
            index += 1
            skipBlankLines()
        }
        if index < lines.count, lines[index].indent == 0, isMarker(lines[index].content, "---") {
            let rest = String(lines[index].content.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || rest.hasPrefix("#") {
                index += 1
            } else {
                lines[index].content = rest
                lines[index].indent = 4
            }
        }
        skipBlankLines()
        guard index < lines.count, !isDocumentEnd(lines[index]) else { return .null }
        let value = try parseNode(minimumIndent: 0, depth: 0)
        skipBlankLines()
        if index < lines.count, !isDocumentEnd(lines[index]) {
            throw error("Unexpected content; check the indentation")
        }
        return value
    }

    func isMarker(_ content: String, _ marker: String) -> Bool {
        content == marker || content.hasPrefix(marker + " ") || content.hasPrefix(marker + "\t")
    }

    func isDocumentEnd(_ line: YAMLLine) -> Bool {
        line.indent == 0 && (isMarker(line.content, "---") || isMarker(line.content, "..."))
    }

    mutating func skipBlankLines() {
        while index < lines.count, lines[index].isBlankOrComment { index += 1 }
    }

    // MARK: Nodes

    mutating func parseNode(minimumIndent: Int, depth: Int) throws(CoreError) -> JSONValue {
        guard depth <= maximumDepth else { throw .nestingTooDeep(limit: maximumDepth) }
        skipBlankLines()
        guard index < lines.count, !isDocumentEnd(lines[index]) else { return .null }
        let line = lines[index]
        guard line.indent >= minimumIndent else { return .null }
        if line.content.hasPrefix("\t") { throw error("Tabs can't be used for indentation", line: line) }
        if isSequenceEntry(line.content) {
            return try parseSequence(indent: line.indent, depth: depth + 1)
        }
        if line.content.hasPrefix("? ") || line.content == "?" {
            throw error("Complex mapping keys (?) are not supported", line: line)
        }
        if try mappingKey(in: line) != nil {
            return try parseMapping(indent: line.indent, depth: depth + 1)
        }
        // A scalar or flow node on its own line.
        let content = stripComment(line.content)
        return try parseInlineValue(content, line: line, parentIndent: line.indent - 1, depth: depth + 1)
    }

    func isSequenceEntry(_ content: String) -> Bool {
        content == "-" || content.hasPrefix("- ") || content.hasPrefix("-\t")
    }

    mutating func parseSequence(indent: Int, depth: Int) throws(CoreError) -> JSONValue {
        guard depth <= maximumDepth else { throw .nestingTooDeep(limit: maximumDepth) }
        try countNodes(1, line: index < lines.count ? lines[index] : nil)
        var items: [JSONValue] = []
        while true {
            skipBlankLines()
            guard index < lines.count, !isDocumentEnd(lines[index]) else { break }
            let line = lines[index]
            guard line.indent == indent, isSequenceEntry(line.content) else {
                if line.indent > indent { throw error("Unexpected indentation in a sequence", line: line) }
                break
            }
            let rest = String(line.content.dropFirst(1))
            let restTrimmed = rest.trimmingCharacters(in: .whitespaces)
            if restTrimmed.isEmpty || restTrimmed.hasPrefix("#") {
                index += 1
                items.append(try parseNode(minimumIndent: indent + 1, depth: depth + 1))
            } else {
                // Re-read the rest of the line as a node indented at its own column (compact nesting).
                let leading = rest.prefix(while: { $0 == " " || $0 == "\t" }).count
                lines[index].indent = indent + 1 + leading
                lines[index].content = String(rest.dropFirst(leading))
                items.append(try parseNode(minimumIndent: lines[index].indent, depth: depth + 1))
            }
        }
        return .array(items)
    }

    struct KeyInfo {
        var key: String
        /// Text after the `:` (not trimmed).
        var rest: String
        /// Column (0-based, within the content) where the value starts.
        var valueOffset: Int
        var isMergeKey: Bool
    }

    /// If the line is a `key: value` mapping entry, returns the key and the remaining text.
    func mappingKey(in line: YAMLLine) throws(CoreError) -> KeyInfo? {
        let content = line.content
        guard let first = content.first, !"[{#*|>%@`".contains(first) else { return nil }
        var keyText: String
        var afterKey: Substring
        if first == "\"" || first == "'" {
            guard let (value, end) = try? scanQuotedOnLine(content, quote: first, line: line) else { return nil }
            keyText = value
            afterKey = content[end...]
            let spaces = afterKey.prefix(while: { $0 == " " })
            afterKey = afterKey.dropFirst(spaces.count)
            guard afterKey.first == ":" else { return nil }
        } else {
            guard let colon = mappingColon(in: content) else { return nil }
            keyText = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
            if keyText.hasPrefix("&") || keyText.hasPrefix("!") || keyText.hasPrefix("*") {
                return nil
            }
            afterKey = content[colon...]
        }
        let rest = afterKey.dropFirst()
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        let offset = content.distance(from: content.startIndex, to: rest.startIndex)
        return KeyInfo(
            key: keyText, rest: String(rest), valueOffset: offset,
            isMergeKey: keyText == "<<" && first != "\"" && first != "'")
    }

    /// The index of the first `:` followed by whitespace or end of line, outside flow brackets.
    func mappingColon(in content: String) -> String.Index? {
        var index = content.startIndex
        var previousWasSpace = true
        while index < content.endIndex {
            let character = content[index]
            if character == "#", previousWasSpace { return nil }
            if character == ":" {
                let next = content.index(after: index)
                if next == content.endIndex || content[next] == " " || content[next] == "\t" { return index }
            }
            previousWasSpace = character == " " || character == "\t"
            index = content.index(after: index)
        }
        return nil
    }

    mutating func parseMapping(indent: Int, depth: Int) throws(CoreError) -> JSONValue {
        guard depth <= maximumDepth else { throw .nestingTooDeep(limit: maximumDepth) }
        try countNodes(1, line: index < lines.count ? lines[index] : nil)
        var members: [JSONMember] = []
        var merged: [JSONMember] = []
        while true {
            skipBlankLines()
            guard index < lines.count, !isDocumentEnd(lines[index]) else { break }
            let line = lines[index]
            guard line.indent == indent else {
                if line.indent > indent { throw error("Unexpected indentation in a mapping", line: line) }
                break
            }
            guard let info = try mappingKey(in: line) else {
                if isSequenceEntry(line.content) { break }
                throw error("Expected “key: value”", line: line)
            }
            let valueText = stripComment(info.rest).trimmingCharacters(in: .whitespaces)
            let value: JSONValue
            if valueText.isEmpty {
                index += 1
                skipBlankLines()
                if index < lines.count, lines[index].indent == indent, isSequenceEntry(lines[index].content) {
                    value = try parseSequence(indent: indent, depth: depth + 1)
                } else if index < lines.count, lines[index].indent > indent, !isDocumentEnd(lines[index]) {
                    value = try parseNode(minimumIndent: indent + 1, depth: depth + 1)
                } else {
                    value = .null
                }
            } else {
                value = try parseInlineValue(valueText, line: line, parentIndent: indent, depth: depth + 1)
            }
            if info.isMergeKey {
                try mergeValue(value, into: &merged, line: line)
            } else if let existing = members.firstIndex(where: { $0.key == info.key }) {
                members[existing].value = value
            } else {
                members.append(JSONMember(info.key, value))
            }
        }
        for member in merged where !members.contains(where: { $0.key == member.key }) {
            members.append(member)
        }
        return .object(members)
    }

    func mergeValue(_ value: JSONValue, into merged: inout [JSONMember], line: YAMLLine) throws(CoreError) {
        switch value {
        case .object(let members):
            for member in members where !merged.contains(where: { $0.key == member.key }) { merged.append(member) }
        case .array(let values):
            for item in values {
                guard case .object = item else { throw error("A merge key (<<) needs mappings", line: line) }
                try mergeValue(item, into: &merged, line: line)
            }
        default:
            throw error("A merge key (<<) needs a mapping", line: line)
        }
    }

    // MARK: Inline values

    /// Parses a value that starts on `line` (after `key:` or `- `, or alone). May consume following lines.
    mutating func parseInlineValue(
        _ text: String, line: YAMLLine, parentIndent: Int, depth: Int
    ) throws(CoreError) -> JSONValue {
        var text = text
        var anchor: String?
        var tag: String?
        // Properties: &anchor and !tag in any order.
        while let first = text.first, first == "&" || first == "!" {
            let token = text.prefix(while: { $0 != " " && $0 != "\t" })
            text = String(text.dropFirst(token.count)).trimmingCharacters(in: .whitespaces)
            if first == "&" {
                anchor = String(token.dropFirst())
                guard !(anchor ?? "").isEmpty else { throw error("An anchor needs a name", line: line) }
            } else {
                tag = String(token)
            }
        }
        let sizeStart = expandedNodes
        var value: JSONValue
        if text.isEmpty {
            index += 1
            skipBlankLines()
            if index < lines.count, lines[index].indent > parentIndent, !isDocumentEnd(lines[index]) {
                value = try parseNode(minimumIndent: parentIndent + 1, depth: depth)
            } else {
                value = .null
            }
        } else if text.hasPrefix("*") {
            let name = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            value = try resolveAlias(name, line: line)
            index += 1
        } else if text.hasPrefix("|") || text.hasPrefix(">") {
            try countNodes(1, line: line)
            value = .string(try parseBlockScalar(header: text, line: line, parentIndent: parentIndent))
        } else if text.hasPrefix("[") || text.hasPrefix("{") {
            value = try parseFlowNode(startingWith: text, line: line, depth: depth)
        } else if text.hasPrefix("\"") || text.hasPrefix("'") {
            try countNodes(1, line: line)
            value = .string(try parseQuotedScalar(startingWith: text, line: line))
        } else {
            try countNodes(1, line: line)
            let plain = parsePlainScalar(first: text, parentIndent: parentIndent)
            value = tag == nil ? resolvePlain(plain) : .string(plain)
        }
        if let tag { value = try applyTag(tag, to: value, line: line) }
        if let anchor { defineAnchor(anchor, value: value, sizeSince: sizeStart) }
        return value
    }

    func applyTag(_ tag: String, to value: JSONValue, line: YAMLLine) throws(CoreError) -> JSONValue {
        let text: String? = {
            switch value {
            case .string(let string): string
            case .number(let number): number
            case .bool(let bool): bool ? "true" : "false"
            case .null: ""
            default: nil
            }
        }()
        switch tag {
        case "!!str", "!": return text.map(JSONValue.string) ?? value
        case "!!int", "!!float":
            guard let text, case .number(let number) = resolvePlain(text) else {
                throw error("The value is not a number", line: line)
            }
            return .number(number)
        case "!!bool":
            guard let text, case .bool(let bool) = resolvePlain(text) else {
                throw error("The value is not a boolean", line: line)
            }
            return .bool(bool)
        case "!!null": return .null
        case "!!map", "!!seq", "!!binary", "!!timestamp": return value
        default: throw error("The tag \(tag) is not supported", line: line)
        }
    }

    // MARK: Plain scalars

    /// Removes a trailing `# comment`. Quotes are only tracked for quoted scalars and flow collections, so an
    /// apostrophe inside plain text (`it's # note`) doesn't hide the comment.
    func stripComment(_ text: String) -> String {
        let first = text.first(where: { $0 != " " && $0 != "\t" })
        guard let first, "'\"[{".contains(first) else {
            var previousWasSpace = true
            var index = text.startIndex
            while index < text.endIndex {
                let character = text[index]
                if character == "#", previousWasSpace { return String(text[..<index]) }
                previousWasSpace = character == " " || character == "\t"
                index = text.index(after: index)
            }
            return text
        }
        var previousWasSpace = true
        var inSingle = false
        var inDouble = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "'" && !inDouble { inSingle.toggle() }
            if character == "\"" && !inSingle { inDouble.toggle() }
            if character == "#", previousWasSpace, !inSingle, !inDouble { return String(text[..<index]) }
            previousWasSpace = character == " " || character == "\t"
            index = text.index(after: index)
        }
        return text
    }

    /// Reads a plain scalar starting with `first` (already comment-stripped) plus continuation lines indented more
    /// than `parentIndent`, folding line breaks.
    mutating func parsePlainScalar(first: String, parentIndent: Int) -> String {
        var result = first.trimmingCharacters(in: .whitespaces)
        index += 1
        var pendingNewlines = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.content.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                pendingNewlines += 1
                index += 1
                continue
            }
            // Continuation lines are more indented than the parent and can't be mapping entries or comments.
            guard line.indent > parentIndent, !isDocumentEnd(line), !trimmed.hasPrefix("#"),
                (try? mappingKey(in: line)) == nil
            else { break }
            let piece = stripComment(trimmed).trimmingCharacters(in: .whitespaces)
            result += pendingNewlines > 0 ? String(repeating: "\n", count: pendingNewlines) : " "
            result += piece
            pendingNewlines = 0
            index += 1
            if piece.count < trimmed.count { break }
        }
        return result
    }

    /// Core schema resolution for untagged plain scalars.
    func resolvePlain(_ text: String) -> JSONValue {
        switch text {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default: break
        }
        if text.range(of: #"^[-+]?[0-9]+$"#, options: .regularExpression) != nil {
            var digits = text.hasPrefix("+") ? String(text.dropFirst()) : text
            let negative = digits.hasPrefix("-")
            if negative { digits.removeFirst() }
            let trimmedZeros = String(digits.drop(while: { $0 == "0" }))
            return .number((negative && !trimmedZeros.isEmpty ? "-" : "") + (trimmedZeros.isEmpty ? "0" : trimmedZeros))
        }
        if text.hasPrefix("0x"), let value = Int(text.dropFirst(2), radix: 16) { return .number(String(value)) }
        if text.hasPrefix("0o"), let value = Int(text.dropFirst(2), radix: 8) { return .number(String(value)) }
        if text.range(of: #"^[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil
        {
            return .number(jsonNumber(text))
        }
        return .string(text)
    }

    /// Rewrites a YAML float literal as valid JSON number text (`+.5` → `0.5`, `1.` → `1.0`).
    func jsonNumber(_ text: String) -> String {
        var value = text.hasPrefix("+") ? String(text.dropFirst()) : text
        var sign = ""
        if value.hasPrefix("-") {
            sign = "-"
            value.removeFirst()
        }
        if value.hasPrefix(".") { value = "0" + value }
        if let exponent = value.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            var mantissa = String(value[..<exponent])
            if mantissa.hasSuffix(".") { mantissa += "0" }
            let digits = mantissa.split(separator: ".", omittingEmptySubsequences: false)
            if let whole = digits.first, whole.count > 1, whole.hasPrefix("0") {
                mantissa =
                    String(whole.drop(while: { $0 == "0" })).ifEmpty("0") + (digits.count > 1 ? "." + digits[1] : "")
            }
            return sign + mantissa + String(value[exponent...])
        }
        if value.hasSuffix(".") { value += "0" }
        let digits = value.split(separator: ".", omittingEmptySubsequences: false)
        if let whole = digits.first, whole.count > 1, whole.hasPrefix("0") {
            value = String(whole.drop(while: { $0 == "0" })).ifEmpty("0") + (digits.count > 1 ? "." + digits[1] : "")
        }
        return sign + value
    }

    // MARK: Quoted scalars

    /// Scans a quoted scalar that closes on the same line (used for keys).
    func scanQuotedOnLine(_ content: String, quote: Character, line: YAMLLine) throws(CoreError) -> (
        String, String.Index
    ) {
        var result = ""
        var index = content.index(after: content.startIndex)
        while index < content.endIndex {
            let character = content[index]
            if character == quote {
                let next = content.index(after: index)
                if quote == "'", next < content.endIndex, content[next] == "'" {
                    result.append("'")
                    index = content.index(after: next)
                    continue
                }
                return (result, next)
            }
            if quote == "\"", character == "\\" {
                let next = content.index(after: index)
                guard next < content.endIndex else { break }
                let (decoded, end) = try decodeEscape(content, at: next, line: line)
                result += decoded
                index = end
                continue
            }
            result.append(character)
            index = content.index(after: index)
        }
        throw error("A quoted key is not closed", line: line)
    }

    func decodeEscape(_ text: String, at index: String.Index, line: YAMLLine) throws(CoreError) -> (
        String, String.Index
    ) {
        let character = text[index]
        let next = text.index(after: index)
        switch character {
        case "n": return ("\n", next)
        case "t", "\t": return ("\t", next)
        case "r": return ("\r", next)
        case "0": return ("\u{0}", next)
        case "a": return ("\u{07}", next)
        case "b": return ("\u{08}", next)
        case "e": return ("\u{1B}", next)
        case "f": return ("\u{0C}", next)
        case "v": return ("\u{0B}", next)
        case " ": return (" ", next)
        case "/": return ("/", next)
        case "\\": return ("\\", next)
        case "\"": return ("\"", next)
        case "N": return ("\u{85}", next)
        case "_": return ("\u{A0}", next)
        case "x", "u", "U":
            let count = character == "x" ? 2 : (character == "u" ? 4 : 8)
            guard let end = text.index(next, offsetBy: count, limitedBy: text.endIndex),
                let value = UInt32(text[next..<end], radix: 16), let scalar = Unicode.Scalar(value)
            else { throw error("Invalid \\\(character) escape", line: line) }
            return (String(Character(scalar)), end)
        default:
            throw error("Invalid escape \\\(character)", line: line)
        }
    }

    /// Parses a quoted scalar that may span lines, applying YAML line folding.
    mutating func parseQuotedScalar(startingWith text: String, line: YAMLLine) throws(CoreError) -> String {
        guard let quote = text.first else { return "" }
        var result = ""
        var current = String(text.dropFirst())
        var currentLine = line
        var isFirstLine = true
        while true {
            var index = current.startIndex
            var closedAt: String.Index?
            var lineText = ""
            var escapedBreak = false
            while index < current.endIndex {
                let character = current[index]
                if character == quote {
                    let next = current.index(after: index)
                    if quote == "'", next < current.endIndex, current[next] == "'" {
                        lineText.append("'")
                        index = current.index(after: next)
                        continue
                    }
                    closedAt = next
                    break
                }
                if quote == "\"", character == "\\" {
                    let next = current.index(after: index)
                    if next == current.endIndex {
                        escapedBreak = true
                        index = next
                        break
                    }
                    let (decoded, end) = try decodeEscape(current, at: next, line: currentLine)
                    lineText += decoded
                    index = end
                    continue
                }
                lineText.append(character)
                index = current.index(after: index)
            }
            if let closedAt {
                result += isFirstLine ? lineText : lineText.trimmingLeadingWhitespace()
                let trailing = stripComment(String(current[closedAt...])).trimmingCharacters(in: .whitespaces)
                guard trailing.isEmpty else { throw error("Unexpected text after a quoted value", line: currentLine) }
                index = current.endIndex
                self.index += 1
                return result
            }
            // Fold: trailing whitespace is dropped; the next non-empty line adds a space (or newlines for blanks).
            let piece = isFirstLine ? lineText : lineText.trimmingLeadingWhitespace()
            result += escapedBreak ? piece : piece.trimmingTrailingWhitespace()
            self.index += 1
            var blanks = 0
            while self.index < lines.count, lines[self.index].content.trimmingCharacters(in: .whitespaces).isEmpty {
                blanks += 1
                self.index += 1
            }
            guard self.index < lines.count else { throw error("A quoted value is not closed", line: line) }
            if !escapedBreak { result += blanks > 0 ? String(repeating: "\n", count: blanks) : " " }
            currentLine = lines[self.index]
            current = currentLine.content
            isFirstLine = false
        }
    }

    // MARK: Block scalars

    mutating func parseBlockScalar(header: String, line: YAMLLine, parentIndent: Int) throws(CoreError) -> String {
        let isFolded = header.hasPrefix(">")
        var chomping: Character = "c"
        var explicitIndent: Int?
        for character in stripComment(String(header.dropFirst())).trimmingCharacters(in: .whitespaces) {
            if character == "-" || character == "+" {
                chomping = character
            } else if let digit = character.wholeNumberValue, digit > 0 {
                explicitIndent = digit
            } else {
                throw error("Invalid block scalar header", line: line)
            }
        }
        index += 1
        var contentIndent = explicitIndent.map { max(parentIndent, 0) + $0 }
        var collected: [String] = []
        while index < lines.count {
            let candidate = lines[index]
            let isBlank = candidate.content.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank {
                collected.append(
                    String(candidate.raw.dropFirst(min(candidate.raw.count, contentIndent ?? candidate.raw.count))))
                index += 1
                continue
            }
            if contentIndent == nil {
                guard candidate.indent > parentIndent else { break }
                contentIndent = candidate.indent
            }
            guard let indent = contentIndent, candidate.indent >= indent, !isDocumentEnd(candidate) else { break }
            collected.append(String(candidate.raw.dropFirst(indent)))
            index += 1
        }
        // Trailing blank lines belong to chomping, not content.
        var trailingBlanks = 0
        while let last = collected.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            collected.removeLast()
            trailingBlanks += 1
        }
        let body = isFolded ? foldBlankRuns(collected) : collected.joined(separator: "\n")
        guard !collected.isEmpty else { return chomping == "+" ? String(repeating: "\n", count: trailingBlanks) : "" }
        switch chomping {
        case "-": return body
        case "+": return body + "\n" + String(repeating: "\n", count: trailingBlanks)
        default: return body + "\n"
        }
    }

    /// Folded-scalar line folding (YAML §8.1.3): a single break between two normal lines becomes a space; each
    /// empty line becomes a newline; breaks around more-indented lines are kept.
    func foldBlankRuns(_ pieces: [String]) -> String {
        var output = ""
        var index = 0
        var previousKind: Int? = nil  // 0 normal, 1 more-indented
        while index < pieces.count {
            let piece = pieces[index]
            if piece.isEmpty {
                var blanks = 0
                while index < pieces.count, pieces[index].isEmpty {
                    blanks += 1
                    index += 1
                }
                let nextIsMore = index < pieces.count && (pieces[index].hasPrefix(" ") || pieces[index].hasPrefix("\t"))
                if previousKind != nil {
                    output += String(repeating: "\n", count: (previousKind == 1 || nextIsMore) ? blanks + 1 : blanks)
                } else {
                    output += String(repeating: "\n", count: blanks)
                }
                if index < pieces.count {
                    output += pieces[index]
                    previousKind = nextIsMore ? 1 : 0
                    index += 1
                }
                continue
            }
            let kind = piece.hasPrefix(" ") || piece.hasPrefix("\t") ? 1 : 0
            if let previousKind {
                output += (previousKind == 0 && kind == 0) ? " " : "\n"
            }
            output += piece
            previousKind = kind
            index += 1
        }
        return output
    }

    // MARK: Flow collections

    mutating func parseFlowNode(startingWith text: String, line: YAMLLine, depth: Int) throws(CoreError) -> JSONValue {
        // Collect text until brackets balance (quotes respected), possibly across lines.
        var buffer = text
        var balance = FlowBalance()
        balance.consume(text)
        let startLine = line
        index += 1
        while !balance.isBalanced {
            guard index < lines.count else {
                throw error("A flow collection ([ ] or { }) is not closed", line: startLine)
            }
            let next = stripComment(lines[index].content)
            buffer += " " + next
            balance.consume(" " + next)
            index += 1
        }
        var scanner = FlowScanner(scalars: Array(buffer.unicodeScalars), line: startLine, maximumDepth: maximumDepth)
        let value = try scanner.parseValue(depth: depth, reader: &self)
        scanner.skipSpaces()
        let trailing = String(String.UnicodeScalarView(scanner.scalars[scanner.index...]))
        guard stripComment(trailing).trimmingCharacters(in: .whitespaces).isEmpty else {
            throw error("Unexpected text after a flow collection", line: startLine)
        }
        return value
    }
}

private struct FlowBalance {
    var depth = 0
    var quote: Character?
    var started = false
    var isBalanced: Bool { started && depth == 0 && quote == nil }

    mutating func consume(_ text: String) {
        var previous: Character = " "
        for character in text {
            if let current = quote {
                if character == current, !(current == "\"" && previous == "\\") { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" || character == "{" {
                depth += 1
                started = true
            } else if character == "]" || character == "}" {
                depth -= 1
            } else if character == "#", previous == " ", depth > 0 {
                break
            }
            previous = character
        }
    }
}

private struct FlowScanner {
    let scalars: [Unicode.Scalar]
    let line: YAMLLine
    let maximumDepth: Int
    var index = 0

    init(scalars: [Unicode.Scalar], line: YAMLLine, maximumDepth: Int) {
        self.scalars = scalars
        self.line = line
        self.maximumDepth = maximumDepth
    }

    var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

    func error(_ reason: String) -> CoreError {
        .yamlSyntax(position: TextPosition(line: line.number, column: line.indent + 1), reason: reason)
    }

    mutating func skipSpaces() {
        while let character = current, character == " " || character == "\t" { index += 1 }
    }

    mutating func parseValue(depth: Int, reader: inout YAMLReader) throws(CoreError) -> JSONValue {
        guard depth <= maximumDepth else { throw .nestingTooDeep(limit: maximumDepth) }
        skipSpaces()
        if current == "&" {
            index += 1
            var name = String.UnicodeScalarView()
            while let next = current, !" \t,]}".unicodeScalars.contains(next) {
                name.append(next)
                index += 1
            }
            guard !name.isEmpty else { throw error("An anchor needs a name") }
            let start = reader.expandedNodes
            let value = try parseValue(depth: depth, reader: &reader)
            reader.defineAnchor(String(name), value: value, sizeSince: start)
            return value
        }
        guard let character = current else { throw error("Unexpected end of a flow collection") }
        if character != "*" { try reader.countNodes(1, line: line) }
        switch character {
        case "[":
            index += 1
            var items: [JSONValue] = []
            while true {
                skipSpaces()
                if current == "]" {
                    index += 1
                    return .array(items)
                }
                items.append(try parseValue(depth: depth + 1, reader: &reader))
                skipSpaces()
                if current == "," {
                    index += 1
                } else if current == "]" {
                    index += 1
                    return .array(items)
                } else {
                    throw error("Expected “,” or “]”")
                }
            }
        case "{":
            index += 1
            var members: [JSONMember] = []
            while true {
                skipSpaces()
                if current == "}" {
                    index += 1
                    return .object(members)
                }
                let keyValue = try parseScalar(isKey: true, reader: &reader)
                let key: String
                switch keyValue {
                case .string(let text): key = text
                case .number(let text): key = text
                case .bool(let flag): key = flag ? "true" : "false"
                case .null: key = "null"
                default: throw error("Flow mapping keys must be scalars")
                }
                skipSpaces()
                var value = JSONValue.null
                if current == ":" {
                    index += 1
                    skipSpaces()
                    if current != "," && current != "}" { value = try parseValue(depth: depth + 1, reader: &reader) }
                }
                if let existing = members.firstIndex(where: { $0.key == key }) {
                    members[existing].value = value
                } else {
                    members.append(JSONMember(key, value))
                }
                skipSpaces()
                if current == "," {
                    index += 1
                } else if current == "}" {
                    index += 1
                    return .object(members)
                } else {
                    throw error("Expected “,” or “}”")
                }
            }
        default:
            return try parseScalar(isKey: false, reader: &reader)
        }
    }

    mutating func parseScalar(isKey: Bool, reader: inout YAMLReader) throws(CoreError) -> JSONValue {
        skipSpaces()
        guard let character = current else { throw error("Expected a value") }
        if character == "\"" || character == "'" {
            index += 1
            var result = String.UnicodeScalarView()
            while let next = current {
                index += 1
                if next == character {
                    if character == "'", current == "'" {
                        result.append("'")
                        index += 1
                        continue
                    }
                    return .string(String(result))
                }
                if character == "\"", next == "\\", let escaped = current {
                    let text = String(String.UnicodeScalarView(scalars[index...]))
                    let (decoded, end) = try reader.decodeEscape(text, at: text.startIndex, line: line)
                    result.append(contentsOf: decoded.unicodeScalars)
                    index += text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: end)
                    _ = escaped
                    continue
                }
                result.append(next)
            }
            throw error("A quoted value is not closed")
        }
        if character == "*" {
            index += 1
            var name = String.UnicodeScalarView()
            while let next = current, !" ,]}".unicodeScalars.contains(next) {
                name.append(next)
                index += 1
            }
            return try reader.resolveAlias(String(name), line: line)
        }
        var result = String.UnicodeScalarView()
        while let next = current {
            if next == "," || next == "]" || next == "}" { break }
            if next == ":", index + 1 >= scalars.count || " ,]}".unicodeScalars.contains(scalars[index + 1]) { break }
            if next == ":", isKey { break }
            result.append(next)
            index += 1
        }
        let text = String(result).trimmingCharacters(in: .whitespaces)
        return isKey ? .string(text) : reader.resolvePlain(text)
    }
}

extension String {
    fileprivate func trimmingLeadingWhitespace() -> String {
        String(drop(while: { $0 == " " || $0 == "\t" }))
    }

    fileprivate func trimmingTrailingWhitespace() -> String {
        var result = self
        while let last = result.last, last == " " || last == "\t" { result.removeLast() }
        return result
    }

    fileprivate func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}
