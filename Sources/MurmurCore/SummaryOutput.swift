import Foundation

/// Splits a raw summary completion into its parts: the leading `TITLE:` line,
/// the visible markdown body, and (stripped out of the body) the machine
/// `<!--TASKS ... -->` block that TaskExtractor reads.
public enum SummaryOutput {

    public static func parse(_ raw: String) -> (title: String?, body: String) {
        var title: String?
        var lines = raw.components(separatedBy: "\n")

        // Title: the first non-empty line if it starts with TITLE:
        if let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           let range = lines[firstIndex].range(of: "TITLE:", options: [.anchored, .caseInsensitive]) {
            title = String(lines[firstIndex][range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            lines.removeSubrange(...firstIndex)
        }

        var body = lines.joined(separator: "\n")
        // Strip the TASKS comment block (non-greedy, across newlines).
        if let start = body.range(of: "<!--TASKS"),
           let end = body.range(of: "-->", range: start.upperBound..<body.endIndex) {
            body.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return (title?.isEmpty == true ? nil : title,
                body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
