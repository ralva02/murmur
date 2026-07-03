import Foundation

public struct ExtractedTask: Sendable, Equatable, Codable {
    public var title: String
    public var assignee: String
    public init(title: String, assignee: String) {
        self.title = title
        self.assignee = assignee
    }
}

/// Extracts action items from the summary's own "Action items" (or "To-dos")
/// section — the one place the model reliably lists them. Bullets read
/// `- <task> (@owner)`, with `(@owner)` optional; a missing owner is
/// "Unassigned". This beats asking a small local model to also emit a
/// separate machine block (it puts the format in the visible section instead).
public enum TaskExtractor {

    private static let headingMatches = ["action item", "to-do", "to do", "todo"]

    public static func parse(_ body: String) -> [ExtractedTask] {
        let lines = body.components(separatedBy: "\n")
        var inSection = false
        var tasks: [ExtractedTask] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                // A heading: enter the section if it names action items/to-dos.
                let heading = trimmed.drop(while: { $0 == "#" }).lowercased()
                inSection = headingMatches.contains { heading.contains($0) }
                continue
            }
            guard inSection else { continue }

            var item = trimmed
            guard item.hasPrefix("-") || item.hasPrefix("*") else { continue }
            item = String(item.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }

            let (title, assignee) = Self.splitAssignee(item)
            guard !title.isEmpty else { continue }
            tasks.append(ExtractedTask(title: title, assignee: assignee))
        }
        return tasks
    }

    /// Pulls a trailing owner marker off a task line. Tolerates the forms a
    /// small local model actually produces: `(@Name)`, `| Name`, `— Name`,
    /// `- Name`. A missing/`Unassigned` owner yields "Unassigned".
    static func splitAssignee(_ item: String) -> (title: String, assignee: String) {
        // Trailing (@Name)
        if item.hasSuffix(")"), let open = item.range(of: "(@", options: .backwards) {
            let name = item[item.index(open.lowerBound, offsetBy: 2)..<item.index(before: item.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                return (String(item[..<open.lowerBound]).trimmingCharacters(in: .whitespaces),
                        normalize(name))
            }
        }
        // Trailing `| Name`, `— Name`, ` - Name` (last separator wins).
        for sep in [" | ", " — ", " – ", " - "] {
            if let r = item.range(of: sep, options: .backwards) {
                let name = String(item[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                let title = String(item[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                // Only treat as an owner if it's short and word-like, not a clause.
                if !name.isEmpty, !title.isEmpty, name.split(separator: " ").count <= 3 {
                    return (title, normalize(name))
                }
            }
        }
        return (item, "Unassigned")
    }

    private static func normalize(_ name: String) -> String {
        let n = name.hasPrefix("@") ? String(name.dropFirst()) : name
        return n.lowercased() == "unassigned" || n.isEmpty ? "Unassigned" : n
    }
}
