import Foundation

/// Shared building blocks for the `.bru` request, folder and collection codecs.
enum BruCodecSupport {
    typealias Block = BruDocument.Block

    // MARK: Rows

    static func rows(from block: Block?) throws(CoreError) -> [KeyValue] {
        guard let block else { return [] }
        return try BruDictionary.parse(block).map { pair in
            KeyValue(name: pair.key, value: pair.text, isEnabled: !pair.isDisabled, annotations: pair.annotations)
        }
    }

    static func pairs(from rows: [KeyValue]) -> [BruPair] {
        rows.map { BruPair(key: $0.name, text: $0.value, isDisabled: !$0.isEnabled, annotations: $0.annotations) }
    }

    static func dictionaryBlock(_ name: String, _ pairs: [BruPair]) -> Block {
        .generated(name: name, lines: BruDictionary.lines(for: pairs))
    }

    static func textBlock(_ name: String, _ text: String) -> Block {
        .generated(name: name, lines: BruText.lines(for: text))
    }

    // MARK: Merging dictionaries by key

    /// Updates `original` pairs with `desired` values, keeping unknown keys, order and annotations. Keys listed in
    /// `desired` with a `nil` value are removed. New keys are appended in `desired` order.
    static func merge(_ original: [BruPair], _ desired: [(key: String, value: String?)]) -> [BruPair] {
        var result = original
        for (key, value) in desired {
            if let index = result.firstIndex(where: { $0.key == key && !$0.isDisabled }) {
                if let value {
                    if result[index].text != value {
                        result[index].value = BruPair(key: key, text: value).value
                    }
                } else {
                    result.remove(at: index)
                }
            } else if let value {
                result.append(BruPair(key: key, text: value))
            }
        }
        return result
    }

    static func value(_ key: String, in pairs: [BruPair]) -> String? {
        pairs.last(where: { $0.key == key && !$0.isDisabled })?.text
    }

    // MARK: Auth

    static let authModesWithBlocks: Set<String> = ["bearer", "basic", "apikey", "oauth2"]

    static func decodeAuth(mode: String, document: BruDocument) throws(CoreError) -> RequestAuth {
        switch mode {
        case "", "none": return .none
        case "inherit": return .inherit
        case "bearer":
            let pairs = try pairs(of: document.firstBlock(named: "auth:bearer"))
            return .bearer(token: value("token", in: pairs) ?? "")
        case "basic":
            let pairs = try pairs(of: document.firstBlock(named: "auth:basic"))
            return .basic(username: value("username", in: pairs) ?? "", password: value("password", in: pairs) ?? "")
        case "apikey":
            let pairs = try pairs(of: document.firstBlock(named: "auth:apikey"))
            let placement = APIKeyAuth.Placement(rawValue: value("placement", in: pairs) ?? "") ?? .header
            return .apiKey(
                APIKeyAuth(
                    key: value("key", in: pairs) ?? "", value: value("value", in: pairs) ?? "", placement: placement))
        case "oauth2":
            let pairs = try pairs(of: document.firstBlock(named: "auth:oauth2"))
            guard let grant = OAuth2Config.GrantType(rawValue: value("grant_type", in: pairs) ?? "") else {
                return .unsupported(mode: mode)
            }
            var config = OAuth2Config(grantType: grant)
            config.accessTokenURL = value("access_token_url", in: pairs) ?? ""
            config.authorizationURL = value("authorization_url", in: pairs) ?? ""
            config.callbackURL = value("callback_url", in: pairs) ?? ""
            config.refreshTokenURL = value("refresh_token_url", in: pairs) ?? ""
            config.clientID = value("client_id", in: pairs) ?? ""
            config.clientSecret = value("client_secret", in: pairs) ?? ""
            config.scope = value("scope", in: pairs) ?? ""
            config.usePKCE = (value("pkce", in: pairs) ?? "false") == "true"
            config.credentialsPlacement =
                OAuth2Config.CredentialsPlacement(rawValue: value("credentials_placement", in: pairs) ?? "")
                ?? .basicAuthHeader
            config.tokenPlacement =
                OAuth2Config.TokenPlacement(rawValue: value("token_placement", in: pairs) ?? "") ?? .header
            config.tokenHeaderPrefix = value("token_header_prefix", in: pairs) ?? "Bearer"
            config.tokenQueryKey = value("token_query_key", in: pairs) ?? "access_token"
            config.autoRefreshToken = (value("auto_refresh_token", in: pairs) ?? "false") == "true"
            return .oauth2(config)
        default:
            return .unsupported(mode: mode)
        }
    }

    /// The `auth:<mode>` block for supported modes. When the original file has the same mode, only fields whose
    /// value changed are rewritten, so values RequestPad does not model (e.g. unknown enum spellings) survive.
    static func authBlock(_ auth: RequestAuth, original: BruDocument?) throws(CoreError) -> Block? {
        guard authModesWithBlocks.contains(auth.bruMode), auth.bruMode != "inherit" else { return nil }
        let name = "auth:\(auth.bruMode)"
        let originalBlock = original?.firstBlock(named: name)
        let originalPairs = try pairs(of: originalBlock)
        let previous: RequestAuth? =
            originalBlock == nil
            ? nil
            : try original.map { document throws(CoreError) in
                try decodeAuth(mode: auth.bruMode, document: document)
            }
        let fields = authFields(auth, isNew: originalPairs.isEmpty)
        let previousFields = previous.map { authFields($0, isNew: false) } ?? []
        let changed = fields.filter { field in
            guard let old = previousFields.first(where: { $0.key == field.key }) else { return true }
            return old.value != field.value
        }
        return dictionaryBlock(name, merge(originalPairs, changed.map { ($0.key, $0.value) }))
    }

    private static func authFields(_ auth: RequestAuth, isNew: Bool) -> [(key: String, value: String?)] {
        switch auth {
        case .inherit, .none, .unsupported:
            return []
        case .bearer(let token):
            return [("token", token)]
        case .basic(let username, let password):
            return [("username", username), ("password", password)]
        case .apiKey(let apiKey):
            return [("key", apiKey.key), ("value", apiKey.value), ("placement", apiKey.placement.rawValue)]
        case .oauth2(let config):
            return oauth2Pairs(config, isNew: isNew)
        }
    }

    private static func oauth2Pairs(_ config: OAuth2Config, isNew: Bool) -> [(key: String, value: String?)] {
        var pairs: [(key: String, value: String?)] = [("grant_type", config.grantType.rawValue)]
        if config.grantType == .authorizationCode {
            pairs += [("callback_url", config.callbackURL), ("authorization_url", config.authorizationURL)]
        }
        pairs += [
            ("access_token_url", config.accessTokenURL), ("refresh_token_url", config.refreshTokenURL),
            ("client_id", config.clientID), ("client_secret", config.clientSecret), ("scope", config.scope),
        ]
        if config.grantType == .authorizationCode {
            pairs.append(("pkce", config.usePKCE ? "true" : "false"))
        }
        pairs.append(("credentials_placement", config.credentialsPlacement.rawValue))
        if isNew {
            pairs += [("credentials_id", "credentials"), ("token_source", "access_token")]
        }
        pairs.append(("token_placement", config.tokenPlacement.rawValue))
        switch config.tokenPlacement {
        case .header: pairs.append(("token_header_prefix", config.tokenHeaderPrefix))
        case .url: pairs.append(("token_query_key", config.tokenQueryKey))
        }
        if isNew { pairs.append(("auto_fetch_token", "true")) }
        pairs.append(("auto_refresh_token", config.autoRefreshToken ? "true" : "false"))
        return pairs
    }

    static func pairs(of block: Block?) throws(CoreError) -> [BruPair] {
        guard let block else { return [] }
        return try BruDictionary.parse(block)
    }

    // MARK: Assembling documents

    /// Canonical block order (Bruno's `jsonToBru`), used when inserting new blocks.
    static func rank(of name: String) -> Int {
        switch name {
        case "meta": 0
        case "get", "post", "put", "delete", "patch", "options", "head", "connect", "trace", "http": 1
        case "params:query", "query": 2
        case "params:path": 3
        case "headers": 4
        case "auth": 5
        case _ where name.hasPrefix("auth:"): 6
        case "body:graphql:vars": 8
        case "body": 7
        case _ where name.hasPrefix("body:"): 7
        case "vars:pre-request": 9
        case "vars:post-response": 10
        case "assert": 11
        case _ where name.hasPrefix("script:"): 12
        case "tests": 13
        case "settings": 14
        case "docs": 15
        default: 16
        }
    }

    /// Builds the output text: blocks in `managed` are replaced by `desired` (or removed when absent), unchanged
    /// content keeps its original text, other blocks pass through untouched, new blocks are inserted in canonical
    /// order.
    static func assemble(desired: [Block], managed: Set<String>, original: BruDocument?) throws(CoreError) -> String {
        guard let original else {
            return desired.map(\.source).joined(separator: "\n")
        }
        var pending = desired
        var result: [Block] = []
        var changedStructure = false
        for block in original.blocks {
            guard managed.contains(block.name) else {
                result.append(block)
                continue
            }
            if let index = pending.firstIndex(where: { $0.name == block.name }) {
                var replacement = pending.remove(at: index)
                if try sameContent(block, replacement) {
                    result.append(block)
                } else {
                    replacement.trailing = block.trailing
                    if !block.source.hasSuffix("\n") {
                        replacement.source.removeLast()
                    }
                    result.append(replacement)
                }
            } else {
                changedStructure = true
            }
        }
        for var block in pending {
            changedStructure = true
            let position = result.firstIndex(where: { rank(of: $0.name) > rank(of: block.name) }) ?? result.count
            if position > 0, !result[position - 1].source.hasSuffix("\n") {
                result[position - 1].source += "\n"
            }
            if position > 0, result[position - 1].trailing.isEmpty {
                result[position - 1].trailing = "\n"
            }
            block.trailing = position < result.count ? "\n" : ""
            result.insert(block, at: position)
        }
        if changedStructure, var last = result.popLast() {
            last.trailing = last.trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : last.trailing
            if !last.source.hasSuffix("\n") { last.source += "\n" }
            result.append(last)
        }
        return BruDocument(leading: original.leading, blocks: result).text
    }

    private static func sameContent(_ lhs: Block, _ rhs: Block) throws(CoreError) -> Bool {
        if lhs.lines == rhs.lines { return true }
        if isTextBlock(lhs.name) { return BruText.text(of: lhs) == BruText.text(of: rhs) }
        return try BruDictionary.parse(lhs) == BruDictionary.parse(rhs)
    }

    static func isTextBlock(_ name: String) -> Bool {
        [
            "body", "body:json", "body:text", "body:xml", "body:sparql", "body:graphql", "body:graphql:vars", "docs",
            "tests",
        ]
        .contains(name) || name.hasPrefix("script:")
    }
}
