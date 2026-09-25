import Foundation

/// Exports a resolved request as a cURL command (F07.2). Callers resolve with ``Interpolator/Mode/display`` to mask
/// secrets, or ``Interpolator/Mode/send`` when the user explicitly chooses "Include secret values".
public enum CurlExporter {
    public enum Style: Sendable {
        case singleLine
        case multiLine
    }

    public static func export(_ request: ResolvedRequest, style: Style = .multiLine) -> String {
        var parts: [String] = ["curl"]
        if request.method != .get || isBodyWithoutMethodChange(request) {
            parts.append("-X \(ShellWords.quote(request.method.rawValue))")
        }
        parts.append(ShellWords.quote(request.url.absoluteString))
        if request.settings.followRedirects { parts.append("-L") }
        for header in request.headers {
            // `-H 'Name:'` would make curl remove the header; `Name;` sends it with an empty value.
            let field = header.value.isEmpty ? "\(header.name);" : "\(header.name): \(header.value)"
            parts.append("-H \(ShellWords.quote(field))")
        }
        switch request.body {
        case .none:
            break
        case .data(let data):
            parts.append("--data-raw \(ShellWords.quote(String(decoding: data, as: UTF8.self)))")
        case .multipart(let multipartParts):
            for part in multipartParts {
                let typeSuffix = part.contentType.map { ";type=\($0)" } ?? ""
                switch part.content {
                case .text(let value):
                    parts.append(
                        typeSuffix.isEmpty
                            ? "--form-string \(ShellWords.quote("\(part.name)=\(value)"))"
                            : "-F \(ShellWords.quote("\(part.name)=\(value)\(typeSuffix)"))")
                case .file(let reference):
                    parts.append("-F \(ShellWords.quote("\(part.name)=@\(reference)\(typeSuffix)"))")
                }
            }
        }
        switch style {
        case .singleLine: return parts.joined(separator: " ")
        case .multiLine: return parts.joined(separator: " \\\n  ")
        }
    }

    /// `curl` switches to POST when a body is present, so a GET with a body needs an explicit `-X GET`.
    private static func isBodyWithoutMethodChange(_ request: ResolvedRequest) -> Bool {
        request.body != .none
    }
}
