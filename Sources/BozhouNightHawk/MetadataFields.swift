import Foundation
import CoreFoundation
import BozhouCore

/// NightHawk schema flattening. Array positions never form part of a property ID.
struct MetadataFields {
    private var values: [String: MetadataField] = [:]
    private var bytes = 0
    private(set) var limited = false
    var fields: [MetadataField] { values.values.sorted { $0.id < $1.id } }

    mutating func add(_ value: Any, path: [String], labels: [String], context: String = "", depth: Int = 0) {
        guard depth < 24 else { limited = true; return }
        if let object = value as? [String: Any], !object.isEmpty {
            for key in object.keys.sorted() {
                add(object[key]!, path: path + [key], labels: labels + [key], context: context, depth: depth + 1)
            }
        } else if let array = value as? [Any], !array.isEmpty {
            for (index, item) in array.enumerated() {
                let row = item as? [String: Any]
                let identity = ["network_interface_id", "volume_id", "subnet_id", "id", "tag_key", "name"]
                    .compactMap { row?[$0] as? String }.first(where: { !$0.isEmpty }) ?? String(index + 1)
                add(item, path: path + ["*"], labels: labels,
                    context: [context, identity].filter { !$0.isEmpty }.joined(separator: " / "), depth: depth + 1)
            }
        } else {
            let id = path.map { $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined(separator: "/")
            guard values[id] != nil || values.count < 4000 else { limited = true; return }
            let text = Self.text(value)
            let line = context.isEmpty ? text : "\(context): \(text)"
            let combined = values[id].map { $0.value + "\n" + line } ?? line
            let oldBytes = values[id]?.value.utf8.count ?? 0
            let allowance = min(16384, max(0, 1024 * 1024 - bytes + oldBytes))
            if combined.utf8.count > allowance { limited = true }
            let bounded = String(decoding: combined.utf8.prefix(allowance), as: UTF8.self)
            bytes += bounded.utf8.count - oldBytes
            values[id] = MetadataField(id: id, title: labels.joined(separator: " › "), value: bounded)
        }
    }

    mutating func list(_ items: [[String: Any]], source: String, section: String, title: String,
                       labels: [String: String], context: String) {
        if items.isEmpty {
            for key in labels.keys.sorted() {
                add([], path: [source, "list", section, "*", key], labels: [source, title, labels[key]!], context: context)
            }
        }
        for (index, item) in items.enumerated() {
            let identity = ["network_interface_id", "volume_id", "subnet_id", "load_balancer_id", "id", "name"]
                .compactMap { item[$0] as? String }.first(where: { !$0.isEmpty }) ?? String(index + 1)
            for key in item.keys.sorted() {
                // Tags are individually selectable and remain stable when other tags are inserted.
                let tag = item["tag_key"] as? String
                let component = tag.map { "tag:" + $0 } ?? "*"
                let caption = tag.map { title + " / " + $0 } ?? title
                add(item[key]!, path: [source, "list", section, component, key],
                    labels: [source, caption, labels[key] ?? key],
                    context: [context, tag == nil ? identity : ""].filter { !$0.isEmpty }.joined(separator: " / "))
            }
        }
    }
    static func text(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let value = value as? String { return value.isEmpty ? "—" : value }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: value)
    }
}
