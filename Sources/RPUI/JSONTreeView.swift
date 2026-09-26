import RPCore
import SwiftUI

/// A node of a JSON document for the collapsible tree (F02.4). Children are built on demand.
public struct JSONNode: Identifiable, Hashable {
    public let id: String
    public let label: String
    public let value: JSONValue

    public init(path: String, label: String, value: JSONValue) {
        id = path
        self.label = label
        self.value = value
    }

    /// `nil` for scalars (leaf rows).
    public var children: [JSONNode]? {
        switch value {
        case .array(let elements):
            return elements.enumerated().map { index, element in
                JSONNode(path: "\(id)[\(index)]", label: "[\(index)]", value: element)
            }
        case .object(let members):
            return members.enumerated().map { index, member in
                JSONNode(path: "\(id)/\(index)", label: member.key, value: member.value)
            }
        default:
            return nil
        }
    }

    /// One-line value text: scalars in full, containers as a count.
    public var summary: String {
        switch value {
        case .null: "null"
        case .bool(let flag): flag ? "true" : "false"
        case .number(let text): text
        case .string(let text): "\"\(text.count > 200 ? String(text.prefix(200)) + "…" : text)\""
        case .array(let elements): elements.count == 1 ? "[1 item]" : "[\(elements.count) items]"
        case .object(let members): members.count == 1 ? "{1 key}" : "{\(members.count) keys}"
        }
    }
}

/// Collapsible JSON tree. `List` + `OutlineGroup` render lazily, so large documents stay responsive.
public struct JSONTreeView: View {
    let root: JSONValue

    public init(root: JSONValue) {
        self.root = root
    }

    public var body: some View {
        let top = JSONNode(path: "$", label: "$", value: root)
        List {
            // The document's members are shown directly (the first level is open); scalars show as one row.
            if let members = top.children {
                OutlineGroup(members, children: \.children) { node in
                    JSONNodeRow(node: node)
                }
            } else {
                JSONNodeRow(node: top)
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("response.jsonTree")
    }
}

struct JSONNodeRow: View {
    let node: JSONNode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
            Text(verbatim: node.label)
                .font(.body.monospaced().weight(.medium))
            Text(verbatim: node.summary)
                .font(.body.monospaced())
                .foregroundStyle(Self.tint(for: node.value))
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    static func tint(for value: JSONValue) -> Color {
        switch value {
        case .string: .primary
        case .number: .textBlue
        case .bool, .null: .textPurple
        default: .textSecondary
        }
    }
}
