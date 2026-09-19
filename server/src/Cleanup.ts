/**
 * Cleanup pipeline (TypeScript mirror of OmilCore's deterministic engine).
 *
 * Qwen proposes repair edits as grounded JSON; everything is validated here:
 * source references, scope, negation, subject/value association, unaffected
 * clauses. Deterministic filler/repeat deletion + number normalization run
 * locally. Anything ungrounded is dropped and the wording is preserved.
 */

export type TokenKind = "word" | "number" | "punctuation" | "filler" | "cue"

export interface Token {
  id: string
  text: string
  normalized: string
  kind: TokenKind
  isProtected: boolean
}

export type EditOp =
  | "deleteFiller" | "deleteRepeat" | "replaceFromSource"
  | "selectCandidate" | "normalizeNumber" | "formattingCommand"
  | "dictionarySubstitution"

export interface ProposedEdit {
  editId: string
  snapshotId: string
  op: EditOp
  targetTokenIds: string[]
  evidenceTokenIds: string[]
  candidateValue?: string
  reason: string
  ruleVersion: string
  replacementText?: string
  /** token index where replacementText is emitted (selectCandidate reverts) */
  replacementAnchor?: number
}

export interface Abstention { reason: string; detail: string; tokenIds: string[] }

export const RULES_VERSION = "omil-ts-1"

// ---------------------------------------------------------------- tokenizer

const STANDALONE_FILLERS = new Set(["um", "uh", "er", "ah", "umm", "uhh", "emm", "hmm", "mm-hmm"])
const PROTECTED_WORDS = new Set(["not", "no", "never", "none", "nobody", "nothing", "neither", "nor"])

export function tokenize(text: string, snapshotId: string): Token[] {
  const tokens: Token[] = []
  const re = /[A-Za-z]+(?:'[A-Za-z]+)?|\d+(?:\.\d+)?|[^\s\w]/g
  let idx = 0
  for (const m of text.matchAll(re)) {
    const word = m[0]
    const lower = word.toLowerCase()
    let kind: TokenKind = "word"
    if (/\d/.test(word) && !/[A-Za-z]/.test(word)) kind = "number"
    else if (word.length === 1 && !/[A-Za-z0-9]/.test(word)) kind = "punctuation"
    else if (STANDALONE_FILLERS.has(lower)) kind = "filler"
    tokens.push({
      id: `${snapshotId.slice(0, 8)}-${idx}`,
      text: word, normalized: lower, kind,
      isProtected: PROTECTED_WORDS.has(lower) || kind === "number",
    })
    idx++
  }
  markCues(tokens)
  markQuoted(tokens)
  return tokens
}

const CUE_PHRASES: string[][] = [
  ["scratch", "that"], ["i", "mean"], ["excuse", "me"], ["my", "bad"],
  ["keep", "the", "original"], ["keep", "it"], ["keep"],
  ["sorry"], ["actually"], ["rather"], ["wait"],
]

function markCues(tokens: Token[]): void {
  const lowers = tokens.map((t) => t.normalized)
  const sorted = [...CUE_PHRASES].sort((a, b) => b.length - a.length)
  let i = 0
  while (i < tokens.length) {
    let matched = 0
    for (const phrase of sorted) {
      if (i + phrase.length > lowers.length) continue
      if (phrase.every((w, k) => lowers[i + k] === w)) {
        for (let k = i; k < i + phrase.length; k++) tokens[k].kind = "cue"
        matched = phrase.length
        break
      }
    }
    if (matched > 0) { i += matched; continue }
    if (lowers[i] === "no") {
      let p = i - 1
      while (p >= 0 && tokens[p].kind === "punctuation") p--
      const prevContent = p >= 0 && (tokens[p].kind === "word" || tokens[p].kind === "number" || tokens[p].kind === "cue")
      const nextContent = i + 1 < lowers.length && lowers[i + 1] !== "."
      if (prevContent && nextContent) { tokens[i].kind = "cue"; tokens[i].isProtected = false }
    }
    i++
  }
}

function markQuoted(tokens: Token[]): void {
  let inDouble = false
  for (const t of tokens) {
    if (t.text === '"' || t.text === "\u201C" || t.text === "\u201D") { inDouble = !inDouble; continue }
    if (inDouble) {
      if (t.kind === "cue" || t.kind === "filler") t.kind = "word"
      t.isProtected = true
    }
  }
}

// ---------------------------------------------------------------- numbers

const ONES: Record<string, number> = {
  zero: 0, one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10,
  eleven: 11, twelve: 12, thirteen: 13, fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17,
  eighteen: 18, nineteen: 19,
}
const TENS: Record<string, number> = {
  twenty: 20, thirty: 30, forty: 40, fifty: 50, sixty: 60, seventy: 70, eighty: 80, ninety: 90,
}
const SCALES: Record<string, number> = { hundred: 100, thousand: 1_000, million: 1_000_000 }

export function deriveNumber(words: string[]): string | null {
  const expanded: string[] = []
  for (const w of words) {
    if (w.includes("-")) expanded.push(...w.split("-").filter(Boolean))
    else expanded.push(w)
  }
  let total = 0, current = 0, used = false, consumed = 0
  for (const w of expanded) {
    if (w in ONES) { current += ONES[w]; used = true; consumed++ }
    else if (w in TENS) { current += TENS[w]; used = true; consumed++ }
    else if (w === "and" && used) { consumed++ }
    else if (w in SCALES) {
      if (current === 0) current = 1
      current *= SCALES[w]
      if (SCALES[w] >= 1000) { total += current; current = 0 }
      used = true; consumed++
    } else if (w === "-") { consumed++ }
    else break
  }
  if (!used || !(consumed === words.length || consumed >= words.length - 1)) return null
  const vocab = new Set([...Object.keys(ONES), ...Object.keys(TENS), ...Object.keys(SCALES), "and", "-"])
  for (const w of words) {
    const parts = w.includes("-") ? w.split("-").filter(Boolean) : [w]
    if (!parts.every((p) => vocab.has(p))) return null
  }
  return String(total + current)
}

const isNumWord = (w: string) => w in ONES || w in TENS || w in SCALES
export { ONES, TENS, SCALES, isNumWord }

export const DAY_WORDS = new Set(["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"])

export function isNameLike(t: Token): boolean {
  if (t.kind !== "word") return false
  const f = t.text[0]
  return !!f && f === f.toUpperCase() && f !== f.toLowerCase() && t.text.length > 1
}

export type RepairKind = "number" | "day" | "name" | "phrase"

/** Classify a repair span by its value type (mirrors OmilCore repairType). */
export function repairKind(span: Token[]): RepairKind {
  const first = span[0]
  if (first) {
    if (first.kind === "number") return "number"
    if (first.normalized in ONES || first.normalized in TENS) return "number"
  }
  if (span.length >= 2 && isNameLike(span[0])) {
    const sub = repairKind(span.slice(1))
    if (sub === "number" || sub === "day") return sub
  }
  if (span.some((t) => DAY_WORDS.has(t.normalized))) return "day"
  if (span.some((t) => t.kind === "word" && isNameLike(t))) return "name"
  if (span.filter((t) => t.kind === "word").length === 1) return "name"
  return "phrase"
}

/**
 * Subject scope: a repair that restates a subject ("actually Bob 24" after
 * "Send Alice 42 and Bob 21") may only replace a value inside that subject's
 * clause. Changing Alice's value would pass word-membership but destroy meaning.
 */
function checkSubjectScope(
  snap: Snapshot,
  edit: ProposedEdit,
  evIdx: number[],
  reparandum: Token[],
): { ok: true } | { ok: false; reason: string } {
  const tokens = snap.tokens
  const repNames = evIdx.map((i) => tokens[i]).filter(isNameLike).map((t) => t.normalized)
  if (repNames.length === 0) return { ok: true }
  const reparaIdx = new Set(
    reparandum.map((t) => tokens.findIndex((x) => x.id === t.id)),
  )
  const firstTarget = Math.min(...edit.targetTokenIds.map((id) => tokens.findIndex((t) => t.id === id)))
  for (const name of repNames) {
    const leftOcc = tokens
      .map((t, i) => i)
      .filter((i) => i < firstTarget && tokens[i].normalized === name)
    if (leftOcc.length === 0) continue
    const subj = leftOcc[leftOcc.length - 1]
    // Clause: expand to sentence/and/but boundaries.
    let s = subj
    while (s > 0 && !isSentenceTok(tokens[s - 1]) && tokens[s - 1].normalized !== "and" && tokens[s - 1].normalized !== "but") s--
    let e = subj
    while (e < tokens.length - 1 && !isSentenceTok(tokens[e + 1]) && tokens[e + 1].normalized !== "and" && tokens[e + 1].normalized !== "but") e++
    for (const ri of reparaIdx) {
      if (ri < s || ri > e) {
        return { ok: false, reason: `scope violation: reparandum outside '${name}' clause` }
      }
    }
  }
  return { ok: true }
}

function isSentenceTok(t: Token): boolean {
  return t.kind === "punctuation" && (t.text === "." || t.text === "?" || t.text === "!")
}

export const CARRIER_VERBS = new Set(["call", "send", "email", "text", "schedule", "book"])

/**
 * Structural mirror between two spans (no window needed): repair and
 * reparandum share an exact tail (2+ words) with one differing value word,
 * or a carrier verb + single differing value ("call Pam" vs "Sam").
 */
export function spansMirror(repair: Token[], repara: Token[]): boolean {
  const rw = repair.map((t) => t.normalized)
  const bw = repara.map((t) => t.normalized)
  const func = new Set(["the", "a", "an", "to", "it", "for", "and", "or", "of", "in", "on", "is", "are", "was", "i", "you", "please", "just", "no", "about", "with", "at"])
  // Full mirror: [newValue] + tail, tail shared, values differ.
  if (rw.length >= 3 && rw.length === bw.length && repair[0].kind === "word" && !func.has(rw[0])) {
    if (rw.slice(1).join(" ") === bw.slice(1).join(" ") && rw[0] !== bw[0]) return true
  }
  // Carrier mirror: "call Pam" replaces "Sam".
  if (rw.length >= 2 && CARRIER_VERBS.has(rw[0]) && bw.length === 1) {
    const val = repair[repair.length - 1]
    const tgt = repara[repara.length - 1]
    if (val && tgt && val.kind === "word" && (tgt.kind === "word" || tgt.kind === "number") &&
        val.normalized !== tgt.normalized) return true
  }
  return false
}

export function structuralSpan(repair: number[], window: number[], tokens: Token[]): number[] | null {
  if (repair.length < 3 || repair.length > 7) return null
  const rwords = repair.map((i) => tokens[i].normalized)
  const wwords = window.map((i) => tokens[i].normalized)
  const value = rwords[0]
  const func = new Set(["the", "a", "an", "to", "it", "for", "and", "or", "of", "in", "on", "is", "are", "was", "i", "you", "please", "just", "no", "about", "with", "at"])
  if (tokens[repair[0]].kind !== "word" || func.has(value)) return null
  for (let suffixLen = Math.min(4, repair.length - 1); suffixLen >= 2; suffixLen--) {
    if (repair.length !== suffixLen + 1) continue
    const tail = rwords.slice(1)
    for (let s = 0; s <= Math.max(0, wwords.length - tail.length); s++) {
      if (wwords.slice(s, s + tail.length).join(" ") !== tail.join(" ")) continue
      if (s < 1) continue
      const pred = window[s - 1]
      if (!(tokens[pred].kind === "word" || tokens[pred].kind === "number")) continue
      if (tokens[pred].normalized === value) continue
      return window.slice(s - 1, s + tail.length)
    }
  }
  return null
}

// ---------------------------------------------------------------- filler + repeat (deterministic)

export function fillerEdits(snapshotId: string, tokens: Token[]): { edits: ProposedEdit[]; abstentions: Abstention[] } {
  const edits: ProposedEdit[] = []
  const abstentions: Abstention[] = []
  const lowers = tokens.map((t) => t.normalized)
  const literalUse = (i: number): boolean => {
    let j = i - 1
    while (j >= 0 && tokens[j].kind === "punctuation") j--
    if (j < 0) return false
    return ["word", "words", "say", "said", "write", "spell", "term", "call"].includes(tokens[j].normalized)
  }
  tokens.forEach((t, i) => {
    if (t.kind !== "filler") return
    if (literalUse(i)) {
      abstentions.push({ reason: "quotedContent", detail: "filler used literally; preserved", tokenIds: [t.id] })
      return
    }
    edits.push({
      editId: crypto.randomUUID(), snapshotId, op: "deleteFiller",
      targetTokenIds: [t.id], evidenceTokenIds: [],
      reason: `standalone filler '${t.text}'`, ruleVersion: RULES_VERSION,
    })
  })
  for (let i = 0; i < tokens.length; i++) {
    if (i + 1 < tokens.length && lowers[i] === "you" && lowers[i + 1] === "know" &&
        tokens[i].kind === "word" && tokens[i + 1].kind === "word" && !literalUse(i)) {
      const leftP = i > 0 && tokens[i - 1].kind === "punctuation"
      const rightP = i + 2 < tokens.length && tokens[i + 2].kind === "punctuation"
      const after = i + 2 < lowers.length ? lowers[i + 2] : ""
      if ((leftP || rightP || i === 0 || i + 2 >= tokens.length) && !(i === 0 && ["what", "why", "how"].includes(after))) {
        edits.push({
          editId: crypto.randomUUID(), snapshotId, op: "deleteFiller",
          targetTokenIds: [tokens[i].id, tokens[i + 1].id], evidenceTokenIds: [],
          reason: "parenthetical 'you know'", ruleVersion: RULES_VERSION,
        })
      }
    }
    if (lowers[i] === "like" && tokens[i].kind === "word") {
      const leftP = i > 0 && tokens[i - 1].kind === "punctuation"
      const rightP = i + 1 < tokens.length && tokens[i + 1].kind === "punctuation"
      if (leftP && rightP) {
        edits.push({
          editId: crypto.randomUUID(), snapshotId, op: "deleteFiller",
          targetTokenIds: [tokens[i].id], evidenceTokenIds: [],
          reason: "parenthetical 'like'", ruleVersion: RULES_VERSION,
        })
      }
    }
  }
  const repeatable = new Set(["the", "a", "an", "to", "of", "and", "in", "on", "for", "is", "are", "was", "it", "that", "this", "i", "you", "we"])
  for (let i = 0; i < tokens.length - 1; i++) {
    const a = tokens[i], b = tokens[i + 1]
    if (a.normalized !== b.normalized || a.kind === "cue" || b.kind === "cue" || a.kind === "punctuation") continue
    if (a.normalized === "no") continue
    if (a.kind === "number" || repeatable.has(a.normalized)) {
      edits.push({
        editId: crypto.randomUUID(), snapshotId, op: "deleteRepeat",
        targetTokenIds: [b.id], evidenceTokenIds: [a.id],
        reason: `accidental repetition '${b.text}'`, ruleVersion: RULES_VERSION,
      })
    }
  }
  return { edits, abstentions }
}

// ---------------------------------------------------------------- validator

export interface Snapshot { id: string; revision: number; tokens: Token[] }

export function validateEdit(edit: ProposedEdit, snap: Snapshot, dictionary?: Record<string, string>): { ok: true } | { ok: false; reason: string } {
  if (edit.snapshotId !== snap.id) return { ok: false, reason: "stale snapshot" }
  const byId = new Map(snap.tokens.map((t) => [t.id, t]))
  for (const t of edit.targetTokenIds) {
    if (!byId.has(t)) return { ok: false, reason: `unknown target ${t}` }
  }
  const targets = edit.targetTokenIds.map((t) => byId.get(t)!)
  switch (edit.op) {
    case "deleteFiller": {
      const words = targets.map((t) => t.normalized)
      if (words.join(" ") === "you know" || words.join(" ") === "like") return { ok: true }
      if (targets.length === 1 && targets[0].kind === "filler") return { ok: true }
      return { ok: false, reason: `'${words.join(" ")}' is not a filler` }
    }
    case "deleteRepeat": {
      if (targets.length !== 1) return { ok: false, reason: "repeat deletion needs one target" }
      const idx = snap.tokens.findIndex((t) => t.id === targets[0].id)
      if (idx <= 0) return { ok: false, reason: "repeat target has no predecessor" }
      const a = snap.tokens[idx - 1], b = snap.tokens[idx]
      if (a.normalized !== b.normalized) return { ok: false, reason: "repeat targets differ" }
      if (a.normalized === "no") return { ok: false, reason: "'no no' is a cue, not a repeat" }
      return { ok: true }
    }
    case "replaceFromSource":
    case "selectCandidate": {
      const targetSet = new Set(edit.targetTokenIds)
      const evidence = edit.evidenceTokenIds.filter((t) => !targetSet.has(t)).map((t) => byId.get(t)).filter(Boolean) as Token[]
      const prot = targets.filter((t) => t.isProtected)
      if (prot.length > 0 && evidence.length === 0) {
        return { ok: false, reason: `protected targets need repair evidence` }
      }
      const NEG = new Set(["not", "never", "none", "nobody", "nothing", "neither", "nor"])
      const isNeg = (t: Token) => NEG.has(t.normalized) || t.normalized.endsWith("n't")
      if (targets.some(isNeg) && !evidence.some(isNeg)) {
        return { ok: false, reason: "repair would drop negation" }
      }
      if (edit.op === "selectCandidate") {
        if (!edit.candidateValue || !edit.replacementText) return { ok: false, reason: "selectCandidate needs value" }
        if (edit.replacementText !== edit.candidateValue) return { ok: false, reason: "selection value mismatch" }
        // The selected value must exist in the snapshot (an earlier value, not invented).
        const texts = snap.tokens.map((t) => t.text.toLowerCase())
        if (!texts.includes(edit.candidateValue.toLowerCase())) {
          return { ok: false, reason: "selected value has no source in snapshot" }
        }
        if (edit.replacementAnchor !== undefined &&
            (edit.replacementAnchor < 0 || edit.replacementAnchor >= snap.tokens.length)) {
          return { ok: false, reason: "selection anchor out of range" }
        }
        // Reversals target a keep utterance: at least one cue among targets.
        if (!targets.some((t) => t.kind === "cue")) {
          return { ok: false, reason: "reversal without keep cue" }
        }
        return { ok: true }
      }
      // Type compatibility between reparandum (non-cue targets) and repair
      // (evidence minus targets). Numbers replace numbers, days replace days;
      // phrases need an exact structural mirror.
      const reparandum = targets.filter((t) => t.kind !== "cue")
      const evIdx = evidence
        .map((t) => snap.tokens.findIndex((x) => x.id === t.id))
        .filter((i) => i >= 0).sort((a, b) => a - b)
      if (reparandum.length > 0 && evIdx.length > 0) {
        const repKind = repairKind(evIdx.map((i) => snap.tokens[i]))
        const reparaKind = repairKind(reparandum)
        const compatible =
          (repKind === "number" && reparaKind === "number") ||
          (repKind === "day" && reparaKind === "day") ||
          (repKind === "name" && reparaKind === "name") ||
          (repKind === "phrase" && (reparaKind === "phrase" || reparaKind === "name") &&
            spansMirror(evIdx.map((i) => snap.tokens[i]), reparandum))
        if (!compatible) {
          return { ok: false, reason: `type mismatch: ${reparaKind} reparandum vs ${repKind} repair` }
        }
        // Subject scope: a repair that restates a subject ("actually Bob 24")
        // may only replace a value inside that subject's clause.
        const scope = checkSubjectScope(snap, edit, evIdx, reparandum)
        if (!scope.ok) return scope
      }
      // replaceFromSource with a replacement must ground it in an evidence span.
      if (edit.replacementText) {
        const evWords = evidence.map((t) => t.text)
        const rep = edit.replacementText
        const joined = evWords.join(" ").toLowerCase()
        if (joined === rep.toLowerCase()) return { ok: true }
        const repWords = rep.split(" ")
        outer: for (let s = 0; s < evWords.length; s++) {
          for (let e = s; e < evWords.length; e++) {
            const cand = evWords.slice(s, e + 1).join(" ")
            if (cand.toLowerCase() === rep.toLowerCase()) return { ok: true }
            if (cand.length > rep.length + 8) break outer
          }
        }
        const derived = deriveNumber(targets.map((t) => t.text.toLowerCase()))
        if (derived === rep) return { ok: true }
        return { ok: false, reason: `replacement '${rep}' not grounded in evidence` }
      }
      return { ok: true }
    }
    case "normalizeNumber": {
      if (!edit.replacementText) return { ok: false, reason: "normalization without value" }
      const derived = deriveNumber(targets.map((t) => t.normalized))
      if (!derived) return { ok: false, reason: "not a number phrase" }
      if (derived !== edit.replacementText) return { ok: false, reason: "derived mismatch" }
      return { ok: true }
    }
    case "dictionarySubstitution": {
      if (!dictionary) return { ok: false, reason: "no dictionary" }
      const key = targets.map((t) => t.text.toLowerCase()).join(" ")
      const expected = dictionary[key]
      if (!expected) return { ok: false, reason: "no confirmed entry" }
      if (edit.replacementText !== expected) return { ok: false, reason: "must equal confirmed entry" }
      return { ok: true }
    }
    case "formattingCommand": {
      const cmds = new Set(["new", "line", "paragraph", "bullet", "point"])
      const words = targets.map((t) => t.normalized)
      if (words.length > 0 && words.every((w) => cmds.has(w))) return { ok: true }
      return { ok: false, reason: "not command words" }
    }
  }
}

// ---------------------------------------------------------------- render

export function render(snap: Snapshot, accepted: ProposedEdit[]): string {
  const tokens = snap.tokens
  const skipped = new Set(accepted.flatMap((e) => e.targetTokenIds))
  const skippedIdx = new Set<number>()
  const skippedKind = new Map<number, TokenKind>()
  tokens.forEach((t, i) => { if (skipped.has(t.id)) { skippedIdx.add(i); skippedKind.set(i, t.kind) } })
  const repairDeleted = new Set<number>()
  for (const e of accepted) {
    if (e.op === "replaceFromSource" || e.op === "selectCandidate") {
      for (const id of e.targetTokenIds) {
        const i = tokens.findIndex((t) => t.id === id)
        if (i >= 0) repairDeleted.add(i)
      }
    }
  }
  const sub = new Map<number, string>()
  const anchors = new Map<number, string>()
  for (const e of accepted) {
    const idxs = e.targetTokenIds
      .map((id) => tokens.findIndex((t) => t.id === id))
      .filter((i) => i >= 0).sort((a, b) => a - b)
    if ((e.op === "normalizeNumber" || e.op === "dictionarySubstitution" || e.op === "formattingCommand") && idxs.length > 0 && e.replacementText !== undefined) {
      sub.set(idxs[0], e.replacementText)
    }
    if (e.op === "selectCandidate" && e.replacementAnchor !== undefined && e.replacementText !== undefined) {
      anchors.set(e.replacementAnchor, e.replacementText)
    }
  }
  const drop = new Set<number>()
  tokens.forEach((t, i) => {
    if (t.kind !== "punctuation" || skippedIdx.has(i)) return
    const adj = [i - 1, i + 1].filter((j) => j >= 0 && j < tokens.length)
    if (t.text === ",") {
      const cueAdj = adj.some((j) => skippedIdx.has(j) && (skippedKind.get(j) === "cue" || skippedKind.get(j) === "filler"))
      if (cueAdj) drop.add(i)
    } else if (t.text === "." || t.text === "?" || t.text === "!") {
      const cueAdj = adj.some((j) => skippedIdx.has(j) && skippedKind.get(j) === "cue")
      const repAdj = adj.some((j) => repairDeleted.has(j))
      if (cueAdj || repAdj) drop.add(i)
    }
  })
  const parts: string[] = []
  let last = ""
  tokens.forEach((t, i) => {
    const a = anchors.get(i)
    if (a !== undefined) { parts.push(a); last = a; return }
    if (skippedIdx.has(i) && sub.get(i) === undefined) return
    if (drop.has(i)) return
    const s = sub.get(i)
    if (s !== undefined) { if (s !== "") { parts.push(s); last = s } return }
    if ((t.text === "." || t.text === "?" || t.text === "!") && (last === "." || last === "?" || last === "!")) return
    parts.push(t.text); last = t.text
  })
  return finishPunct(sentenceCase(join(parts)))
}

const isPunct = (s: string) => s.length === 1 && !/[A-Za-z0-9]/.test(s) && s !== "\n"

function join(parts: string[]): string {
  let out = ""
  let inQuote = false
  let suppress = false
  for (const p of parts) {
    if (p === "\n" || p === "\n\n" || p.startsWith("\n•")) { out += p; suppress = true; continue }
    if (p === '"' || p === "\u201C" || p === "\u201D") {
      if (inQuote) { out += p; inQuote = false; suppress = false }
      else {
        if (out !== "" && !out.endsWith(" ") && !out.endsWith("\n")) out += " "
        out += p; inQuote = true; suppress = true
      }
      continue
    }
    if (out === "" || out.endsWith("\n") || out.endsWith(" ") || suppress) { out += p; suppress = false; continue }
    out += isPunct(p) ? p : " " + p
    suppress = false
  }
  let s = out
  while (s.includes("  ")) s = s.replaceAll("  ", " ")
  s = s.replaceAll(", ,", ",").trim().replace(/^[,;:\s]+/, "")
  return s
}

function sentenceCase(s: string): string {
  let out = "", cap = true
  for (const ch of s) {
    if (cap && /[A-Za-z]/.test(ch)) { out += ch.toUpperCase(); cap = false }
    else out += ch
    if (".?!:\n".includes(ch)) cap = true
  }
  return out
}

function finishPunct(s: string): string {
  const t = s.trim()
  if (!t) return t
  if (".?!".includes(t[t.length - 1])) return t
  if ((t.endsWith('"') || t.endsWith("\u201D")) && ".?!".includes(t[t.length - 2] ?? "")) return t
  return t + "."
}

/** Every kept content token (or its approved derived value) appears in order. */
export function verifyPreservation(snap: Snapshot, accepted: ProposedEdit[], output: string): boolean {
  const skipped = new Set(accepted.flatMap((e) => e.targetTokenIds))
  const sub = new Map<string, string>()
  for (const e of accepted) {
    const idxs = e.targetTokenIds
      .map((id) => snap.tokens.findIndex((t) => t.id === id))
      .filter((i) => i >= 0).sort((a, b) => a - b)
    if ((e.op === "normalizeNumber" || e.op === "dictionarySubstitution") && idxs.length > 0 && e.replacementText) {
      sub.set(snap.tokens[idxs[0]].id, e.replacementText)
    } else if (e.op === "formattingCommand" && idxs.length > 0) {
      sub.set(snap.tokens[idxs[0]].id, "")
    } else if (e.op === "selectCandidate" && e.replacementAnchor !== undefined && e.replacementText) {
      sub.set(snap.tokens[e.replacementAnchor].id, e.replacementText)
    }
  }
  const expected: string[] = []
  for (const t of snap.tokens) {
    if (skipped.has(t.id) && !sub.has(t.id)) continue
    const s = sub.get(t.id)
    if (s !== undefined) { if (s !== "") expected.push(s.toLowerCase()); continue }
    if (t.kind === "word" || t.kind === "number") expected.push(t.text.toLowerCase())
  }
  const outWords = output.toLowerCase().replaceAll("\n", " ").split(/[^a-z0-9]+/).filter(Boolean)
  let oi = 0
  for (const e of expected) {
    for (const part of e.split(/[^a-z0-9]+/).filter(Boolean)) {
      let found = false
      while (oi < outWords.length) {
        if (outWords[oi] === part) { found = true; oi++; break }
        oi++
      }
      if (!found) return false
    }
  }
  return true
}

// ---------------------------------------------------------------- normalizations over kept tokens

export function numberEdits(snap: Snapshot, skipped: Set<string>): ProposedEdit[] {
  const out: ProposedEdit[] = []
  const order = snap.tokens.map((t, i) => i).filter((i) => !skipped.has(snap.tokens[i].id))
  let k = 0
  while (k < order.length) {
    const t = snap.tokens[order[k]]
    if (!(t.kind === "word" && isNumWord(t.normalized))) { k++; continue }
    const run = [order[k]]
    let j = k + 1
    while (j < order.length) {
      const nt = snap.tokens[order[j]]
      if (nt.kind === "punctuation" && nt.text === "-") {
        const after = j + 1 < order.length ? snap.tokens[order[j + 1]] : null
        if (after && after.kind === "word" && (after.normalized in ONES || after.normalized in TENS)) {
          run.push(order[j]); j++; continue
        }
        break
      }
      if (nt.kind === "word" && (isNumWord(nt.normalized) || nt.normalized === "and")) { run.push(order[j]); j++; continue }
      break
    }
    const words = run.map((i) => snap.tokens[i].normalized).filter((w) => w !== "-")
    if (words.length === 0 || (words.length === 1 && words[0] === "and")) { k = j; continue }
    if (words.length === 1 && words[0] === "one") {
      const prev = k > 0 ? snap.tokens[order[k - 1]].normalized : ""
      if (["the", "a", "an", "second", "first", "number", "version", "one"].includes(prev)) { k = j; continue }
    }
    const derived = deriveNumber(run.map((i) => snap.tokens[i].text.toLowerCase()))
    if (derived) {
      out.push({
        editId: crypto.randomUUID(), snapshotId: snap.id, op: "normalizeNumber",
        targetTokenIds: run.map((i) => snap.tokens[i].id), evidenceTokenIds: [],
        reason: `number normalization -> ${derived}`, ruleVersion: RULES_VERSION, replacementText: derived,
      })
    }
    k = j
  }
  return out
}
