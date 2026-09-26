import Foundation

/// Imports OpenAPI 3.0.x / 3.1.x documents (JSON or YAML) as a collection (P02).
///
/// - Tags become folders (first tag of each operation); untagged operations go to the collection root.
/// - `servers[0]` becomes the `baseUrl` collection variable; every server also becomes an environment.
/// - Path templates `{id}` become Bruno path parameters `:id` with example values.
/// - Request bodies use `example`/`examples`, else an example synthesized from the schema (depth ≤ 8).
/// - Security schemes map to Bearer, Basic, API key and OAuth 2.0 auth with `{{variables}}` for secrets.
/// - Only local `$ref`s (`#/…`) are resolved; external and cyclic references are reported, not followed.
public enum OpenAPIImporter {
    public static let maximumSchemaDepth = 8
    static let methods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

    /// `{name}` segments left in a path after declared parameters were converted.
    static func undeclaredTemplates(in path: String) -> [String] {
        var names: [String] = []
        var remainder = path[...]
        while let open = remainder.firstIndex(of: "{"), let close = remainder[open...].firstIndex(of: "}") {
            let name = String(remainder[remainder.index(after: open)..<close])
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "_.-".contains($0) }),
                !names.contains(name)
            {
                names.append(name)
            }
            remainder = remainder[remainder.index(after: close)...]
        }
        return names
    }

    public static func importDocument(_ data: Data) throws(CoreError) -> ImportedCollection {
        let root = try StructuredDocument.parse(data)
        guard case .object = root else {
            throw .invalidDocument(path: "$", reason: "Expected an object at the top level")
        }
        if root["swagger"] != nil {
            throw .unsupportedDocument(
                reason: "Swagger 2.0 files aren't supported. Convert the file to OpenAPI 3 and try again.")
        }
        guard let version = root["openapi"]?.stringValue ?? root["openapi"].flatMap(numberText),
            version.hasPrefix("3.0") || version.hasPrefix("3.1")
        else {
            throw .unsupportedDocument(reason: "Only OpenAPI 3.0 and 3.1 documents are supported.")
        }
        var context = Context(root: root)
        return try context.build()
    }

    private static func numberText(_ value: JSONValue) -> String? {
        if case .number(let text) = value { return text }
        return nil
    }

    private struct Context {
        let root: JSONValue
        var collection: ImportedCollection
        var sequence = 0

        init(root: JSONValue) {
            self.root = root
            let title = root["info"]?["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            collection = ImportedCollection(name: title.isEmpty ? "Imported API" : title)
        }

        mutating func build() throws(CoreError) -> ImportedCollection {
            configureServers()
            let globalSecurity = root["security"]
            collection.settings.auth = auth(forSecurity: globalSecurity, path: "security") ?? .none
            guard let paths = root["paths"]?.objectValue else {
                collection.notice("The document has no paths.")
                return collection
            }
            for pathMember in paths {
                let pathItem = try resolve(pathMember.value, path: "paths.\(pathMember.key)")
                let sharedParameters = pathItem["parameters"]?.arrayValue ?? []
                for method in methods {
                    guard let operationValue = pathItem[method] else { continue }
                    let operation = try resolve(operationValue, path: "paths.\(pathMember.key).\(method)")
                    try addOperation(
                        operation, method: method, path: pathMember.key, sharedParameters: sharedParameters,
                        globalSecurity: globalSecurity)
                }
            }
            if collection.items.isEmpty { collection.notice("The document has no operations.") }
            return collection
        }

        // MARK: Servers

        mutating func configureServers() {
            let servers = root["servers"]?.arrayValue ?? []
            var urls: [(name: String, url: String)] = []
            for (offset, server) in servers.enumerated() {
                guard var url = server["url"]?.stringValue else { continue }
                for variable in server["variables"]?.objectValue ?? [] {
                    let value = variable.value["default"]?.stringValue ?? variable.value["enum"]?[0]?.stringValue ?? ""
                    url = url.replacingOccurrences(of: "{\(variable.key)}", with: value)
                }
                if url.hasSuffix("/") { url.removeLast() }
                let description = server["description"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
                urls.append((description.isEmpty ? "Server \(offset + 1)" : description, url))
            }
            if urls.isEmpty {
                urls = [("Local", "http://localhost")]
                collection.notice("The document has no servers; baseUrl is set to http://localhost.")
            }
            if let first = urls.first, first.url.hasPrefix("/") {
                collection.notice("The server URL “\(first.url)” is relative; add the host to baseUrl.")
            }
            collection.settings.variables = [KeyValue(name: "baseUrl", value: urls[0].url)]
            collection.environments = urls.map { Environment(name: $0.name, variables: [.plain("baseUrl", $0.url)]) }
        }

        // MARK: Operations

        mutating func addOperation(
            _ operation: JSONValue, method: String, path: String, sharedParameters: [JSONValue],
            globalSecurity: JSONValue?
        ) throws(CoreError) {
            guard let httpMethod = HTTPMethod(rawValue: method) else { return }
            let location = "paths.\(path).\(method)"
            let summary = operation["summary"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let operationID = operation["operationId"]?.stringValue ?? ""
            let name =
                !summary.isEmpty ? summary : (!operationID.isEmpty ? operationID : "\(httpMethod.rawValue) \(path)")
            sequence += 1
            var request = RequestItem(name: String(name.prefix(200)), method: httpMethod, sortOrder: sequence)
            request.docs = operation["description"]?.stringValue ?? ""

            var brunoPath = path
            var parameters: [String: JSONValue] = [:]
            var order: [String] = []
            for (offset, raw) in (sharedParameters + (operation["parameters"]?.arrayValue ?? [])).enumerated() {
                let parameter = try resolve(raw, path: "\(location).parameters[\(offset)]")
                guard let paramName = parameter["name"]?.stringValue, let location = parameter["in"]?.stringValue else {
                    continue
                }
                let key = "\(location):\(paramName)"
                if parameters[key] == nil { order.append(key) }
                parameters[key] = parameter
            }
            for key in order {
                guard let parameter = parameters[key], let paramName = parameter["name"]?.stringValue else { continue }
                let required = parameter["required"]?.boolValue ?? false
                let value = try exampleText(forParameter: parameter, path: "\(location).parameters.\(paramName)")
                switch parameter["in"]?.stringValue {
                case "path":
                    brunoPath = brunoPath.replacingOccurrences(of: "{\(paramName)}", with: ":\(paramName)")
                    request.pathParams.append(KeyValue(name: paramName, value: value))
                case "query":
                    request.queryParams.append(KeyValue(name: paramName, value: value, isEnabled: required))
                case "header":
                    request.headers.append(KeyValue(name: paramName, value: value, isEnabled: required))
                case "cookie":
                    collection.notice(
                        "Cookie parameters were skipped; set them with a Cookie header or the cookie jar.")
                default:
                    break
                }
            }
            // Templated segments the spec doesn't declare (common in hand-written specs) still become path
            // parameters, so `{id}` is never sent literally.
            for name in OpenAPIImporter.undeclaredTemplates(in: brunoPath)
            where !request.pathParams.contains(where: { $0.name == name }) {
                brunoPath = brunoPath.replacingOccurrences(of: "{\(name)}", with: ":\(name)")
                request.pathParams.append(KeyValue(name: name, value: ""))
            }
            request.url = QueryParameters.url("{{baseUrl}}\(brunoPath)", replacingQueryWith: request.queryParams)

            if let requestBody = operation["requestBody"] {
                request.body = try body(from: try resolve(requestBody, path: "\(location).requestBody"), path: location)
            }
            let security = operation["security"]
            if security != nil, let auth = auth(forSecurity: security, path: "\(location).security") {
                request.auth = auth == collection.settings.auth ? .inherit : auth
            } else {
                request.auth = .inherit
            }

            let tag = operation["tags"]?[0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let folder = tag.flatMap { $0.isEmpty ? nil : sanitizedFolderName($0) }
            if let folder { collection.ensureFolder(folder) }
            collection.items.append(ImportedCollection.Item(folderPath: folder, request: request))
        }

        func sanitizedFolderName(_ name: String) -> String {
            String(name.map { "/\\:".contains($0) ? "-" : $0 }.prefix(100))
        }

        // MARK: Bodies

        mutating func body(from requestBody: JSONValue, path: String) throws(CoreError) -> RequestBody {
            guard let content = requestBody["content"]?.objectValue, !content.isEmpty else { return .none }
            func media(_ predicate: (String) -> Bool) -> (String, JSONValue)? {
                content.first(where: { predicate($0.key.lowercased()) }).map { ($0.key, $0.value) }
            }
            if let (type, media) = media({ $0 == "application/json" || $0.hasSuffix("+json") || $0 == "*/*" }) {
                let example = try exampleValue(media: media, path: "\(path).requestBody.\(type)")
                return .json(example.map { JSONSerializer.string(from: $0) } ?? "{}")
            }
            if let (type, media) = media({ $0 == "application/x-www-form-urlencoded" }) {
                return .formURLEncoded(try formRows(media: media, path: "\(path).requestBody.\(type)"))
            }
            if let (type, media) = media({ $0 == "multipart/form-data" }) {
                let schema = try media["schema"].map { value throws(CoreError) in
                    try resolve(value, path: "\(path).schema")
                }
                var fields: [MultipartField] = []
                for property in try properties(of: schema, path: "\(path).requestBody.\(type)") {
                    let resolved = try resolve(property.value, path: "\(path).\(property.key)")
                    if resolved["format"]?.stringValue == "binary" || resolved["type"]?.stringValue == "file" {
                        fields.append(MultipartField(name: property.key, content: .files([])))
                    } else {
                        let sample = try synthesize(resolved, depth: 0, stack: [], path: "\(path).\(property.key)")
                        fields.append(MultipartField(name: property.key, content: .text(scalarText(sample))))
                    }
                }
                return .multipart(fields)
            }
            if let (type, media) = media({ $0.hasPrefix("text/") }) {
                let example = try exampleValue(media: media, path: "\(path).requestBody.\(type)")
                return .text(example.map(scalarText) ?? "")
            }
            if let (type, media) = media({ $0.hasSuffix("/xml") || $0.hasSuffix("+xml") }) {
                let example = try exampleValue(media: media, path: "\(path).requestBody.\(type)")
                if case .string(let xml) = example { return .xml(xml) }
                return .xml("")
            }
            collection.notice("Request bodies of type \(content[0].key) were skipped.")
            return .none
        }

        mutating func formRows(media: JSONValue, path: String) throws(CoreError) -> [KeyValue] {
            let schema = try media["schema"].map { value throws(CoreError) in try resolve(value, path: "\(path).schema")
            }
            let example = media["example"]
            var rows: [KeyValue] = []
            for property in try properties(of: schema, path: path) {
                let value: JSONValue
                if let exampleValue = example?[property.key] {
                    value = exampleValue
                } else {
                    value = try synthesize(
                        try resolve(property.value, path: "\(path).\(property.key)"), depth: 0, stack: [], path: path)
                }
                rows.append(KeyValue(name: property.key, value: scalarText(value)))
            }
            return rows
        }

        func properties(of schema: JSONValue?, path: String) throws(CoreError) -> [JSONMember] {
            guard let schema else { return [] }
            var result = schema["properties"]?.objectValue ?? []
            for part in schema["allOf"]?.arrayValue ?? [] {
                for member in try properties(of: try resolve(part, path: path), path: path)
                where !result.contains(where: { $0.key == member.key }) {
                    result.append(member)
                }
            }
            return result
        }

        // MARK: Examples

        mutating func exampleValue(media: JSONValue, path: String) throws(CoreError) -> JSONValue? {
            if let example = media["example"] { return example }
            if let first = media["examples"]?.objectValue?.first {
                let resolved = try resolve(first.value, path: "\(path).examples.\(first.key)")
                if let value = resolved["value"] { return value }
            }
            guard let schema = media["schema"] else { return nil }
            // Pass the schema unresolved so its own `$ref` is tracked for cycle detection.
            return try synthesize(schema, depth: 0, stack: [], path: path)
        }

        mutating func exampleText(forParameter parameter: JSONValue, path: String) throws(CoreError) -> String {
            if let example = parameter["example"] { return scalarText(example) }
            if let first = parameter["examples"]?.objectValue?.first,
                let value = try resolve(first.value, path: path)["value"]
            {
                return scalarText(value)
            }
            guard let schema = parameter["schema"] else { return "" }
            let resolved = try resolve(schema, path: "\(path).schema")
            if let example = resolved["example"] ?? resolved["default"] ?? resolved["enum"]?[0] {
                return scalarText(example)
            }
            return ""
        }

        func scalarText(_ value: JSONValue) -> String {
            switch value {
            case .null: ""
            case .bool(let flag): flag ? "true" : "false"
            case .number(let text): text
            case .string(let text): text
            case .array, .object: JSONSerializer.string(from: value, style: .compact)
            }
        }

        /// Builds an example value from a schema. `stack` holds `$ref`s being expanded (cycle protection).
        mutating func synthesize(_ schema: JSONValue, depth: Int, stack: Set<String>, path: String) throws(CoreError)
            -> JSONValue
        {
            if let reference = schema["$ref"]?.stringValue {
                guard !stack.contains(reference) else { return .null }
                guard depth < maximumSchemaDepth else { return .null }
                return try synthesize(
                    try resolve(schema, path: path), depth: depth + 1, stack: stack.union([reference]), path: path)
            }
            if let example = schema["example"] { return example }
            if let example = schema["examples"]?[0] { return example }
            if let value = schema["default"] { return value }
            if let value = schema["const"] { return value }
            if let value = schema["enum"]?[0] { return value }
            guard depth < maximumSchemaDepth else { return .null }
            if let parts = schema["allOf"]?.arrayValue {
                var members: [JSONMember] = []
                for part in parts {
                    if case .object(let partMembers) = try synthesize(part, depth: depth + 1, stack: stack, path: path)
                    {
                        for member in partMembers {
                            if let index = members.firstIndex(where: { $0.key == member.key }) {
                                members[index] = member
                            } else {
                                members.append(member)
                            }
                        }
                    }
                }
                return .object(members)
            }
            if let first = schema["oneOf"]?[0] ?? schema["anyOf"]?[0] {
                return try synthesize(first, depth: depth + 1, stack: stack, path: path)
            }
            var type = schema["type"]?.stringValue
            if type == nil, case .array(let types) = schema["type"] {
                type = types.compactMap(\.stringValue).first { $0 != "null" }
            }
            switch type ?? (schema["properties"] != nil ? "object" : (schema["items"] != nil ? "array" : nil)) {
            case "object":
                var members: [JSONMember] = []
                for property in schema["properties"]?.objectValue ?? [] {
                    members.append(
                        JSONMember(
                            property.key, try synthesize(property.value, depth: depth + 1, stack: stack, path: path)))
                }
                return .object(members)
            case "array":
                guard let items = schema["items"] else { return .array([]) }
                return .array([try synthesize(items, depth: depth + 1, stack: stack, path: path)])
            case "integer": return .number("0")
            case "number": return .number("0")
            case "boolean": return .bool(false)
            case "string": return .string(sampleString(format: schema["format"]?.stringValue))
            default: return .null
            }
        }

        func sampleString(format: String?) -> String {
            switch format {
            case "date-time": "2024-01-01T00:00:00Z"
            case "date": "2024-01-01"
            case "time": "12:00:00"
            case "email": "user@example.com"
            case "uuid": "00000000-0000-0000-0000-000000000000"
            case "uri", "url": "https://example.com"
            case "hostname": "example.com"
            case "ipv4": "192.0.2.1"
            case "ipv6": "2001:db8::1"
            case "password": ""
            case "byte": "U3dhZ2dlciByb2Nrcw=="
            default: "string"
            }
        }

        // MARK: Security

        mutating func auth(forSecurity security: JSONValue?, path: String) -> RequestAuth? {
            guard let requirements = security?.arrayValue else { return nil }
            guard let requirement = requirements.first(where: { !($0.objectValue?.isEmpty ?? true) }) else {
                return RequestAuth.none
            }
            guard let schemeName = requirement.objectValue?.first?.key else { return RequestAuth.none }
            guard let schemeValue = root["components"]?["securitySchemes"]?[schemeName],
                let scheme = try? resolve(schemeValue, path: "components.securitySchemes.\(schemeName)")
            else {
                collection.notice("The security scheme “\(schemeName)” is not defined.")
                return nil
            }
            let scopes =
                requirement.objectValue?.first?.value.arrayValue?.compactMap(\.stringValue).joined(separator: " ") ?? ""
            switch (scheme["type"]?.stringValue, scheme["scheme"]?.stringValue?.lowercased()) {
            case ("http", "bearer"):
                return .bearer(token: "{{bearerToken}}")
            case ("http", "basic"):
                return .basic(username: "{{username}}", password: "{{password}}")
            case ("apiKey", _):
                let name = scheme["name"]?.stringValue ?? "api_key"
                switch scheme["in"]?.stringValue {
                case "query": return .apiKey(APIKeyAuth(key: name, value: "{{apiKey}}", placement: .query))
                case "cookie":
                    collection.notice("Cookie API keys aren't supported as auth; add a Cookie header instead.")
                    return RequestAuth.none
                default: return .apiKey(APIKeyAuth(key: name, value: "{{apiKey}}", placement: .header))
                }
            case ("oauth2", _):
                let flows = scheme["flows"]
                if let flow = flows?["authorizationCode"] {
                    return .oauth2(
                        OAuth2Config(
                            grantType: .authorizationCode, accessTokenURL: flow["tokenUrl"]?.stringValue ?? "",
                            authorizationURL: flow["authorizationUrl"]?.stringValue ?? "",
                            refreshTokenURL: flow["refreshUrl"]?.stringValue ?? "", clientID: "{{clientId}}",
                            clientSecret: "{{clientSecret}}", scope: scopes))
                }
                if let flow = flows?["clientCredentials"] {
                    return .oauth2(
                        OAuth2Config(
                            grantType: .clientCredentials, accessTokenURL: flow["tokenUrl"]?.stringValue ?? "",
                            refreshTokenURL: flow["refreshUrl"]?.stringValue ?? "", clientID: "{{clientId}}",
                            clientSecret: "{{clientSecret}}", scope: scopes))
                }
                collection.notice("OAuth 2.0 flows other than authorization code and client credentials were skipped.")
                return nil
            default:
                collection.notice("The security scheme “\(schemeName)” isn't supported; set auth manually.")
                return nil
            }
        }

        // MARK: References

        /// Follows `$ref` chains to local components. External references throw; cycles throw.
        func resolve(_ value: JSONValue, path: String) throws(CoreError) -> JSONValue {
            var current = value
            var seen: Set<String> = []
            while let reference = current["$ref"]?.stringValue {
                guard reference.hasPrefix("#/") else {
                    throw .invalidDocument(
                        path: path, reason: "External reference “\(reference.prefix(80))” isn't supported")
                }
                guard seen.insert(reference).inserted, seen.count <= 32 else {
                    throw .invalidDocument(path: path, reason: "Circular reference “\(reference.prefix(80))”")
                }
                var target: JSONValue? = root
                for token in reference.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
                    let key = String(token).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(
                        of: "~0", with: "~")
                    let decoded = key.removingPercentEncoding ?? key
                    if case .array = target, let index = Int(decoded) {
                        target = target?[index]
                    } else {
                        target = target?[decoded]
                    }
                }
                guard let target else {
                    throw .invalidDocument(path: path, reason: "Reference “\(reference.prefix(80))” points to nothing")
                }
                current = target
            }
            return current
        }
    }
}
