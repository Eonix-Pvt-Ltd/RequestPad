import Foundation

/// Result of importing a cURL command (F07.1).
public struct CurlImport: Hashable, Sendable {
    public var request: RequestItem
    /// Flags that were ignored or only partly supported, for display after import.
    public var notices: [String]
}

/// Parses `curl …` commands from browsers ("Copy as cURL"), Postman, Bruno and documentation.
public enum CurlParser {
    public static let maximumCommandBytes = 5 * 1024 * 1024

    private enum Flag {
        case method, header, data(DataKind), json, form(isString: Bool), user, get, head, url, cookie, userAgent
        case referer, maxTime, oauth2Bearer, ignored(takesValue: Bool, notice: String?)
    }

    private enum DataKind {
        case raw
        case binary
        case urlencode
    }

    private static let longFlags: [String: Flag] = [
        "--request": .method, "--header": .header, "--data": .data(.raw), "--data-ascii": .data(.raw),
        "--data-raw": .data(.raw), "--data-binary": .data(.binary), "--data-urlencode": .data(.urlencode),
        "--json": .json, "--form": .form(isString: false), "--form-string": .form(isString: true), "--user": .user,
        "--get": .get, "--head": .head, "--url": .url, "--cookie": .cookie, "--user-agent": .userAgent,
        "--referer": .referer, "--max-time": .maxTime, "--oauth2-bearer": .oauth2Bearer,
        "--location": .ignored(takesValue: false, notice: nil),
        "--compressed": .ignored(takesValue: false, notice: nil),
        "--silent": .ignored(takesValue: false, notice: nil), "--show-error": .ignored(takesValue: false, notice: nil),
        "--verbose": .ignored(takesValue: false, notice: nil), "--include": .ignored(takesValue: false, notice: nil),
        "--fail": .ignored(takesValue: false, notice: nil), "--globoff": .ignored(takesValue: false, notice: nil),
        "--http1.1": .ignored(takesValue: false, notice: nil), "--http2": .ignored(takesValue: false, notice: nil),
        "--http2-prior-knowledge": .ignored(takesValue: false, notice: nil),
        "--http3": .ignored(takesValue: false, notice: nil),
        "--insecure": .ignored(
            takesValue: false, notice: "--insecure was ignored: RequestPad always verifies TLS certificates."),
        "--output": .ignored(takesValue: true, notice: nil),
        "--connect-timeout": .ignored(takesValue: true, notice: nil),
        "--proxy": .ignored(takesValue: true, notice: "--proxy was ignored: proxies are not supported."),
        "--cert": .ignored(takesValue: true, notice: "--cert was ignored: client certificates are not supported."),
        "--key": .ignored(takesValue: true, notice: "--key was ignored: client certificates are not supported."),
        "--cacert": .ignored(takesValue: true, notice: "--cacert was ignored: RequestPad uses the system trust store."),
        "--retry": .ignored(takesValue: true, notice: nil), "--write-out": .ignored(takesValue: true, notice: nil),
        "--cookie-jar": .ignored(takesValue: true, notice: nil),
        "--max-redirs": .ignored(takesValue: true, notice: nil),
        "--no-buffer": .ignored(takesValue: false, notice: nil),
        "--path-as-is": .ignored(takesValue: false, notice: nil),
    ]

    private static let shortFlags: [Character: Flag] = [
        "X": .method, "H": .header, "d": .data(.raw), "F": .form(isString: false), "u": .user, "G": .get, "I": .head,
        "b": .cookie, "A": .userAgent, "e": .referer, "m": .maxTime, "L": .ignored(takesValue: false, notice: nil),
        "s": .ignored(takesValue: false, notice: nil), "S": .ignored(takesValue: false, notice: nil),
        "v": .ignored(takesValue: false, notice: nil), "i": .ignored(takesValue: false, notice: nil),
        "f": .ignored(takesValue: false, notice: nil), "g": .ignored(takesValue: false, notice: nil),
        "k": .ignored(takesValue: false, notice: "-k was ignored: RequestPad always verifies TLS certificates."),
        "o": .ignored(takesValue: true, notice: nil), "c": .ignored(takesValue: true, notice: nil),
        "x": .ignored(takesValue: true, notice: "-x was ignored: proxies are not supported."),
        "E": .ignored(takesValue: true, notice: "-E was ignored: client certificates are not supported."),
        "w": .ignored(takesValue: true, notice: nil),
    ]

    private struct State {
        var method: String?
        var url: String?
        var headers: [KeyValue] = []
        var data: [String] = []
        var dataIsJSON = false
        var formFields: [MultipartField] = []
        var user: String?
        var useGet = false
        var useHead = false
        var timeoutMilliseconds: Int?
        var bearer: String?
        var notices: [String] = []

        mutating func notice(_ text: String) {
            if !notices.contains(text) { notices.append(text) }
        }
    }

    public static func parse(_ command: String) throws(CoreError) -> CurlImport {
        guard command.utf8.count <= maximumCommandBytes else { throw .inputTooLarge(limitBytes: maximumCommandBytes) }
        var text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("$ ") { text.removeFirst(2) }
        var words = try ShellWords.split(text)
        guard let first = words.first, first == "curl" || first.hasSuffix("/curl") || first == "curl.exe" else {
            throw .curlSyntax(reason: "The command must start with “curl”.")
        }
        words.removeFirst()
        var state = State()
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            if word == "--" {
                if index < words.count, state.url == nil { state.url = words[index] }
                break
            }
            if word.hasPrefix("--") {
                var name = word
                var inlineValue: String?
                if let equals = word.firstIndex(of: "=") {
                    name = String(word[..<equals])
                    inlineValue = String(word[word.index(after: equals)...])
                }
                guard let flag = longFlags[name] else {
                    state.notice("\(name) is not supported and was ignored.")
                    continue
                }
                try apply(flag, name: name, inlineValue: inlineValue, words: words, index: &index, state: &state)
            } else if word.hasPrefix("-"), word.count > 1 {
                var characters = Array(word.dropFirst())
                while !characters.isEmpty {
                    let character = characters.removeFirst()
                    guard let flag = shortFlags[character] else {
                        state.notice("-\(character) is not supported and was ignored.")
                        continue
                    }
                    if takesValue(flag) {
                        let attached = characters.isEmpty ? nil : String(characters)
                        characters.removeAll()
                        try apply(
                            flag, name: "-\(character)", inlineValue: attached, words: words, index: &index,
                            state: &state)
                    } else {
                        try apply(
                            flag, name: "-\(character)", inlineValue: nil, words: words, index: &index, state: &state)
                    }
                }
            } else if state.url == nil {
                state.url = word
            } else {
                state.notice("Extra argument “\(word.prefix(40))” was ignored.")
            }
        }
        return CurlImport(request: try buildRequest(from: state), notices: state.notices)
    }

    private static func takesValue(_ flag: Flag) -> Bool {
        switch flag {
        case .get, .head: false
        case .ignored(let takesValue, _): takesValue
        default: true
        }
    }

    private static func apply(
        _ flag: Flag, name: String, inlineValue: String?, words: [String], index: inout Int, state: inout State
    ) throws(CoreError) {
        var value = inlineValue
        if takesValue(flag), value == nil {
            guard index < words.count else { throw .curlSyntax(reason: "\(name) needs a value.") }
            value = words[index]
            index += 1
        }
        let argument = value ?? ""
        switch flag {
        case .method: state.method = argument
        case .header:
            guard let colon = argument.firstIndex(of: ":") ?? argument.firstIndex(of: ";") else {
                state.notice("Header “\(argument.prefix(40))” has no value and was ignored.")
                return
            }
            let headerName = argument[..<colon].trimmingCharacters(in: .whitespaces)
            let headerValue = argument[argument.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if argument[colon] == ":" && headerValue.isEmpty { return }
            state.headers.append(KeyValue(name: headerName, value: headerValue))
        case .data(let kind):
            if argument.hasPrefix("@"), kind != .urlencode || !argument.contains("=") {
                state.notice("\(name) \(argument.prefix(40)) reads a file; add the body manually.")
                return
            }
            switch kind {
            case .raw, .binary:
                state.data.append(argument)
            case .urlencode:
                if let equals = argument.firstIndex(of: "=") {
                    let key = String(argument[..<equals])
                    let raw = String(argument[argument.index(after: equals)...])
                    state.data.append(
                        key.isEmpty ? RequestResolver.formEncode(raw) : "\(key)=\(RequestResolver.formEncode(raw))")
                } else {
                    state.data.append(RequestResolver.formEncode(argument))
                }
            }
        case .json:
            state.data.append(argument)
            state.dataIsJSON = true
        case .form(let isString):
            guard let equals = argument.firstIndex(of: "=") else {
                state.notice("Form field “\(argument.prefix(40))” has no value and was ignored.")
                return
            }
            let fieldName = String(argument[..<equals])
            var fieldValue = String(argument[argument.index(after: equals)...])
            var contentType: String?
            if !isString, let typeRange = fieldValue.range(of: ";type=") {
                contentType = String(fieldValue[typeRange.upperBound...])
                fieldValue = String(fieldValue[..<typeRange.lowerBound])
            }
            if !isString, fieldValue.hasPrefix("@") || fieldValue.hasPrefix("<") {
                let path = String(fieldValue.dropFirst())
                state.formFields.append(
                    MultipartField(name: fieldName, content: .files([path]), contentType: contentType))
                state.notice(
                    "Choose the file for form field “\(fieldName)” again; the path from the command can't be opened.")
            } else {
                state.formFields.append(
                    MultipartField(name: fieldName, content: .text(fieldValue), contentType: contentType))
            }
        case .user: state.user = argument
        case .get: state.useGet = true
        case .head: state.useHead = true
        case .url: state.url = argument
        case .cookie:
            if argument.contains("=") {
                state.headers.append(KeyValue(name: "Cookie", value: argument))
            } else {
                state.notice("\(name) with a cookie file was ignored.")
            }
        case .userAgent: state.headers.append(KeyValue(name: "User-Agent", value: argument))
        case .referer: state.headers.append(KeyValue(name: "Referer", value: argument))
        case .maxTime:
            if let seconds = Double(argument), seconds > 0 { state.timeoutMilliseconds = Int(seconds * 1000) }
        case .oauth2Bearer: state.bearer = argument
        case .ignored(_, let notice):
            if let notice { state.notice(notice) }
        }
    }

    private static func buildRequest(from state: State) throws(CoreError) -> RequestItem {
        guard var url = state.url, !url.isEmpty else { throw .curlSyntax(reason: "The command has no URL.") }
        var request = RequestItem(name: "")
        var headers = state.headers
        let joinedData = state.data.joined(separator: "&")
        if state.useGet, !state.data.isEmpty {
            url += (url.contains("?") ? "&" : "?") + joinedData
        }
        let methodText =
            state.method
            ?? {
                if state.useHead { return "HEAD" }
                if state.useGet { return "GET" }
                return state.data.isEmpty && state.formFields.isEmpty ? "GET" : "POST"
            }()
        guard let method = HTTPMethod(rawValue: methodText) else {
            throw .curlSyntax(reason: "“\(methodText.prefix(40))” isn't a valid HTTP method.")
        }
        request.method = method
        request.url = url
        request.queryParams = QueryParameters.parse(fromURL: url)
        request.name = defaultName(method: method, url: url)
        if let timeout = state.timeoutMilliseconds { request.settings.timeoutMilliseconds = timeout }

        if let user = state.user {
            let parts = user.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            request.auth = .basic(username: String(parts[0]), password: parts.count > 1 ? String(parts[1]) : "")
        } else if let bearer = state.bearer {
            request.auth = .bearer(token: bearer)
        } else {
            request.auth = .none
        }

        let contentType = headers.lastValue(forCaseInsensitiveName: "Content-Type")?.lowercased()
        func removeContentType() {
            headers.removeAll { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }
        }
        if !state.formFields.isEmpty {
            request.body = .multipart(state.formFields)
            removeContentType()
        } else if !state.data.isEmpty, !state.useGet {
            if state.dataIsJSON {
                if !headers.contains(where: { $0.name.caseInsensitiveCompare("Accept") == .orderedSame }) {
                    headers.append(KeyValue(name: "Accept", value: "application/json"))
                }
            }
            let data = joinedData
            if state.dataIsJSON || contentType?.contains("json") == true
                || (contentType == nil && looksLikeJSON(data))
            {
                request.body = .json(data)
                if contentType == "application/json" || contentType == nil { removeContentType() }
            } else if contentType?.contains("xml") == true {
                request.body = .xml(data)
                if contentType == "application/xml" { removeContentType() }
            } else if contentType == nil || contentType?.hasPrefix("application/x-www-form-urlencoded") == true,
                let rows = formRows(data)
            {
                request.body = .formURLEncoded(rows)
                removeContentType()
            } else {
                request.body = .text(data)
                if contentType == nil {
                    headers.append(KeyValue(name: "Content-Type", value: "application/x-www-form-urlencoded"))
                }
            }
        }
        request.headers = headers
        return request
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
        return (try? JSONParser(maximumDepth: 64).parse(trimmed)) != nil
    }

    /// Parses `a=1&b=2` into rows; returns nil if the text isn't form-shaped.
    private static func formRows(_ text: String) -> [KeyValue]? {
        guard !text.isEmpty else { return [] }
        var rows: [KeyValue] = []
        for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[0].contains(where: \.isWhitespace) else { return nil }
            rows.append(
                KeyValue(
                    name: QueryParameters.decode(String(parts[0])), value: QueryParameters.decode(String(parts[1]))))
        }
        return rows
    }

    static func defaultName(method: HTTPMethod, url: String) -> String {
        let withoutScheme = url.replacingOccurrences(
            of: "^[A-Za-z][A-Za-z0-9+.-]*://", with: "", options: .regularExpression)
        let path = withoutScheme.split(separator: "?").first.map(String.init) ?? withoutScheme
        let segments = path.split(separator: "/").dropFirst()
        let last = segments.last.map(String.init) ?? (path.split(separator: "/").first.map(String.init) ?? url)
        return "\(method.rawValue) \(last)"
    }
}
