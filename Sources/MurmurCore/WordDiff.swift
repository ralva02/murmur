import Foundation

/// Word-level diff for the View Diff UI (spec §12).
public enum WordDiff {

    public enum DiffSegment: Equatable, Sendable {
        case same(String)
        case added(String)
        case removed(String)
    }

    public static func diff(old: String, new: String) -> [DiffSegment] {
        let oldWords = old.split(separator: " ").map(String.init)
        let newWords = new.split(separator: " ").map(String.init)

        // Standard LCS table.
        let n = oldWords.count, m = newWords.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = oldWords[i] == newWords[j]
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var result: [DiffSegment] = []
        var i = 0, j = 0
        while i < n && j < m {
            if oldWords[i] == newWords[j] {
                result.append(.same(oldWords[i])); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                result.append(.removed(oldWords[i])); i += 1
            } else {
                result.append(.added(newWords[j])); j += 1
            }
        }
        while i < n { result.append(.removed(oldWords[i])); i += 1 }
        while j < m { result.append(.added(newWords[j])); j += 1 }
        return result
    }
}
