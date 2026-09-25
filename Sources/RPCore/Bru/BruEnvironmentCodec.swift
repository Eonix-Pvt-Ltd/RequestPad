import Foundation

/// Reads and writes Bruno environment files (`environments/<name>.bru`). Secret variables follow Bruno's
/// convention: names are listed in `vars:secret [ … ]` and values live outside the file — in RequestPad, in the
/// Keychain (P01.5, F04.4). Blocks RequestPad does not use (`color`, `extends`, external secrets) are preserved.
public enum BruEnvironmentCodec {
    /// Decodes an environment. `environmentKey` identifies the environment for Keychain references
    /// (e.g. `"<collection key>/environments/Local.bru"`).
    public static func decode(
        _ text: String, name: String, environmentKey: String
    ) throws(CoreError) -> (environment: Environment, document: BruDocument) {
        let document = try BruDocument.parse(text)
        var variables: [Variable] = []
        for pair in try BruCodecSupport.pairs(of: document.firstBlock(named: "vars")) {
            variables.append(Variable(name: pair.key, value: .plain(pair.text), isEnabled: !pair.isDisabled))
        }
        for block in document.blocks(named: "vars:secret") {
            for item in secretItems(block) {
                variables.append(
                    Variable(
                        name: item.name,
                        value: .secret(.environmentVariable(environmentKey: environmentKey, name: item.name)),
                        isEnabled: item.isEnabled))
            }
        }
        let preserved = document.blocks.filter { $0.name != "vars" && $0.name != "vars:secret" }.map(\.source)
        return (Environment(name: name, variables: variables, preservedBlocks: preserved), document)
    }

    public static func encode(_ environment: Environment, preserving original: BruDocument? = nil) throws(CoreError)
        -> String
    {
        let plain = environment.variables.compactMap { variable -> BruPair? in
            guard case .plain(let value) = variable.value else { return nil }
            return BruPair(key: variable.name, text: value, isDisabled: !variable.isEnabled)
        }
        let secrets = environment.variables.filter(\.value.isSecret)
        var desired: [BruDocument.Block] = [BruCodecSupport.dictionaryBlock("vars", plain)]
        if !secrets.isEmpty {
            let items = secrets.enumerated().map { offset, variable in
                "  " + (variable.isEnabled ? "" : "~") + variable.name + (offset < secrets.count - 1 ? "," : "")
            }
            desired.append(.generated(name: "vars:secret", bracket: .square, lines: items))
        }
        guard let original else {
            let extra = environment.preservedBlocks
            return (desired.map(\.source) + extra).joined(separator: "\n")
        }
        return try assembleEnvironment(desired: desired, original: original)
    }

    private static func assembleEnvironment(desired: [BruDocument.Block], original: BruDocument) throws(CoreError)
        -> String
    {
        var result: [BruDocument.Block] = []
        var pending = desired
        for block in original.blocks {
            guard block.name == "vars" || block.name == "vars:secret" else {
                result.append(block)
                continue
            }
            guard let index = pending.firstIndex(where: { $0.name == block.name }) else { continue }
            var replacement = pending.remove(at: index)
            if block.name == "vars" {
                if try BruDictionary.parse(block) == BruDictionary.parse(replacement) {
                    replacement = block
                }
            } else if secretItems(block) == secretItems(replacement) {
                replacement = block
            }
            replacement.trailing = block.trailing
            result.append(replacement)
        }
        for var block in pending {
            if let last = result.indices.last, result[last].trailing.isEmpty { result[last].trailing = "\n" }
            block.trailing = ""
            result.append(block)
        }
        return BruDocument(leading: original.leading, blocks: result).text
    }

    private struct SecretItem: Hashable {
        var name: String
        var isEnabled: Bool
    }

    private static func secretItems(_ block: BruDocument.Block) -> [SecretItem] {
        block.lines.joined(separator: "\n")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("@") }
            .map { item in
                item.hasPrefix("~")
                    ? SecretItem(name: String(item.dropFirst()), isEnabled: false)
                    : SecretItem(name: item, isEnabled: true)
            }
    }
}

/// Bruno's `bruno.json` collection manifest (P01.2, P01.6).
public struct BrunoManifest: Hashable, Sendable {
    public var name: String
    public var version: String
    public var ignore: [String]
    /// The full JSON document, so unknown keys are preserved on save.
    public var document: JSONValue

    public static let fileName = "bruno.json"

    public init(name: String) {
        self.name = name
        version = "1"
        ignore = ["node_modules", ".git"]
        document = .object([
            JSONMember("version", .string("1")), JSONMember("name", .string(name)),
            JSONMember("type", .string("collection")),
            JSONMember("ignore", .array([.string("node_modules"), .string(".git")])),
        ])
    }

    public static func decode(_ data: Data) throws(CoreError) -> BrunoManifest {
        let value = try JSONParser(maximumBytes: 1024 * 1024, maximumDepth: 32).parse(data)
        guard case .object = value else { throw .invalidDocument(path: fileName, reason: "Expected a JSON object") }
        guard let name = value["name"]?.stringValue, !name.isEmpty else {
            throw .invalidDocument(path: fileName, reason: "The collection has no name")
        }
        if let type = value["type"]?.stringValue, type != "collection" {
            throw .unsupportedDocument(reason: "bruno.json type “\(type)” is not a collection")
        }
        var manifest = BrunoManifest(name: name)
        manifest.version = value["version"]?.stringValue ?? "1"
        manifest.ignore = value["ignore"]?.arrayValue?.compactMap(\.stringValue) ?? []
        manifest.document = value
        return manifest
    }

    public func encoded() -> Data {
        guard case .object(var members) = document else { return Data() }
        if let index = members.firstIndex(where: { $0.key == "name" }) {
            members[index].value = .string(name)
        } else {
            members.append(JSONMember("name", .string(name)))
        }
        return Data((JSONSerializer.string(from: .object(members)) + "\n").utf8)
    }
}
