import Foundation
import RPCore

/// A request received by Local Echo.
public struct EchoRequest: Sendable, Hashable {
    public var method: String
    public var target: String
    public var version: String
    public var headers: [EchoHeader]
    public var body: Data

    public func header(_ name: String) -> String? {
        headers.last(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    public var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }
    public var query: String? {
        let parts = target.split(separator: "?", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : nil
    }

    public var keepAlive: Bool {
        let connection = header("Connection")?.lowercased()
        return version == "HTTP/1.1" ? connection != "close" : connection == "keep-alive"
    }
}

public struct EchoHeader: Sendable, Hashable {
    public var name: String
    public var value: String
}

public struct EchoResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [EchoHeader]
    public var body: Data
    /// Delay before responding (`/delay/{ms}`).
    public var delayMilliseconds: Int

    public init(status: Int, headers: [EchoHeader] = [], body: Data = Data(), delayMilliseconds: Int = 0) {
        self.status = status
        self.headers = headers
        self.body = body
        self.delayMilliseconds = delayMilliseconds
    }

    /// Serialized status line, headers and body.
    /// RFC 9110 §6.4.1: 1xx, 204 and 304 responses have no body (1xx/204 no Content-Length either); responses to
    /// HEAD carry the length but never the body bytes.
    public func serialized(keepAlive: Bool, isHeadRequest: Bool = false) -> Data {
        let reason = HTTPReasonPhrase.phrase(for: status)
        let forbidsBody = (100..<200).contains(status) || status == 204 || status == 304
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for header in headers where !(forbidsBody && header.name.caseInsensitiveCompare("Content-Type") == .orderedSame)
        {
            head += "\(header.name): \(header.value)\r\n"
        }
        if !forbidsBody || status == 304 { head += "Content-Length: \(forbidsBody ? 0 : body.count)\r\n" }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\nServer: RequestPad-Echo\r\n\r\n"
        var data = Data(head.utf8)
        if !forbidsBody && !isHeadRequest { data.append(body) }
        return data
    }
}

/// Incremental HTTP/1.1 request parser with limits (F08.4). Supports `Content-Length` and chunked bodies.
public struct EchoRequestParser: Sendable {
    public static let maximumHeaderBytes = 64 * 1024
    public static let maximumBodyBytes = 20 * 1024 * 1024

    public enum ParseError: Error, Sendable, Equatable {
        case malformed(String)
        case headersTooLarge
        case bodyTooLarge
    }

    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) { buffer.append(data) }

    /// Returns the next complete request, `nil` if more data is needed.
    public mutating func next() throws(ParseError) -> EchoRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maximumHeaderBytes { throw .headersTooLarge }
            return nil
        }
        guard headerEnd.lowerBound - buffer.startIndex <= Self.maximumHeaderBytes else { throw .headersTooLarge }
        let headText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw .malformed("request line") }
        var headers: [EchoHeader] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw .malformed("header") }
            headers.append(
                EchoHeader(
                    name: String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                    value: String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
        var request = EchoRequest(
            method: String(requestLine[0]), target: String(requestLine[1]), version: String(requestLine[2]),
            headers: headers,
            body: Data())
        let bodyStart = headerEnd.upperBound
        if request.header("Transfer-Encoding")?.lowercased().contains("chunked") == true {
            guard let (body, consumed) = try decodeChunked(from: bodyStart) else { return nil }
            request.body = body
            buffer.removeSubrange(buffer.startIndex..<consumed)
            return request
        }
        let length = Int(request.header("Content-Length") ?? "0") ?? -1
        guard length >= 0 else { throw .malformed("Content-Length") }
        guard length <= Self.maximumBodyBytes else { throw .bodyTooLarge }
        guard buffer.endIndex - bodyStart >= length else { return nil }
        request.body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer.removeSubrange(buffer.startIndex..<(bodyStart + length))
        return request
    }

    private func decodeChunked(from start: Data.Index) throws(ParseError) -> (Data, Data.Index)? {
        var body = Data()
        var cursor = start
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = buffer[cursor...].range(of: crlf) else { return nil }
            let sizeText =
                String(decoding: buffer[cursor..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                throw .malformed("chunk size")
            }
            cursor = lineEnd.upperBound
            if size == 0 {
                // Skip optional trailers up to the final CRLF.
                guard let end = buffer[cursor...].range(of: crlf) else { return nil }
                return (body, end.upperBound)
            }
            guard body.count + size <= Self.maximumBodyBytes else { throw .bodyTooLarge }
            guard buffer.endIndex - cursor >= size + 2 else { return nil }
            body.append(buffer[cursor..<(cursor + size)])
            cursor += size + 2
        }
    }
}

/// Builds Local Echo responses (F08.2). Pure: no I/O, no evaluation of user code.
public enum EchoRouter {
    public static let maximumGeneratedBytes = 20 * 1024 * 1024
    public static let maximumDelayMilliseconds = 10_000

    public static func respond(to request: EchoRequest, tokenID: () -> String = { UUID().uuidString.lowercased() })
        -> EchoResponse
    {
        let path = request.path
        let segments = path.split(separator: "/").map(String.init)
        switch (request.method, segments.first) {
        case (_, "status") where segments.count == 2:
            guard let code = Int(segments[1]), (200...599).contains(code) else {
                return json(400, #"{"error":"Use /status/{code} with a code from 200 to 599."}"#)
            }
            return EchoResponse(status: code, headers: [contentType("application/json")], body: echoBody(request))
        case (_, "delay") where segments.count == 2:
            guard let milliseconds = Int(segments[1]), milliseconds >= 0 else {
                return json(400, #"{"error":"Use /delay/{milliseconds}."}"#)
            }
            var response = EchoResponse(
                status: 200, headers: [contentType("application/json")], body: echoBody(request))
            response.delayMilliseconds = min(milliseconds, maximumDelayMilliseconds)
            return response
        case (_, "bytes") where segments.count == 2:
            guard let count = Int(segments[1]), count >= 0, count <= maximumGeneratedBytes else {
                return json(400, #"{"error":"Use /bytes/{count} with at most 20971520 bytes."}"#)
            }
            return EchoResponse(
                status: 200, headers: [contentType("application/octet-stream")], body: generatedBytes(count))
        case (_, "redirect") where segments.count == 2:
            guard let remaining = Int(segments[1]), (0...20).contains(remaining) else {
                return json(400, #"{"error":"Use /redirect/{count} with a count from 0 to 20."}"#)
            }
            guard remaining > 0 else {
                return EchoResponse(status: 200, headers: [contentType("application/json")], body: echoBody(request))
            }
            return EchoResponse(
                status: 302, headers: [EchoHeader(name: "Location", value: "/redirect/\(remaining - 1)")])
        case (_, "redirect-to") where segments.count == 1:
            // Only loopback targets, so Local Echo can never be used as an open redirector.
            let target =
                QueryParameters.parse(fromURL: "?" + (request.query ?? "")).first { $0.name == "url" }?.value ?? ""
            guard let url = URL(string: target), let host = url.host(percentEncoded: false),
                LocalAddress.isLoopback(host: host),
                url.scheme == "http"
            else {
                return json(
                    400, #"{"error":"Use /redirect-to?url= with an http://127.0.0.1 or http://localhost URL."}"#)
            }
            return EchoResponse(status: 307, headers: [EchoHeader(name: "Location", value: url.absoluteString)])
        case (_, "image.png") where segments.count == 1:
            return EchoResponse(status: 200, headers: [contentType("image/png")], body: samplePNG)
        case (_, "cookies") where segments.count == 2 && segments[1] == "set":
            let cookies = QueryParameters.parse(fromURL: "?" + (request.query ?? "")).filter { !$0.name.isEmpty }
            var response = EchoResponse(
                status: 200, headers: [contentType("application/json")], body: echoBody(request))
            response.headers += cookies.map { EchoHeader(name: "Set-Cookie", value: "\($0.name)=\($0.value); Path=/") }
            return response
        case ("POST", "oauth") where segments.count == 2 && segments[1] == "token":
            return tokenResponse(request, tokenID: tokenID)
        case (_, "graphql") where segments.count == 1:
            return graphQLResponse(request)
        default:
            return EchoResponse(status: 200, headers: [contentType("application/json")], body: echoBody(request))
        }
    }

    /// JSON describing the received request.
    static func echoBody(_ request: EchoRequest) -> Data {
        var query: [JSONMember] = []
        for row in QueryParameters.parse(fromURL: "?" + (request.query ?? "")) {
            if let index = query.firstIndex(where: { $0.key == row.name }), case .array(var values) = query[index].value
            {
                values.append(.string(row.value))
                query[index].value = .array(values)
            } else {
                query.append(JSONMember(row.name, .array([.string(row.value)])))
            }
        }
        var headers: [JSONMember] = []
        for header in request.headers {
            if let index = headers.firstIndex(where: { $0.key.caseInsensitiveCompare(header.name) == .orderedSame }),
                case .string(let existing) = headers[index].value
            {
                headers[index].value = .string("\(existing), \(header.value)")
            } else {
                headers.append(JSONMember(header.name, .string(header.value)))
            }
        }
        var bodyMembers: [JSONMember] = [JSONMember("size", .number(request.body.count))]
        if let text = String(data: request.body, encoding: .utf8) {
            bodyMembers.append(JSONMember("text", .string(text)))
            if let json = try? JSONParser(maximumDepth: 64).parse(request.body) {
                bodyMembers.append(JSONMember("json", json))
            }
        } else {
            bodyMembers.append(JSONMember("base64", .string(request.body.base64EncodedString())))
        }
        let value = JSONValue.object([
            JSONMember("method", .string(request.method)), JSONMember("path", .string(request.path)),
            JSONMember("query", .object(query)), JSONMember("headers", .object(headers)),
            JSONMember("body", .object(bodyMembers)),
        ])
        return Data(JSONSerializer.string(from: value).utf8)
    }

    private static func tokenResponse(_ request: EchoRequest, tokenID: () -> String) -> EchoResponse {
        let form = Dictionary(
            QueryParameters.parse(fromURL: "?" + String(decoding: request.body, as: UTF8.self)).map {
                ($0.name, $0.value)
            },
            uniquingKeysWith: { _, last in last })
        guard form["grant_type"] == "client_credentials" else {
            return json(
                400,
                #"{"error":"unsupported_grant_type","error_description":"Local Echo supports client_credentials."}"#)
        }
        let hasBasicClient = request.header("Authorization")?.hasPrefix("Basic ") == true
        guard hasBasicClient || !(form["client_id"] ?? "").isEmpty else {
            return json(401, #"{"error":"invalid_client","error_description":"Send a client ID."}"#)
        }
        let scope = form["scope"].map { ",\"scope\":\(JSONSerializer.quoted($0))" } ?? ""
        return json(200, #"{"access_token":"echo-\#(tokenID())","token_type":"Bearer","expires_in":3600\#(scope)}"#)
    }

    private static func graphQLResponse(_ request: EchoRequest) -> EchoResponse {
        let payload = try? JSONParser(maximumDepth: 64).parse(request.body)
        let query = payload?["query"]?.stringValue ?? ""
        if query.contains("__schema") { return json(200, sampleIntrospectionJSON) }
        let variables = payload?["variables"] ?? .null
        let echo = JSONValue.object([
            JSONMember(
                "data",
                .object([
                    JSONMember(
                        "echo", .object([JSONMember("query", .string(query)), JSONMember("variables", variables)]))
                ]))
        ])
        return EchoResponse(
            status: 200, headers: [contentType("application/json")], body: Data(JSONSerializer.string(from: echo).utf8))
    }

    private static func json(_ status: Int, _ text: String) -> EchoResponse {
        EchoResponse(status: status, headers: [contentType("application/json")], body: Data(text.utf8))
    }

    private static func contentType(_ value: String) -> EchoHeader { EchoHeader(name: "Content-Type", value: value) }

    static func generatedBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            for index in 0..<count { raw[index] = UInt8(truncatingIfNeeded: index) }
        }
        return data
    }

    /// A 1×1 PNG.
    static let samplePNG =
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
        ?? Data()

    /// Introspection result for the sample GraphQL schema (P04 demo without external services).
    static let sampleIntrospectionJSON: String = {
        func named(_ kind: String, _ name: String) -> String { #"{"kind":"\#(kind)","name":"\#(name)","ofType":null}"# }
        func nonNull(_ inner: String) -> String { #"{"kind":"NON_NULL","name":null,"ofType":\#(inner)}"# }
        func list(_ inner: String) -> String { #"{"kind":"LIST","name":null,"ofType":\#(inner)}"# }
        func field(_ name: String, _ type: String, args: String = "[]") -> String {
            #"{"name":"\#(name)","description":null,"args":\#(args),"type":\#(type),"isDeprecated":false}"#
        }
        func arg(_ name: String, _ type: String) -> String {
            #"{"name":"\#(name)","description":null,"type":\#(type)}"#
        }
        let string = named("SCALAR", "String")
        let types = [
            #"{"kind":"OBJECT","name":"Query","description":"Local Echo sample schema","fields":[\#(field("hello", string, args: "[\(arg("name", string))]")),\#(field("echo", named("OBJECT", "Echo"))),\#(field("items", nonNull(list(nonNull(named("OBJECT", "Item")))), args: "[\(arg("first", named("SCALAR", "Int")))]"))],"inputFields":null,"enumValues":null,"possibleTypes":null}"#,
            #"{"kind":"OBJECT","name":"Echo","description":null,"fields":[\#(field("query", string)),\#(field("variables", string))],"inputFields":null,"enumValues":null,"possibleTypes":null}"#,
            #"{"kind":"OBJECT","name":"Item","description":null,"fields":[\#(field("id", nonNull(named("SCALAR", "ID")))),\#(field("name", string)),\#(field("status", named("ENUM", "Status")))],"inputFields":null,"enumValues":null,"possibleTypes":null}"#,
            #"{"kind":"ENUM","name":"Status","description":null,"fields":null,"inputFields":null,"enumValues":[{"name":"ACTIVE"},{"name":"ARCHIVED"}],"possibleTypes":null}"#,
            #"{"kind":"SCALAR","name":"String","fields":null,"inputFields":null,"enumValues":null,"possibleTypes":null}"#,
            #"{"kind":"SCALAR","name":"Int","fields":null,"inputFields":null,"enumValues":null,"possibleTypes":null}"#,
            #"{"kind":"SCALAR","name":"ID","fields":null,"inputFields":null,"enumValues":null,"possibleTypes":null}"#,
        ]
        return
            #"{"data":{"__schema":{"queryType":{"name":"Query"},"mutationType":null,"subscriptionType":null,"types":[\#(types.joined(separator: ","))]}}}"#
    }()
}
