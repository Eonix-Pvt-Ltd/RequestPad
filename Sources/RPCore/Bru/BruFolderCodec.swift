import Foundation

/// Reads and writes Bruno `folder.bru` and `collection.bru` files as ``FolderSettings`` (F03.3, P01.2).
/// Scripts, tests and post-response variables at folder/collection level are preserved but not interpreted.
public enum BruFolderCodec {
    public struct Decoded: Hashable, Sendable {
        public var name: String?
        public var settings: FolderSettings
        public var hasUnsupportedScripts: Bool
    }

    public static func decode(_ text: String) throws(CoreError) -> (folder: Decoded, document: BruDocument) {
        let document = try BruDocument.parse(text)
        return (try decode(document), document)
    }

    public static func decode(_ document: BruDocument) throws(CoreError) -> Decoded {
        let meta = try BruCodecSupport.pairs(of: document.firstBlock(named: "meta"))
        let authPairs = try BruCodecSupport.pairs(of: document.firstBlock(named: "auth"))
        let mode =
            BruCodecSupport.value("mode", in: authPairs)
            ?? (document.firstBlock(named: "auth") == nil ? "inherit" : "none")
        let settings = FolderSettings(
            headers: try BruCodecSupport.rows(from: document.firstBlock(named: "headers")),
            auth: try BruCodecSupport.decodeAuth(mode: mode, document: document),
            variables: try BruCodecSupport.rows(from: document.firstBlock(named: "vars:pre-request")),
            docs: document.firstBlock(named: "docs").map(BruText.text(of:)) ?? "",
            sequence: Int(BruCodecSupport.value("seq", in: meta) ?? ""))
        let scripts = document.blocks.contains { block in
            (block.name.hasPrefix("script:") || block.name == "tests")
                && !BruText.text(of: block).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return Decoded(
            name: BruCodecSupport.value("name", in: meta), settings: settings, hasUnsupportedScripts: scripts)
    }

    /// Serializes folder/collection settings. `name` is written to `meta` for folders; pass `nil` for
    /// `collection.bru` (Bruno keeps the collection name in `bruno.json`).
    public static func encode(
        _ settings: FolderSettings, name: String?, preserving original: BruDocument? = nil
    ) throws(CoreError) -> String {
        var desired: [BruDocument.Block] = []
        let originalMeta = try BruCodecSupport.pairs(of: original?.firstBlock(named: "meta"))
        let meta = BruCodecSupport.merge(
            originalMeta,
            [
                ("name", name), ("seq", settings.sequence.map(String.init)),
            ])
        if !meta.isEmpty { desired.append(BruCodecSupport.dictionaryBlock("meta", meta)) }
        if !settings.headers.isEmpty {
            desired.append(BruCodecSupport.dictionaryBlock("headers", BruCodecSupport.pairs(from: settings.headers)))
        }
        let originalAuth = try BruCodecSupport.pairs(of: original?.firstBlock(named: "auth"))
        let includeAuth = settings.auth != .inherit || !originalAuth.isEmpty
        if includeAuth {
            desired.append(
                BruCodecSupport.dictionaryBlock(
                    "auth", BruCodecSupport.merge(originalAuth, [("mode", settings.auth.bruMode)])))
        }
        if let block = try BruCodecSupport.authBlock(settings.auth, original: original) { desired.append(block) }
        if !settings.variables.isEmpty {
            desired.append(
                BruCodecSupport.dictionaryBlock("vars:pre-request", BruCodecSupport.pairs(from: settings.variables)))
        }
        if !settings.docs.isEmpty { desired.append(BruCodecSupport.textBlock("docs", settings.docs)) }

        var managed: Set<String> = ["meta", "headers", "auth", "vars:pre-request", "docs"]
        if BruCodecSupport.authModesWithBlocks.contains(settings.auth.bruMode) {
            managed.insert("auth:\(settings.auth.bruMode)")
        }
        return try BruCodecSupport.assemble(desired: desired, managed: managed, original: original)
    }
}
