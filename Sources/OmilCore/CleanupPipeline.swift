import Foundation

// MARK: - CleanupPipeline
//
// Clean mode: filler/repeat rules + correction resolution + approved
// normalization, all validated through EditValidator. Any preservation
// failure falls back to filler-only output (never ships a harmful repair).

public struct CleanupPipeline: Sendable {
    public static let pipelineVersion = "omil-pipe-1"

    public var dictionary: PersonalDictionary
    public var applyDictionary: Bool
    private let filler = FillerRules()
    private let resolver = CorrectionResolver()
    private let validator = EditValidator()
    private let numbers = NumberNormalizer()
    private let formatting = FormattingCommands()

    public init(dictionary: PersonalDictionary = PersonalDictionary(), applyDictionary: Bool = true) {
        self.dictionary = dictionary
        self.applyDictionary = applyDictionary
    }

    public func clean(
        snapshot: TranscriptSnapshot,
        mode: CleanupMode = .clean,
        priorCandidates: [CorrectionCandidate] = []
    ) -> CleanedView {
        switch mode {
        case .verbatim:
            var journal = EditJournal(sessionId: snapshot.sessionId, baseSnapshotId: snapshot.snapshotId)
            journal.derivedRevision = 1
            return CleanedView(
                sessionId: snapshot.sessionId, snapshotId: snapshot.snapshotId,
                text: renderVerbatim(snapshot), journal: journal, mode: mode,
                backend: snapshot.backend,
                rulesVersion: "\(Self.pipelineVersion)/verbatim")
        case .clean:
            return cleanResolved(snapshot: snapshot, priorCandidates: priorCandidates)
        }
    }

    // MARK: Clean

    func cleanResolved(snapshot: TranscriptSnapshot, priorCandidates: [CorrectionCandidate]) -> CleanedView {
        var journal = EditJournal(sessionId: snapshot.sessionId, baseSnapshotId: snapshot.snapshotId)

        // 1. Propose.
        let fill = filler.apply(snapshot: snapshot)
        let res = resolver.resolve(snapshot: snapshot, priorCandidates: priorCandidates)
        journal.abstentions += fill.abstentions
        journal.abstentions += res.abstentions

        // 2. Validate filler + repair edits.
        let firstPass = validator.validate(fill.edits + res.edits, in: snapshot, dictionary: dictionary)
        var accepted: [ProposedEdit] = []
        for (edit, verdict) in firstPass {
            switch verdict {
            case .accept: accepted.append(edit)
            case .reject(let reason):
                journal.rejectedEdits.append(edit)
                journal.abstentions.append(Abstention(reason: .conflictingEdits, detail: "rejected \(edit.op): \(reason)", tokenIds: edit.targetTokenIds))
            }
        }

        // 3. Normalization / dictionary / formatting over kept tokens.
        let keptIdx = keptIndices(snapshot: snapshot, accepted: accepted)
        var extra: [ProposedEdit] = []
        extra += proposeNumberNormalizations(snapshot: snapshot, kept: keptIdx, claimed: Set(accepted.flatMap { $0.targetTokenIds }))
        if applyDictionary {
            extra += proposeDictionary(snapshot: snapshot, kept: keptIdx, claimed: Set(accepted.flatMap { $0.targetTokenIds } + extra.flatMap { $0.targetTokenIds }))
        }
        extra += proposeFormatting(snapshot: snapshot, kept: keptIdx, claimed: Set(accepted.flatMap { $0.targetTokenIds } + extra.flatMap { $0.targetTokenIds }))
        let secondPass = validator.validate(extra, in: snapshot, dictionary: dictionary)
        for (edit, verdict) in secondPass {
            switch verdict {
            case .accept: accepted.append(edit)
            case .reject(let reason):
                journal.rejectedEdits.append(edit)
                journal.abstentions.append(Abstention(reason: .conflictingEdits, detail: "rejected \(edit.op): \(reason)", tokenIds: edit.targetTokenIds))
            }
        }

        // 4. Render + preservation check with fallback.
        var renderAccepted = accepted
        var text = render(snapshot: snapshot, accepted: renderAccepted)
        if !verifyPreservation(snapshot: snapshot, accepted: renderAccepted, output: text) {
            // Drop repair/selection edits, keep safe deletions + normalization.
            renderAccepted = accepted.filter { $0.op == .deleteFiller || $0.op == .deleteRepeat || $0.op == .normalizeNumber || $0.op == .punctuation }
            text = render(snapshot: snapshot, accepted: renderAccepted)
            journal.abstentions.append(Abstention(reason: .ambiguousScope, detail: "preservation check failed; repairs dropped, filler-only output", tokenIds: []))
            if !verifyPreservation(snapshot: snapshot, accepted: renderAccepted, output: text) {
                renderAccepted = []
                text = renderVerbatim(snapshot)
                journal.abstentions.append(Abstention(reason: .missingEvidence, detail: "fallback to verbatim", tokenIds: []))
            }
        }

        journal.acceptedEdits = renderAccepted
        journal.candidates = res.candidates
        journal.derivedRevision = 1
        let rulesVersion = "\(Self.pipelineVersion)/\(CorrectionResolver.rulesVersion)+\(FillerRules.rulesVersion)+\(NumberNormalizer.ruleVersion)"
        return CleanedView(
            sessionId: snapshot.sessionId, snapshotId: snapshot.snapshotId,
            text: text, journal: journal, mode: .clean,
            backend: snapshot.backend, rulesVersion: rulesVersion)
    }

    // MARK: Proposal helpers

    func keptIndices(snapshot: TranscriptSnapshot, accepted: [ProposedEdit]) -> [Int] {
        let skipped = Set(accepted.flatMap { $0.targetTokenIds })
        return snapshot.tokens.indices.filter { !skipped.contains(snapshot.tokens[$0].id) }
    }

    func proposeNumberNormalizations(snapshot: TranscriptSnapshot, kept: [Int], claimed: Set<TokenID>) -> [ProposedEdit] {
        var out: [ProposedEdit] = []
        let keptSet = Set(kept)
        var i = 0
        let order = snapshot.tokens.indices.filter { keptSet.contains($0) }
        var k = 0
        while k < order.count {
            let idx = order[k]
            let t = snapshot.tokens[idx]
            let isNumWord = t.kind == .word && (NumberNormalizer.ones[t.normalized] != nil || NumberNormalizer.tens[t.normalized] != nil || NumberNormalizer.scales[t.normalized] != nil)
            // Hyphen inside a number phrase ("twenty-one").
            if isNumWord {
                var run = [idx]
                var j = k + 1
                while j < order.count {
                    let nj = order[j]
                    let nt = snapshot.tokens[nj]
                    // Allow hyphen joining number words.
                    if nt.kind == .punctuation && nt.text == "-" {
                        // Must be between number words: check next is num word.
                        if j + 1 < order.count {
                            let after = snapshot.tokens[order[j+1]]
                            if after.kind == .word && (NumberNormalizer.ones[after.normalized] != nil || NumberNormalizer.tens[after.normalized] != nil) {
                                run.append(nj)
                                j += 1
                                continue
                            }
                        }
                        break
                    }
                    if nt.kind == .word && (NumberNormalizer.ones[nt.normalized] != nil || NumberNormalizer.tens[nt.normalized] != nil || NumberNormalizer.scales[nt.normalized] != nil || nt.normalized == "and") {
                        run.append(nj); j += 1; continue
                    }
                    break
                }
                // Single-word guard: bare "one" after ordinals/articles stays.
                let words = run.map { snapshot.tokens[$0].normalized }.filter { $0 != "-" }
                if words == ["and"] || words.isEmpty { k = j; continue }
                if words.count == 1 && words[0] == "one" {
                    let prevKept: String? = {
                        guard k > 0 else { return nil }
                        return snapshot.tokens[order[k-1]].normalized
                    }()
                    if ["the","a","an","second","first","number","version","one"].contains(prevKept ?? "") {
                        k = j; continue
                    }
                }
                if words.count == 1 && words[0] == "and" { k = j; continue }
                let ids = run.map { snapshot.tokens[$0].id }
                if ids.contains(where: { claimed.contains($0) }) { k = j; continue }
                if let derived = numbers.derivedText(sourceWords: run.map { snapshot.tokens[$0].text.lowercased() }) {
                    // Skip if already digits (single digit token handled as number kind, not here).
                    out.append(ProposedEdit(
                        snapshotId: snapshot.snapshotId, snapshotRevision: snapshot.revision,
                        op: .normalizeNumber, targetTokenIds: ids,
                        reason: "number normalization '\(words.joined(separator: " "))' -> \(derived)",
                        ruleVersion: NumberNormalizer.ruleVersion, replacementText: derived,
                        sourceDescription: "number-rule:\(NumberNormalizer.ruleVersion)"))
                }
                k = j
                continue
            }
            _ = i
            k += 1
        }
        return out
    }

    func proposeDictionary(snapshot: TranscriptSnapshot, kept: [Int], claimed: Set<TokenID>) -> [ProposedEdit] {
        if dictionary.entries.isEmpty { return [] }
        var out: [ProposedEdit] = []
        let keptSet = Set(kept)
        let order = snapshot.tokens.indices.filter { keptSet.contains($0) }
        let maxKeyLen = dictionary.entries.keys.map { $0.split(separator: " ").count }.max() ?? 1
        var k = 0
        while k < order.count {
            var matched: (len: Int, written: String)? = nil
            for len in stride(from: min(maxKeyLen, order.count - k), through: 1, by: -1) {
                let slice = (k ..< k + len).map { snapshot.tokens[order[$0]] }
                guard slice.allSatisfy({ $0.kind == .word }) else { continue }
                let key = slice.map { $0.normalized }.joined(separator: " ")
                if let written = dictionary.writtenForm(forSpoken: key) {
                    matched = (len, written); break
                }
            }
            if let m = matched {
                let ids = (k ..< k + m.len).map { snapshot.tokens[order[$0]].id }
                if !ids.contains(where: { claimed.contains($0) }) {
                    // Only substitute when the surface actually differs.
                    let surface = (k ..< k + m.len).map { snapshot.tokens[order[$0]].text }.joined(separator: " ")
                    if surface != m.written {
                        out.append(ProposedEdit(
                            snapshotId: snapshot.snapshotId, snapshotRevision: snapshot.revision,
                            op: .dictionarySubstitution, targetTokenIds: ids,
                            reason: "confirmed dictionary '\(surface)' -> '\(m.written)'",
                            ruleVersion: "omil-dict-\(dictionary.version)", replacementText: m.written,
                            sourceDescription: "dictionary:v\(dictionary.version)"))
                    }
                }
                k += m.len
            } else {
                k += 1
            }
        }
        return out
    }

    func proposeFormatting(snapshot: TranscriptSnapshot, kept: [Int], claimed: Set<TokenID>) -> [ProposedEdit] {
        var out: [ProposedEdit] = []
        let keptSet = Set(kept)
        let order = snapshot.tokens.indices.filter { keptSet.contains($0) }
        // Map order-position -> token index for contiguous command detection.
        var k = 0
        while k < order.count {
            let idx = order[k]
            let w = snapshot.tokens[idx].normalized
            func contiguous(_ words: [String]) -> [Int]? {
                guard k + words.count <= order.count else { return nil }
                for o in 0 ..< words.count {
                    let ti = order[k + o]
                    // Must be contiguous in the snapshot (no gaps from deletions).
                    if o > 0 && ti != order[k + o - 1] + 1 { return nil }
                    if snapshot.tokens[ti].normalized != words[o] { return nil }
                }
                return (0 ..< words.count).map { order[k + $0] }
            }
            if let span = contiguous(["new", "line"]) {
                out.append(fmtEdit(snapshot: snapshot, span: span, text: "\n", name: "new line", claimed: claimed))
                k += 2; continue
            }
            if let span = contiguous(["new", "paragraph"]) {
                out.append(fmtEdit(snapshot: snapshot, span: span, text: "\n\n", name: "new paragraph", claimed: claimed))
                k += 2; continue
            }
            if contiguous(["bullet", "point"]) != nil, let span = contiguous(["bullet", "point"]) {
                out.append(fmtEdit(snapshot: snapshot, span: span, text: "\n• ", name: "bullet", claimed: claimed))
                k += 2; continue
            }
            _ = w
            k += 1
        }
        return out.filter {
            // Drop edits whose targets were already claimed.
            !Set($0.targetTokenIds).isSubset(of: claimed) || $0.targetTokenIds.isEmpty
        }
    }

    func fmtEdit(snapshot: TranscriptSnapshot, span: [Int], text: String, name: String, claimed: Set<TokenID>) -> ProposedEdit {
        ProposedEdit(
            snapshotId: snapshot.snapshotId, snapshotRevision: snapshot.revision,
            op: .formattingCommand, targetTokenIds: span.map { snapshot.tokens[$0].id },
            reason: "formatting command '\(name)'", ruleVersion: FormattingCommands.rulesVersion,
            replacementText: text, sourceDescription: "format:\(name)")
    }

    // MARK: Rendering

    /// Verbatim: no cleanup beyond trimming, whitespace collapse,
    /// sentence casing, and terminal punctuation.
    func renderVerbatim(_ snapshot: TranscriptSnapshot) -> String {
        let raw = snapshot.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return "" }
        return finishPunctuation(sentenceCase(collapseWhitespace(raw)))
    }

    func render(snapshot: TranscriptSnapshot, accepted: [ProposedEdit]) -> String {
        let tokens = snapshot.tokens
        let skippedIds = Set(accepted.flatMap { $0.targetTokenIds })
        let skippedIdx = Set(tokens.indices.filter { skippedIds.contains(tokens[$0].id) })
        let skippedKinds: [Int: TokenKind] = Dictionary(uniqueKeysWithValues: skippedIdx.map { ($0, tokens[$0].kind) })

        // Substitution map: first index of span -> replacement; rest skipped.
        var sub: [Int: String] = [:]
        // Anchor map: anchor index -> replacement (selectCandidate re-emission).
        var anchors: [Int: String] = [:]
        for edit in accepted {
            let idxs = edit.targetTokenIds.compactMap { snapshot.indexOf(id: $0) }.sorted()
            switch edit.op {
            case .normalizeNumber, .dictionarySubstitution, .formattingCommand:
                if let first = idxs.first, let rep = edit.replacementText {
                    sub[first] = rep
                }
            case .selectCandidate:
                if let a = edit.replacementAnchor, let rep = edit.replacementText {
                    anchors[a] = rep
                }
            default: break
            }
        }

        // Comma-drop: kept comma adjacent to a skipped cue/filler token.
        // Period-drop: kept sentence boundary adjacent to a skipped cue or to
        // a token deleted as a repair reparandum ("Make it 42. Sorry, 21."
        // must not leave "Make it. 21."). Filler-adjacent periods are kept.
        let repairDeletedIdx: Set<Int> = Set(accepted.flatMap { edit -> [Int] in
            switch edit.op {
            case .replaceFromSource, .selectCandidate:
                return edit.targetTokenIds.compactMap { snapshot.indexOf(id: $0) }
            default:
                return []
            }
        })
        var dropComma = Set<Int>()
        var dropSentence = Set<Int>()
        for i in tokens.indices where tokens[i].kind == .punctuation {
            if skippedIdx.contains(i) { continue }
            let leftSkippedCue = i > 0 && skippedIdx.contains(i-1) && (skippedKinds[i-1] == .cue || skippedKinds[i-1] == .filler)
            let rightSkippedCue = i + 1 < tokens.count && skippedIdx.contains(i+1) && (skippedKinds[i+1] == .cue || skippedKinds[i+1] == .filler)
            if tokens[i].text == "," {
                if leftSkippedCue || rightSkippedCue { dropComma.insert(i) }
                continue
            }
            if tokens[i].text == "." || tokens[i].text == "?" || tokens[i].text == "!" {
                let adj: [Int] = [i - 1, i + 1].filter { $0 >= 0 && $0 < tokens.count }
                let cueAdj = adj.contains { skippedIdx.contains($0) && skippedKinds[$0] == .cue }
                let repAdj = adj.contains { repairDeletedIdx.contains($0) }
                if cueAdj || repAdj { dropSentence.insert(i) }
            }
        }

        var parts: [String] = []
        var lastEmitted: String? = nil
        for i in tokens.indices {
            // Anchors and substitutions re-emit at skipped positions, so they
            // must be checked BEFORE the deletion skip.
            if let a = anchors[i] {
                parts.append(a)
                lastEmitted = a
                continue
            }
            if skippedIdx.contains(i) && sub[i] == nil {
                continue // deleted
            }
            if dropComma.contains(i) || dropSentence.contains(i) { continue }
            if let s = sub[i] {
                if !s.isEmpty {
                    parts.append(s)
                    lastEmitted = s
                }
                continue
            }
            // Other indices of a substitution span are skipped targets already.
            let t = tokens[i].text
            if (t == "." || t == "?" || t == "!"), let l = lastEmitted, l == "." || l == "?" || l == "!" {
                continue // collapse doubled sentence boundaries from deletions
            }
            parts.append(t)
            lastEmitted = t
        }
        let joined = joinTokens(parts)
        if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        return finishPunctuation(sentenceCase(joined))
    }

    func joinTokens(_ parts: [String]) -> String {
        var out = ""
        var inQuote = false
        var suppressSpace = false
        for p in parts {
            if p == "\n" || p == "\n\n" || p.hasPrefix("\n•") {
                out += p
                suppressSpace = true
                continue
            }
            if p == "\"" || p == "\u{201C}" || p == "\u{201D}" {
                if inQuote {
                    out += p // closing quote: no preceding space
                    inQuote = false
                    suppressSpace = false
                } else {
                    if !out.isEmpty && !out.hasSuffix(" ") && !out.hasSuffix("\n") { out += " " }
                    out += p
                    inQuote = true
                    suppressSpace = true // no space after opening quote
                }
                continue
            }
            if out.isEmpty || out.hasSuffix("\n") || out.hasSuffix(" ") || suppressSpace {
                out += p
                suppressSpace = false
                continue
            }
            if isPunctStr(p) {
                out += p
            } else {
                out += " " + p
            }
            suppressSpace = false
        }
        // Cleanup artifacts.
        var s = out
        s = s.replacingOccurrences(of: " \n", with: "\n")
        s = s.replacingOccurrences(of: "\n ", with: "\n")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        // Drop empty ", ," remnants and leading punctuation.
        s = s.replacingOccurrences(of: ", ,", with: ",")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "^[,;:\\s]+", with: "", options: .regularExpression)
        return s
    }

    func isPunctStr(_ s: String) -> Bool {
        s.count == 1 && s.rangeOfCharacter(from: .alphanumerics) == nil && s != "\n"
    }

    func collapseWhitespace(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func sentenceCase(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var chars = Array(s)
        var out = ""
        var capitalizeNext = true
        for ch in chars {
            if capitalizeNext && ch.isLetter {
                out += String(ch).uppercased()
                capitalizeNext = false
            } else {
                out.append(ch)
            }
            if ".?!:\n".contains(ch) { capitalizeNext = true }
        }
        _ = chars
        return out
    }

    func finishPunctuation(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return t }
        if ".?!".contains(t.last!) { return t }
        // A closing quote after sentence punctuation needs no extra period.
        if t.last == "\"" || t.last == "\u{201D}" {
            let inner = t.dropLast().trimmingCharacters(in: .whitespaces)
            if let last = inner.last, ".?!".contains(last) { return t }
        }
        return t + "."
    }

    // MARK: Preservation

    /// Every kept content token (or its approved derived value) must appear in
    /// the output in order. This is the check that rejects e.g. "Send 42." for
    /// "Do not send 42. Send 21."-style over-editing.
    func verifyPreservation(snapshot: TranscriptSnapshot, accepted: [ProposedEdit], output: String) -> Bool {
        let tokens = snapshot.tokens
        let skippedIds = Set(accepted.flatMap { $0.targetTokenIds })
        var expected: [String] = []
        var sub: [Int: String] = [:]
        for edit in accepted {
            let idxs = edit.targetTokenIds.compactMap { snapshot.indexOf(id: $0) }.sorted()
            switch edit.op {
            case .normalizeNumber, .dictionarySubstitution:
                if let first = idxs.first, let rep = edit.replacementText { sub[first] = rep }
            case .formattingCommand:
                if let first = idxs.first { sub[first] = "" } // newline, not a word
            case .selectCandidate:
                if let a = edit.replacementAnchor, let rep = edit.replacementText { sub[a] = rep }
            default: break
            }
        }
        for i in tokens.indices {
            let t = tokens[i]
            if skippedIds.contains(t.id) && sub[i] == nil { continue }
            if let s = sub[i] {
                if !s.isEmpty { expected.append(s.lowercased()) }
                continue
            }
            if t.kind == .word || t.kind == .number {
                expected.append(t.text.lowercased())
            }
        }
        // Output words: lowercase, strip punctuation, expand \n.
        let outWords = output.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var oi = 0
        for e in expected {
            let eParts = e.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            for part in eParts {
                var found = false
                while oi < outWords.count {
                    if outWords[oi] == part { found = true; oi += 1; break }
                    oi += 1
                }
                if !found { return false }
            }
        }
        return true
    }
}
