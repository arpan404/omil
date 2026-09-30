import SwiftUI

/// Word-level diff between the raw transcript and the cleaned text, for the
/// Changes view. Same algorithm as the Mac app's DiffUtil: words and
/// punctuation are separate tokens, so a punctuation fix doesn't show up as
/// replacing the neighboring word.
enum TranscriptDiff {
    enum Kind: Equatable { case same, added, removed }

    struct Token: Equatable {
        let text: String
        let kind: Kind
    }

    static func tokens(raw: String, cleaned: String) -> [Token] {
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

    /// Renders tokens as text: additions tinted, removals struck through.
    static func attributed(_ tokens: [Token], added: Color, removed: Color) -> AttributedString {
        var result = AttributedString()
        for (index, token) in tokens.enumerated() {
            if index > 0 && !attachesToPrevious(token.text) {
                result += AttributedString(" ")
            }
            var piece = AttributedString(token.text)
            switch token.kind {
            case .same:
                break
            case .added:
                piece.foregroundColor = added
                piece.backgroundColor = added.opacity(0.14)
            case .removed:
                piece.foregroundColor = removed
                piece.strikethroughStyle = .single
                piece.backgroundColor = removed.opacity(0.1)
            }
            result += piece
        }
        return result
    }

    private static func attachesToPrevious(_ token: String) -> Bool {
        guard token.count == 1, let c = token.first else { return false }
        return ".,!?;:)]}%”’".contains(c)
    }

    private nonisolated(unsafe) static let pattern = try? NSRegularExpression(
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
