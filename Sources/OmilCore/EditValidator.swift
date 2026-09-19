import Foundation

// MARK: - EditValidator
//
// Every Clean-mode edit needs a valid source reference or an approved
// transformation, must pass scope checks, and must leave unaffected clauses
// intact. Validation is independent of proposal so rules, model proposals,
// and the hybrid are compared on equal terms.

public struct EditValidator: Sendable {
    private let numbers = NumberNormalizer()

    public init() {}

    public enum Verdict: Sendable {
        case accept
        case reject(reason: String)
    }

    /// Validate a batch in order. Later edits may depend on earlier ones via
    /// `dependsOn`; overlapping targets without a dependency are conflicts.
    public func validate(
        _ edits: [ProposedEdit],
        in snapshot: TranscriptSnapshot,
        dictionary: PersonalDictionary? = nil
    ) -> [(edit: ProposedEdit, verdict: Verdict)] {
        var results: [(ProposedEdit, Verdict)] = []
        var acceptedIds = Set<String>()
        var claimedTargets = Set<String>() // target rawValues claimed w/o sharing
        var acceptedById: [String: ProposedEdit] = [:]

        for edit in edits {
            let v = validateOne(
                edit, in: snapshot, dictionary: dictionary,
                acceptedIds: acceptedIds, acceptedById: acceptedById,
                claimedTargets: claimedTargets)
            switch v {
            case .accept:
                acceptedIds.insert(edit.editId.rawValue)
                acceptedById[edit.editId.rawValue] = edit
                for t in edit.targetTokenIds where !edit.dependsOn.isEmpty {
                    // Shared targets allowed through dependencies; still record.
                    claimedTargets.insert(t.rawValue)
                }
                for t in edit.targetTokenIds { claimedTargets.insert(t.rawValue) }
                results.append((edit, .accept))
            case .reject:
                results.append((edit, .reject(reason: "")))
                // Preserve the reason by re-validating? Instead store below.
                results[results.count - 1] = (edit, v)
            }
        }
        return results
    }

    func validateOne(
        _ edit: ProposedEdit, in snapshot: TranscriptSnapshot,
        dictionary: PersonalDictionary?,
        acceptedIds: Set<String>, acceptedById: [String: ProposedEdit],
        claimedTargets: Set<String>
    ) -> Verdict {
        // 1. Snapshot identity + revision (reject stale proposals).
        guard edit.snapshotId == snapshot.snapshotId else {
            return .reject(reason: "stale snapshot \(edit.snapshotId) vs \(snapshot.snapshotId)")
        }
        guard edit.snapshotRevision == snapshot.revision else {
            return .reject(reason: "stale revision \(edit.snapshotRevision) vs \(snapshot.revision)")
        }
        // 2. All targets exist.
        for t in edit.targetTokenIds {
            guard snapshot.token(id: t) != nil else {
                return .reject(reason: "unknown target token \(t)")
            }
        }
        // 3. Dependencies resolve to accepted edits.
        for d in edit.dependsOn {
            guard acceptedIds.contains(d.rawValue) else {
                return .reject(reason: "unsatisfied dependency \(d)")
            }
        }
        // 4. Conflicts: target already claimed by a non-dependency edit.
        if edit.dependsOn.isEmpty {
            for t in edit.targetTokenIds where claimedTargets.contains(t.rawValue) {
                return .reject(reason: "conflicting edit on token \(t)")
            }
        }
        // 5. Op-specific checks.
        switch edit.op {
        case .deleteFiller:
            return validateFillerDeletion(edit, in: snapshot)
        case .deleteRepeat:
            return validateRepeatDeletion(edit, in: snapshot)
        case .deleteCue:
            return .reject(reason: "standalone cue deletion is not allowed; cues are removed only with a validated repair")
        case .replaceFromSource:
            return validateReplacement(edit, in: snapshot)
        case .selectCandidate:
            return validateSelection(edit, in: snapshot)
        case .revertEdit:
            return .reject(reason: "revertEdit must reference an edit ID via candidate; unsupported")
        case .normalizeNumber:
            return validateNumberNormalization(edit, in: snapshot)
        case .normalizeDate, .punctuation:
            // Approved low-risk ops with source spans; accept when targets exist
            // and replacement is deterministic (checked by pipeline tests).
            return .accept
        case .formattingCommand:
            return validateFormatting(edit, in: snapshot)
        case .dictionarySubstitution:
            return validateDictionary(edit, in: snapshot, dictionary: dictionary)
        }
    }

    // MARK: Op checks

    func validateFillerDeletion(_ edit: ProposedEdit, in snapshot: TranscriptSnapshot) -> Verdict {
        let targets = edit.targetTokenIds.compactMap { snapshot.token(id: $0) }
        guard !targets.isEmpty else { return .reject(reason: "empty filler deletion") }
        // Single standalone filler, or the exact phrases "you know" / parenthetical "like".
        let words = targets.map { $0.normalized }
        if words == ["you", "know"] || words == ["like"] { return .accept }
        guard targets.count == 1, let t = targets.first else {
            return .reject(reason: "filler deletion must be a single token or an approved phrase")
        }
        if t.kind == .filler { return .accept }
        return .reject(reason: "'\(t.text)' is not a filler (kind \(t.kind))")
    }

    func validateRepeatDeletion(_ edit: ProposedEdit, in snapshot: TranscriptSnapshot) -> Verdict {
        guard edit.targetTokenIds.count == 1,
              let tid = edit.targetTokenIds.first,
              let idx = snapshot.indexOf(id: tid), idx > 0 else {
            return .reject(reason: "repeat deletion needs one target with a predecessor")
        }
        let a = snapshot.tokens[idx - 1], b = snapshot.tokens[idx]
        guard a.normalized == b.normalized else {
            return .reject(reason: "repeat targets are not identical ('\(a.text)' vs '\(b.text)')")
        }
        if a.normalized == "no" { return .reject(reason: "'no no' is a repair cue, not a repeat") }
        return .accept
    }

    func validateReplacement(_ edit: ProposedEdit, in snapshot: TranscriptSnapshot) -> Verdict {
        // Protected targets (numbers, negation, quoted) require evidence of a
        // compatible repair: evidence must name a non-empty source span.
        let targets = edit.targetTokenIds.compactMap { snapshot.token(id: $0) }
        let protected = targets.filter { $0.isProtected }
        if !protected.isEmpty {
            // Evidence must include cue or repair tokens distinct from targets.
            let targetSet = Set(edit.targetTokenIds)
            let externalEvidence = edit.evidenceTokenIds.filter { !targetSet.contains($0) }
                .compactMap { snapshot.token(id: $0) }
            guard !externalEvidence.isEmpty else {
                return .reject(reason: "protected targets \(protected.map { $0.text }) need repair evidence")
            }
            // Negation may only be touched when the repair also carries negation
            // in the same role; the resolver guarantees this, double-check here.
            let neg: Set<String> = ["not", "never", "none", "nobody", "nothing", "neither", "nor"]
            let targetNeg = targets.contains { neg.contains($0.normalized) || $0.normalized.hasSuffix("n't") }
            if targetNeg {
                let evNeg = externalEvidence.contains { neg.contains($0.normalized) || $0.normalized.hasSuffix("n't") }
                if !evNeg { return .reject(reason: "repair would drop negation") }
            }
        }
        // replacementText, when present (selectCandidate/normalization), must be
        // traceable: for replaceFromSource with nil replacement the value stays
        // in place (evidence span carries it). Non-nil replacement on
        // replaceFromSource is allowed only if it equals an evidence span's text
        // (case-insensitive) or a recomputable normalization.
        if let rep = edit.replacementText, edit.op == .replaceFromSource {
            let targetSet = Set(edit.targetTokenIds)
            let evTexts = edit.evidenceTokenIds.filter { !targetSet.contains($0) }
                .compactMap { snapshot.token(id: $0) }
            // Contiguous-run check: is rep the join of some contiguous evidence run?
            let evWords = evTexts.map { $0.text }
            let joined = evWords.joined(separator: " ")
            if joined.lowercased() == rep.lowercased() { return .accept }
            // Sliding window over evidence words.
            let repWords = rep.split(separator: " ").map(String.init)
            outer: for s in evWords.indices {
                for e in s ..< evWords.count {
                    let cand = evWords[s ... e].joined(separator: " ")
                    if cand.lowercased() == rep.lowercased() { return .accept }
                    if cand.count > rep.count + 8 { break outer }
                }
            }
            // Approved normalization of a target span?
            let targetWords = targets.map { $0.text.lowercased() }
            if let derived = numbers.derivedText(sourceWords: targetWords), derived == rep {
                return .accept
            }
            return .reject(reason: "replacement '\(rep)' is not grounded in an evidence span")
        }
        return .accept
    }

    func validateSelection(_ edit: ProposedEdit, in snapshot: TranscriptSnapshot) -> Verdict {
        // selectCandidate must name a candidate and carry its value; the value
        // must equal the cited candidate's value (checked by pipeline against
        // the journal) — here check structural presence.
        guard edit.candidateId != nil else {
            return .reject(reason: "selectCandidate without candidateId")
        }
        guard edit.replacementText != nil else {
            return .reject(reason: "selectCandidate without replacement value")
        }
        // Targets: keep-utterance tokens + reverted value tokens. At least the
        // keep cue must be present as evidence.
        guard !edit.evidenceTokenIds.isEmpty else {
            return .reject(reason: "selectCandidate without evidence")
        }
        return .accept
    }

    func validateNumberNormalization(_ edit: ProposedEdit, in snapshot: TranscriptSnapshot) -> Verdict {
        let targets = edit.targetTokenIds.compactMap { snapshot.token(id: $0) }
        guard !targets.isEmpty else { return .reject(reason: "empty normalization") }
        guard let rep = edit.replacementText else {
            return .reject(reason: "normalization without derived value")
        }
        let words = targets.map { $0.normalized }
        guard let derived = numbers.derivedText(sourceWords: words) else {
            return .reject(reason: "'\(words.joined(separator: " "))' is not a number phrase")
        }
        guard derived == rep else {
            return .reject(reason: "derived '\(derived)' != proposed '\(rep)'")
        }
        return .accept
    }

    func validateFormatting(_ edit: ProposedEdit, in snapshot: TranscriptSnapshot) -> Verdict {
        // Command words must be exactly the target span.
        let words = edit.targetTokenIds.compactMap { snapshot.token(id: $0)?.normalized }
        let cmds: Set<String> = ["new", "line", "paragraph", "bullet", "point"]
        guard !words.isEmpty, words.allSatisfy({ cmds.contains($0) }) else {
            return .reject(reason: "formatting targets are not command words")
        }
        return .accept
    }

    func validateDictionary(_ edit: ProposedEdit, in snapshot: TranscriptSnapshot, dictionary: PersonalDictionary?) -> Verdict {
        guard let dict = dictionary else {
            return .reject(reason: "no personal dictionary configured")
        }
        let words = edit.targetTokenIds.compactMap { snapshot.token(id: $0)?.text.lowercased() }
        let key = words.joined(separator: " ")
        guard let expected = dict.writtenForm(forSpoken: key) else {
            return .reject(reason: "'\(key)' has no confirmed dictionary entry")
        }
        guard edit.replacementText == expected else {
            return .reject(reason: "dictionary replacement must equal confirmed entry '\(expected)'")
        }
        return .accept
    }
}
