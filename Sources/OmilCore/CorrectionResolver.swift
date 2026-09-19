import Foundation

// MARK: - CorrectionResolver
//
// Deterministic repair resolution over an immutable snapshot.
// Rendering model: repair values STAY IN PLACE; edits delete the reparandum,
// the cue, and redundant restatements (carrier verbs, scoped subject mentions).
// Reversals (selectCandidate) additionally re-emit the selected value at the
// reverted position. Rules version is recorded on every edit.

public struct CorrectionResolver: Sendable {
    public static let rulesVersion = "omil-corr-1"
    private let numbers = NumberNormalizer()

    public init() {}

    public struct Resolution: Sendable {
        public var edits: [ProposedEdit]
        public var abstentions: [Abstention]
        public var candidates: [CorrectionCandidate]
    }

    /// Resolve repairs in `snapshot`, chaining onto `priorCandidates`
    /// (retained across pauses / finalized ASR segments in the session).
    /// Initial content values are seeded as candidates so later reversals
    /// ("keep the original") can select them.
    public func resolve(
        snapshot: TranscriptSnapshot,
        priorCandidates: [CorrectionCandidate] = []
    ) -> Resolution {
        var edits: [ProposedEdit] = []
        var abstentions: [Abstention] = []
        var candidates: [CorrectionCandidate] = []
        // Seed initial values ONLY when there is no history: the snapshot's own
        // values become candidates (c0) that later cues can supersede/select.
        // With prior history (session re-resolution), reuse it verbatim so IDs
        // stay stable across revisions.
        if priorCandidates.isEmpty {
            candidates = seedCandidates(snapshot: snapshot)
        } else {
            candidates = priorCandidates
        }
        let tokens = snapshot.tokens

        let quoted = quotedRanges(tokens: tokens)
        func isQuoted(_ idx: Int) -> Bool {
            quoted.contains(where: { $0.contains(idx) })
        }

        // ---- 1. Full-restart cues ("scratch that") first (widest scope). ----
        for cue in findCueSpans(tokens: tokens, kinds: [.scratchThat]) {
            if cue.range.contains(where: isQuoted) { continue }
            let leftBound = sentenceStart(before: cue.range.lowerBound, tokens: tokens)
            let rightEnd = sentenceEnd(after: cue.range.upperBound, tokens: tokens)
            let reparandum = contentRange(leftBound ..< cue.range.lowerBound, tokens: tokens)
            let repair = contentRange(cue.range.upperBound ..< rightEnd, tokens: tokens)
            guard !reparandum.isEmpty, !repair.isEmpty else {
                abstentions.append(Abstention(reason: .missingEvidence, detail: "scratch-that without full spans", tokenIds: ids(tokens, cue.range)))
                continue
            }
            if containsNegation(tokens, reparandum) && !containsNegation(tokens, repair) {
                abstentions.append(Abstention(reason: .protectedContent, detail: "restart would drop negation", tokenIds: ids(tokens, reparandum)))
                continue
            }
            let repairText = repair.map { tokens[$0].text }.joined(separator: " ")
            let slot = slotKey(for: repair, tokens: tokens, clauseIndex: 0)
            let editId = EditID()
            let cand = CorrectionCandidate(slotKey: slot, valueText: repairText, sourceTokenIds: ids(tokens, repair), supersedes: latestCandidate(for: slot, in: candidates)?.candidateId, editId: editId)
            let targets = reparandum.map { tokens[$0].id } + cue.range.map { tokens[$0].id }
            edits.append(ProposedEdit(
                editId: editId, snapshotId: snapshot.snapshotId, snapshotRevision: snapshot.revision,
                op: .replaceFromSource, targetTokenIds: targets,
                evidenceTokenIds: ids(tokens, repair) + ids(tokens, cue.range),
                candidateId: cand.candidateId, reason: "full restart via scratch-that",
                ruleVersion: Self.rulesVersion, replacementText: nil,
                sourceDescription: "repair-span:\(repair.first ?? -1)-\(repair.last ?? -1)"))
            candidates.append(cand)
        }
        if !edits.isEmpty {
            return Resolution(edits: edits, abstentions: abstentions, candidates: candidates)
        }

        // ---- 2. Ordinary cue repairs first, so later "keep" reversals can
        // select the values these repairs produce. ----
        var consumed = Set<Int>()
        for cue in findCueSpans(tokens: tokens, kinds: [.repair]) {
            if cue.range.contains(where: isQuoted) { continue }
            if cue.range.contains(where: { consumed.contains($0) }) { continue }
            let lookahead = contentRange(cue.range.upperBound ..< min(cue.range.upperBound + 6, tokens.count), tokens: tokens)
            if isMetaLanguage(tokens, lookahead) {
                abstentions.append(Abstention(reason: .quotedContent, detail: "repair talks about words themselves", tokenIds: ids(tokens, cue.range)))
                continue
            }
            guard let found = findRepair(cue: cue.range, tokens: tokens, consumed: consumed) else {
                abstentions.append(Abstention(reason: .weakCue, detail: "cue without compatible reparandum/repair", tokenIds: ids(tokens, cue.range)))
                continue
            }
            if isLiteralUse(tokens, found.reparandum) {
                abstentions.append(Abstention(reason: .quotedContent, detail: "literal word use", tokenIds: ids(tokens, found.reparandum)))
                continue
            }
            if containsNegation(tokens, found.reparandum) && !containsNegation(tokens, found.repair) {
                abstentions.append(Abstention(reason: .protectedContent, detail: "repair would drop negation", tokenIds: ids(tokens, found.reparandum)))
                continue
            }
            let valueText = normalizedValueText(tokens, found.replacement)
            let slot = slotKey(for: found.replacement, tokens: tokens, clauseIndex: clauseIndex(of: found.reparandum.first ?? 0, tokens: tokens))
            let prev = latestCandidate(for: slot, in: candidates)
            let editId = EditID()
            let cand = CorrectionCandidate(slotKey: slot, valueText: valueText, sourceTokenIds: ids(tokens, found.replacement), supersedes: prev?.candidateId, editId: editId)
            let targets = found.reparandum.map { tokens[$0].id } + cue.range.map { tokens[$0].id } + found.redundantInRepair.map { tokens[$0].id }
            edits.append(ProposedEdit(
                editId: editId, snapshotId: snapshot.snapshotId, snapshotRevision: snapshot.revision,
                op: .replaceFromSource, targetTokenIds: targets,
                evidenceTokenIds: ids(tokens, found.repair) + ids(tokens, cue.range),
                candidateId: cand.candidateId, reason: "cue '\(cue.label)' replaces \(describe(tokens, found.reparandum)) with \(describe(tokens, found.replacement))",
                ruleVersion: Self.rulesVersion, replacementText: nil,
                sourceDescription: "repair-span:\(found.repair.first ?? -1)-\(found.repair.last ?? -1)"))
            candidates.append(cand)
            consumed.formUnion(Set(cue.range))
            consumed.formUnion(Set(found.reparandum))
            consumed.formUnion(Set(found.replacement))
            consumed.formUnion(Set(found.redundantInRepair))
        }

        // ---- 3. "keep" reversals select earlier candidates. ----
        for cue in findCueSpans(tokens: tokens, kinds: [.keep]) {
            if cue.range.contains(where: isQuoted) { continue }
            // Absorb adjacent "no"/"wait" cue tokens ("no no keep it 42").
            var absorb = cue.range.lowerBound - 1
            var absorbed: [Int] = []
            while absorb >= 0 {
                if tokens[absorb].kind == .punctuation { absorb -= 1; continue }
                if tokens[absorb].kind == .cue && (tokens[absorb].normalized == "no" || tokens[absorb].normalized == "wait") && !consumed.contains(absorb) {
                    absorbed.append(absorb); absorb -= 1; continue
                }
                break
            }
            if cue.range.contains(where: { consumed.contains($0) }) { continue }
            if cue.range.contains(where: isQuoted) { continue }
            if cue.label == "go back" {
                abstentions.append(Abstention(reason: .ambiguousScope, detail: "go-back reference is ambiguous; preserved", tokenIds: ids(tokens, cue.range)))
                continue
            }
            let valueRange = repairValueRange(after: cue.range.upperBound, tokens: tokens)
            // Slot + selection.
            let slotOfLatest = latestCandidate(in: candidates)?.slotKey
            var selected: CorrectionCandidate?
            var isNovelValue = false
            if let vr = valueRange {
                let vtext = normalizedValueText(Array(tokens[vr]))
                if let match = candidates.last(where: { normEq($0.valueText, vtext) }) {
                    selected = match
                } else if let slot = slotOfLatest {
                    // Novel value after keep ("keep it 99"): treat as a new
                    // correction, not a reversal. Fall through to repair logic.
                    isNovelValue = true
                    _ = slot
                }
            } else {
                // "keep the original": earliest candidate of the latest slot.
                if let latest = latestCandidate(in: candidates) {
                    selected = candidates.first(where: { $0.slotKey == latest.slotKey })
                }
            }
            if isNovelValue, let vr = valueRange {
                // New correction via keep-cue: replace current value with novel one.
                let slot = slotOfLatest ?? "clause0:number"
                if let current = latestCandidate(for: slot, in: candidates),
                   let curIdx = current.sourceTokenIds.compactMap({ snapshot.indexOf(id: $0) }).first,
                   snapshot.tokens.indices.contains(curIdx), !consumed.contains(curIdx) {
                    let editId = EditID()
                    let cand = CorrectionCandidate(slotKey: slot, valueText: normalizedValueText(Array(tokens[vr])), sourceTokenIds: ids(tokens, vr), supersedes: current.candidateId, editId: editId)
                    var novelTargets = [tokens[curIdx].id] + cue.range.map { tokens[$0].id }
                    novelTargets += absorbed.map { tokens[$0].id }
                    let targets = novelTargets
                    edits.append(ProposedEdit(
                        editId: editId, snapshotId: snapshot.snapshotId, snapshotRevision: snapshot.revision,
                        op: .replaceFromSource, targetTokenIds: targets,
                        evidenceTokenIds: ids(tokens, vr) + ids(tokens, cue.range),
                        candidateId: cand.candidateId, dependsOn: [],
                        reason: "keep-cue introduces novel value", ruleVersion: Self.rulesVersion,
                        replacementText: nil, sourceDescription: "repair-span:\(vr.lowerBound)-\(vr.upperBound)"))
                    // Hmm: repair value stays in place but current value also stays
                    // -> would duplicate. Mark repair value redundant instead:
                    // fallthrough handled below by treating vr as redundant.
                    candidates.append(cand)
                    // Repair value tokens stay; current value must be removed:
                    // targets already include current value token. But repair value
                    // "99" stays in place AFTER the keep cue -> "... 21 keep it 99"
                    // minus targets -> "... 99"? Walk: ...21(del) keep(del) it(del) 99(kept) -> good.
                    consumed.formUnion(vr)
                    continue
                }
            }
            guard let sel = selected else {
                abstentions.append(Abstention(reason: .missingEvidence, detail: "keep without candidate history", tokenIds: ids(tokens, cue.range)))
                continue
            }
            // Reverted position: latest candidate's value tokens in THIS snapshot.
            // These may overlap an earlier repair's kept value; that overlap is
            // expressed through dependsOn (validator permits shared targets
            // across a dependency edge), so do NOT filter by `consumed` here.
            let revertedIdxs: [Int] = {
                if let latest = latestCandidate(for: sel.slotKey, in: candidates) {
                    return latest.sourceTokenIds.compactMap { snapshot.indexOf(id: $0) }.sorted()
                }
                return []
            }()
            var targets = cue.range.map { tokens[$0].id }
            // Absorbed "no"/"wait" cue tokens belong to the reversal utterance.
            targets += absorbed.map { tokens[$0].id }
            consumed.formUnion(Set(absorbed))
            if let vr = valueRange {
                // Repeated reference value is redundant (it names the selection).
                targets += vr.map { tokens[$0].id }
                consumed.formUnion(vr)
            }
            var anchor: Int? = nil
            var deps: [EditID] = []
            if !revertedIdxs.isEmpty {
                targets += revertedIdxs.map { tokens[$0].id }
                anchor = revertedIdxs.first
                // The edit that produced the reverted value is a dependency.
                if let producer = edits.first(where: { $0.candidateId == latestCandidate(for: sel.slotKey, in: candidates)?.candidateId }) {
                    deps = [producer.editId]
                }
            }
            let editId = EditID()
            let newCand = CorrectionCandidate(slotKey: sel.slotKey, valueText: sel.valueText, sourceTokenIds: sel.sourceTokenIds, supersedes: latestCandidate(for: sel.slotKey, in: candidates)?.candidateId, editId: editId)
            let edit = ProposedEdit(
                editId: editId, snapshotId: snapshot.snapshotId, snapshotRevision: snapshot.revision,
                op: .selectCandidate, targetTokenIds: targets,
                evidenceTokenIds: sel.sourceTokenIds + ids(tokens, cue.range),
                candidateId: sel.candidateId, dependsOn: deps,
                reason: "reversal to earlier candidate '\(sel.valueText)'",
                ruleVersion: Self.rulesVersion, replacementText: sel.valueText,
                sourceDescription: "candidate:\(sel.candidateId)",
                replacementAnchor: anchor)
            edits.append(edit)
            candidates.append(newCand)
            consumed.formUnion(Set(cue.range))
            consumed.formUnion(Set(revertedIdxs))
        }

        return Resolution(edits: edits, abstentions: abstentions, candidates: candidates)
    }

    // MARK: - Candidate seeding

    /// Seed one candidate per value slot from source content so later cues can
    /// supersede/select them. Seeds carry the source span as evidence.
    func seedCandidates(snapshot: TranscriptSnapshot) -> [CorrectionCandidate] {
        var out: [CorrectionCandidate] = []
        let tokens = snapshot.tokens
        var i = 0
        var clause = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.kind == .punctuation && (t.text == "." || t.text == "?" || t.text == "!") { clause += 1; i += 1; continue }
            if t.kind == .number {
                let slot: String
                if let subj = subjectHint(near: i, tokens: tokens) { slot = "\(subj):number" }
                else { slot = "clause\(clause):number" }
                if out.last(where: { $0.slotKey == slot }) == nil {
                    out.append(CorrectionCandidate(slotKey: slot, valueText: t.text, sourceTokenIds: [t.id], editId: EditID()))
                }
                i += 1; continue
            }
            if t.kind == .word && Self.days.contains(t.normalized) {
                let slot = "clause\(clause):day"
                if out.last(where: { $0.slotKey == slot }) == nil {
                    out.append(CorrectionCandidate(slotKey: slot, valueText: t.text, sourceTokenIds: [t.id], editId: EditID()))
                }
                i += 1; continue
            }
            // Number-word runs.
            if t.kind == .word && (NumberNormalizer.ones[t.normalized] != nil || NumberNormalizer.tens[t.normalized] != nil) {
                var j = i + 1
                while j < tokens.count && (NumberNormalizer.ones[tokens[j].normalized] != nil || NumberNormalizer.tens[tokens[j].normalized] != nil || NumberNormalizer.scales[tokens[j].normalized] != nil) { j += 1 }
                let slot = "clause\(clause):number"
                if out.last(where: { $0.slotKey == slot }) == nil {
                    out.append(CorrectionCandidate(slotKey: slot, valueText: tokens[i..<j].map { $0.text }.joined(separator: " "), sourceTokenIds: (i..<j).map { tokens[$0].id }, editId: EditID()))
                }
                i = j; continue
            }
            i += 1
        }
        return out
    }

    // MARK: - Cue inventory

    enum CueKind: Hashable { case repair, keep, scratchThat }

    struct CueSpan {
        let range: Range<Int>
        let label: String
        let kind: CueKind
    }

    func findCueSpans(tokens: [Token], kinds: Set<CueKind>) -> [CueSpan] {
        var out: [CueSpan] = []
        let n = tokens.map { $0.normalized }
        var i = 0
        func isCueToken(_ k: Int) -> Bool { tokens[k].kind == .cue }
        while i < n.count {
            if kinds.contains(.scratchThat), i + 1 < n.count, n[i] == "scratch", n[i+1] == "that", isCueToken(i) {
                out.append(CueSpan(range: i..<i+2, label: "scratch that", kind: .scratchThat)); i += 2; continue
            }
            if kinds.contains(.keep), n[i] == "keep" {
                if i + 2 < n.count, n[i+1] == "the", n[i+2] == "original" {
                    out.append(CueSpan(range: i..<i+3, label: "keep the original", kind: .keep)); i += 3; continue
                }
                if i + 1 < n.count, n[i+1] == "it" {
                    out.append(CueSpan(range: i..<i+2, label: "keep it", kind: .keep)); i += 2; continue
                }
                out.append(CueSpan(range: i..<i+1, label: "keep", kind: .keep)); i += 1; continue
            }
            if kinds.contains(.keep), i + 1 < n.count, n[i] == "go", n[i+1] == "back" {
                var end = i + 2
                while end < n.count && !isSentenceBoundary(tokens[end]) { end += 1 }
                out.append(CueSpan(range: i..<end, label: "go back", kind: .keep)); i = end; continue
            }
            if kinds.contains(.repair) {
                if i + 1 < n.count, n[i] == "i", n[i+1] == "mean", isCueToken(i) {
                    out.append(CueSpan(range: i..<i+2, label: "i mean", kind: .repair)); i += 2; continue
                }
                if i + 1 < n.count, n[i] == "excuse", n[i+1] == "me" {
                    out.append(CueSpan(range: i..<i+2, label: "excuse me", kind: .repair)); i += 2; continue
                }
                if n[i] == "sorry" && isCueToken(i) {
                    out.append(CueSpan(range: i..<i+1, label: "sorry", kind: .repair)); i += 1; continue
                }
                if (n[i] == "actually" || n[i] == "rather" || n[i] == "wait") && isCueToken(i) {
                    out.append(CueSpan(range: i..<i+1, label: n[i], kind: .repair)); i += 1; continue
                }
                if n[i] == "no" && tokens[i].kind == .cue {
                    var end = i + 1
                    while end < n.count && tokens[end].normalized == "no" && tokens[end].kind == .cue { end += 1 }
                    var e2 = end
                    while e2 < n.count && isPunct(tokens[e2]) { e2 += 1 }
                    if e2 < n.count && tokens[e2].normalized == "no" && tokens[e2].kind == .cue {
                        end = e2 + 1
                        while end < n.count && tokens[end].normalized == "no" { end += 1 }
                    }
                    out.append(CueSpan(range: i..<end, label: "no", kind: .repair)); i = end; continue
                }
            }
            i += 1
        }
        return out
    }

    // MARK: - Repair search

    struct FoundRepair {
        /// Left span to delete.
        let reparandum: [Int]
        /// Full right span (kept in place).
        let repair: [Int]
        /// Redundant mentions inside repair to also delete (carrier verbs,
        /// scoped subject restatements).
        let redundantInRepair: [Int]
        /// Sub-span of repair carrying the new value (for candidates/slots).
        let replacement: [Int]
    }

    func findRepair(cue: Range<Int>, tokens: [Token], consumed: Set<Int>) -> FoundRepair? {
        var rEnd = cue.upperBound
        while rEnd < tokens.count && isPunct(tokens[rEnd]) { rEnd += 1 }
        var rStop = rEnd
        while rStop < tokens.count {
            if tokens[rStop].kind == .cue { break }
            if isSentenceBoundary(tokens[rStop]) { break }
            if consumed.contains(rStop) { break }
            rStop += 1
        }
        let repair = contentRange(rEnd ..< rStop, tokens: tokens)
        if repair.isEmpty { return nil }
        if tokens[cue.lowerBound].normalized == "wait", repair.count <= 3,
           repair.map({ tokens[$0].normalized }).contains("keep") { return nil }

        // Scoped repair: subject restated in repair.
        if let scoped = scopedReparandum(cue: cue, repair: repair, tokens: tokens) {
            return scoped
        }

        let rtype = repairType(repair, tokens: tokens)
        // Left window: back to sentence start / previous cue.
        var lStart = cue.lowerBound - 1
        while lStart >= 0 && isPunct(tokens[lStart]) { lStart -= 1 }
        var lo = lStart
        while lo >= 0 {
            if isSentenceBoundary(tokens[lo]) { lo += 1; break }
            if tokens[lo].kind == .cue { lo += 1; break }
            if consumed.contains(lo) { lo += 1; break }
            lo -= 1
        }
        lo = max(0, lo)
        let window = contentRange(lo ..< cue.lowerBound, tokens: tokens).filter { !consumed.contains($0) }
        guard !window.isEmpty else { return nil }
        switch rtype {
        case .number:
            guard let run = nearestNumberRun(in: window, tokens: tokens) else { return nil }
            return FoundRepair(reparandum: Array(run), repair: repair, redundantInRepair: [], replacement: repair)
        case .day:
            guard let run = nearestDayRun(in: window, tokens: tokens) else { return nil }
            return FoundRepair(reparandum: Array(run), repair: repair, redundantInRepair: [], replacement: repair)
        case .name:
            if let run = nearestNameRun(in: window, tokens: tokens, repair: repair) {
                var redundant: [Int] = []
                var replacement = repair
                if let carrier = carrierPrefix(reparandum: run, repair: repair, tokens: tokens) {
                    redundant = carrier
                    replacement = Array(repair.dropFirst(carrier.count))
                }
                return FoundRepair(reparandum: Array(run), repair: repair, redundantInRepair: redundant, replacement: replacement)
            }
            return nil
        case .phrase:
            // Multi-word, non-name repairs are ambiguous ("I am sorry about
            // the delay") unless they structurally mirror the left clause via
            // a restated carrier verb ("call Pam" after "call Sam") or an
            // exact shared tail with one differing value ("jane at example
            // dot com" after "john at example dot com").
            if repair.count <= 4, let first = repair.first, Self.carriers.contains(tokens[first].normalized) {
                let leftHasVerb = window.contains { tokens[$0].normalized == tokens[first].normalized }
                if leftHasVerb, let run = nearestNameRun(in: window, tokens: tokens, repair: repair) {
                    return FoundRepair(reparandum: run, repair: repair, redundantInRepair: [first], replacement: Array(repair.dropFirst()))
                }
            }
            if let aligned = structuralAlignment(repair: repair, window: window, tokens: tokens) {
                return aligned
            }
            return nil
        }
    }

    /// Exact-tail mirroring: repair = [newValue] + tail where tail (2+ words)
    /// occurs contiguously in the left window preceded by a single differing
    /// word. The whole left span (value + tail) is the reparandum; the repair
    /// stays in place. Returns nil unless the alignment is exact.
    func structuralAlignment(repair: [Int], window: [Int], tokens: [Token]) -> FoundRepair? {
        guard repair.count >= 3 && repair.count <= 7 else { return nil }
        let rwords = repair.map { tokens[$0].normalized }
        let wwords = window.map { tokens[$0].normalized }
        // Value must be a plain word (not a function word).
        let value = rwords[0]
        let function: Set<String> = ["the","a","an","to","it","for","and","or","of","in","on","is","are","was","i","you","please","just","no","about","with","at"]
        guard tokens[repair[0]].kind == .word && !function.contains(value) else { return nil }
        for suffixLen in stride(from: min(4, repair.count - 1), through: 2, by: -1) {
            guard repair.count == suffixLen + 1 else { continue }
            let tail = Array(rwords[1...])
            // Find tail contiguously in window.
            for s in 0 ... max(0, wwords.count - tail.count) {
                guard Array(wwords[s ..< s + tail.count]) == tail else { continue }
                // Immediate predecessor: the single differing word.
                guard s >= 1 else { continue }
                let pred = window[s - 1]
                guard (tokens[pred].kind == .word || tokens[pred].kind == .number),
                      tokens[pred].normalized != value else { continue }
                // Full left span (predecessor + tail) is the reparandum.
                let reparandum = Array(window[(s - 1) ..< s + tail.count])
                return FoundRepair(
                    reparandum: reparandum, repair: repair,
                    redundantInRepair: [], replacement: repair)
            }
        }
        return nil
    }

    static let carriers: Set<String> = ["call", "send", "email", "text", "schedule", "book"]

    enum RepairType { case number, day, name, phrase }

    func repairType(_ repair: [Int], tokens: [Token]) -> RepairType {
        let kept = repair.map { tokens[$0] }
        if let first = kept.first {
            if first.kind == .number { return .number }
            if NumberNormalizer.ones[first.normalized] != nil || NumberNormalizer.tens[first.normalized] != nil { return .number }
        }
        // Scoped restatement "Bob 24": name + value -> value type decides.
        if kept.count >= 2 && isNameToken(kept[0]) {
            let rest = Array(repair.dropFirst())
            let sub = repairType(rest, tokens: tokens)
            switch sub {
            case .number, .day: return sub
            default: break
            }
        }
        if kept.contains(where: { Self.days.contains($0.normalized) }) { return .day }
        for t in kept where t.kind == .word {
            if isNameToken(t) { return .name }
        }
        let content = kept.filter { $0.kind == .word }
        if content.count == 1 { return .name }
        return .phrase
    }

    static let days: Set<String> = ["monday","tuesday","wednesday","thursday","friday","saturday","sunday"]

    // MARK: Scoped (subject, value) resolution

    func scopedReparandum(cue: Range<Int>, repair: [Int], tokens: [Token]) -> FoundRepair? {
        let repairNames = repair.filter { isNameToken(tokens[$0]) }.map { tokens[$0].normalized }
        guard !repairNames.isEmpty else { return nil }
        for name in repairNames {
            let leftWindow = contentRange(0 ..< cue.lowerBound, tokens: tokens)
            guard leftWindow.last(where: { tokens[$0].normalized == name }) != nil else { continue }
            guard let namePos = repair.first(where: { tokens[$0].normalized == name }) else { continue }
            // Subject mention inside repair is redundant; value follows it.
            let namePosInRepair = repair.firstIndex(of: namePos)!
            let redundant = Array(repair[..<namePosInRepair]) + [namePos]
            let afterName = Array(repair[(namePosInRepair + 1)...])
            let afterContent = afterName.filter { tokens[$0].kind == .word || tokens[$0].kind == .number }
            guard !afterContent.isEmpty else { continue }
            // Find subject's clause to the left and the compatible value in it.
            guard let subjIdx = leftWindow.last(where: { tokens[$0].normalized == name }) else { continue }
            let clause = clauseAround(subjIdx, tokens: tokens).filter { $0 < cue.lowerBound }
            let rtype = repairType(afterContent, tokens: tokens)
            let run: [Int]?
            switch rtype {
            case .number:
                run = nearestNumberRun(in: clause, tokens: tokens).map { Array($0) }
            case .day:
                run = nearestDayRun(in: clause, tokens: tokens).map { Array($0) }
            default:
                run = nearestContentWord(in: clause, tokens: tokens).map { Array($0) }
            }
            guard let rep = run else { continue }
            return FoundRepair(reparandum: rep, repair: repair, redundantInRepair: redundant, replacement: afterContent)
        }
        return nil
    }

    // MARK: Helpers

    func isPunct(_ t: Token) -> Bool { t.kind == .punctuation }
    func isSentenceBoundary(_ t: Token) -> Bool { t.kind == .punctuation && (t.text == "." || t.text == "?" || t.text == "!") }

    func ids(_ tokens: [Token], _ range: Range<Int>) -> [TokenID] {
        range.clamped(to: 0 ..< tokens.count).map { tokens[$0].id }
    }
    func ids(_ tokens: [Token], _ idxs: [Int]) -> [TokenID] {
        idxs.filter { $0 >= 0 && $0 < tokens.count }.map { tokens[$0].id }
    }

    func contentRange(_ range: Range<Int>, tokens: [Token]) -> [Int] {
        range.filter { $0 >= 0 && $0 < tokens.count && tokens[$0].kind != .punctuation }
    }

    func sentenceStart(before idx: Int, tokens: [Token]) -> Int {
        var i = idx - 1
        while i >= 0 {
            if isSentenceBoundary(tokens[i]) { return i + 1 }
            i -= 1
        }
        return 0
    }

    func sentenceEnd(after idx: Int, tokens: [Token]) -> Int {
        var i = idx
        while i < tokens.count {
            if isSentenceBoundary(tokens[i]) { return i + 1 }
            i += 1
        }
        return tokens.count
    }

    func clauseAround(_ idx: Int, tokens: [Token]) -> [Int] {
        var s = idx
        while s > 0 && !isSentenceBoundary(tokens[s-1]) && tokens[s-1].normalized != "and" && tokens[s-1].normalized != "but" { s -= 1 }
        var e = idx
        while e < tokens.count - 1 && !isSentenceBoundary(tokens[e+1]) && tokens[e+1].normalized != "and" && tokens[e+1].normalized != "but" { e += 1 }
        return contentRange(s ..< e + 1, tokens: tokens)
    }

    func clauseIndex(of idx: Int, tokens: [Token]) -> Int {
        tokens[0 ..< min(idx, tokens.count)].filter { isSentenceBoundary($0) }.count
    }

    func quotedRanges(tokens: [Token]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var open: Int?
        for (i, t) in tokens.enumerated() {
            if t.text == "\"" || t.text == "\u{201C}" || t.text == "\u{201D}" {
                if let o = open { ranges.append(o ..< i + 1); open = nil }
                else { open = i }
            }
        }
        return ranges
    }

    func containsNegation(_ tokens: [Token], _ idxs: [Int]) -> Bool {
        let neg: Set<String> = ["not", "never", "none", "nobody", "nothing", "neither", "nor", "don't", "doesn't", "didn't", "won't", "can't", "cannot"]
        return idxs.contains {
            let w = tokens[$0]
            if w.normalized == "no" && w.kind == .cue { return false } // repair cue, not negation
            return neg.contains(w.normalized) || w.normalized.hasSuffix("n't")
        }
    }

    func isMetaLanguage(_ tokens: [Token], _ idxs: [Int]) -> Bool {
        let meta: Set<String> = ["said", "say", "saying", "words", "word", "quoted", "quote", "literally", "spell", "spelled", "password"]
        return idxs.contains { meta.contains(tokens[$0].normalized) }
    }

    func isLiteralUse(_ tokens: [Token], _ idxs: [Int]) -> Bool {
        guard let first = idxs.first else { return false }
        var j = first - 1
        while j >= 0 && tokens[j].kind == .punctuation { j -= 1 }
        guard j >= 0 else { return false }
        return ["word", "words", "say", "said", "write", "spell"].contains(tokens[j].normalized)
    }

    func isNameToken(_ t: Token) -> Bool {
        guard t.kind == .word else { return false }
        if let f = t.text.first, f.isUppercase && t.text.count > 1 { return true }
        return false
    }

    func nearestNumberRun(in window: [Int], tokens: [Token]) -> Range<Int>? {
        var i = window.count - 1
        while i >= 0 {
            let ti = window[i]
            let t = tokens[ti]
            if t.kind == .number { return ti ..< ti + 1 }
            if NumberNormalizer.ones[t.normalized] != nil || NumberNormalizer.tens[t.normalized] != nil {
                var s = i
                while s - 1 >= 0 {
                    let p = tokens[window[s-1]].normalized
                    if NumberNormalizer.ones[p] != nil || NumberNormalizer.tens[p] != nil || NumberNormalizer.scales[p] != nil || p == "and" || p == "-" { s -= 1 } else { break }
                }
                return window[s] ..< window[i] + 1
            }
            i -= 1
        }
        return nil
    }

    func nearestDayRun(in window: [Int], tokens: [Token]) -> Range<Int>? {
        for ti in window.reversed() {
            if Self.days.contains(tokens[ti].normalized) { return ti ..< ti + 1 }
        }
        return nil
    }

    func nearestNameRun(in window: [Int], tokens: [Token], repair: [Int]) -> [Int]? {
        let repairNames = Set(repair.map { tokens[$0].normalized })
        for ti in window.reversed() {
            let t = tokens[ti]
            if t.kind != .word { continue }
            if isNameToken(t) && !repairNames.contains(t.normalized) { return [ti] }
        }
        let function: Set<String> = ["the","a","an","to","it","for","and","or","of","in","on","is","are","was","i","you","he","she","we","they","me","him","her","us","them","my","your","his","our","their","please","just","now","then","so","call","send","email","schedule","book","make","said","say"]
        for ti in window.reversed() {
            let t = tokens[ti]
            if t.kind == .word && !function.contains(t.normalized) && !repairNames.contains(t.normalized) { return [ti] }
        }
        return nil
    }

    func nearestContentWord(in window: [Int], tokens: [Token]) -> [Int]? {
        let skip: Set<String> = ["the","a","an","to","it","for","and","or","of","in","on","is","are","please"]
        for ti in window.reversed() {
            let t = tokens[ti]
            if (t.kind == .word || t.kind == .number) && !skip.contains(t.normalized) { return [ti] }
        }
        return nil
    }

    func carrierPrefix(reparandum: [Int], repair: [Int], tokens: [Token]) -> [Int]? {
        let repWords = Set(reparandum.map { tokens[$0].normalized })
        guard repair.count >= 2 else { return nil }
        let first = tokens[repair[0]].normalized
        let carriers: Set<String> = ["call", "send", "email", "text", "schedule", "book"]
        guard carriers.contains(first), repWords.contains(first) || true else { return nil }
        // Only treat as carrier when the same verb appears left of the cue.
        let leftHas = reparandum.contains { tokens[$0].normalized == first } ||
            (repair[0] > 0 && tokens[0 ..< repair[0]].contains(where: { $0.normalized == first && $0.kind == .word }))
        guard leftHas else { return nil }
        return [repair[0]]
    }

    func repairValueRange(after idx: Int, tokens: [Token]) -> Range<Int>? {
        var i = idx
        while i < tokens.count && tokens[i].kind == .punctuation { i += 1 }
        guard i < tokens.count else { return nil }
        if tokens[i].normalized == "the" && i + 1 < tokens.count && tokens[i+1].normalized == "original" {
            return nil
        }
        if tokens[i].kind == .number { return i ..< i + 1 }
        if tokens[i].kind == .word {
            var j = i
            while j < tokens.count && (NumberNormalizer.ones[tokens[j].normalized] != nil || NumberNormalizer.tens[tokens[j].normalized] != nil || NumberNormalizer.scales[tokens[j].normalized] != nil) { j += 1 }
            if j > i { return i ..< j }
            return i ..< i + 1
        }
        return nil
    }

    func normalizedValueText(_ slice: [Token]) -> String {
        slice.map { $0.text }.joined(separator: " ")
    }
    func normalizedValueText(_ tokens: [Token], _ idxs: [Int]) -> String {
        normalizedValueText(idxs.map { tokens[$0] })
    }

    func normEq(_ a: String, _ b: String) -> Bool {
        let trim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return a.lowercased().trimmingCharacters(in: trim)
            == b.lowercased().trimmingCharacters(in: trim)
    }

    func slotKey(for replacement: [Int], tokens: [Token], clauseIndex: Int) -> String {
        let rtype = repairType(replacement, tokens: tokens)
        switch rtype {
        case .number:
            if let subj = subjectHint(near: replacement.first ?? 0, tokens: tokens) { return "\(subj):number" }
            return "clause\(clauseIndex):number"
        case .day: return "clause\(clauseIndex):day"
        case .name: return "clause\(clauseIndex):name"
        case .phrase: return "clause\(clauseIndex):phrase"
        }
    }

    func subjectHint(near idx: Int, tokens: [Token]) -> String? {
        guard tokens.indices.contains(idx) else { return nil }
        let clause = clauseAround(idx, tokens: tokens)
        for ci in clause {
            if isNameToken(tokens[ci]) { return tokens[ci].normalized }
        }
        return nil
    }

    func latestCandidate(for slot: String, in list: [CorrectionCandidate]) -> CorrectionCandidate? {
        list.last(where: { $0.slotKey == slot })
    }
    func latestCandidate(in list: [CorrectionCandidate]) -> CorrectionCandidate? {
        list.last
    }

    func describe(_ tokens: [Token], _ idxs: [Int]) -> String {
        "'\(idxs.map { tokens[$0].text }.joined(separator: " "))'"
    }
}
