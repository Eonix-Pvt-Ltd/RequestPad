import Foundation

/// A request ready to hand to the network layer (all variables substituted, auth applied).
public struct ResolvedRequest: Hashable, Sendable {
    public enum Body: Hashable, Sendable {
        case none
        case data(Data)
        /// Multipart parts; file parts carry references the services layer opens at send time.
        case multipart([MultipartPart])
    }

    public struct MultipartPart: Hashable, Sendable {
        public enum Content: Hashable, Sendable {
            case text(String)
            case file(reference: String)
        }

        public var name: String
        public var content: Content
        public var contentType: String?

        public init(name: String, content: Content, contentType: String? = nil) {
            self.name = name
            self.content = content
            self.contentType = contentType
        }
    }

    public var method: HTTPMethod
    public var url: URL
    /// Header fields in send order; duplicates allowed (F01.3).
    public var headers: [(name: String, value: String)]
    public var body: Body
    public var settings: RequestSettings
    /// Variable names that had no value (sent literally, F04.3).
    public var unresolvedVariables: [String]
    /// Whether any secret value was substituted.
    public var containsSecrets: Bool
    /// Whether auth could not be applied because the mode is unsupported or needs a token first.
    public var authIssue: AuthIssue?

    public enum AuthIssue: Hashable, Sendable {
        case unsupportedMode(String)
        case oauth2TokenRequired
    }

    public init(
        method: HTTPMethod, url: URL, headers: [(name: String, value: String)] = [], body: Body = .none,
        settings: RequestSettings = RequestSettings(), unresolvedVariables: [String] = [],
        containsSecrets: Bool = false,
        authIssue: AuthIssue? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.settings = settings
        self.unresolvedVariables = unresolvedVariables
        self.containsSecrets = containsSecrets
        self.authIssue = authIssue
    }

    public static func == (lhs: ResolvedRequest, rhs: ResolvedRequest) -> Bool {
        lhs.method == rhs.method && lhs.url == rhs.url && lhs.body == rhs.body && lhs.settings == rhs.settings
            && lhs.headers.map { [$0.name, $0.value] } == rhs.headers.map { [$0.name, $0.value] }
            && lhs.unresolvedVariables == rhs.unresolvedVariables && lhs.containsSecrets == rhs.containsSecrets
            && lhs.authIssue == rhs.authIssue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(method)
        hasher.combine(url)
    }

    /// Value of the last header with `name` (case-insensitive).
    public func headerValue(_ name: String) -> String? {
        headers.last(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value
    }
}

/// Inputs outside the request itself that determine how it is sent.
public struct ResolutionContext: Sendable {
    /// Folder settings from the outermost folder to the innermost.
    public var folders: [FolderSettings]
    public var collection: FolderSettings
    public var variables: VariableContext
    /// Access token for OAuth 2.0 auth, fetched beforehand by the services layer.
    public var oauth2AccessToken: String?

    public init(
        folders: [FolderSettings] = [], collection: FolderSettings = FolderSettings(),
        variables: VariableContext = VariableContext(), oauth2AccessToken: String? = nil
    ) {
        self.folders = folders
        self.collection = collection
        self.variables = variables
        self.oauth2AccessToken = oauth2AccessToken
    }

    /// Auth after resolving `inherit` through request → innermost folder → collection (F05.2).
    public func effectiveAuth(for request: RequestItem) -> RequestAuth {
        if request.auth != .inherit { return request.auth }
        for folder in folders.reversed() where folder.auth != .inherit {
            return folder.auth
        }
        return collection.auth == .inherit ? .none : collection.auth
    }
}

/// Turns a ``RequestItem`` into a ``ResolvedRequest`` (pure; no I/O).
public struct RequestResolver: Sendable {
    public var interpolator: Interpolator

    public init(interpolator: Interpolator) {
        self.interpolator = interpolator
    }

    public func resolve(
        _ request: RequestItem, context: ResolutionContext, mode: Interpolator.Mode = .send
    ) throws(CoreError) -> ResolvedRequest {
        var variables = context.variables
        variables.scopes.append(contentsOf: [VariableScope(kind: .request, rows: request.variables)])
        variables.scopes.append(
            contentsOf: context.folders.reversed().map { VariableScope(kind: .folder, rows: $0.variables) })
        variables.scopes.append(VariableScope(kind: .collection, rows: context.collection.variables))
        variables = VariableContext(scopes: variables.scopes)

        var tracker = Tracker(interpolator: interpolator, variables: variables, mode: mode)
        var urlText = tracker.apply(request.url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlText.isEmpty else { throw .invalidRequest(reason: "Enter a URL.") }
        urlText = substitutePathParameters(in: urlText, rows: request.pathParams, tracker: &tracker)
        urlText = Self.addingDefaultScheme(to: urlText)

        var headers = mergedHeaders(for: request, context: context, tracker: &tracker)
        let auth = context.effectiveAuth(for: request)
        var authIssue: ResolvedRequest.AuthIssue?
        var extraQuery: [(String, String)] = []
        switch auth {
        case .inherit, .none:
            break
        case .bearer(let token):
            appendIfMissing(&headers, "Authorization", "Bearer \(tracker.apply(token))")
        case .basic(let username, let password):
            let credentials = "\(tracker.apply(username)):\(tracker.apply(password))"
            appendIfMissing(&headers, "Authorization", "Basic \(Data(credentials.utf8).base64EncodedString())")
        case .apiKey(let apiKey):
            let key = tracker.apply(apiKey.key)
            let value = tracker.apply(apiKey.value)
            if !key.isEmpty {
                switch apiKey.placement {
                case .header: appendIfMissing(&headers, key, value)
                case .query: extraQuery.append((key, value))
                }
            }
        case .oauth2(let config):
            if let token = context.oauth2AccessToken, !token.isEmpty {
                switch config.tokenPlacement {
                case .header:
                    let prefix = tracker.apply(config.tokenHeaderPrefix).trimmingCharacters(in: .whitespaces)
                    appendIfMissing(&headers, "Authorization", prefix.isEmpty ? token : "\(prefix) \(token)")
                case .url:
                    extraQuery.append((config.tokenQueryKey.isEmpty ? "access_token" : config.tokenQueryKey, token))
                }
            } else {
                authIssue = .oauth2TokenRequired
            }
        case .unsupported(let mode):
            authIssue = .unsupportedMode(mode)
        }

        for (name, value) in extraQuery {
            let separator = urlText.contains("?") ? "&" : "?"
            urlText += "\(separator)\(QueryParameters.encode(name))=\(QueryParameters.encode(value))"
        }
        guard let url = URL(string: urlText, encodingInvalidCharacters: true), url.scheme != nil, url.host() != nil
        else {
            throw .invalidRequest(reason: "“\(Self.redactedForMessage(urlText))” isn't a valid URL.")
        }

        let body = try resolveBody(request.body, tracker: &tracker)
        if let contentType = request.body.defaultContentType, !Self.hasHeader(headers, "Content-Type") {
            headers.append((name: "Content-Type", value: contentType))
        }

        return ResolvedRequest(
            method: request.method, url: url, headers: headers, body: body, settings: request.settings,
            unresolvedVariables: tracker.unresolved, containsSecrets: tracker.containsSecrets, authIssue: authIssue)
    }

    /// Adds `http://` for local-looking hosts and `https://` otherwise when the URL has no scheme.
    public static func addingDefaultScheme(to url: String) -> String {
        if url.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil { return url }
        let host = url.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? url
        let hostWithoutPort: String
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            hostWithoutPort = String(host[host.index(after: host.startIndex)..<close])
        } else {
            hostWithoutPort = host.split(separator: ":").first.map(String.init) ?? host
        }
        return (LocalAddress.isLocal(host: hostWithoutPort) ? "http://" : "https://") + url
    }

    private static func redactedForMessage(_ text: String) -> String {
        text.count > 80 ? String(text.prefix(77)) + "…" : text
    }

    private func mergedHeaders(
        for request: RequestItem, context: ResolutionContext, tracker: inout Tracker
    ) -> [(name: String, value: String)] {
        // Collection → folders (outer → inner) → request; a header defined at a narrower scope replaces all
        // broader definitions of the same name (case-insensitive), while duplicates within one scope are kept.
        let layers = [context.collection.headers] + context.folders.map(\.headers) + [request.headers]
        var result: [(name: String, value: String)] = []
        for layer in layers {
            let rows = layer.active
            let names = Set(rows.map { $0.name.lowercased() })
            result.removeAll { names.contains($0.name.lowercased()) }
            for row in rows {
                result.append((name: tracker.apply(row.name), value: tracker.apply(row.value)))
            }
        }
        return result
    }

    private func substitutePathParameters(in url: String, rows: [KeyValue], tracker: inout Tracker) -> String {
        let active = rows.active
        guard !active.isEmpty else { return url }
        let queryStart = url.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? url.endIndex
        var path = String(url[..<queryStart])
        for row in active {
            let value = tracker.apply(row.value).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            path = path.replacingOccurrences(
                of: "/:\(NSRegularExpression.escapedPattern(for: row.name))(?=/|$)", with: "/\(value)",
                options: .regularExpression)
        }
        return path + url[queryStart...]
    }

    private func resolveBody(_ body: RequestBody, tracker: inout Tracker) throws(CoreError) -> ResolvedRequest.Body {
        switch body {
        case .none, .unsupported:
            return .none
        case .json(let text), .text(let text), .xml(let text):
            return .data(Data(tracker.apply(text).utf8))
        case .formURLEncoded(let rows):
            let encoded = rows.active.map { row in
                "\(Self.formEncode(tracker.apply(row.name)))=\(Self.formEncode(tracker.apply(row.value)))"
            }.joined(separator: "&")
            return .data(Data(encoded.utf8))
        case .multipart(let fields):
            var parts: [ResolvedRequest.MultipartPart] = []
            for field in fields where field.isEnabled && !field.name.isEmpty {
                let name = tracker.apply(field.name)
                switch field.content {
                case .text(let value):
                    parts.append(
                        .init(name: name, content: .text(tracker.apply(value)), contentType: field.contentType))
                case .files(let references):
                    for reference in references {
                        parts.append(
                            .init(
                                name: name, content: .file(reference: tracker.apply(reference)),
                                contentType: field.contentType))
                    }
                }
            }
            return .multipart(parts)
        case .graphQL(let graphQL):
            var members = [JSONMember("query", .string(tracker.apply(graphQL.query)))]
            let variablesText = tracker.apply(graphQL.variables).trimmingCharacters(in: .whitespacesAndNewlines)
            if !variablesText.isEmpty {
                let variables: JSONValue
                do {
                    variables = try JSONParser(maximumDepth: 64).parse(variablesText)
                } catch {
                    throw .invalidRequest(
                        reason: "The GraphQL variables aren't valid JSON. \(error.errorDescription ?? "")")
                }
                guard case .object = variables else {
                    throw .invalidRequest(reason: "The GraphQL variables must be a JSON object.")
                }
                members.append(JSONMember("variables", variables))
            }
            return .data(Data(JSONSerializer.string(from: .object(members), style: .compact).utf8))
        }
    }

    /// `application/x-www-form-urlencoded` encoding (WHATWG): space → `+`, unreserved kept, rest percent-encoded.
    static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "*-._ ")
        return (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "").replacingOccurrences(
            of: " ", with: "+")
    }

    private static func hasHeader(_ headers: [(name: String, value: String)], _ name: String) -> Bool {
        headers.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func appendIfMissing(_ headers: inout [(name: String, value: String)], _ name: String, _ value: String) {
        // An explicit header set by the user wins over the auth helper.
        if !Self.hasHeader(headers, name) { headers.append((name: name, value: value)) }
    }

    private struct Tracker {
        let interpolator: Interpolator
        let variables: VariableContext
        let mode: Interpolator.Mode
        var unresolved: [String] = []
        var containsSecrets = false

        mutating func apply(_ template: String) -> String {
            let result = interpolator.interpolate(template, in: variables, mode: mode)
            for name in result.unresolved where !unresolved.contains(name) { unresolved.append(name) }
            containsSecrets = containsSecrets || result.containsSecrets
            return result.text
        }
    }
}
