import Foundation

/// Word-level diff between the raw transcript and the cleaned text. Words and
/// punctuation are separate tokens, so a punctuation fix doesn't show up as
/// replacing the neighboring word. Shared by the Mac and iOS Changes views.
public enum TranscriptDiff {
    public enum Kind: Equatable, Sendable { case same, added, removed }

    public struct Token: Equatable, Sendable {
        public let text: String
        public let kind: Kind

        public init(text: String, kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    /// The diff the way git shows it: the original line with its removals marked,
    /// and the cleaned line with its additions marked. Unchanged words appear in both.
    public struct Lines: Equatable, Sendable {
        public let original: [Token]
        public let cleaned: [Token]
        public var hasChanges: Bool { original.contains { $0.kind != .same } || cleaned.contains { $0.kind != .same } }
    }

    public static func lines(raw: String, cleaned: String) -> Lines {
        let all = tokens(raw: raw, cleaned: cleaned)
        return Lines(
            original: all.filter { $0.kind != .added },
            cleaned: all.filter { $0.kind != .removed }
        )
    }

    public static func tokens(raw: String, cleaned: String) -> [Token] {
        let a = split(raw)
        let b = split(cleaned)
        // Past this size the table gets expensive; show the cleaned text as-is.
        if (a.count + 1) * (b.count + 1) > 250_000 {
            return b.map { Token(text: $0, kind: .same) }
        }
        let n = a.count, m = b.count, width = m + 1
        var lcs = [Int](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i * width + j] = a[i] == b[j]
                    ? lcs[(i + 1) * width + j + 1] + 1
                    : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
            }
        }
        var out: [Token] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                out.append(Token(text: a[i], kind: .same)); i += 1; j += 1
            } else if j < m, i >= n || lcs[i * width + j + 1] > lcs[(i + 1) * width + j] {
                out.append(Token(text: b[j], kind: .added)); j += 1
            } else if i < n {
                out.append(Token(text: a[i], kind: .removed)); i += 1
            }
        }
        return out
    }

    /// Whether a token is written without a space before it (closing punctuation).
    public static func attachesToPrevious(_ token: String) -> Bool {
        guard token.count == 1, let c = token.first else { return false }
        return ".,!?;:)]}%”’".contains(c)
    }

    private static let pattern = try? NSRegularExpression(
        pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*|[^\p{L}\p{N}\s]"#
    )

    private static func split(_ text: String) -> [String] {
        guard let regex = pattern else { return [text] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
