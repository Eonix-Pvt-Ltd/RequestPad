import Foundation
import Testing

@testable import RPCore

@Suite("ResponseBody")
struct ResponseBodyTests {
    @Test(
        arguments: [
            ("application/json; charset=utf-8", "", ResponseContentKind.json), ("application/problem+json", "", .json),
            ("text/xml", "", .xml), ("application/atom+xml", "", .xml), ("image/svg+xml", "", .text),
            ("text/html", "", .html),
            ("image/png", "", .image), ("text/csv", "", .text), ("application/javascript", "", .text),
            (nil, "  {\"a\":1}", .json), (nil, "<!DOCTYPE html><html>", .html), (nil, "<?xml version=\"1.0\"?>", .xml),
            (nil, "hello", .text), ("application/octet-stream", "plain text", .text),
        ] as [(String?, String, ResponseContentKind)])
    func classifiesText(contentType: String?, body: String, expected: ResponseContentKind) {
        #expect(ResponseContentKind.classify(contentType: contentType, prefix: Data(body.utf8)) == expected)
    }

    @Test func sniffsBinaryAndImages() {
        #expect(ResponseContentKind.classify(contentType: nil, prefix: Data([0x89, 0x50, 0x4E, 0x47, 0x0D])) == .image)
        #expect(ResponseContentKind.classify(contentType: nil, prefix: Data([0xFF, 0xD8, 0xFF, 0xE0])) == .image)
        #expect(ResponseContentKind.classify(contentType: nil, prefix: Data("GIF89a".utf8)) == .image)
        #expect(
            ResponseContentKind.classify(contentType: nil, prefix: Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8))
                == .image)
        #expect(
            ResponseContentKind.classify(contentType: "application/octet-stream", prefix: Data([0x00, 0x01, 0x02]))
                == .binary)
        #expect(ResponseContentKind.classify(contentType: nil, prefix: Data([0xC3, 0x28])) == .binary)
    }

    @Test func decodesCharsets() {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9])
        #expect(
            BodyDecoder.decode(latin1, contentType: "text/plain; charset=ISO-8859-1")
                == .init(text: "café", encodingName: "iso-8859-1", isLossy: false))
        #expect(BodyDecoder.decode(latin1, contentType: "text/plain").encodingName == "iso-8859-1")
        #expect(BodyDecoder.decode(latin1, contentType: "text/plain").text == "café")
        let utf8 = Data("café ✓".utf8)
        #expect(BodyDecoder.decode(utf8, contentType: "text/plain; charset=\"utf-8\"").text == "café ✓")
        #expect(BodyDecoder.decode(Data([0xEF, 0xBB, 0xBF]) + utf8, contentType: nil).text == "café ✓")
        let shiftJIS = Data([0x82, 0xA0])
        #expect(BodyDecoder.decode(shiftJIS, contentType: "text/plain; charset=Shift_JIS").text == "あ")
        #expect(BodyDecoder.decode(utf8, contentType: "text/plain; charset=bogus-charset").encodingName == "utf-8")
    }

    @Test func mostlyUTF8IsLossyNotLatin1() {
        var data = Data(String(repeating: "valid text ", count: 10).utf8)
        data.append(0xFF)
        let decoded = BodyDecoder.decode(data, contentType: nil)
        #expect(decoded.isLossy)
        #expect(decoded.encodingName == "utf-8")
        #expect(decoded.text.hasSuffix("\u{FFFD}"))
    }

    @Test func emptyBody() {
        #expect(BodyDecoder.decode(Data(), contentType: nil).text == "")
        #expect(BodyDecoder.charset(in: "text/plain; format=flowed; charset=utf-8") == "utf-8")
        #expect(BodyDecoder.charset(in: nil) == nil)
    }
}
