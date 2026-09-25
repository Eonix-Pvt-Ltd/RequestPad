import Foundation

/// Serializes ``JSONValue`` as compact or pretty-printed (2-space) JSON. Number literals are written verbatim.
public enum JSONSerializer {
    public enum Style: Sendable {
        case compact
        case pretty
    }

    public static func string(from value: JSONValue, style: Style = .pretty) -> String {
        var output = ""
        write(value, style: style, into: &output)
        return output
    }

    private enum Frame {
        case array([JSONValue], next: Int)
        case object([JSONMember], next: Int)
    }

    /// Iterative writer (explicit stack) so deeply nested values can't overflow the thread stack.
    private static func write(_ root: JSONValue, style: Style, into output: inout String) {
        var stack: [Frame] = []
        var pending: JSONValue? = root
        while true {
            if let value = pending {
                pending = nil
                switch value {
                case .null: output += "null"
                case .bool(let flag): output += flag ? "true" : "false"
                case .number(let literal): output += literal
                case .string(let text): writeString(text, into: &output)
                case .array(let elements):
                    if elements.isEmpty {
                        output += "[]"
                    } else {
                        output += "["
                        stack.append(.array(elements, next: 0))
                    }
                case .object(let members):
                    if members.isEmpty {
                        output += "{}"
                    } else {
                        output += "{"
                        stack.append(.object(members, next: 0))
                    }
                }
            }
            guard let frame = stack.popLast() else { return }
            let depth = stack.count + 1
            switch frame {
            case .array(let elements, let next):
                if next < elements.count {
                    if next > 0 { output += "," }
                    newline(style: style, indent: depth, into: &output)
                    stack.append(.array(elements, next: next + 1))
                    pending = elements[next]
                } else {
                    newline(style: style, indent: depth - 1, into: &output)
                    output += "]"
                }
            case .object(let members, let next):
                if next < members.count {
                    if next > 0 { output += "," }
                    newline(style: style, indent: depth, into: &output)
                    writeString(members[next].key, into: &output)
                    output += style == .pretty ? ": " : ":"
                    stack.append(.object(members, next: next + 1))
                    pending = members[next].value
                } else {
                    newline(style: style, indent: depth - 1, into: &output)
                    output += "}"
                }
            }
        }
    }

    private static func newline(style: Style, indent: Int, into output: inout String) {
        guard style == .pretty else { return }
        output += "\n"
        output += String(repeating: "  ", count: indent)
    }

    static func writeString(_ text: String, into output: inout String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\u{00}"..."\u{1F}":
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }

    /// Escapes `text` as a JSON string literal (including quotes).
    public static func quoted(_ text: String) -> String {
        var output = ""
        writeString(text, into: &output)
        return output
    }
}
