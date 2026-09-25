import Foundation

/// Serializes ``JSONValue`` as compact or pretty-printed (2-space) JSON. Number literals are written verbatim.
public enum JSONSerializer {
    public enum Style: Sendable {
        case compact
        case pretty
    }

    public static func string(from value: JSONValue, style: Style = .pretty) -> String {
        var output = ""
        write(value, style: style, indent: 0, into: &output)
        return output
    }

    private static func write(_ value: JSONValue, style: Style, indent: Int, into output: inout String) {
        switch value {
        case .null: output += "null"
        case .bool(let flag): output += flag ? "true" : "false"
        case .number(let literal): output += literal
        case .string(let text): writeString(text, into: &output)
        case .array(let elements):
            guard !elements.isEmpty else { output += "[]"; return }
            output += "["
            for (offset, element) in elements.enumerated() {
                if offset > 0 { output += "," }
                newline(style: style, indent: indent + 1, into: &output)
                write(element, style: style, indent: indent + 1, into: &output)
            }
            newline(style: style, indent: indent, into: &output)
            output += "]"
        case .object(let members):
            guard !members.isEmpty else { output += "{}"; return }
            output += "{"
            for (offset, member) in members.enumerated() {
                if offset > 0 { output += "," }
                newline(style: style, indent: indent + 1, into: &output)
                writeString(member.key, into: &output)
                output += style == .pretty ? ": " : ":"
                write(member.value, style: style, indent: indent + 1, into: &output)
            }
            newline(style: style, indent: indent, into: &output)
            output += "}"
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
