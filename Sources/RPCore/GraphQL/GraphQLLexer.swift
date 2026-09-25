import Foundation

/// A GraphQL token (October 2021 spec, §2.1).
public struct GraphQLToken: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case punctuator(String)
        case name
        case int
        case float
        case string
        case blockString
    }

    public var kind: Kind
    public var text: String
    /// Offset of the first character, in Unicode scalars from the start of the document.
    public var offset: Int
    public var position: TextPosition
}

/// Tokenizes GraphQL documents. Whitespace, commas and comments are skipped.
public enum GraphQLLexer {
    public static let maximumBytes = 1024 * 1024

    public static func tokenize(_ source: String) throws(CoreError) -> [GraphQLToken] {
        guard source.utf8.count <= maximumBytes else { throw .inputTooLarge(limitBytes: maximumBytes) }
        let scalars = Array(source.unicodeScalars)
        var tokens: [GraphQLToken] = []
        var index = 0
        var line = 1
        var lineStart = 0

        func position(_ offset: Int) -> TextPosition { TextPosition(line: line, column: offset - lineStart + 1) }
        func error(_ reason: String, at offset: Int) -> CoreError {
            .invalidDocument(path: "GraphQL \(position(offset))", reason: reason)
        }

        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "\n":
                index += 1
                line += 1
                lineStart = index
            case "\r":
                index += 1
                if index < scalars.count, scalars[index] == "\n" { index += 1 }
                line += 1
                lineStart = index
            case " ", "\t", ",", "\u{FEFF}":
                index += 1
            case "#":
                while index < scalars.count, scalars[index] != "\n", scalars[index] != "\r" { index += 1 }
            case "!", "$", "&", "(", ")", ":", "=", "@", "[", "]", "{", "|", "}":
                tokens.append(
                    GraphQLToken(
                        kind: .punctuator(String(scalar)), text: String(scalar), offset: index,
                        position: position(index)))
                index += 1
            case ".":
                guard index + 2 < scalars.count, scalars[index + 1] == ".", scalars[index + 2] == "." else {
                    throw error("Unexpected “.”; did you mean “...”?", at: index)
                }
                tokens.append(
                    GraphQLToken(kind: .punctuator("..."), text: "...", offset: index, position: position(index)))
                index += 3
            case "\"":
                let start = index
                let startPosition = position(index)
                if index + 2 < scalars.count, scalars[index + 1] == "\"", scalars[index + 2] == "\"" {
                    index += 3
                    var closed = false
                    while index < scalars.count {
                        if scalars[index] == "\\", index + 3 < scalars.count, scalars[index + 1] == "\"",
                            scalars[index + 2] == "\"",
                            scalars[index + 3] == "\""
                        {
                            index += 4
                            continue
                        }
                        if scalars[index] == "\"", index + 2 < scalars.count, scalars[index + 1] == "\"",
                            scalars[index + 2] == "\""
                        {
                            index += 3
                            closed = true
                            break
                        }
                        if scalars[index] == "\n" {
                            line += 1
                            lineStart = index + 1
                        }
                        index += 1
                    }
                    guard closed else { throw error("A block string (\"\"\") is not closed.", at: start) }
                    let text = String(String.UnicodeScalarView(scalars[start..<index]))
                    tokens.append(GraphQLToken(kind: .blockString, text: text, offset: start, position: startPosition))
                } else {
                    index += 1
                    var closed = false
                    while index < scalars.count {
                        let character = scalars[index]
                        if character == "\n" || character == "\r" { break }
                        if character == "\\" {
                            index += 2
                            continue
                        }
                        index += 1
                        if character == "\"" {
                            closed = true
                            break
                        }
                    }
                    guard closed else { throw error("A string is not closed.", at: start) }
                    tokens.append(
                        GraphQLToken(
                            kind: .string, text: String(String.UnicodeScalarView(scalars[start..<index])),
                            offset: start, position: startPosition))
                }
            case "-", "0"..."9":
                let start = index
                if scalars[index] == "-" { index += 1 }
                var isFloat = false
                while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1 }
                if index < scalars.count, scalars[index] == "." {
                    isFloat = true
                    index += 1
                    while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1 }
                }
                if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
                    isFloat = true
                    index += 1
                    if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }
                    while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1 }
                }
                let text = String(String.UnicodeScalarView(scalars[start..<index]))
                guard text != "-", text.last?.isNumber ?? false else {
                    throw error("Invalid number “\(text)”.", at: start)
                }
                tokens.append(
                    GraphQLToken(kind: isFloat ? .float : .int, text: text, offset: start, position: position(start)))
            case "_", "a"..."z", "A"..."Z":
                let start = index
                while index < scalars.count, isNameContinue(scalars[index]) { index += 1 }
                tokens.append(
                    GraphQLToken(
                        kind: .name, text: String(String.UnicodeScalarView(scalars[start..<index])), offset: start,
                        position: position(start)))
            default:
                throw error("Unexpected character “\(scalar)”.", at: index)
            }
        }
        return tokens
    }

    static func isNameContinue(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}
