import Foundation

// MARK: - Tokenizer
// Splits recognizer text into stable tokens. Token IDs are
// "<snapshotShortId>-<index>" and stable for a given snapshot.

public struct Tokenizer: Sendable {
    public static let rulesVersion = "omil-tok-1"

    public init() {}

    private static let standaloneFillers: Set<String> = [
        "um", "uh", "er", "ah", "umm", "uhh", "emm", "hmm", "mm-hmm"
    ]

    private static let cuePhrases: [[String]] = [
        ["scratch", "that"],
        ["i", "mean"],
        ["excuse", "me"],
        ["my", "bad"],
        ["keep", "the", "original"],
        ["keep", "it"],
        ["keep"],
        ["sorry"],
        ["actually"],
        ["rather"],
        ["wait"],
    ]

    /// Words that must never be deleted as fillers.
    static let protectedWords: Set<String> = [
        "not", "no", // handled contextually; default protected
        "never", "none", "nobody", "nothing", "neither", "nor",
    ]

    public func tokenize(text: String, snapshotId: SnapshotID) -> [Token] {
        // Split into words / numbers / punctuation, keeping quoted spans detectable.
        var tokens: [Token] = []
        // Regex: words with apostrophes, numbers, or single punctuation.
        let pattern = "[A-Za-z]+(?:'[A-Za-z]+)?|\\d+(?:\\.\\d+)?|[^\\s\\w]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var idx = 0
        for m in matches {
            let word = ns.substring(with: m.range)
            let lower = word.lowercased()
            var kind: TokenKind = .word
            if word.rangeOfCharacter(from: .decimalDigits) != nil && word.rangeOfCharacter(from: .letters) == nil {
                kind = .number
            } else if word.count == 1 && word.rangeOfCharacter(from: .alphanumerics) == nil {
                kind = .punctuation
            } else if Self.standaloneFillers.contains(lower) {
                kind = .filler
            }
            let isProtected = Self.protectedWords.contains(lower) || kind == .number
            tokens.append(Token(
                id: TokenID("\(snapshotId.rawValue.prefix(8))-\(idx)"),
                text: word, normalized: lower, kind: kind, isProtected: isProtected
            ))
            idx += 1
        }
        markCues(tokens: &tokens)
        markQuotedRegions(tokens: &tokens)
        return tokens
    }

    /// Second pass: multi-word cue phrases + single-word cues.
    private func markCues(tokens: inout [Token]) {
        let lowers = tokens.map { $0.normalized }
        var i = 0
        while i < tokens.count {
            var matched = 0
            // Try longest cue phrases first.
            for phrase in Self.cuePhrases.sorted(by: { $0.count > $1.count }) {
                guard i + phrase.count <= lowers.count else { continue }
                let slice = Array(lowers[i ..< i + phrase.count])
                if slice == phrase {
                    // Contextual guard for bare "no"/"keep":
                    // mark as cue tentatively; resolver decides with type evidence.
                    // "keep the original" / "keep it 42" / "keep 42" are cues.
                    for k in i ..< i + phrase.count {
                        tokens[k].kind = .cue
                    }
                    matched = phrase.count
                    break
                }
            }
            if matched > 0 {
                i += matched
                continue
            }
            // Bare "no" handling: mark as cue only if it looks like a repair cue.
            // Resolver re-validates; marker here is a proposal signal, not a decision.
            if lowers[i] == "no" {
                var p = i - 1
                while p >= 0 && tokens[p].kind == .punctuation { p -= 1 }
                // A preceding "no" cue is content for run detection ("no no").
                let prevIsContent = p >= 0 && (tokens[p].kind == .word || tokens[p].kind == .number || tokens[p].kind == .cue)
                let nextIsContent = i + 1 < lowers.count && lowers[i + 1] != "."
                if prevIsContent && nextIsContent {
                    // e.g. "42, sorry 21, no no keep it 42": the "no"s sit between values.
                    tokens[i].kind = .cue
                    tokens[i].isProtected = false
                }
            }
            i += 1
        }
    }

    /// Tokens inside paired double/single quotes are protected content:
    /// cues inside quotes must not trigger edits.
    private func markQuotedRegions(tokens: inout [Token]) {
        var inDouble = false
        var inSingle = false
        for k in tokens.indices {
            let t = tokens[k].text
            if t == "\"" || t == "\u{201C}" || t == "\u{201D}" {
                inDouble.toggle()
                continue
            }
            if t == "'" && (k == 0 || tokens[k - 1].text == " " ) {
                // crude; apostrophes already kept inside words by regex
                inSingle.toggle()
                continue
            }
            if inDouble || inSingle {
                // Quoted content: never a cue or filler.
                if tokens[k].kind == .cue || tokens[k].kind == .filler {
                    tokens[k].kind = .word
                }
                tokens[k].isProtected = true
            }
        }
    }
}

// MARK: - Snapshot builder

public struct SnapshotBuilder: Sendable {
    private let tokenizer = Tokenizer()
    public init() {}

    public func makeSnapshot(
        sessionId: SessionID, revision: Int, rawText: String,
        backend: BackendIdentity, locale: String = "en-US",
        segments: [SegmentRevision] = [], alternatives: [AlternativeHypothesis] = []
    ) -> TranscriptSnapshot {
        let sid = SnapshotID()
        let tokens = tokenizer.tokenize(text: rawText, snapshotId: sid)
        return TranscriptSnapshot(
            sessionId: sessionId, snapshotId: sid, revision: revision,
            backend: backend, locale: locale, rawText: rawText,
            tokens: tokens, segments: segments, alternatives: alternatives
        )
    }
}
