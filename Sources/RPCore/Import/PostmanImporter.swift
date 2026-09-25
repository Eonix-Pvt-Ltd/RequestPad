import Foundation

/// Imports Postman Collection v2.1 (and v2.0) JSON exports (P03).
///
/// Folders, requests, headers, query, bodies (raw, urlencoded, formdata, graphql), auth (bearer, basic, apikey,
/// OAuth 2.0 client credentials / authorization code) and collection variables are imported. Pre-request and test
/// scripts are dropped and the affected requests are listed in the notices.
public enum PostmanImporter {
    public static let maximumItems = 10_000
    static let maximumFolderDepth = 16

    public static func importDocument(_ data: Data) throws(CoreError) -> ImportedCollection {
        let root = try JSONParser(maximumBytes: StructuredDocument.maximumBytes, maximumDepth: 128).parse(data)
        guard let schema = root["info"]?["schema"]?.stringValue,
            schema.contains("schema.getpostman.com") || schema.contains("schema.postman.com")
        else {
            throw .unsupportedDocument(reason: "This isn't a Postman collection export.")
        }
        guard schema.contains("v2.1") || schema.contains("v2.0") else {
            throw .unsupportedDocument(reason: "Only Postman Collection v2.0 and v2.1 exports are supported.")
        }
        let name = root["info"]?["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var context = Context(collection: ImportedCollection(name: name.isEmpty ? "Imported Collection" : name))
        context.collection.settings.variables = (root["variable"]?.arrayValue ?? []).compactMap(variableRow)
        context.collection.settings.auth = context.auth(root["auth"]) ?? .none
        if hasScripts(root) { context.collection.notice("Collection-level scripts were not imported.") }
        try context.importItems(root["item"]?.arrayValue ?? [], folderPath: nil, depth: 0)
        if !context.scriptedRequests.isEmpty {
            let list = context.scriptedRequests.prefix(10).joined(separator: ", ")
            let more = context.scriptedRequests.count > 10 ? " and \(context.scriptedRequests.count - 10) more" : ""
            context.collection.notice("Scripts were not imported for: \(list)\(more).")
        }
        return context.collection
    }

    static func hasScripts(_ value: JSONValue) -> Bool {
        (value["event"]?.arrayValue ?? []).contains { event in
            let exec = event["script"]?["exec"]
            let lines = exec?.arrayValue?.compactMap(\.stringValue) ?? (exec?.stringValue.map { [$0] } ?? [])
            return lines.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    static func variableRow(_ value: JSONValue) -> KeyValue? {
        guard let key = value["key"]?.stringValue, !key.isEmpty else { return nil }
        return KeyValue(name: key, value: text(value["value"]), isEnabled: !(value["disabled"]?.boolValue ?? false))
    }

    static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text): text
        case .number(let text): text
        case .bool(let flag): flag ? "true" : "false"
        case .array, .object: value.map { JSONSerializer.string(from: $0, style: .compact) } ?? ""
        case .null, .none: ""
        }
    }

    private struct Context {
        var collection: ImportedCollection
        var sequence = 0
        var scriptedRequests: [String] = []

        mutating func importItems(_ items: [JSONValue], folderPath: String?, depth: Int) throws(CoreError) {
            guard depth <= PostmanImporter.maximumFolderDepth else {
                throw .nestingTooDeep(limit: PostmanImporter.maximumFolderDepth)
            }
            for item in items {
                guard collection.items.count + collection.folders.count < PostmanImporter.maximumItems else {
                    throw .unsupportedDocument(
                        reason: "The collection has more than \(PostmanImporter.maximumItems) items.")
                }
                let rawName = item["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let children = item["item"]?.arrayValue {
                    let name = String(
                        (rawName.isEmpty ? "Folder" : rawName).map { "/\\:".contains($0) ? "-" : $0 }.prefix(100))
                    let path = folderPath.map { "\($0)/\(name)" } ?? name
                    collection.ensureFolder(path)
                    if let index = collection.folders.firstIndex(where: { $0.path == path }) {
                        if let folderAuth = auth(item["auth"]) { collection.folders[index].settings.auth = folderAuth }
                        collection.folders[index].settings.docs =
                            item["description"].map { PostmanImporter.text($0) } ?? ""
                    }
                    if PostmanImporter.hasScripts(item) { scriptedRequests.append(name) }
                    try importItems(children, folderPath: path, depth: depth + 1)
                } else if let request = item["request"] {
                    sequence += 1
                    let name = rawName.isEmpty ? "Request \(sequence)" : rawName
                    var imported = try importRequest(request, name: String(name.prefix(200)))
                    imported.sortOrder = sequence
                    if PostmanImporter.hasScripts(item) { scriptedRequests.append(name) }
                    collection.items.append(ImportedCollection.Item(folderPath: folderPath, request: imported))
                }
            }
        }

        mutating func importRequest(_ request: JSONValue, name: String) throws(CoreError) -> RequestItem {
            // Postman allows a bare URL string as the whole request.
            if case .string(let url) = request {
                return RequestItem(
                    name: name, url: url, queryParams: QueryParameters.parse(fromURL: url), auth: .inherit)
            }
            let methodText = request["method"]?.stringValue ?? "GET"
            guard let method = HTTPMethod(rawValue: methodText) ?? HTTPMethod(lenientBruValue: methodText) else {
                throw .invalidDocument(path: name, reason: "“\(methodText.prefix(40))” isn't a valid HTTP method")
            }
            var item = RequestItem(name: name, method: method)
            item.url = url(request["url"])
            item.queryParams = queryRows(request["url"]) ?? QueryParameters.parse(fromURL: item.url)
            item.pathParams = (request["url"]?["variable"]?.arrayValue ?? []).compactMap(PostmanImporter.variableRow)
            item.headers = (request["header"]?.arrayValue ?? []).compactMap { header in
                guard let key = header["key"]?.stringValue, !key.isEmpty else { return nil }
                return KeyValue(
                    name: key, value: PostmanImporter.text(header["value"]),
                    isEnabled: !(header["disabled"]?.boolValue ?? false))
            }
            item.docs =
                request["description"].map { value in value.stringValue ?? PostmanImporter.text(value["content"]) }
                ?? ""
            item.auth = request["auth"] == nil ? .inherit : (auth(request["auth"]) ?? .none)
            item.body = body(request["body"], requestName: name)
            if case .graphQL = item.body { item.kind = .graphql }
            // Postman stores an explicit Content-Type header; drop it when it only repeats the body's default.
            if let defaultType = item.body.defaultContentType,
                item.headers.lastValue(forCaseInsensitiveName: "Content-Type")?.lowercased() == defaultType.lowercased()
            {
                item.headers.removeAll { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }
            }
            return item
        }

        func url(_ value: JSONValue?) -> String {
            guard let value else { return "" }
            if case .string(let text) = value { return text }
            if let raw = value["raw"]?.stringValue { return raw }
            let host = (value["host"]?.arrayValue?.compactMap(\.stringValue) ?? []).joined(separator: ".")
            let path = (value["path"]?.arrayValue?.compactMap(\.stringValue) ?? []).joined(separator: "/")
            let scheme = value["protocol"]?.stringValue.map { "\($0)://" } ?? ""
            return scheme + host + (path.isEmpty ? "" : "/\(path)")
        }

        func queryRows(_ value: JSONValue?) -> [KeyValue]? {
            guard let query = value?["query"]?.arrayValue else { return nil }
            return query.compactMap { entry in
                guard let key = entry["key"]?.stringValue else { return nil }
                return KeyValue(
                    name: key, value: PostmanImporter.text(entry["value"]),
                    isEnabled: !(entry["disabled"]?.boolValue ?? false))
            }
        }

        mutating func body(_ value: JSONValue?, requestName: String) -> RequestBody {
            guard let value, value["disabled"]?.boolValue != true else { return .none }
            switch value["mode"]?.stringValue {
            case "raw":
                let raw = value["raw"]?.stringValue ?? ""
                switch value["options"]?["raw"]?["language"]?.stringValue {
                case "json": return .json(raw)
                case "xml", "html": return .xml(raw)
                default:
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")), (try? JSONParser().parse(trimmed)) != nil {
                        return .json(raw)
                    }
                    return .text(raw)
                }
            case "urlencoded":
                return .formURLEncoded(
                    (value["urlencoded"]?.arrayValue ?? []).compactMap { entry in
                        guard let key = entry["key"]?.stringValue else { return nil }
                        return KeyValue(
                            name: key, value: PostmanImporter.text(entry["value"]),
                            isEnabled: !(entry["disabled"]?.boolValue ?? false))
                    })
            case "formdata":
                var hasFiles = false
                let fields: [MultipartField] = (value["formdata"]?.arrayValue ?? []).compactMap { entry in
                    guard let key = entry["key"]?.stringValue else { return nil }
                    let enabled = !(entry["disabled"]?.boolValue ?? false)
                    let contentType = entry["contentType"]?.stringValue
                    if entry["type"]?.stringValue == "file" {
                        hasFiles = true
                        let sources =
                            entry["src"]?.arrayValue?.compactMap(\.stringValue) ?? entry["src"]?.stringValue.map {
                                [$0]
                            } ?? []
                        return MultipartField(
                            name: key, content: .files(sources), contentType: contentType, isEnabled: enabled)
                    }
                    return MultipartField(
                        name: key, content: .text(PostmanImporter.text(entry["value"])), contentType: contentType,
                        isEnabled: enabled)
                }
                if hasFiles {
                    collection.notice("Choose the files for form fields again; Postman file paths can't be opened.")
                }
                return .multipart(fields)
            case "graphql":
                let graphQL = value["graphql"]
                return .graphQL(
                    GraphQLBody(
                        query: graphQL?["query"]?.stringValue ?? "", variables: graphQL?["variables"]?.stringValue ?? ""
                    ))
            case "file":
                collection.notice("A binary file body in “\(requestName)” was not imported.")
                return .none
            default:
                return .none
            }
        }

        /// Maps a Postman auth object; `nil` when absent (inherit) or unsupported (with a notice).
        mutating func auth(_ value: JSONValue?) -> RequestAuth? {
            guard let value, let type = value["type"]?.stringValue else { return nil }
            func parameter(_ key: String) -> String {
                let entries = value[type]?.arrayValue ?? []
                if let entry = entries.first(where: { $0["key"]?.stringValue == key }) {
                    return PostmanImporter.text(entry["value"])
                }
                // Postman v2.0 stored auth parameters as an object.
                return PostmanImporter.text(value[type]?[key])
            }
            switch type {
            case "noauth": return RequestAuth.none
            case "inherit": return RequestAuth.inherit
            case "bearer": return .bearer(token: parameter("token"))
            case "basic": return .basic(username: parameter("username"), password: parameter("password"))
            case "apikey":
                let placement: APIKeyAuth.Placement = parameter("in") == "query" ? .query : .header
                return .apiKey(APIKeyAuth(key: parameter("key"), value: parameter("value"), placement: placement))
            case "oauth2":
                let grant = parameter("grant_type")
                let credentialsPlacement: OAuth2Config.CredentialsPlacement =
                    parameter("client_authentication") == "body" ? .body : .basicAuthHeader
                if grant == "client_credentials" {
                    return .oauth2(
                        OAuth2Config(
                            grantType: .clientCredentials, accessTokenURL: parameter("accessTokenUrl"),
                            clientID: parameter("clientId"),
                            clientSecret: parameter("clientSecret"), scope: parameter("scope"),
                            credentialsPlacement: credentialsPlacement))
                }
                if grant == "authorization_code" || grant == "authorization_code_with_pkce" || grant.isEmpty {
                    return .oauth2(
                        OAuth2Config(
                            grantType: .authorizationCode, accessTokenURL: parameter("accessTokenUrl"),
                            authorizationURL: parameter("authUrl"), clientID: parameter("clientId"),
                            clientSecret: parameter("clientSecret"),
                            scope: parameter("scope"), usePKCE: true, credentialsPlacement: credentialsPlacement))
                }
                collection.notice("OAuth 2.0 grant “\(grant)” isn't supported; those requests use no auth.")
                return RequestAuth.none
            default:
                collection.notice("Postman “\(type)” auth isn't supported; those requests use no auth.")
                return RequestAuth.none
            }
        }
    }
}
