import Foundation

public struct ExtractedTask: Sendable, Equatable, Codable {
    public var title: String
    public var assignee: String
    public init(title: String, assignee: String) {
        self.title = title
        self.assignee = assignee
    }
}

/// Reads action items from the `<!--TASKS ... -->` block in a raw summary.
/// Each line is `<task> | <assignee>` with an optional leading `-`; the
/// assignee defaults to "Unassigned" when absent.
public enum TaskExtractor {
    public static func parse(_ raw: String) -> [ExtractedTask] {
        guard let start = raw.range(of: "<!--TASKS"),
              let end = raw.range(of: "-->", range: start.upperBound..<raw.endIndex) else {
            return []
        }
        let block = raw[start.upperBound..<end.lowerBound]
        return block.components(separatedBy: "\n").compactMap { line in
            var item = line.trimmingCharacters(in: .whitespaces)
            if item.hasPrefix("-") { item = String(item.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard !item.isEmpty else { return nil }
            let title: String
            let assignee: String
            if let pipe = item.range(of: "|", options: .backwards) {
                title = String(item[..<pipe.lowerBound]).trimmingCharacters(in: .whitespaces)
                let a = String(item[pipe.upperBound...]).trimmingCharacters(in: .whitespaces)
                assignee = a.isEmpty ? "Unassigned" : a
            } else {
                title = item
                assignee = "Unassigned"
            }
            guard !title.isEmpty else { return nil }
            return ExtractedTask(title: title, assignee: assignee)
        }
    }
}
