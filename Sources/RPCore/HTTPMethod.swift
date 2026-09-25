import Foundation

/// An HTTP request method. Standard methods are offered in the picker; any RFC 9110 `token` is accepted as a
/// custom method (F01.1).
public struct HTTPMethod: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public static let get = HTTPMethod(uncheckedToken: "GET")
    public static let post = HTTPMethod(uncheckedToken: "POST")
    public static let put = HTTPMethod(uncheckedToken: "PUT")
    public static let patch = HTTPMethod(uncheckedToken: "PATCH")
    public static let delete = HTTPMethod(uncheckedToken: "DELETE")
    public static let head = HTTPMethod(uncheckedToken: "HEAD")
    public static let options = HTTPMethod(uncheckedToken: "OPTIONS")

    /// Methods shown in the method picker, in display order.
    public static let standard: [HTTPMethod] = [.get, .post, .put, .patch, .delete, .head, .options]

    /// Longest custom method accepted. Real methods are short; the cap bounds UI and file sizes.
    public static let maximumLength = 32

    /// Creates a method from user input. Returns `nil` unless `rawValue` is a non-empty RFC 9110 token no longer
    /// than ``maximumLength``. Standard methods are matched case-insensitively and normalized to upper case;
    /// custom methods keep their case because methods are case-sensitive on the wire.
    public init?(rawValue: String) {
        guard Self.isValidToken(rawValue) else { return nil }
        if let standard = Self.standard.first(where: { $0.rawValue.caseInsensitiveCompare(rawValue) == .orderedSame }) {
            self = standard
        } else {
            self.rawValue = rawValue
        }
    }

    /// Accepts any printable ASCII method without spaces (up to ``maximumLength``). Bruno allows methods that are
    /// not RFC 9110 tokens (e.g. `CUSTOM@METHOD`); such requests open and round-trip, and ``isValidForSending``
    /// reports that the network layer will refuse them.
    public init?(lenientBruValue value: String) {
        guard !value.isEmpty, value.utf8.count <= Self.maximumLength,
            value.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) })
        else { return nil }
        self.rawValue = value
    }

    /// Whether the method is an RFC 9110 token that can be sent on the wire.
    public var isValidForSending: Bool { Self.isValidToken(rawValue) }

    private init(uncheckedToken: String) {
        rawValue = uncheckedToken
    }

    public var description: String { rawValue }

    /// Whether the method is one of ``standard``.
    public var isStandard: Bool { Self.standard.contains(self) }

    /// Whether requests with this method conventionally carry a body. Used to decide default body UI only;
    /// the user can always attach a body.
    public var conventionallyHasBody: Bool {
        switch self {
        case .post, .put, .patch: true
        default: !isStandard
        }
    }

    /// RFC 9110 §5.6.2: `token = 1*tchar`, limited to `maximumLength` bytes (method names by default).
    public static func isValidToken(_ value: String, maximumLength: Int = HTTPMethod.maximumLength) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumLength else { return false }
        return value.unicodeScalars.allSatisfy(isTokenCharacter)
    }

    private static func isTokenCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9":
            true
        case "!", "#", "$", "%", "&", "'", "*", "+", "-", ".", "^", "_", "`", "|", "~":
            true
        default:
            false
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let method = HTTPMethod(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid HTTP method token")
        }
        self = method
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
