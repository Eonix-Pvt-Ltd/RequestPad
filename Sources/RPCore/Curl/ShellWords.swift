import Foundation

/// Splits a POSIX-shell command line into words: single quotes, double quotes (with `\"`, `\\`, `\$`, `` \` ``
/// escapes), ANSI-C `$'…'` quoting, backslash escapes, and backslash-newline continuations (also after `\r\n`).
public enum ShellWords {
    public static func split(_ command: String) throws(CoreError) -> [String] {
        let scalars = Array(command.unicodeScalars)
        var words: [String] = []
        var current = String.UnicodeScalarView()
        var inWord = false
        var index = 0

        func finishWord() {
            if inWord { words.append(String(current)) }
            current = String.UnicodeScalarView()
            inWord = false
        }

        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case " ", "\t", "\n", "\r":
                finishWord()
                index += 1
            case "\\":
                index += 1
                guard index < scalars.count else { break }
                if scalars[index] == "\n" {
                    index += 1
                } else if scalars[index] == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" {
                    index += 2
                } else {
                    current.append(scalars[index])
                    inWord = true
                    index += 1
                }
            case "'":
                inWord = true
                index += 1
                guard let close = scalars[index...].firstIndex(of: "'") else {
                    throw .curlSyntax(reason: "A single quote (') is not closed.")
                }
                current.append(contentsOf: scalars[index..<close])
                index = close + 1
            case "\"":
                inWord = true
                index += 1
                var closed = false
                while index < scalars.count {
                    let character = scalars[index]
                    if character == "\"" {
                        closed = true
                        index += 1
                        break
                    }
                    if character == "\\", index + 1 < scalars.count {
                        let next = scalars[index + 1]
                        if next == "\n" {
                            index += 2
                            continue
                        }
                        if "\"\\$`".unicodeScalars.contains(next) {
                            current.append(next)
                            index += 2
                            continue
                        }
                    }
                    current.append(character)
                    index += 1
                }
                guard closed else { throw .curlSyntax(reason: "A double quote (\") is not closed.") }
            case "$" where index + 1 < scalars.count && scalars[index + 1] == "'":
                inWord = true
                index += 2
                var closed = false
                while index < scalars.count {
                    let character = scalars[index]
                    if character == "'" {
                        closed = true
                        index += 1
                        break
                    }
                    if character == "\\", index + 1 < scalars.count {
                        let (decoded, consumed) = ansiEscape(scalars, at: index + 1)
                        current.append(contentsOf: decoded.unicodeScalars)
                        index += 1 + consumed
                        continue
                    }
                    current.append(character)
                    index += 1
                }
                guard closed else { throw .curlSyntax(reason: "A $'…' quote is not closed.") }
            default:
                current.append(scalar)
                inWord = true
                index += 1
            }
        }
        finishWord()
        return words
    }

    /// Decodes the ANSI-C escape starting at `index` (after the backslash). Returns the text and scalars consumed.
    private static func ansiEscape(_ scalars: [Unicode.Scalar], at index: Int) -> (String, Int) {
        let character = scalars[index]
        switch character {
        case "n": return ("\n", 1)
        case "t": return ("\t", 1)
        case "r": return ("\r", 1)
        case "a": return ("\u{07}", 1)
        case "b": return ("\u{08}", 1)
        case "e", "E": return ("\u{1B}", 1)
        case "f": return ("\u{0C}", 1)
        case "v": return ("\u{0B}", 1)
        case "0": return ("\u{0}", 1)
        case "x", "u", "U":
            let maxDigits = character == "x" ? 2 : (character == "u" ? 4 : 8)
            var digits = ""
            var cursor = index + 1
            while cursor < scalars.count, digits.count < maxDigits, scalars[cursor].properties.isASCIIHexDigit {
                digits.unicodeScalars.append(scalars[cursor])
                cursor += 1
            }
            guard let value = UInt32(digits, radix: 16), let decoded = Unicode.Scalar(value) else {
                return ("\\" + String(character), 1)
            }
            return (String(Character(decoded)), 1 + digits.count)
        default:
            return (String(Character(character)), 1)
        }
    }

    /// Quotes `word` for a POSIX shell using single quotes (`'` becomes `'\''`). Plain safe words are left bare.
    public static func quote(_ word: String) -> String {
        let safe = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@,+%")
        if !word.isEmpty, word.unicodeScalars.allSatisfy({ safe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
