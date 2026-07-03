import Foundation

/// Splits a raw summary completion into the leading `TITLE:` line and the
/// visible markdown body. Tasks are NOT stripped — they live in the body's
/// own action-items section, which TaskExtractor reads.
public enum SummaryOutput {

    public static func parse(_ raw: String) -> (title: String?, body: String) {
        var title: String?
        var lines = raw.components(separatedBy: "\n")

        if let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           let range = lines[firstIndex].range(of: "TITLE:", options: [.anchored, .caseInsensitive]) {
            title = String(lines[firstIndex][range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            lines.removeSubrange(...firstIndex)
        }

        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == true ? nil : title, body)
    }
}
