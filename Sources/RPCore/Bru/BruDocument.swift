import Foundation

/// A `.bru` file split into top-level blocks, each keeping its exact source text, so blocks RequestPad does not
/// change (or does not understand) are written back byte-for-byte (P01.3).
public struct BruDocument: Hashable, Sendable {
    /// Largest `.bru` file RequestPad reads (threat model: untrusted input).
    public static let maximumBytes = 1024 * 1024

    public enum Bracket: Hashable, Sendable {
        case brace
        case square
    }

    public struct Block: Hashable, Sendable {
        public var name: String
        public var bracket: Bracket
        /// Lines between the header and the closing bracket, as in the source (a trailing `\r` is kept).
        public var contentLines: [String]
        /// Exact source text from the header through the closing bracket, including its line break (if any).
        public var source: String
        /// Blank lines after the block, up to the next block.
        public var trailing: String
        /// 1-based line number of the header (for error messages).
        public var line: Int

        /// Content lines with `\r` removed.
        public var lines: [String] { contentLines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 } }
    }

    /// Text before the first block (normally empty).
    public var leading: String
    public var blocks: [Block]

    public init(leading: String = "", blocks: [Block] = []) {
        self.leading = leading
        self.blocks = blocks
    }

    public func blocks(named name: String) -> [Block] { blocks.filter { $0.name == name } }
    public func firstBlock(named name: String) -> Block? { blocks.first { $0.name == name } }

    /// The document as text: unchanged blocks reproduce the original file exactly.
    public var text: String {
        leading + blocks.map { $0.source + $0.trailing }.joined()
    }

    public static func parse(_ text: String) throws(CoreError) -> BruDocument {
        guard text.utf8.count <= maximumBytes else { throw .inputTooLarge(limitBytes: maximumBytes) }
        let lines = text.components(separatedBy: "\n")
        var document = BruDocument()
        var index = 0
        var pendingBlank: [String] = []

        func flushBlank(into document: inout BruDocument, isEndOfFile: Bool) {
            guard !pendingBlank.isEmpty else { return }
            var joined = pendingBlank.joined(separator: "\n")
            if !isEndOfFile { joined += "\n" }
            if document.blocks.isEmpty {
                document.leading += joined
            } else {
                document.blocks[document.blocks.count - 1].trailing += joined
            }
            pendingBlank.removeAll()
        }

        while index < lines.count {
            let rawLine = lines[index]
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                pendingBlank.append(rawLine)
                index += 1
                continue
            }
            flushBlank(into: &document, isEndOfFile: false)
            guard let header = parseHeader(line) else {
                throw .bruSyntax(
                    position: TextPosition(line: index + 1, column: 1), reason: "Expected a block such as “meta {”")
            }
            let headerIndex = index
            var content: [String] = []
            var closed = false
            if let inline = header.inline {
                let closing = header.bracket == .brace ? "}" : "]"
                if inline.trimmingCharacters(in: .whitespaces) == closing {
                    closed = true
                } else {
                    content.append(inline)
                }
            }
            index += 1
            if !closed {
                while index < lines.count {
                    let candidate = lines[index]
                    let trimmed = candidate.hasSuffix("\r") ? String(candidate.dropLast()) : candidate
                    if isClosing(trimmed, bracket: header.bracket) {
                        closed = true
                        break
                    }
                    content.append(candidate)
                    index += 1
                }
            }
            guard closed else {
                throw .bruSyntax(
                    position: TextPosition(line: headerIndex + 1, column: 1),
                    reason: "The “\(header.name)” block is missing its closing bracket")
            }
            let lastLine = header.inline != nil && content.isEmpty && index == headerIndex + 1 ? headerIndex : index
            let isFinalLine = lastLine == lines.count - 1
            var source = lines[headerIndex...lastLine].joined(separator: "\n")
            if !isFinalLine { source += "\n" }
            document.blocks.append(
                Block(
                    name: header.name, bracket: header.bracket, contentLines: content, source: source, trailing: "",
                    line: headerIndex + 1))
            index = lastLine + 1
        }
        flushBlank(into: &document, isEndOfFile: true)
        return document
    }

    private static func parseHeader(_ line: String) -> (name: String, bracket: Bracket, inline: String?)? {
        guard let first = line.unicodeScalars.first, CharacterSet.letters.contains(first) else { return nil }
        var name = ""
        var remainder = Substring(line)
        while let character = remainder.first, character.isLetter || character.isNumber || ":_-.".contains(character) {
            name.append(character)
            remainder = remainder.dropFirst()
        }
        remainder = remainder.drop(while: { $0 == " " || $0 == "\t" })
        guard let opener = remainder.first, opener == "{" || opener == "[" else { return nil }
        let rest = remainder.dropFirst()
        let inline = rest.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String(rest)
        return (name, opener == "{" ? .brace : .square, inline)
    }

    private static func isClosing(_ line: String, bracket: Bracket) -> Bool {
        let closing: Character = bracket == .brace ? "}" : "]"
        return line.first == closing && line.dropFirst().allSatisfy { $0 == " " || $0 == "\t" }
    }
}

extension BruDocument.Block {
    /// Builds a block from generated content lines (no trailing blank line; callers set `trailing`).
    static func generated(name: String, bracket: BruDocument.Bracket = .brace, lines: [String]) -> BruDocument.Block {
        let open = bracket == .brace ? "{" : "["
        let close = bracket == .brace ? "}" : "]"
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        return BruDocument.Block(
            name: name, bracket: bracket, contentLines: lines, source: "\(name) \(open)\n\(body)\(close)\n",
            trailing: "", line: 0)
    }
}
