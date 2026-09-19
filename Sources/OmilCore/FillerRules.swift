import Foundation

// MARK: - Filler & repetition rules (deterministic, conservative)

public struct FillerRules: Sendable {
    public static let rulesVersion = "omil-fill-1"

    public init() {}

    public struct Result: Sendable {
        public var edits: [ProposedEdit]
        public var abstentions: [Abstention]
    }

    public func apply(snapshot: TranscriptSnapshot) -> Result {
        var edits: [ProposedEdit] = []
        var abstentions: [Abstention] = []
        let tokens = snapshot.tokens

        // 1. Standalone fillers (um, uh, er, ah, ...), unless literal use.
        for (i, t) in tokens.enumerated() where t.kind == .filler {
            if isLiteralUse(tokens, at: i) {
                abstentions.append(Abstention(reason: .quotedContent, detail: "filler used literally; preserved", tokenIds: [t.id]))
                continue
            }
            edits.append(ProposedEdit(
                snapshotId: snapshot.snapshotId, snapshotRevision: snapshot.revision,
                op: .deleteFiller, targetTokenIds: [t.id],
                reason: "standalone filler '\(t.text)'", ruleVersion: Self.rulesVersion))
        }

        // 2. Parenthetical "you know" (adjacent to comma/boundary), "like"
        //    only when clearly parenthetical (between punctuation).
        let lowers = tokens.map { $0.normalized }
        for i in tokens.indices {
            // "you know"
            if i + 1 < tokens.count, lowers[i] == "you", lowers[i+1] == "know",
               tokens[i].kind == .word, tokens[i+1].kind == .word {
                if isLiteralUse(tokens, at: i) { continue }
                let leftPunct = i > 0 && tokens[i-1].kind == .punctuation
                let rightPunct = i + 2 < tokens.count && tokens[i+2].kind == .punctuation
                let atEdge = i == 0 || i + 2 >= tokens.count
                if leftPunct || rightPunct || atEdge {
                    // Guard: sentence-initial "You know what ..." is content.
                    let after = (i + 2 < lowers.count) ? lowers[i+2] : ""
                    if i == 0 && ["what", "why", "how"].contains(after) { continue }
                    edits.append(ProposedEdit(
                        snapshotId: snapshot.snapshotId, snapshotRevision: snapshot.revision,
                        op: .deleteFiller, targetTokenIds: [tokens[i].id, tokens[i+1].id],
                        evidenceTokenIds: (i > 0 ? [tokens[i-1].id] : []) + ((i+2 < tokens.count) ? [tokens[i+2].id] : []),
                        reason: "parenthetical 'you know'", ruleVersion: Self.rulesVersion))
                }
            }
            // "like" between punctuation only.
            if lowers[i] == "like", tokens[i].kind == .word {
                let leftPunct = i > 0 && tokens[i-1].kind == .punctuation
                let rightPunct = i + 1 < tokens.count && tokens[i+1].kind == .punctuation
                if leftPunct && rightPunct {
                    edits.append(ProposedEdit(
                        snapshotId: snapshot.snapshotId, snapshotRevision: snapshot.revision,
                        op: .deleteFiller, targetTokenIds: [tokens[i].id],
                        reason: "parenthetical 'like'", ruleVersion: Self.rulesVersion))
                }
            }
        }

        // 3. Immediate accidental repetition: adjacent identical function words
        //    or numbers ("the the", "42 42"). Never cues, never across quotes
        //    (tokenizer protects quoted), never "no no" (repair cue).
        let repeatable: Set<String> = ["the","a","an","to","of","and","in","on","for","is","are","was","it","that","this","i","you","we"]
        for i in 0 ..< max(0, tokens.count - 1) {
            let a = tokens[i], b = tokens[i+1]
            guard a.normalized == b.normalized else { continue }
            guard a.kind != .cue && b.kind != .cue else { continue }
            guard a.kind != .punctuation else { continue }
            if a.normalized == "no" { continue }
            if a.kind == .number || repeatable.contains(a.normalized) {
                edits.append(ProposedEdit(
                    snapshotId: snapshot.snapshotId, snapshotRevision: snapshot.revision,
                    op: .deleteRepeat, targetTokenIds: [b.id], evidenceTokenIds: [a.id],
                    reason: "accidental repetition '\(b.text)'", ruleVersion: Self.rulesVersion))
            } else {
                abstentions.append(Abstention(reason: .ambiguousScope, detail: "repeated content word '\(b.text)' preserved (possible emphasis)", tokenIds: [b.id]))
            }
        }

        return Result(edits: edits, abstentions: abstentions)
    }

    func isLiteralUse(_ tokens: [Token], at i: Int) -> Bool {
        var j = i - 1
        while j >= 0 && tokens[j].kind == .punctuation { j -= 1 }
        guard j >= 0 else { return false }
        let w = tokens[j].normalized
        if ["word", "words", "say", "said", "write", "spell", "term", "call"].contains(w) { return true }
        // 'the words "A B"': filler inside quotes already demoted; this covers
        // unquoted "say um".
        if w == "say" || w == "says" { return true }
        return false
    }
}
