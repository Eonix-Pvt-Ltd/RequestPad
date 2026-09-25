import Foundation

/// A strict RFC 8259 JSON parser producing ``JSONValue``. Preserves member order and number literals, reports the
/// line and column of the first error, and enforces size and nesting limits so hostile input cannot exhaust
/// memory or the stack.
public struct JSONParser: Sendable {
    public static let defaultMaximumBytes = 64 * 1024 * 1024
    public static let defaultMaximumDepth = 256

    public var maximumBytes: Int
    public var maximumDepth: Int

    public init(maximumBytes: Int = defaultMaximumBytes, maximumDepth: Int = defaultMaximumDepth) {
        self.maximumBytes = maximumBytes
        self.maximumDepth = maximumDepth
    }

    public func parse(_ text: String) throws(CoreError) -> JSONValue {
        try parse(Data(text.utf8))
    }

    public func parse(_ data: Data) throws(CoreError) -> JSONValue {
        guard data.count <= maximumBytes else { throw .inputTooLarge(limitBytes: maximumBytes) }
        let result: Result<JSONValue, CoreError> = data.withUnsafeBytes { raw in
            var cursor = Cursor(bytes: raw.bindMemory(to: UInt8.self), maximumDepth: maximumDepth)
            do throws(CoreError) {
                cursor.skipWhitespace()
                let value = try cursor.parseValue(depth: 0)
                cursor.skipWhitespace()
                guard cursor.isAtEnd else { throw cursor.error("Unexpected text after the JSON value") }
                return .success(value)
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }
}

private struct Cursor {
    let bytes: UnsafeBufferPointer<UInt8>
    let maximumDepth: Int
    var index = 0

    init(bytes: UnsafeBufferPointer<UInt8>, maximumDepth: Int) {
        self.bytes = bytes
        self.maximumDepth = maximumDepth
        // Skip a UTF-8 byte order mark.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }
    }

    var isAtEnd: Bool { index >= bytes.count }
    var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    func error(_ reason: String, at offset: Int? = nil) -> CoreError {
        .jsonSyntax(position: TextLocator.position(of: min(offset ?? index, bytes.count), in: bytes), reason: reason)
    }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    /// A container being built. The parser keeps these on the heap instead of recursing, so nesting depth
    /// never consumes thread stack (hostile input can't overflow the 512 KB stacks of concurrency threads).
    /// Frames are mutated in place (`stack[top]`) so appends never copy the collection.
    private struct Frame {
        var isObject: Bool
        var elements: [JSONValue] = []
        var members: [JSONMember] = []
        var key = ""
    }

    mutating func parseValue(depth _: Int) throws(CoreError) -> JSONValue {
        var stack: [Frame] = []
        while true {
            // 1. Read one value, or open a container and continue with its first element.
            skipWhitespace()
            guard let byte = current else { throw error("Unexpected end of input") }
            var value: JSONValue
            switch byte {
            case UInt8(ascii: "{"):
                guard stack.count < maximumDepth else { throw .nestingTooDeep(limit: maximumDepth) }
                index += 1
                skipWhitespace()
                if current == UInt8(ascii: "}") {
                    index += 1
                    value = .object([])
                } else {
                    stack.append(Frame(isObject: true, key: try parseKey()))
                    continue
                }
            case UInt8(ascii: "["):
                guard stack.count < maximumDepth else { throw .nestingTooDeep(limit: maximumDepth) }
                index += 1
                skipWhitespace()
                if current == UInt8(ascii: "]") {
                    index += 1
                    value = .array([])
                } else {
                    stack.append(Frame(isObject: false))
                    continue
                }
            case UInt8(ascii: "\""): value = .string(try parseString())
            case UInt8(ascii: "t"):
                try expectLiteral("true")
                value = .bool(true)
            case UInt8(ascii: "f"):
                try expectLiteral("false")
                value = .bool(false)
            case UInt8(ascii: "n"):
                try expectLiteral("null")
                value = .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): value = .number(try parseNumber())
            default: throw error("Unexpected character")
            }
            // 2. Attach the value to its parent; close parents that end here.
            attach: while true {
                guard let top = stack.indices.last else { return value }
                skipWhitespace()
                if stack[top].isObject {
                    stack[top].members.append(JSONMember(stack[top].key, value))
                    switch current {
                    case UInt8(ascii: ","):
                        index += 1
                        skipWhitespace()
                        stack[top].key = try parseKey()
                        break attach
                    case UInt8(ascii: "}"):
                        index += 1
                        value = .object(stack.removeLast().members)
                    case nil: throw error("Unexpected end of input; expected '}'")
                    default: throw error("Expected ',' or '}'")
                    }
                } else {
                    stack[top].elements.append(value)
                    switch current {
                    case UInt8(ascii: ","):
                        index += 1
                        break attach
                    case UInt8(ascii: "]"):
                        index += 1
                        value = .array(stack.removeLast().elements)
                    case nil: throw error("Unexpected end of input; expected ']'")
                    default: throw error("Expected ',' or ']'")
                    }
                }
            }
        }
    }

    mutating func expectLiteral(_ literal: StaticString) throws(CoreError) {
        let start = index
        let count = literal.utf8CodeUnitCount
        guard index + count <= bytes.count else { throw error("Unexpected end of input", at: start) }
        let matches = literal.withUTF8Buffer { expected in
            (0..<count).allSatisfy { bytes[index + $0] == expected[$0] }
        }
        guard matches else { throw error("Invalid literal", at: start) }
        index += count
    }

    /// Reads `"key":` and positions the cursor at the value.
    mutating func parseKey() throws(CoreError) -> String {
        guard current == UInt8(ascii: "\"") else { throw error("Expected a string key") }
        let key = try parseString()
        skipWhitespace()
        guard current == UInt8(ascii: ":") else { throw error("Expected ':' after key") }
        index += 1
        return key
    }

    mutating func parseNumber() throws(CoreError) -> String {
        let start = index
        if current == UInt8(ascii: "-") { index += 1 }
        guard let first = current, isDigit(first) else { throw error("Invalid number", at: start) }
        if first == UInt8(ascii: "0") {
            index += 1
            if let next = current, isDigit(next) { throw error("Leading zeros are not allowed", at: start) }
        } else {
            consumeDigits()
        }
        if current == UInt8(ascii: ".") {
            index += 1
            guard let digit = current, isDigit(digit) else { throw error("Expected digits after '.'") }
            consumeDigits()
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            index += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
            guard let digit = current, isDigit(digit) else { throw error("Expected exponent digits") }
            consumeDigits()
        }
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
    }

    func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

    mutating func consumeDigits() {
        while let byte = current, isDigit(byte) { index += 1 }
    }

    mutating func parseString() throws(CoreError) -> String {
        let start = index
        index += 1
        var utf8: [UInt8] = []
        var runStart = index
        while true {
            guard let byte = current else { throw error("Unterminated string", at: start) }
            switch byte {
            case UInt8(ascii: "\""):
                utf8.append(contentsOf: bytes[runStart..<index])
                index += 1
                return String(decoding: utf8, as: UTF8.self)
            case UInt8(ascii: "\\"):
                utf8.append(contentsOf: bytes[runStart..<index])
                index += 1
                try appendEscape(to: &utf8)
                runStart = index
            case 0x00..<0x20:
                throw error("Control characters must be escaped in strings")
            default:
                index += 1
            }
        }
    }

    mutating func appendEscape(to utf8: inout [UInt8]) throws(CoreError) {
        guard let escape = current else { throw error("Unterminated escape sequence") }
        index += 1
        switch escape {
        case UInt8(ascii: "\""): utf8.append(0x22)
        case UInt8(ascii: "\\"): utf8.append(0x5C)
        case UInt8(ascii: "/"): utf8.append(0x2F)
        case UInt8(ascii: "b"): utf8.append(0x08)
        case UInt8(ascii: "f"): utf8.append(0x0C)
        case UInt8(ascii: "n"): utf8.append(0x0A)
        case UInt8(ascii: "r"): utf8.append(0x0D)
        case UInt8(ascii: "t"): utf8.append(0x09)
        case UInt8(ascii: "u"):
            let scalar = try parseUnicodeEscape()
            utf8.append(contentsOf: Array(String(Character(scalar)).utf8))
        default:
            throw error("Invalid escape sequence", at: index - 2)
        }
    }

    mutating func parseUnicodeEscape() throws(CoreError) -> Unicode.Scalar {
        let high = try parseHex4()
        if (0xD800...0xDBFF).contains(high) {
            // A high surrogate must be followed by an escaped low surrogate; otherwise emit U+FFFD.
            if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                let saved = index
                index += 2
                let low = try parseHex4()
                if (0xDC00...0xDFFF).contains(low) {
                    let value = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                    return Unicode.Scalar(value) ?? "\u{FFFD}"
                }
                index = saved
            }
            return "\u{FFFD}"
        }
        if (0xDC00...0xDFFF).contains(high) { return "\u{FFFD}" }
        return Unicode.Scalar(high) ?? "\u{FFFD}"
    }

    mutating func parseHex4() throws(CoreError) -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("Incomplete \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: throw error("Invalid hex digit in \\u escape")
            }
            value = value * 16 + UInt32(digit)
            index += 1
        }
        return value
    }
}

/// Converts byte offsets to 1-based line/column positions (columns count characters, not bytes).
enum TextLocator {
    static func position(of offset: Int, in bytes: UnsafeBufferPointer<UInt8>) -> TextPosition {
        var line = 1
        var lineStart = 0
        for index in 0..<min(offset, bytes.count) where bytes[index] == 0x0A {
            line += 1
            lineStart = index + 1
        }
        let columnBytes = UnsafeBufferPointer(rebasing: bytes[lineStart..<min(offset, bytes.count)])
        let column = String(decoding: columnBytes, as: UTF8.self).count + 1
        return TextPosition(line: line, column: column)
    }
}
