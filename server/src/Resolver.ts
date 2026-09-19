/**
 * Deterministic repair resolution — TypeScript port of OmilCore's
 * CorrectionResolver (omil-corr-1). Same semantics: repair values stay in
 * place; edits delete reparandum + cue + redundant restatements; keep-
 * reversals re-emit the selected value at the reverted position.
 *
 * Role in the hybrid: handles full restarts, keep-reversals, scoped
 * subject/value restatements, and structural mirroring deterministically.
 * Qwen proposes ordinary cue repairs; everything passes the same validator.
 */

import { ONES, TENS, SCALES, DAY_WORDS, isNameLike, repairKind, structuralSpan, type Token, type Snapshot, type ProposedEdit, type Abstention } from "./Cleanup"

export const RESOLVER_VERSION = "omil-ts-corr-1"

export interface CorrectionCandidate {
  candidateId: string
  slotKey: string
  valueText: string
  sourceTokenIds: string[]
  supersedes?: string
  editId: string
}

export interface Resolution {
  edits: ProposedEdit[]
  abstentions: Abstention[]
  candidates: CorrectionCandidate[]
}

const DAYS = DAY_WORDS
const CARRIERS = new Set(["call", "send", "email", "text", "schedule", "book"])
const FUNCTION = new Set(["the", "a", "an", "to", "it", "for", "and", "or", "of", "in", "on", "is", "are", "was", "i", "you", "he", "she", "we", "they", "me", "him", "her", "us", "them", "my", "your", "his", "our", "their", "please", "just", "now", "then", "so", "call", "send", "email", "schedule", "book", "make", "said", "say"])
const NEG = new Set(["not", "never", "none", "nobody", "nothing", "neither", "nor", "don't", "doesn't", "didn't", "won't", "can't", "cannot"])

type CueKind = "repair" | "keep" | "scratchThat"
interface CueSpan { range: [number, number]; label: string; kind: CueKind }

const uid = () => crypto.randomUUID()

export function resolve(snapshot: Snapshot, priorCandidates: CorrectionCandidate[] = []): Resolution {
  const tokens = snapshot.tokens
  const edits: ProposedEdit[] = []
  const abstentions: Abstention[] = []
  let candidates: CorrectionCandidate[] = priorCandidates.length === 0
    ? seedCandidates(snapshot)
    : [...priorCandidates]

  const quoted = quotedRanges(tokens)
  const isQuoted = (i: number) => quoted.some(([a, b]) => i >= a && i < b)

  // 1. Full restarts.
  for (const cue of findCueSpans(tokens, new Set<CueKind>(["scratchThat"]))) {
    if (rangeHas(cue.range, isQuoted)) continue
    const leftBound = sentenceStart(cue.range[0], tokens)
    const rightEnd = sentenceEnd(cue.range[1], tokens)
    const reparandum = contentRange(leftBound, cue.range[0], tokens)
    const repair = contentRange(cue.range[1], rightEnd, tokens)
    if (reparandum.length === 0 || repair.length === 0) {
      abstentions.push({ reason: "missingEvidence", detail: "scratch-that without full spans", tokenIds: ids(tokens, cue.range) })
      continue
    }
    if (containsNegation(tokens, reparandum) && !containsNegation(tokens, repair)) {
      abstentions.push({ reason: "protectedContent", detail: "restart would drop negation", tokenIds: ids(tokens, reparandum) })
      continue
    }
    const repairText = repair.map((i) => tokens[i].text).join(" ")
    const slot = slotKey(repair, tokens, 0)
    const editId = uid()
    const cand: CorrectionCandidate = {
      candidateId: uid(), slotKey: slot, valueText: repairText,
      sourceTokenIds: ids(tokens, repair),
      supersedes: latestFor(slot, candidates)?.candidateId, editId,
    }
    edits.push({
      editId, snapshotId: snapshot.id, op: "replaceFromSource",
      targetTokenIds: [...reparandum.map((i) => tokens[i].id), ...rangeIds(tokens, cue.range)],
      evidenceTokenIds: [...ids(tokens, repair), ...rangeIds(tokens, cue.range)],
      reason: "full restart via scratch-that", ruleVersion: RESOLVER_VERSION,
    })
    candidates.push(cand)
  }
  if (edits.length > 0) return { edits, abstentions, candidates }
  // 2. Ordinary cue repairs.
  const consumed = new Set<number>()
  for (const cue of findCueSpans(tokens, new Set<CueKind>(["repair"]))) {
    if (rangeHas(cue.range, isQuoted)) continue
    if (rangeHas(cue.range, (i) => consumed.has(i))) continue
    const lookahead = contentRange(cue.range[1], Math.min(cue.range[1] + 6, tokens.length), tokens)
    if (isMetaLanguage(tokens, lookahead)) {
      abstentions.push({ reason: "quotedContent", detail: "repair talks about words themselves", tokenIds: ids(tokens, cue.range) })
      continue
    }
    const found = findRepair(cue.range, tokens, consumed)
    if (!found) {
      abstentions.push({ reason: "weakCue", detail: "cue without compatible reparandum/repair", tokenIds: ids(tokens, cue.range) })
      continue
    }
    if (isLiteralUse(tokens, found.reparandum)) {
      abstentions.push({ reason: "quotedContent", detail: "literal word use", tokenIds: ids(tokens, found.reparandum) })
      continue
    }
    if (containsNegation(tokens, found.reparandum) && !containsNegation(tokens, found.repair)) {
      abstentions.push({ reason: "protectedContent", detail: "repair would drop negation", tokenIds: ids(tokens, found.reparandum) })
      continue
    }
    const valueText = found.replacement.map((i) => tokens[i].text).join(" ")
    const slot = slotKey(found.replacement, tokens, clauseIndex(found.reparandum[0] ?? 0, tokens))
    const prev = latestFor(slot, candidates)
    const editId = uid()
    const cand: CorrectionCandidate = {
      candidateId: uid(), slotKey: slot, valueText,
      sourceTokenIds: ids(tokens, found.replacement), supersedes: prev?.candidateId, editId,
    }
    edits.push({
      editId, snapshotId: snapshot.id, op: "replaceFromSource",
      targetTokenIds: [
        ...found.reparandum.map((i) => tokens[i].id),
        ...rangeIds(tokens, cue.range),
        ...found.redundantInRepair.map((i) => tokens[i].id),
      ],
      evidenceTokenIds: [...ids(tokens, found.repair), ...rangeIds(tokens, cue.range)],
      reason: `cue '${cue.label}'`, ruleVersion: RESOLVER_VERSION,
    })
    candidates.push(cand)
    for (const i of [...cueRange(cue.range), ...found.reparandum, ...found.replacement, ...found.redundantInRepair]) consumed.add(i)
  }

  // 3. Keep reversals.
  for (const cue of findCueSpans(tokens, new Set<CueKind>(["keep"]))) {
    if (rangeHas(cue.range, isQuoted)) continue
    if (cue.label === "go back") {
      abstentions.push({ reason: "ambiguousScope", detail: "go-back reference is ambiguous; preserved", tokenIds: ids(tokens, cue.range) })
      continue
    }
    // Absorb adjacent no/wait cues.
    let absorb = cue.range[0] - 1
    const absorbed: number[] = []
    for (;;) {
      if (absorb < 0) break
      if (tokens[absorb].kind === "punctuation") { absorb--; continue }
      if (tokens[absorb].kind === "cue" && (tokens[absorb].normalized === "no" || tokens[absorb].normalized === "wait") && !consumed.has(absorb)) {
        absorbed.push(absorb); absorb--; continue
      }
      break
    }
    if (rangeHas(cue.range, (i) => consumed.has(i))) continue
    const vr = repairValueRange(cue.range[1], tokens)
    const slotOfLatest = candidates.length > 0 ? candidates[candidates.length - 1].slotKey : undefined
    let selected: CorrectionCandidate | undefined
    let isNovel = false
    if (vr) {
      const vtext = vr.map((i) => tokens[i].text).join(" ")
      selected = [...candidates].reverse().find((c) => normEq(c.valueText, vtext))
      if (!selected && slotOfLatest) isNovel = true
    } else if (candidates.length > 0) {
      const latest = candidates[candidates.length - 1]
      selected = candidates.find((c) => c.slotKey === latest.slotKey)
    }
    if (isNovel && vr) {
      const slot = slotOfLatest ?? "clause0:number"
      const current = latestFor(slot, candidates)
      const curIdx = current ? current.sourceTokenIds.map((id) => tokens.findIndex((t) => t.id === id)).find((i) => i >= 0 && !consumed.has(i)) : undefined
      if (current !== undefined && curIdx !== undefined) {
        const editId = uid()
        const cand: CorrectionCandidate = {
          candidateId: uid(), slotKey: slot, valueText: vr.map((i) => tokens[i].text).join(" "),
          sourceTokenIds: ids(tokens, vr), supersedes: current.candidateId, editId,
        }
        edits.push({
          editId, snapshotId: snapshot.id, op: "replaceFromSource",
          targetTokenIds: [tokens[curIdx].id, ...rangeIds(tokens, cue.range), ...absorbed.map((i) => tokens[i].id)],
          evidenceTokenIds: [...ids(tokens, vr), ...rangeIds(tokens, cue.range)],
          reason: "keep-cue introduces novel value", ruleVersion: RESOLVER_VERSION,
        })
        candidates.push(cand)
        for (const i of vr) consumed.add(i)
        continue
      }
    }
    if (!selected) {
      abstentions.push({ reason: "missingEvidence", detail: "keep without candidate history", tokenIds: ids(tokens, cue.range) })
      continue
    }
    const latest = latestFor(selected.slotKey, candidates)
    const revertedIdxs = latest ? latest.sourceTokenIds.map((id) => tokens.findIndex((t) => t.id === id)).filter((i) => i >= 0).sort((a, b) => a - b) : []
    let targets = [...rangeIds(tokens, cue.range)]
    if (vr) {
      targets.push(...vr.map((i) => tokens[i].id))
      for (const i of vr) consumed.add(i)
    }
    targets.push(...absorbed.map((i) => tokens[i].id))
    for (const a of absorbed) consumed.add(a)
    let anchor: number | undefined
    if (revertedIdxs.length > 0) {
      targets.push(...revertedIdxs.map((i) => tokens[i].id))
      anchor = revertedIdxs[0]
    }
    const editId = uid()
    const newCand: CorrectionCandidate = {
      candidateId: uid(), slotKey: selected.slotKey, valueText: selected.valueText,
      sourceTokenIds: selected.sourceTokenIds,
      supersedes: latestFor(selected.slotKey, candidates)?.candidateId, editId,
    }
    edits.push({
      editId, snapshotId: snapshot.id, op: "selectCandidate",
      targetTokenIds: targets,
      evidenceTokenIds: [...selected.sourceTokenIds, ...rangeIds(tokens, cue.range)],
      candidateValue: selected.valueText,
      reason: `reversal to earlier candidate '${selected.valueText}'`, ruleVersion: RESOLVER_VERSION,
      replacementText: selected.valueText, replacementAnchor: anchor,
    })
    candidates.push(newCand)
    for (const i of [...cueRange(cue.range), ...revertedIdxs]) consumed.add(i)
  }

  return { edits, abstentions, candidates }
}

// --- seeds ---------------------------------------------------------------

function seedCandidates(snapshot: Snapshot): CorrectionCandidate[] {
  const tokens = snapshot.tokens
  const out: CorrectionCandidate[] = []
  let i = 0, clause = 0
  while (i < tokens.length) {
    const t = tokens[i]
    if (t.kind === "punctuation" && (t.text === "." || t.text === "?" || t.text === "!")) { clause++; i++; continue }
    if (t.kind === "number") {
      const subj = subjectHint(i, tokens)
      const slot = subj ? `${subj}:number` : `clause${clause}:number`
      if (!out.some((c) => c.slotKey === slot)) {
        out.push({ candidateId: uid(), slotKey: slot, valueText: t.text, sourceTokenIds: [t.id], editId: uid() })
      }
      i++; continue
    }
    if (t.kind === "word" && DAYS.has(t.normalized)) {
      const slot = `clause${clause}:day`
      if (!out.some((c) => c.slotKey === slot)) {
        out.push({ candidateId: uid(), slotKey: slot, valueText: t.text, sourceTokenIds: [t.id], editId: uid() })
      }
      i++; continue
    }
    if (t.kind === "word" && (t.normalized in ONES || t.normalized in TENS)) {
      let j = i + 1
      while (j < tokens.length && (tokens[j].normalized in ONES || tokens[j].normalized in TENS || tokens[j].normalized in SCALES)) j++
      const slot = `clause${clause}:number`
      if (!out.some((c) => c.slotKey === slot)) {
        out.push({
          candidateId: uid(), slotKey: slot,
          valueText: tokens.slice(i, j).map((x) => x.text).join(" "),
          sourceTokenIds: tokens.slice(i, j).map((x) => x.id), editId: uid(),
        })
      }
      i = j; continue
    }
    i++
  }
  return out
}

// --- cues -----------------------------------------------------------------

function findCueSpans(tokens: Token[], kinds: Set<CueKind>): CueSpan[] {
  const out: CueSpan[] = []
  const n = tokens.map((t) => t.normalized)
  const isCue = (k: number) => tokens[k].kind === "cue"
  let i = 0
  while (i < n.length) {
    if (kinds.has("scratchThat") && i + 1 < n.length && n[i] === "scratch" && n[i + 1] === "that" && isCue(i)) {
      out.push({ range: [i, i + 2], label: "scratch that", kind: "scratchThat" }); i += 2; continue
    }
    if (kinds.has("keep") && n[i] === "keep") {
      if (i + 2 < n.length && n[i + 1] === "the" && n[i + 2] === "original") {
        out.push({ range: [i, i + 3], label: "keep the original", kind: "keep" }); i += 3; continue
      }
      if (i + 1 < n.length && n[i + 1] === "it") {
        out.push({ range: [i, i + 2], label: "keep it", kind: "keep" }); i += 2; continue
      }
      out.push({ range: [i, i + 1], label: "keep", kind: "keep" }); i += 1; continue
    }
    if (kinds.has("keep") && i + 1 < n.length && n[i] === "go" && n[i + 1] === "back") {
      let end = i + 2
      while (end < n.length && !isSentence(tokens[end])) end++
      out.push({ range: [i, end], label: "go back", kind: "keep" }); i = end; continue
    }
    if (kinds.has("repair")) {
      if (i + 1 < n.length && n[i] === "i" && n[i + 1] === "mean" && isCue(i)) {
        out.push({ range: [i, i + 2], label: "i mean", kind: "repair" }); i += 2; continue
      }
      if (i + 1 < n.length && n[i] === "excuse" && n[i + 1] === "me") {
        out.push({ range: [i, i + 2], label: "excuse me", kind: "repair" }); i += 2; continue
      }
      if (n[i] === "sorry" && isCue(i)) { out.push({ range: [i, i + 1], label: "sorry", kind: "repair" }); i += 1; continue }
      if ((n[i] === "actually" || n[i] === "rather" || n[i] === "wait") && isCue(i)) {
        out.push({ range: [i, i + 1], label: n[i], kind: "repair" }); i += 1; continue
      }
      if (n[i] === "no" && tokens[i].kind === "cue") {
        let end = i + 1
        while (end < n.length && tokens[end].normalized === "no" && tokens[end].kind === "cue") end++
        let e2 = end
        while (e2 < n.length && isPunct(tokens[e2])) e2++
        if (e2 < n.length && tokens[e2].normalized === "no" && tokens[e2].kind === "cue") {
          end = e2 + 1
          while (end < n.length && tokens[end].normalized === "no") end++
        }
        out.push({ range: [i, end], label: "no", kind: "repair" }); i = end; continue
      }
    }
    i++
  }
  return out
}

// --- repair search ----------------------------------------------------------

interface FoundRepair { reparandum: number[]; repair: number[]; redundantInRepair: number[]; replacement: number[] }

type RepairType = "number" | "day" | "name" | "phrase"

function findRepair(cue: [number, number], tokens: Token[], consumed: Set<number>): FoundRepair | null {
  let rEnd = cue[1]
  while (rEnd < tokens.length && isPunct(tokens[rEnd])) rEnd++
  let rStop = rEnd
  while (rStop < tokens.length) {
    if (tokens[rStop].kind === "cue") break
    if (isSentence(tokens[rStop])) break
    if (consumed.has(rStop)) break
    rStop++
  }
  const repair = contentRange(rEnd, rStop, tokens)
  if (repair.length === 0) return null
  if (tokens[cue[0]].normalized === "wait" && repair.length <= 3 &&
      repair.some((i) => tokens[i].normalized === "keep")) return null

  const scoped = scopedReparandum(cue, repair, tokens)
  if (scoped) return scoped

  const rtype = repairType(repair, tokens)
  let lStart = cue[0] - 1
  while (lStart >= 0 && isPunct(tokens[lStart])) lStart--
  let lo = lStart
  while (lo >= 0) {
    if (isSentence(tokens[lo])) { lo++; break }
    if (tokens[lo].kind === "cue") { lo++; break }
    if (consumed.has(lo)) { lo++; break }
    lo--
  }
  lo = Math.max(0, lo)
  const window = contentRange(lo, cue[0], tokens).filter((i) => !consumed.has(i))
  if (window.length === 0) return null
  if (rtype === "number") {
    const run = nearestNumberRun(window, tokens)
    return run ? { reparandum: run, repair, redundantInRepair: [], replacement: repair } : null
  }
  if (rtype === "day") {
    const ti = [...window].reverse().find((t) => DAYS.has(tokens[t].normalized))
    return ti !== undefined ? { reparandum: [ti], repair, redundantInRepair: [], replacement: repair } : null
  }
  if (rtype === "name") {
    const run = nearestNameRun(window, tokens, repair)
    if (!run) return null
    let redundant: number[] = []
    let replacement = repair
    const carrier = carrierPrefix(run, repair, tokens)
    if (carrier) { redundant = carrier; replacement = repair.slice(carrier.length) }
    return { reparandum: run, repair, redundantInRepair: redundant, replacement }
  }
  // phrase: only via carrier alignment or structural mirroring
  if (repair.length <= 4 && repair.length > 0 && CARRIERS.has(tokens[repair[0]].normalized)) {
    if (window.some((i) => tokens[i].normalized === tokens[repair[0]].normalized)) {
      const run = nearestNameRun(window, tokens, repair)
      if (run) return { reparandum: run, repair, redundantInRepair: [repair[0]], replacement: repair.slice(1) }
    }
  }
  const aligned = structuralAlignment(repair, window, tokens)
  return aligned
}

function repairType(repair: number[], tokens: Token[]): RepairType {
  return repairKind(repair.map((i) => tokens[i]))
}

function scopedReparandum(cue: [number, number], repair: number[], tokens: Token[]): FoundRepair | null {
  const repairNames = repair.filter((i) => isNameToken(tokens[i])).map((i) => tokens[i].normalized)
  if (repairNames.length === 0) return null
  for (const name of repairNames) {
    const leftWindow = contentRange(0, cue[0], tokens)
    if (!leftWindow.some((i) => tokens[i].normalized === name)) continue
    const namePos = repair.find((i) => tokens[i].normalized === name)
    if (namePos === undefined) continue
    const posInRepair = repair.indexOf(namePos)
    const redundant = [...repair.slice(0, posInRepair), namePos]
    const afterName = repair.slice(posInRepair + 1)
    const afterContent = afterName.filter((i) => tokens[i].kind === "word" || tokens[i].kind === "number")
    if (afterContent.length === 0) continue
    const subjIdx = [...leftWindow].reverse().find((i) => tokens[i].normalized === name)
    if (subjIdx === undefined) continue
    const clause = clauseAround(subjIdx, tokens).filter((i) => i < cue[0])
    const rtype = repairType(afterContent, tokens)
    let run: number[] | null = null
    if (rtype === "number") run = nearestNumberRun(clause, tokens) as unknown as number[] | null
    else if (rtype === "day") {
      const ti = [...clause].reverse().find((i) => DAYS.has(tokens[i].normalized))
      run = ti !== undefined ? [ti] : null
    } else run = nearestContentWord(clause, tokens)
    if (!run) continue
    return { reparandum: run, repair, redundantInRepair: redundant, replacement: afterContent }
  }
  return null
}

function structuralAlignment(repair: number[], window: number[], tokens: Token[]): FoundRepair | null {
  const span = structuralSpan(repair, window, tokens)
  if (!span) return null
  return { reparandum: span, repair, redundantInRepair: [], replacement: repair }
}

// --- helpers ------------------------------------------------------------------

function isPunct(t: Token): boolean { return t.kind === "punctuation" }
function isSentence(t: Token): boolean { return t.kind === "punctuation" && (t.text === "." || t.text === "?" || t.text === "!") }

function ids(tokens: Token[], idxs: number[]): string[] {
  return idxs.filter((i) => i >= 0 && i < tokens.length).map((i) => tokens[i].id)
}
function rangeIds(tokens: Token[], r: [number, number]): string[] {
  const out: string[] = []
  for (let i = r[0]; i < r[1] && i < tokens.length; i++) if (i >= 0) out.push(tokens[i].id)
  return out
}
function cueRange(r: [number, number]): number[] {
  const out: number[] = []
  for (let i = r[0]; i < r[1]; i++) out.push(i)
  return out
}
function rangeHas(r: [number, number], pred: (i: number) => boolean): boolean {
  for (let i = r[0]; i < r[1]; i++) if (pred(i)) return true
  return false
}
function contentRange(lo: number, hi: number, tokens: Token[]): number[] {
  const out: number[] = []
  for (let i = lo; i < hi; i++) if (i >= 0 && i < tokens.length && tokens[i].kind !== "punctuation") out.push(i)
  return out
}
function sentenceStart(before: number, tokens: Token[]): number {
  let i = before - 1
  while (i >= 0) { if (isSentence(tokens[i])) return i + 1; i-- }
  return 0
}
function sentenceEnd(after: number, tokens: Token[]): number {
  let i = after
  while (i < tokens.length) { if (isSentence(tokens[i])) return i + 1; i++ }
  return tokens.length
}
function clauseAround(idx: number, tokens: Token[]): number[] {
  let s = idx
  while (s > 0 && !isSentence(tokens[s - 1]) && tokens[s - 1].normalized !== "and" && tokens[s - 1].normalized !== "but") s--
  let e = idx
  while (e < tokens.length - 1 && !isSentence(tokens[e + 1]) && tokens[e + 1].normalized !== "and" && tokens[e + 1].normalized !== "but") e++
  return contentRange(s, e + 1, tokens)
}
function clauseIndex(idx: number, tokens: Token[]): number {
  return tokens.slice(0, Math.min(idx, tokens.length)).filter(isSentence).length
}
function quotedRanges(tokens: Token[]): Array<[number, number]> {
  const ranges: Array<[number, number]> = []
  let open: number | null = null
  tokens.forEach((t, i) => {
    if (t.text === '"' || t.text === "\u201C" || t.text === "\u201D") {
      if (open !== null) { ranges.push([open, i + 1]); open = null }
      else open = i
    }
  })
  return ranges
}
function containsNegation(tokens: Token[], idxs: number[]): boolean {
  return idxs.some((i) => {
    const w = tokens[i]
    if (w.normalized === "no" && w.kind === "cue") return false
    return NEG.has(w.normalized) || w.normalized.endsWith("n't")
  })
}
const META = new Set(["said", "say", "saying", "words", "word", "quoted", "quote", "literally", "spell", "spelled", "password"])
function isMetaLanguage(tokens: Token[], idxs: number[]): boolean {
  return idxs.some((i) => META.has(tokens[i].normalized))
}
function isLiteralUse(tokens: Token[], idxs: number[]): boolean {
  if (idxs.length === 0) return false
  let j = idxs[0] - 1
  while (j >= 0 && tokens[j].kind === "punctuation") j--
  if (j < 0) return false
  return ["word", "words", "say", "said", "write", "spell"].includes(tokens[j].normalized)
}
function isNameToken(t: Token): boolean {
  return isNameLike(t)
}
function nearestNumberRun(window: number[], tokens: Token[]): number[] | null {
  let i = window.length - 1
  while (i >= 0) {
    const ti = window[i], t = tokens[ti]
    if (t.kind === "number") return [ti]
    if (t.normalized in ONES || t.normalized in TENS) {
      let s = i
      while (s - 1 >= 0) {
        const p = tokens[window[s - 1]].normalized
        if (p in ONES || p in TENS || p in SCALES || p === "and" || p === "-") s--
        else break
      }
      return window.slice(s, i + 1)
    }
    i--
  }
  return null
}
function nearestNameRun(window: number[], tokens: Token[], repair: number[]): number[] | null {
  const repairNames = new Set(repair.map((i) => tokens[i].normalized))
  for (const ti of [...window].reverse()) {
    const t = tokens[ti]
    if (t.kind !== "word") continue
    if (isNameToken(t) && !repairNames.has(t.normalized)) return [ti]
  }
  for (const ti of [...window].reverse()) {
    const t = tokens[ti]
    if (t.kind === "word" && !FUNCTION.has(t.normalized) && !repairNames.has(t.normalized)) return [ti]
  }
  return null
}
function nearestContentWord(window: number[], tokens: Token[]): number[] | null {
  const skip = new Set(["the", "a", "an", "to", "it", "for", "and", "or", "of", "in", "on", "is", "are", "please"])
  for (const ti of [...window].reverse()) {
    const t = tokens[ti]
    if ((t.kind === "word" || t.kind === "number") && !skip.has(t.normalized)) return [ti]
  }
  return null
}
function carrierPrefix(reparandum: number[], repair: number[], tokens: Token[]): number[] | null {
  if (repair.length < 2) return null
  const first = tokens[repair[0]].normalized
  if (!CARRIERS.has(first)) return null
  const leftHas = reparandum.some((i) => tokens[i].normalized === first) ||
    tokens.slice(0, repair[0]).some((t) => t.normalized === first && t.kind === "word")
  return leftHas ? [repair[0]] : null
}
function repairValueRange(after: number, tokens: Token[]): number[] | null {
  let i = after
  while (i < tokens.length && tokens[i].kind === "punctuation") i++
  if (i >= tokens.length) return null
  if (tokens[i].normalized === "the" && i + 1 < tokens.length && tokens[i + 1].normalized === "original") return null
  if (tokens[i].kind === "number") return [i]
  if (tokens[i].kind === "word") {
    let j = i
    while (j < tokens.length && (tokens[j].normalized in ONES || tokens[j].normalized in TENS || tokens[j].normalized in SCALES)) j++
    if (j > i) return tokens.slice(i, j).map((_, k) => i + k)
    return [i]
  }
  return null
}
function normEq(a: string, b: string): boolean {
  const trim = (s: string) => s.toLowerCase().replace(/^[\s\p{P}]+|[\s\p{P}]+$/gu, "")
  return trim(a) === trim(b)
}
function slotKey(replacement: number[], tokens: Token[], clause: number): string {
  const rt = repairType(replacement, tokens)
  if (rt === "number") {
    const subj = subjectHint(replacement[0] ?? 0, tokens)
    return subj ? `${subj}:number` : `clause${clause}:number`
  }
  if (rt === "day") return `clause${clause}:day`
  if (rt === "name") return `clause${clause}:name`
  return `clause${clause}:phrase`
}
function subjectHint(idx: number, tokens: Token[]): string | null {
  if (idx < 0 || idx >= tokens.length) return null
  for (const ci of clauseAround(idx, tokens)) {
    if (isNameToken(tokens[ci])) return tokens[ci].normalized
  }
  return null
}
function latestFor(slot: string, list: CorrectionCandidate[]): CorrectionCandidate | undefined {
  return [...list].reverse().find((c) => c.slotKey === slot)
}
