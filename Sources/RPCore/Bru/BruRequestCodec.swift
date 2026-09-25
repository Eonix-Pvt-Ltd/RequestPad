import Foundation

/// Reads and writes Bruno request files (`*.bru`) as ``RequestItem`` (P01.2, P01.3).
public enum BruRequestCodec {
    typealias Block = BruDocument.Block

    static let methodBlocks: Set<String> = [
        "get", "post", "put", "delete", "patch", "options", "head", "connect", "trace",
    ]

    public static func decode(_ text: String) throws(CoreError) -> (request: RequestItem, document: BruDocument) {
        let document = try BruDocument.parse(text)
        return (try decode(document), document)
    }

    public static func decode(_ document: BruDocument) throws(CoreError) -> RequestItem {
        let meta = try BruCodecSupport.pairs(of: document.firstBlock(named: "meta"))
        var request = RequestItem(name: BruCodecSupport.value("name", in: meta) ?? "")
        request.kind = RequestKind(rawValue: BruCodecSupport.value("type", in: meta) ?? "http") ?? .http
        request.sortOrder = Int(BruCodecSupport.value("seq", in: meta) ?? "") ?? 1
        if case .list(let tags) = meta.last(where: { $0.key == "tags" })?.value { request.tags = tags }

        guard let methodBlock = document.blocks.first(where: { methodBlocks.contains($0.name) || $0.name == "http" })
        else {
            throw .bruSyntax(
                position: TextPosition(line: 1, column: 1), reason: "The request has no method block (e.g. “get {”)")
        }
        let methodPairs = try BruDictionary.parse(methodBlock)
        let methodName =
            methodBlock.name == "http" ? BruCodecSupport.value("method", in: methodPairs) ?? "" : methodBlock.name
        guard let method = HTTPMethod(rawValue: methodName) ?? HTTPMethod(lenientBruValue: methodName) else {
            throw .bruSyntax(
                position: TextPosition(line: methodBlock.line, column: 1),
                reason: "“\(methodName)” isn't a valid HTTP method")
        }
        request.method = method
        request.url = BruCodecSupport.value("url", in: methodPairs) ?? ""

        request.queryParams = try BruCodecSupport.rows(
            from: document.firstBlock(named: "params:query") ?? document.firstBlock(named: "query"))
        request.pathParams = try BruCodecSupport.rows(from: document.firstBlock(named: "params:path"))
        request.headers = try BruCodecSupport.rows(from: document.firstBlock(named: "headers"))
        request.body = try decodeBody(
            mode: BruCodecSupport.value("body", in: methodPairs) ?? "none", document: document)
        request.auth = try BruCodecSupport.decodeAuth(
            mode: BruCodecSupport.value("auth", in: methodPairs) ?? "none", document: document)
        request.variables = try BruCodecSupport.rows(from: document.firstBlock(named: "vars:pre-request"))
        request.extractors = try BruCodecSupport.pairs(of: document.firstBlock(named: "vars:post-response")).map {
            pair in
            Extractor(
                variableName: pair.key, source: BruExpression.parse(pair.text), rawExpression: pair.text,
                isEnabled: !pair.isDisabled, annotations: pair.annotations)
        }
        request.assertions = try BruCodecSupport.pairs(of: document.firstBlock(named: "assert")).map { pair in
            Assertion.fromBru(
                key: pair.key, value: pair.text, isEnabled: !pair.isDisabled, annotations: pair.annotations)
        }
        let settings = try BruCodecSupport.pairs(of: document.firstBlock(named: "settings"))
        request.settings = RequestSettings(
            followRedirects: (BruCodecSupport.value("followRedirects", in: settings) ?? "true") != "false",
            maximumRedirects: Int(BruCodecSupport.value("maxRedirects", in: settings) ?? "")
                ?? RequestDefaults.maximumRedirects,
            timeoutMilliseconds: Int(BruCodecSupport.value("timeout", in: settings) ?? ""))
        request.docs = document.firstBlock(named: "docs").map(BruText.text(of:)) ?? ""
        request.hasUnsupportedScripts = document.blocks.contains { block in
            (block.name.hasPrefix("script:") || block.name == "tests")
                && !BruText.text(of: block).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return request
    }

    /// Serializes `request`. When `original` is the document the request was read from, untouched and unknown
    /// blocks are reproduced exactly.
    public static func encode(_ request: RequestItem, preserving original: BruDocument? = nil) throws(CoreError)
        -> String
    {
        var desired: [Block] = []
        let originalMeta = try BruCodecSupport.pairs(of: original?.firstBlock(named: "meta"))
        func metaValue(_ key: String, _ value: String, default defaultValue: String) -> (key: String, value: String?) {
            // Bruno reads a missing `type` as http and a missing `seq` as 1; don't add them when unchanged.
            (
                key,
                value == defaultValue && original != nil && BruCodecSupport.value(key, in: originalMeta) == nil
                    ? nil : value
            )
        }
        var metaPairs = BruCodecSupport.merge(
            originalMeta,
            [
                ("name", request.name), metaValue("type", request.kind.rawValue, default: "http"),
                metaValue("seq", String(request.sortOrder), default: "1"),
            ])
        let originalTags: [String] = {
            if case .list(let tags) = originalMeta.last(where: { $0.key == "tags" })?.value { return tags }
            return []
        }()
        if originalTags != request.tags {
            metaPairs.removeAll { $0.key == "tags" }
            if !request.tags.isEmpty { metaPairs.append(BruPair(key: "tags", value: .list(request.tags))) }
        }
        desired.append(BruCodecSupport.dictionaryBlock("meta", metaPairs))

        let methodName = request.method.rawValue.lowercased()
        let isStandardBlock = methodBlocks.contains(methodName)
        let blockName = isStandardBlock ? methodName : "http"
        let originalMethodBlock = original?.blocks.first(where: { methodBlocks.contains($0.name) || $0.name == "http" })
        // Keys RequestPad doesn't model are kept even when the method (and so the block name) changes.
        var methodPairs = try BruCodecSupport.pairs(of: originalMethodBlock)
        let originalBodyMode = BruCodecSupport.value("body", in: methodPairs)
        let originalAuthMode = BruCodecSupport.value("auth", in: methodPairs)
        methodPairs = BruCodecSupport.merge(
            methodPairs,
            [
                ("method", isStandardBlock ? nil : request.method.rawValue), ("url", request.url),
                ("body", request.body == .none && originalBodyMode == nil ? nil : request.body.bruMode),
                ("auth", request.auth == .none && originalAuthMode == nil ? nil : request.auth.bruMode),
            ])
        if !isStandardBlock, let index = methodPairs.firstIndex(where: { $0.key == "method" }), index != 0 {
            methodPairs.insert(methodPairs.remove(at: index), at: 0)
        }
        desired.append(BruCodecSupport.dictionaryBlock(blockName, methodPairs))

        if !request.queryParams.isEmpty {
            desired.append(
                BruCodecSupport.dictionaryBlock("params:query", BruCodecSupport.pairs(from: request.queryParams)))
        }
        if !request.pathParams.isEmpty {
            desired.append(
                BruCodecSupport.dictionaryBlock("params:path", BruCodecSupport.pairs(from: request.pathParams)))
        }
        if !request.headers.isEmpty {
            desired.append(BruCodecSupport.dictionaryBlock("headers", BruCodecSupport.pairs(from: request.headers)))
        }
        if let authBlock = try BruCodecSupport.authBlock(request.auth, original: original) { desired.append(authBlock) }
        desired.append(contentsOf: bodyBlocks(request.body))
        if !request.variables.isEmpty {
            desired.append(
                BruCodecSupport.dictionaryBlock("vars:pre-request", BruCodecSupport.pairs(from: request.variables)))
        }
        if !request.extractors.isEmpty {
            desired.append(
                BruCodecSupport.dictionaryBlock(
                    "vars:post-response",
                    request.extractors.map { extractor in
                        let expression: String
                        if let source = extractor.source, BruExpression.parse(extractor.rawExpression) != source {
                            expression = BruExpression.format(source)
                        } else {
                            expression = extractor.rawExpression
                        }
                        return BruPair(
                            key: extractor.variableName, text: expression, isDisabled: !extractor.isEnabled,
                            annotations: extractor.annotations)
                    }))
        }
        if !request.assertions.isEmpty {
            desired.append(
                BruCodecSupport.dictionaryBlock(
                    "assert",
                    request.assertions.map {
                        BruPair(
                            key: $0.rawKey, text: $0.rawValue, isDisabled: !$0.isEnabled, annotations: $0.annotations)
                    }))
        }
        if let settings = try settingsBlock(request.settings, original: original) { desired.append(settings) }
        if !request.docs.isEmpty { desired.append(BruCodecSupport.textBlock("docs", request.docs)) }

        var managed: Set<String> = methodBlocks.union([
            "http", "meta", "params:query", "query", "params:path", "headers", "vars:pre-request", "vars:post-response",
            "assert", "settings", "docs",
        ])
        if BruCodecSupport.authModesWithBlocks.contains(request.auth.bruMode) {
            managed.insert("auth:\(request.auth.bruMode)")
        }
        managed.formUnion(activeBodyBlockNames(request.body))
        return try BruCodecSupport.assemble(desired: desired, managed: managed, original: original)
    }

    // MARK: Body

    private static func decodeBody(mode: String, document: BruDocument) throws(CoreError) -> RequestBody {
        switch mode {
        case "none", "": return .none
        case "json":
            return .json(
                (document.firstBlock(named: "body:json") ?? document.firstBlock(named: "body")).map(BruText.text(of:))
                    ?? "")
        case "text": return .text(document.firstBlock(named: "body:text").map(BruText.text(of:)) ?? "")
        case "xml": return .xml(document.firstBlock(named: "body:xml").map(BruText.text(of:)) ?? "")
        case "formUrlEncoded":
            return .formURLEncoded(try BruCodecSupport.rows(from: document.firstBlock(named: "body:form-urlencoded")))
        case "multipartForm":
            return .multipart(
                try BruCodecSupport.pairs(of: document.firstBlock(named: "body:multipart-form")).map(
                    multipartField(from:)))
        case "graphql":
            return .graphQL(
                GraphQLBody(
                    query: document.firstBlock(named: "body:graphql").map(BruText.text(of:)) ?? "",
                    variables: document.firstBlock(named: "body:graphql:vars").map(BruText.text(of:)) ?? ""))
        default: return .unsupported(mode: mode)
        }
    }

    private static func activeBodyBlockNames(_ body: RequestBody) -> Set<String> {
        switch body {
        case .none, .unsupported: []
        case .json: ["body:json", "body"]
        case .text: ["body:text"]
        case .xml: ["body:xml"]
        case .formURLEncoded: ["body:form-urlencoded"]
        case .multipart: ["body:multipart-form"]
        case .graphQL: ["body:graphql", "body:graphql:vars"]
        }
    }

    private static func bodyBlocks(_ body: RequestBody) -> [Block] {
        switch body {
        case .none, .unsupported: return []
        case .json(let text): return text.isEmpty ? [] : [BruCodecSupport.textBlock("body:json", text)]
        case .text(let text): return text.isEmpty ? [] : [BruCodecSupport.textBlock("body:text", text)]
        case .xml(let text): return text.isEmpty ? [] : [BruCodecSupport.textBlock("body:xml", text)]
        case .formURLEncoded(let rows):
            return rows.isEmpty
                ? [] : [BruCodecSupport.dictionaryBlock("body:form-urlencoded", BruCodecSupport.pairs(from: rows))]
        case .multipart(let fields):
            return fields.isEmpty
                ? [] : [BruCodecSupport.dictionaryBlock("body:multipart-form", fields.map(pair(from:)))]
        case .graphQL(let graphQL):
            var blocks: [Block] = []
            if !graphQL.query.isEmpty { blocks.append(BruCodecSupport.textBlock("body:graphql", graphQL.query)) }
            if !graphQL.variables.isEmpty {
                blocks.append(BruCodecSupport.textBlock("body:graphql:vars", graphQL.variables))
            }
            return blocks
        }
    }

    private static func multipartField(from pair: BruPair) -> MultipartField {
        var text: String
        var contentType: String?
        switch pair.value {
        case .multiline(let content, let suffix):
            text = content
            contentType = contentTypeAnnotation(suffix)
        default:
            text = pair.text
            if let range = text.range(of: #"\s*@contentType\(([^)]*)\)\s*$"#, options: .regularExpression) {
                contentType = contentTypeAnnotation(String(text[range]).trimmingCharacters(in: .whitespaces))
                text = String(text[..<range.lowerBound])
            }
        }
        let content: MultipartField.Content
        if text.hasPrefix("@file("), text.hasSuffix(")") {
            let inner = text.dropFirst("@file(".count).dropLast()
            content = .files(inner.split(separator: "|").map(String.init).filter { !$0.isEmpty })
        } else {
            content = .text(text)
        }
        return MultipartField(
            name: pair.key, content: content, contentType: contentType, isEnabled: !pair.isDisabled,
            annotations: pair.annotations)
    }

    private static func contentTypeAnnotation(_ text: String) -> String? {
        guard text.hasPrefix("@contentType("), text.hasSuffix(")") else { return nil }
        let value = String(text.dropFirst("@contentType(".count).dropLast())
        return value.isEmpty ? nil : value
    }

    private static func pair(from field: MultipartField) -> BruPair {
        let suffix = field.contentType.map { "@contentType(\($0))" } ?? ""
        let value: BruPair.Value
        switch field.content {
        case .files(let references):
            let text = "@file(\(references.joined(separator: "|")))"
            value = .single(suffix.isEmpty ? text : "\(text) \(suffix)")
        case .text(let text):
            if text.contains("\n") {
                value = .multiline(text, suffix: suffix)
            } else {
                value = .single(suffix.isEmpty ? text : "\(text) \(suffix)")
            }
        }
        return BruPair(key: field.name, value: value, isDisabled: !field.isEnabled, annotations: field.annotations)
    }

    // MARK: Settings

    private static func settingsBlock(_ settings: RequestSettings, original: BruDocument?) throws(CoreError) -> Block? {
        let originalPairs = try BruCodecSupport.pairs(of: original?.firstBlock(named: "settings"))
        func include(_ key: String, _ value: String, isDefault: Bool) -> (key: String, value: String?) {
            (key, isDefault && BruCodecSupport.value(key, in: originalPairs) == nil ? nil : value)
        }
        let merged = BruCodecSupport.merge(
            originalPairs,
            [
                include(
                    "followRedirects", settings.followRedirects ? "true" : "false", isDefault: settings.followRedirects),
                include(
                    "maxRedirects", String(settings.maximumRedirects),
                    isDefault: settings.maximumRedirects == RequestDefaults.maximumRedirects),
                include(
                    "timeout", String(settings.timeoutMilliseconds ?? 0), isDefault: settings.timeoutMilliseconds == nil
                ),
            ])
        return merged.isEmpty ? nil : BruCodecSupport.dictionaryBlock("settings", merged)
    }
}
