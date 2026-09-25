import Foundation

/// A position in a text document, 1-based.
public struct TextPosition: Hashable, Sendable, CustomStringConvertible {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public var description: String { "\(line):\(column)" }
}

/// Errors raised by RPCore parsers, importers and evaluators. Every case carries enough context for a specific,
/// user-facing message; none carries document contents (so errors are safe to log).
public enum CoreError: Error, Hashable, Sendable, LocalizedError {
    case inputTooLarge(limitBytes: Int)
    case nestingTooDeep(limit: Int)
    case jsonSyntax(position: TextPosition, reason: String)
    case yamlSyntax(position: TextPosition, reason: String)
    case bruSyntax(position: TextPosition, reason: String)
    case curlSyntax(reason: String)
    case invalidJSONPath(reason: String)
    case unsupportedDocument(reason: String)
    case invalidDocument(path: String, reason: String)
    case invalidRequest(reason: String)

    public var errorDescription: String? {
        switch self {
        case .inputTooLarge(let limit):
            let size = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            return String(localized: "The file is larger than the \(size) limit.", bundle: .module)
        case .nestingTooDeep(let limit):
            return String(localized: "The document is nested more than \(limit) levels deep.", bundle: .module)
        case .jsonSyntax(let position, let reason):
            return String(
                localized: "Invalid JSON at line \(position.line), column \(position.column): \(reason)",
                bundle: .module)
        case .yamlSyntax(let position, let reason):
            return String(
                localized: "Invalid YAML at line \(position.line), column \(position.column): \(reason)",
                bundle: .module)
        case .bruSyntax(let position, let reason):
            return String(localized: "Invalid .bru file at line \(position.line): \(reason)", bundle: .module)
        case .curlSyntax(let reason):
            return String(localized: "This cURL command can't be imported: \(reason)", bundle: .module)
        case .invalidJSONPath(let reason):
            return String(localized: "Invalid JSON path: \(reason)", bundle: .module)
        case .unsupportedDocument(let reason):
            return String(localized: "This document isn't supported: \(reason)", bundle: .module)
        case .invalidDocument(let path, let reason):
            return String(localized: "Invalid document at \(path): \(reason)", bundle: .module)
        case .invalidRequest(let reason):
            return String(localized: "The request can't be sent: \(reason)", bundle: .module)
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .inputTooLarge:
            String(localized: "Split the document into smaller files and try again.", bundle: .module)
        case .jsonSyntax, .yamlSyntax, .bruSyntax, .invalidDocument, .nestingTooDeep:
            String(localized: "Fix the problem at the reported location, then try again.", bundle: .module)
        case .curlSyntax:
            String(localized: "Check that the command is complete and its quotes are balanced.", bundle: .module)
        case .invalidJSONPath:
            String(localized: "Use a path such as $.data.items[0].id or $..name.", bundle: .module)
        case .unsupportedDocument:
            String(localized: "Export the document in a supported format and try again.", bundle: .module)
        case .invalidRequest:
            String(localized: "Check the URL, variables and body, then send again.", bundle: .module)
        }
    }
}
