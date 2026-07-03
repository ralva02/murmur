import Foundation

/// Deterministic transcript transformations that must not be left to the LLM:
/// the "press enter" meta-command (spec §9) and snippet expansion (spec §7.2).
public enum TranscriptProcessor {

    // MARK: - "press enter" (spec §9)

    /// Recognized only at the very end of the transcript; mid-sentence stays literal.
    public static func extractPressEnter(from transcript: String) -> (text: String, pressEnter: Bool) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Either the whole transcript is "press enter", or it follows a
        // separator (whitespace/punctuation) at the end. Trailing punctuation
        // after the command is tolerated.
        let pattern = /(?i)(?:^|[\s.,!?;:])press enter[\s.,!?;:]*$/
        guard let match = trimmed.firstMatch(of: pattern) else {
            return (trimmed, false)
        }
        var head = String(trimmed[..<match.range.lowerBound])
        // The separator that preceded the command (e.g. the "." in "Ship it. Press enter.")
        // belongs to the remaining text; only strip dangling whitespace/commas.
        while let last = head.last, last.isWhitespace || last == "," || last == ";" || last == ":" {
            head.removeLast()
        }
        // Re-attach a sentence terminator consumed by the match, if any.
        let separator = trimmed[match.range.lowerBound]
        if !head.isEmpty, separator == "." || separator == "!" || separator == "?" {
            head.append(separator)
        }
        return (head, true)
    }

    // MARK: - Snippets (spec §7.2)

    /// Case-insensitive, word-boundary, longest-trigger-first replacement.
    public static func expandSnippets(in text: String, snippets: [Snippet]) -> String {
        var result = text
        for snippet in snippets.sorted(by: { $0.triggerPhrase.count > $1.triggerPhrase.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: snippet.triggerPhrase)
            guard let regex = try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])",
                options: [.caseInsensitive]
            ) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: snippet.body)
            )
        }
        return result
    }
}
