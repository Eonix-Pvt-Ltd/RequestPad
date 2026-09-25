import Foundation

/// How a response body should be presented (F02.4–F02.6).
public enum ResponseContentKind: String, Hashable, Sendable {
    case json
    case xml
    case html
    case text
    case image
    case binary

    /// Classifies by `Content-Type`, falling back to sniffing the first bytes.
    public static func classify(contentType: String?, prefix: Data) -> ResponseContentKind {
        let mime = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch mime {
        case "application/json", "text/json": return .json
        case _ where mime.hasSuffix("+json"): return .json
        case "application/xml", "text/xml": return .xml
        case _ where mime.hasSuffix("+xml") && mime != "image/svg+xml": return .xml
        case "text/html", "application/xhtml+xml": return .html
        case "image/png", "image/jpeg", "image/gif", "image/heic", "image/heif", "image/webp", "image/bmp",
            "image/tiff":
            return .image
        case _ where mime.hasPrefix("text/"): return .text
        case "application/javascript", "application/x-www-form-urlencoded", "image/svg+xml", "application/graphql":
            return .text
        default: return sniff(prefix)
        }
    }

    private static func sniff(_ prefix: Data) -> ResponseContentKind {
        let bytes = [UInt8](prefix.prefix(512))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) || bytes.starts(with: [0xFF, 0xD8, 0xFF])
            || bytes.starts(with: Array("GIF8".utf8)) || (bytes.count > 12 && bytes[8..<12].elementsEqual("WEBP".utf8))
        {
            return .image
        }
        guard !bytes.contains(0), String(bytes: bytes, encoding: .utf8) != nil || bytes.count == 512 else {
            return .binary
        }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") || text.hasPrefix("[") { return .json }
        if text.lowercased().hasPrefix("<!doctype html") || text.lowercased().hasPrefix("<html") { return .html }
        if text.hasPrefix("<?xml") || text.hasPrefix("<") { return .xml }
        return .text
    }
}

/// Decodes body bytes to text for the Raw view (F02.5): the `charset` parameter if valid, else UTF-8, else
/// Latin-1 (which never fails). Invalid UTF-8 is replaced with U+FFFD rather than failing.
public enum BodyDecoder {
    public struct Decoded: Hashable, Sendable {
        public var text: String
        /// IANA name of the encoding used, for display.
        public var encodingName: String
        /// Whether replacement characters were inserted.
        public var isLossy: Bool
    }

    public static func decode(_ data: Data, contentType: String?) -> Decoded {
        if let charset = charset(in: contentType), let encoding = encoding(named: charset) {
            if let text = String(data: data, encoding: encoding) {
                return Decoded(text: text, encodingName: charset.lowercased(), isLossy: false)
            }
        }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let text = String(data: bytes, encoding: .utf8) {
            return Decoded(text: text, encodingName: "utf-8", isLossy: false)
        }
        // Mostly-UTF-8 content with a few bad bytes reads better lossy than as Latin-1.
        let lossy = String(decoding: bytes, as: UTF8.self)
        let replacements = lossy.unicodeScalars.filter { $0 == "\u{FFFD}" }.count
        if replacements * 20 < max(lossy.unicodeScalars.count, 1) {
            return Decoded(text: lossy, encodingName: "utf-8", isLossy: true)
        }
        // ISO-8859-1 maps every byte to a character, so this cannot fail.
        return Decoded(
            text: String(data: bytes, encoding: .isoLatin1) ?? lossy, encodingName: "iso-8859-1", isLossy: false)
    }

    static func charset(in contentType: String?) -> String? {
        guard let contentType else { return nil }
        for parameter in contentType.split(separator: ";").dropFirst() {
            let parts = parameter.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset" else {
                continue
            }
            return parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(
                in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    static func encoding(named name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}
