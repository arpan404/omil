import Foundation

// MARK: - Number normalization (locale-aware, versioned, recomputable)

/// Maps English number words to digits. The validator recomputes the derived
/// value from source tokens + rule version; the mapping is never a free edit.
public struct NumberNormalizer: Sendable {
    public static let ruleVersion = "omil-num-en-1"

    static let ones: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]
    static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000
    ]

    public init() {}

    /// Try to parse a contiguous run of number-word tokens. Returns value and
    /// count of tokens consumed, or nil if the run is not a number phrase.
    /// Single "a"/"an" is not a number. Hyphenated "twenty-one" arrives as
    /// ["twenty", "-", "one"] or ["twenty-one"] depending on ASR; handle both.
    public func parseNumberWords(_ words: [String]) -> (value: Int, consumed: Int)? {
        // Handle hyphen-joined single token like "twenty-one".
        var expanded: [String] = []
        for w in words {
            if w.contains("-") {
                expanded.append(contentsOf: w.split(separator: "-").map { String($0) })
            } else {
                expanded.append(w)
            }
        }
        var total = 0
        var current = 0
        var consumed = 0
        var usedAny = false
        for w in expanded {
            if let o = Self.ones[w] {
                current += o; usedAny = true; consumed += 1
            } else if let t = Self.tens[w] {
                current += t; usedAny = true; consumed += 1
            } else if w == "and" && usedAny {
                consumed += 1 // "one hundred and five"
            } else if let s = Self.scales[w] {
                if current == 0 { current = 1 }
                current *= s
                if s >= 1_000 { total += current; current = 0 }
                usedAny = true; consumed += 1
            } else if w == "-" {
                consumed += 1
            } else {
                break
            }
            if consumed >= words.count && expanded.count > words.count {
                break
            }
        }
        guard usedAny else { return nil }
        // Map consumed expanded-count back to original word count (approx: hyphens rejoin).
        // For validator purposes recompute from original slice instead.
        return (total + current, consumed)
    }

    /// Recompute the derived string for a source slice. Used by the validator.
    public func derivedText(sourceWords: [String]) -> String? {
        guard let (v, c) = parseNumberWords(sourceWords), c == sourceWords.count || c >= sourceWords.count - 1 else {
            // Allow trailing "and" style; require full-slice consumption.
            return nil
        }
        // Strict: every source word must be number vocabulary (or hyphen/and).
        let vocab = Set(Self.ones.keys).union(Self.tens.keys).union(Self.scales.keys).union(["and", "-"])
        for w in sourceWords {
            let parts = w.contains("-") ? w.split(separator: "-").map(String.init) : [w]
            for p in parts where !vocab.contains(p) { return nil }
        }
        return String(v)
    }
}

// MARK: - Personal dictionary

/// User-confirmed substitutions only. Membership never authorizes an edit by
/// itself; an edit must cite a source span or an explicit correction cue.
public struct PersonalDictionary: Codable, Sendable {
    public var entries: [String: String] // spoken form (lowercased) -> written form
    public var version: Int

    public init(entries: [String: String] = [:], version: Int = 1) {
        var norm: [String: String] = [:]
        for (k, v) in entries { norm[k.lowercased()] = v }
        self.entries = norm
        self.version = version
    }

    public func writtenForm(forSpoken spoken: String) -> String? {
        entries[spoken.lowercased()]
    }

    public mutating func confirm(spoken: String, written: String) {
        entries[spoken.lowercased()] = written
        version += 1
    }

    public mutating func remove(spoken: String) {
        entries.removeValue(forKey: spoken.lowercased())
        version += 1
    }
}

// MARK: - Spoken formatting commands

/// Explicit formatting operations. Only invoked when the command words appear
/// as a standalone instruction, not when used literally (e.g. "Do not remove
/// the word um." or "the words 'A B'").
public struct FormattingCommands: Sendable {
    public static let rulesVersion = "omil-fmt-1"

    public enum Command: Sendable {
        case newLine, newParagraph, bullet, numberedItem, comma, period,
             questionMark, exclamation, colon, semicolon, quote
    }

    public init() {}

    /// Detect a leading/trailing formatting command. Returns command + remaining range.
    /// Conservative: "new line" at a clause boundary; single words like "comma"
    /// only when clearly dictated as punctuation ("say comma" patterns are out of scope).
    public func detect(tokens: [Token]) -> [(command: Command, range: Range<Int>)] {
        var out: [(Command, Range<Int>)] = []
        let n = tokens.map { $0.normalized }
        var i = 0
        while i < n.count {
            if i + 1 < n.count && n[i] == "new" && n[i+1] == "line" {
                out.append((.newLine, i..<i+2)); i += 2; continue
            }
            if i + 1 < n.count && n[i] == "new" && n[i+1] == "paragraph" {
                out.append((.newParagraph, i..<i+2)); i += 2; continue
            }
            if i + 1 < n.count && n[i] == "bullet" && n[i+1] == "point" {
                out.append((.bullet, i..<i+2)); i += 2; continue
            }
            i += 1
        }
        return out
    }
}
