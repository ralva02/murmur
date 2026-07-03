import Foundation

/// Auto-add-to-dictionary (spec §7.1): after inserting a transcript, the field
/// is re-read a little later; words the user re-spelled are learned. This is
/// the pure comparison half — the field monitoring lives in the app target.
public enum CorrectionDetector {

    /// Corrected spellings the user applied to the inserted text.
    ///
    /// Conservative by design: only word substitutions that look like spelling
    /// fixes (small edit distance, not case-only, not already known) count.
    /// Rewrites, appends, and word-choice edits yield nothing.
    public static func corrections(
        inserted: String,
        current: String,
        knownTerms: [String]
    ) -> [String] {
        let diff = WordDiff.diff(old: inserted, new: current)

        // A heavily-changed text is a rewrite, not a correction pass.
        let changed = diff.filter { if case .same = $0 { return false }; return true }.count
        let total = max(diff.count, 1)
        guard changed * 3 < total || changed <= 2 else { return [] }

        let known = Set(knownTerms.map { $0.lowercased() })
        var results: [String] = []

        var index = 0
        while index < diff.count - 1, results.count < 3 {
            defer { index += 1 }
            guard case .removed(let rawOld) = diff[index],
                  case .added(let rawNew) = diff[index + 1] else { continue }
            let old = strip(rawOld)
            let new = strip(rawNew)
            guard old.count >= 3, new.count >= 3 else { continue }
            guard old.lowercased() != new.lowercased() else { continue }   // case-only
            guard !known.contains(new.lowercased()) else { continue }
            let distance = editDistance(old.lowercased(), new.lowercased())
            guard (1...3).contains(distance) else { continue }             // spelling fix, not new word
            results.append(new)
            index += 1
        }
        return results
    }

    private static func strip(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters)
    }

    /// Levenshtein distance.
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var row = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            row[0] = i
            for j in 1...y.count {
                let substitution = previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)
                row[j] = min(previous[j] + 1, row[j - 1] + 1, substitution)
            }
            swap(&previous, &row)
        }
        return previous[y.count]
    }
}
