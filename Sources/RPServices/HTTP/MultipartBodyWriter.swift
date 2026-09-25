import Foundation
import RPCore
import UniformTypeIdentifiers

/// Writes a `multipart/form-data` body (RFC 7578) to a temporary file, streaming file parts in chunks so large
/// uploads never load into memory.
public enum MultipartBodyWriter {
    static let chunkSize = 256 * 1024

    public struct Output: Sendable {
        public var file: URL
        public var contentType: String
        public var size: Int
    }

    public static func write(
        _ parts: [ResolvedRequest.MultipartPart], files: any FileReferenceResolver, directory: URL,
        boundary: String = makeBoundary()
    ) throws(ServiceError) -> Output {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .fileUnavailable(name: directory.lastPathComponent)
        }
        let output = directory.appending(path: "upload-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: output.path(percentEncoded: false), contents: nil),
            let handle = try? FileHandle(forWritingTo: output)
        else { throw .fileUnavailable(name: output.lastPathComponent) }
        defer { try? handle.close() }
        var size = 0
        func append(_ data: Data) throws(ServiceError) {
            do {
                try handle.write(contentsOf: data)
                size += data.count
            } catch {
                throw .fileUnavailable(name: output.lastPathComponent)
            }
        }
        do throws(ServiceError) {
            for part in parts {
                try append(Data("--\(boundary)\r\n".utf8))
                switch part.content {
                case .text(let value):
                    var head = "Content-Disposition: form-data; name=\"\(escape(part.name))\"\r\n"
                    if let contentType = part.contentType { head += "Content-Type: \(contentType)\r\n" }
                    try append(Data((head + "\r\n").utf8))
                    try append(Data(value.utf8))
                case .file(let reference):
                    let (url, access) = try files.open(reference)
                    defer { access?.stop() }
                    let fileName = url.lastPathComponent
                    let contentType = part.contentType ?? mimeType(for: url)
                    let head =
                        "Content-Disposition: form-data; name=\"\(escape(part.name))\"; filename=\"\(escape(fileName))\"\r\nContent-Type: \(contentType)\r\n\r\n"
                    try append(Data(head.utf8))
                    guard let input = try? FileHandle(forReadingFrom: url) else {
                        throw ServiceError.fileUnavailable(name: fileName)
                    }
                    defer { try? input.close() }
                    while true {
                        let chunk: Data
                        do {
                            chunk = try input.read(upToCount: chunkSize) ?? Data()
                        } catch {
                            throw ServiceError.fileUnavailable(name: fileName)
                        }
                        if chunk.isEmpty { break }
                        try append(chunk)
                    }
                }
                try append(Data("\r\n".utf8))
            }
            try append(Data("--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return Output(file: output, contentType: "multipart/form-data; boundary=\(boundary)", size: size)
    }

    public static func makeBoundary() -> String { "RequestPadBoundary-\(UUID().uuidString)" }

    /// RFC 7578 §4.2: quotes and line breaks in names are percent-encoded.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
